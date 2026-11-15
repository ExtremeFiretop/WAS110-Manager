#!/bin/sh

###############################################################################
# WAS-110 management access for Asuswrt-Merlin
#
# One universal logic script registered with:
#   - wan-event
#   - nat-start
#   - firewall-start
#
# Commands:
#   install     Install/update script and hook registrations
#   apply       Apply the configuration immediately
#   status      Display configuration status
#   uninstall   Completely remove this installation
#
# Running with no argument defaults to "install".
# Hardened revision 2026-11-15: serialized, non-disruptive reconciliation.
###############################################################################

###############################################################################
# USER Configuration
###############################################################################

ONT_IP="192.168.11.1"

# Safety guard for this installation.  The management address must NEVER be
# installed on ppp0, the LAN bridge, or an unexpected WAN interface.
EXPECTED_ONT_IF="vlan4094"

###############################################################################
# SCRIPT Configuration (DO NOT TOUCH UNLESS SURE!)
###############################################################################

NAT_CHAIN="WAS110_NAT"
FORWARD_CHAIN="WAS110_FWD"
NAT_STAGE="WAS110_NAT_NEW"
FORWARD_STAGE="WAS110_FWD_NEW"
LOCK_DIR="/tmp/was110-manager.lock"
LOCK_WAIT_SECONDS=10
LOCK_HELD=0
CHANGED=0

# Detected dynamically at runtime.
LAN_IF=""
PRIMARY_SUBNET=""
ONT_IF=""
ONT_ALIAS_IP=""
ONT_PREFIX="24"

SCRIPT_PATH="/jffs/scripts/was110-manager.sh"
HOOK_DIR="/jffs/scripts"

BEGIN_MARKER="# BEGIN WAS110-MANAGER"
END_MARKER="# END WAS110-MANAGER"

TAG="was110-manager"

###############################################################################
# Logging
###############################################################################

log_msg() {
    logger -t "$TAG" "$*" 2>/dev/null || :
}

print_msg() {
    printf '%s\n' "$*"
    log_msg "$*"
}

###############################################################################
# Single-writer lock shared by install/apply/uninstall and all Merlin hooks.
# mkdir is atomic on the router filesystem, and requires no Entware/flock.
###############################################################################

release_lock() {
    local lock_owner
    if [ "$LOCK_HELD" = 1 ]; then
        # Only this PID may release the lock it acquired.
        if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
            rm -f "$LOCK_DIR/pid"
            rmdir "$LOCK_DIR" 2>/dev/null || :
        fi
        LOCK_HELD=0
    fi
}

acquire_lock() {
    local lock_attempt owner
    lock_attempt=0
    while [ "$lock_attempt" -le "$LOCK_WAIT_SECONDS" ]; do
        if (umask 077; mkdir "$LOCK_DIR" 2>/dev/null); then
            if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
                rmdir "$LOCK_DIR" 2>/dev/null || :
                log_msg 'ERROR: could not record lock owner'
                return 1
            fi
            LOCK_HELD=1
            trap 'release_lock' 0
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM
            return 0
        fi

        owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || :)"
        case "$owner" in
            ''|*[!0-9]*)
                # A different invocation may be between mkdir and PID write.
                # Only remove an empty, ownerless lock after the full timeout.
                if [ "$lock_attempt" -eq "$LOCK_WAIT_SECONDS" ]; then
                    rmdir "$LOCK_DIR" 2>/dev/null || :
                    if (umask 077; mkdir "$LOCK_DIR" 2>/dev/null); then
                        if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
                            rmdir "$LOCK_DIR" 2>/dev/null || :
                            return 1
                        fi
                        LOCK_HELD=1
                        trap 'release_lock' 0
                        trap 'exit 129' HUP
                        trap 'exit 130' INT
                        trap 'exit 143' TERM
                        return 0
                    fi
                fi
                ;;
            *)
                if ! kill -0 "$owner" 2>/dev/null; then
                    # Stale owner: re-check before removal, and fail closed
                    # if another process is already taking ownership.
                    if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$owner" ]; then
                        rm -f "$LOCK_DIR/pid"
                        if rmdir "$LOCK_DIR" 2>/dev/null; then
                            continue
                        fi
                    fi
                fi
                ;;
        esac
        [ "$lock_attempt" -lt "$LOCK_WAIT_SECONDS" ] || break
        lock_attempt=$((lock_attempt + 1))
        sleep 1
    done
    log_msg "DEFERRED: exclusive lock busy after ${LOCK_WAIT_SECONDS}s (owner=${owner:-unknown})"
    return 1
}

uptime_seconds() {
    awk -F. '{print $1; exit}' /proc/uptime 2>/dev/null
}

###############################################################################
# ONT management detection
###############################################################################

detect_ont_settings() {
    # Asuswrt stores the physical primary-WAN interface here. With PPPoE,
    # this is the underlying interface, not the logical ppp0 session.
    ONT_IF="$(nvram get wan0_ifname 2>/dev/null)"

    # Fallback for firmware variants that expose only wan_ifname.
    if [ -z "$ONT_IF" ]; then
        ONT_IF="$(nvram get wan_ifname 2>/dev/null)"
    fi

    # A PPP interface is not suitable for direct ONT management access.
    case "$ONT_IF" in
        ppp*)
            log_msg "Refusing logical WAN interface $ONT_IF"
            return 2
            ;;
    esac

    [ -n "$ONT_IF" ] || {
        log_msg "Could not determine the physical WAN interface"
        return 1
    }

    # Never silently move the management alias to an unexpected interface.
    # WAN firmware can temporarily expose a logical PPP device or a different
    # primary-WAN mapping while applying settings.
    if [ "$ONT_IF" != "$EXPECTED_ONT_IF" ]; then
        log_msg "Refusing WAN interface $ONT_IF (expected $EXPECTED_ONT_IF)"
        return 2
    fi
    ip link show "$ONT_IF" >/dev/null 2>&1 || {
        log_msg "Detected WAN interface $ONT_IF does not exist"
        return 1
    }

    # Use an address in the same /24 as the ONT. For the default ONT address
    # 192.168.11.1, this selects 192.168.11.2 for the router.
    ONT_ALIAS_IP="$(
        printf '%s\n' "$ONT_IP" |
        awk -F. '
            NF == 4 {
                host = ($4 == 2 ? 3 : 2)
                printf "%s.%s.%s.%s\n", $1, $2, $3, host
            }
        '
    )"

    [ -n "$ONT_ALIAS_IP" ] || {
        log_msg "Could not derive an ONT alias address from $ONT_IP"
        return 1
    }

    return 0
}

###############################################################################
# Primary LAN detection
###############################################################################

detect_primary_lan() {
    LAN_IF="$(nvram get lan_ifname 2>/dev/null)"

    # Standard Asuswrt primary LAN bridge fallback.
    [ -n "$LAN_IF" ] || LAN_IF="br0"

    ip link show "$LAN_IF" >/dev/null 2>&1 || {
        log_msg "Primary LAN interface $LAN_IF does not exist"
        return 1
    }

    # Prefer the directly connected IPv4 route for the primary LAN bridge.
    #
    # Example:
    # 192.168.50.0/24
    PRIMARY_SUBNET="$(
        ip -4 route show dev "$LAN_IF" proto kernel scope link 2>/dev/null |
        awk '
            $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
                print $1
                exit
            }
        '
    )"

    # Broader route lookup fallback for firmware variants that omit one of
    # the route attributes above.
    if [ -z "$PRIMARY_SUBNET" ]; then
        PRIMARY_SUBNET="$(
            ip -4 route show dev "$LAN_IF" 2>/dev/null |
            awk '
                $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
                    print $1
                    exit
                }
            '
        )"
    fi

    # Final fallback to the interface address and prefix.
    if [ -z "$PRIMARY_SUBNET" ]; then
        PRIMARY_SUBNET="$(
            ip -4 addr show dev "$LAN_IF" scope global 2>/dev/null |
            awk '
                $1 == "inet" {
                    print $2
                    exit
                }
            '
        )"
    fi

    [ -n "$PRIMARY_SUBNET" ] || {
        log_msg "Could not determine primary subnet on $LAN_IF"
        return 1
    }

    return 0
}

###############################################################################
# Runtime configuration
#
# The dedicated chains are owned by this script.  Correct chains are NEVER
# flushed.  On a genuine mismatch, populate a staging chain first, install
# its jump, then retire the old chain.  The old or new protection is therefore
# present throughout a normal repair, including interrupted repairs.
###############################################################################

ipt() {
    local table
    table="$1"
    shift
    case "$table" in
        nat) iptables -t nat "$@" ;;
        filter) iptables "$@" ;;
        *) return 2 ;;
    esac
}

chain_exists() {
    ipt "$1" -S "$2" >/dev/null 2>&1
}

# An existing alias with a different prefix is treated as a conflict, not
# overwritten during the WAN's PPP negotiation.
ensure_address() {
    local all_aliases
    ip link show "$ONT_IF" >/dev/null 2>&1 || return 1
    all_aliases="$(ip -4 addr show dev "$ONT_IF" 2>/dev/null)" || return 1

    if printf '%s\n' "$all_aliases" | awk -v want="$ONT_ALIAS_IP/$ONT_PREFIX" '
        $1 == "inet" && $2 == want {found=1}
        END {exit !found}
    '; then
        return 0
    fi
    if printf '%s\n' "$all_aliases" | awk -v ip="$ONT_ALIAS_IP" '
        $1 == "inet" {split($2,parts,"/"); if (parts[1] == ip) found=1}
        END {exit !found}
    '; then
        log_msg "ERROR: alias $ONT_ALIAS_IP already exists with unexpected prefix on $ONT_IF"
        return 2
    fi

    # Add only when absent; do not churn the kernel address/route state.
    ip addr add "$ONT_ALIAS_IP/$ONT_PREFIX" dev "$ONT_IF" >/dev/null 2>&1 || {
        log_msg "ERROR: could not add $ONT_ALIAS_IP/$ONT_PREFIX to $ONT_IF"
        return 1
    }
    CHANGED=1
    log_msg "Management alias added: $ONT_ALIAS_IP/$ONT_PREFIX dev $ONT_IF"
    return 0
}

# Ensure a jump is the FIRST rule and appears exactly once.  If it already
# is, no iptables write is made.  Duplicate removals use rule numbers in
# descending order, preserving the first/top jump throughout.
ensure_parent_jump() {
    local table parent target first extra index
    table="$1" parent="$2" target="$3"
    first="$(ipt "$table" -S "$parent" 2>/dev/null | awk -v p="$parent" -v t="$target" '
        $1 == "-A" && $2 == p {
            if (NF == 4 && $3 == "-j" && $4 == t) print "yes"
            else print "no"
            exit
        }')" || return 1

    if [ "$first" != yes ]; then
        ipt "$table" -I "$parent" 1 -j "$target" || return 1
        CHANGED=1
    fi

    extra="$(ipt "$table" -S "$parent" 2>/dev/null | awk -v p="$parent" -v t="$target" '
        $1 == "-A" && $2 == p {
            n++
            if (n > 1 && NF == 4 && $3 == "-j" && $4 == t) print n
        }' | sort -rn)" || return 1
    for index in $extra; do
        ipt "$table" -D "$parent" "$index" || return 1
        CHANGED=1
    done
    ipt "$table" -C "$parent" -j "$target" >/dev/null 2>&1
}

remove_parent_jumps() {
    local table parent target iterations
    table="$1" parent="$2" target="$3"
    iterations=0
    while ipt "$table" -C "$parent" -j "$target" >/dev/null 2>&1; do
        ipt "$table" -D "$parent" -j "$target" || return 1
        iterations=$((iterations + 1))
        [ "$iterations" -le 64 ] || {
            log_msg "ERROR: too many parent jumps to $target; refusing continued changes"
            return 1
        }
    done
}

# Matches complete membership plus the required order of the two ACCEPT
# rules followed by two DROP rules.  -C handles iptables serialization
# differences such as explicit /32 masks and conntrack option rendering.
chain_rules_valid() {
    local table chain count sequence
    table="$1" chain="$2"
    chain_exists "$table" "$chain" || return 1
    count="$(ipt "$table" -S "$chain" 2>/dev/null | awk -v c="$chain" '$1 == "-A" && $2 == c {n++} END {print n+0}')" || return 1

    if [ "$table" = nat ]; then
        [ "$count" -eq 1 ] || return 1
        ipt nat -C "$chain" -s "$PRIMARY_SUBNET" -d "$ONT_IP/32" \
            -o "$ONT_IF" -j SNAT --to-source "$ONT_ALIAS_IP" >/dev/null 2>&1
    else
        [ "$count" -eq 4 ] || return 1
        sequence="$(ipt filter -S "$chain" 2>/dev/null | awk -v c="$chain" '
            $1 == "-A" && $2 == c {
                for (i=3;i<=NF;i++) if ($i == "-j") {printf "%s%s",(n++ ? " " : ""),$(i+1); break}
            }
        ')" || return 1
        [ "$sequence" = 'ACCEPT ACCEPT DROP DROP' ] || return 1
        ipt filter -C "$chain" -i "$LAN_IF" -s "$PRIMARY_SUBNET" \
            -d "$ONT_IP/32" -o "$ONT_IF" -j ACCEPT >/dev/null 2>&1 &&
        ipt filter -C "$chain" -i "$ONT_IF" -s "$ONT_IP/32" \
            -d "$PRIMARY_SUBNET" -o "$LAN_IF" \
            -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 &&
        ipt filter -C "$chain" -d "$ONT_IP/32" -j DROP >/dev/null 2>&1 &&
        ipt filter -C "$chain" -s "$ONT_IP/32" -j DROP >/dev/null 2>&1
    fi
}

append_chain_rules() {
    local table chain
    table="$1" chain="$2"
    if [ "$table" = nat ]; then
        ipt nat -A "$chain" -s "$PRIMARY_SUBNET" -d "$ONT_IP/32" \
            -o "$ONT_IF" -j SNAT --to-source "$ONT_ALIAS_IP"
    else
        ipt filter -A "$chain" -i "$LAN_IF" -s "$PRIMARY_SUBNET" \
            -d "$ONT_IP/32" -o "$ONT_IF" -j ACCEPT &&
        ipt filter -A "$chain" -i "$ONT_IF" -s "$ONT_IP/32" \
            -d "$PRIMARY_SUBNET" -o "$LAN_IF" \
            -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &&
        ipt filter -A "$chain" -d "$ONT_IP/32" -j DROP &&
        ipt filter -A "$chain" -s "$ONT_IP/32" -j DROP
    fi
}

# Clean only a detached staging chain after verifying table-wide references.
# Never flush a chain whose jump may still be in use.
cleanup_orphan_stage() {
    local table stage all_rules references_rc
    table="$1" stage="$2"
    chain_exists "$table" "$stage" || return 0
    all_rules="$(ipt "$table" -S 2>/dev/null)" || return 1
    if printf '%s\n' "$all_rules" | awk -v t="$stage" '
        $1 == "-A" {
            for (i=3;i<NF;i++) if ($i == "-j" && $(i+1) == t) found=1
        }
        END {exit !found}
    '; then
        log_msg "ERROR: staging chain $stage still referenced; leaving intact"
        return 1
    fi
    ipt "$table" -F "$stage" && ipt "$table" -X "$stage" || return 1
    CHANGED=1
    log_msg "Removed detached staging chain $stage"
}

ensure_chain() {
    local table parent live stage
    table="$1" parent="$2" live="$3" stage="$4"

    if chain_rules_valid "$table" "$live"; then
        # If an interrupted repair left a staged jump behind, restore the
        # known-good live chain to priority before removing that jump.
        ensure_parent_jump "$table" "$parent" "$live" || return 1
        if chain_exists "$table" "$stage"; then
            if ipt "$table" -C "$parent" -j "$stage" >/dev/null 2>&1; then
                remove_parent_jumps "$table" "$parent" "$stage" || return 1
                CHANGED=1
                log_msg "Recovered stale $table staging jump, retained verified $live"
            fi
            cleanup_orphan_stage "$table" "$stage" || return 1
        fi
        return 0
    fi

    if chain_exists "$table" "$stage" && ! chain_rules_valid "$table" "$stage"; then
        cleanup_orphan_stage "$table" "$stage" || {
            log_msg "ERROR: unexpected referenced staging chain $stage; refusing unsafe rebuild"
            return 1
        }
    fi
    if chain_exists "$table" "$stage"; then
        # Recover a verified, interrupted staged swap without flushing its
        # still-referenced rules.
        log_msg "Resuming verified staged $table chain $stage"
    else
        ipt "$table" -N "$stage" || return 1
        if ! append_chain_rules "$table" "$stage"; then
            ipt "$table" -F "$stage" >/dev/null 2>&1 || :
            ipt "$table" -X "$stage" >/dev/null 2>&1 || :
            return 1
        fi
        chain_rules_valid "$table" "$stage" || return 1
    fi

    # Stage first, so WAN management filtering is never absent during swap.
    ensure_parent_jump "$table" "$parent" "$stage" || return 1
    remove_parent_jumps "$table" "$parent" "$live" || return 1
    if chain_exists "$table" "$live"; then
        ipt "$table" -F "$live" || return 1
        ipt "$table" -X "$live" || return 1
    fi
    ipt "$table" -E "$stage" "$live" || return 1
    ensure_parent_jump "$table" "$parent" "$live" || return 1
    CHANGED=1
    log_msg "Installed verified $table chain $live via prepopulated staging"
}

apply_all() {
    local attempt step_rc
    attempt=1
    while [ "$attempt" -le 5 ]; do
        # Hard configuration conflicts are not boot-time transient failures.
        if detect_ont_settings; then
            step_rc=0
        else
            step_rc=$?
        fi
        if [ "$step_rc" -eq 2 ]; then break; fi
        if [ "$step_rc" -eq 0 ] && detect_primary_lan &&
           [ "$LAN_IF" != "$ONT_IF" ]; then
            if ensure_address; then
                step_rc=0
            else
                step_rc=$?
            fi
            if [ "$step_rc" -eq 2 ]; then break; fi
            if [ "$step_rc" -eq 0 ] &&
               ensure_chain filter FORWARD "$FORWARD_CHAIN" "$FORWARD_STAGE" &&
               ensure_chain nat POSTROUTING "$NAT_CHAIN" "$NAT_STAGE"; then
                log_msg "Configuration verified: LAN=$LAN_IF subnet=$PRIMARY_SUBNET ONT=$ONT_IF result=$([ "$CHANGED" = 1 ] && printf repaired || printf unchanged)"
                return 0
            fi
        fi
        [ "$attempt" -lt 5 ] || break
        attempt=$((attempt + 1))
        sleep 2
    done
    log_msg 'ERROR: configuration could not be verified after five attempts'
    return 1
}

apply_with_lock() {
    local action start_seconds end_seconds duration rc
    action="$1"
    acquire_lock || return 1
    CHANGED=0
    start_seconds="$(uptime_seconds)"
    log_msg "Apply begin: source=$action pid=$$"
    if apply_all; then
        rc=0
    else
        rc=$?
    fi
    end_seconds="$(uptime_seconds)"
    case "$start_seconds:$end_seconds" in
        *[!0-9:]*|:*|*:) duration='unknown' ;;
        *) duration=$((end_seconds - start_seconds)) ;;
    esac
    log_msg "Apply end: source=$action pid=$$ result=$rc duration=${duration}s"
    release_lock
    return "$rc"
}

###############################################################################
# Hook installation and removal
###############################################################################

install_hook() {
    hook_name="$1"
    hook_file="$HOOK_DIR/$hook_name"

    # Create the hook file only when it does not already exist.
    if [ ! -e "$hook_file" ]; then
        printf '%s\n' '#!/bin/sh' > "$hook_file" || return 1
    fi

    chmod 755 "$hook_file"

    # Add only one marked dispatcher block.
    if ! grep -Fq "$BEGIN_MARKER" "$hook_file"; then
        {
            printf '\n%s\n' "$BEGIN_MARKER"
            printf '"%s" hook %s "$@"\n' \
                "$SCRIPT_PATH" "$hook_name"
            printf '%s\n' "$END_MARKER"
        } >> "$hook_file" || return 1
    fi

    return 0
}

remove_hook() {
    hook_name="$1"
    hook_file="$HOOK_DIR/$hook_name"

    [ -f "$hook_file" ] || return 0

    # Remove only the block belonging to this installation.
    sed -i \
        "/^${BEGIN_MARKER}$/,/^${END_MARKER}$/d" \
        "$hook_file"

    # Remove blank lines left at the end.
    while [ -s "$hook_file" ] &&
          [ -z "$(tail -n 1 "$hook_file")" ]; do
        sed -i '$d' "$hook_file"
    done

    # Delete the hook file only when nothing remains except its shebang and
    # blank lines. Any unrelated hook commands are preserved.
    if ! grep -vE \
        '^[[:space:]]*$|^#!/bin/sh$' \
        "$hook_file" | grep -q .; then

        rm -f "$hook_file"
    fi
}

###############################################################################
# Runtime removal
###############################################################################

remove_runtime_configuration() {
    # Remove every jump belonging to this installation's NAT chain.
    while iptables -t nat -C POSTROUTING \
        -j "$NAT_CHAIN" 2>/dev/null; do

        iptables -t nat -D POSTROUTING \
            -j "$NAT_CHAIN" || break
    done

    # Also remove any staging jump left by an interrupted hot swap.
    while iptables -t nat -C POSTROUTING -j "$NAT_STAGE" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$NAT_STAGE" || break
    done

    # Remove this installation's NAT chain and any detached staging chain.
    iptables -t nat -F "$NAT_STAGE" 2>/dev/null || true
    iptables -t nat -X "$NAT_STAGE" 2>/dev/null || true
    iptables -t nat -F "$NAT_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$NAT_CHAIN" 2>/dev/null || true

    # Remove every jump belonging to this installation's forwarding chain.
    while iptables -C FORWARD \
        -j "$FORWARD_CHAIN" 2>/dev/null; do

        iptables -D FORWARD \
            -j "$FORWARD_CHAIN" || break
    done

    # Also remove any staging jump left by an interrupted hot swap.
    while iptables -C FORWARD -j "$FORWARD_STAGE" 2>/dev/null; do
        iptables -D FORWARD -j "$FORWARD_STAGE" || break
    done

    # Remove this installation's forwarding chain and detached staging chain.
    iptables -F "$FORWARD_STAGE" 2>/dev/null || true
    iptables -X "$FORWARD_STAGE" 2>/dev/null || true
    iptables -F "$FORWARD_CHAIN" 2>/dev/null || true
    iptables -X "$FORWARD_CHAIN" 2>/dev/null || true

    # Remove the management address created by this installation.
    if [ -n "$ONT_IF" ] && [ -n "$ONT_ALIAS_IP" ]; then
        ip addr del \
            "$ONT_ALIAS_IP/$ONT_PREFIX" \
            dev "$ONT_IF" 2>/dev/null || true
    fi
}

###############################################################################
# Installation
###############################################################################

install_self() {
    self_path="$(readlink -f "$0" 2>/dev/null)"
    [ -n "$self_path" ] || self_path="$0"

    target_path="$(readlink -f "$SCRIPT_PATH" 2>/dev/null)"
    [ -n "$target_path" ] || target_path="$SCRIPT_PATH"

    acquire_lock || return 1
    chmod 755 "$SCRIPT_PATH" || return 1

    # All three Merlin event points call the same universal script.
    install_hook wan-event || return 1
    install_hook nat-start || return 1
    install_hook firewall-start || return 1

    # Apply immediately; no reboot is required.
    CHANGED=0
    apply_all || {
        print_msg \
            "Installed, but the runtime configuration could not yet be applied."
        print_msg \
            "It will be retried automatically by the Merlin hooks."
        return 1
    }

    print_msg "WAS-110 manager installed."
    print_msg "Universal script: $SCRIPT_PATH"
    print_msg "Primary LAN interface: $LAN_IF"
    print_msg "Authorized primary subnet: $PRIMARY_SUBNET"
    print_msg "WAS-110 WebUI: https://$ONT_IP/"

    if [ "$(nvram get jffs2_scripts 2>/dev/null)" != "1" ]; then
        print_msg \
            "WARNING: Enable JFFS custom scripts and configs under Administration > System."
    fi

    return 0
}

###############################################################################
# Uninstallation
###############################################################################

uninstall_all() {
    acquire_lock || return 1
    detect_ont_settings >/dev/null 2>&1 || true

    remove_hook wan-event
    remove_hook nat-start
    remove_hook firewall-start

    remove_runtime_configuration

    print_msg "WAS-110 manager completely uninstalled."
    print_msg "Its hooks, chains, rules, address, and files were removed."

    # Delete this installed universal script.
    rm -f "$SCRIPT_PATH"

    return 0
}

###############################################################################
# Status
###############################################################################

show_status() {
    if detect_ont_settings; then
        printf '%-27s %s\n' "ONT interface:" "$ONT_IF"
        printf '%-27s %s\n' "ONT address:" "$ONT_IP"
        printf '%-27s %s\n' "Router ONT address:" "$ONT_ALIAS_IP/$ONT_PREFIX"
    else
        printf '%-27s %s\n' "ONT detection:" "failed"
    fi

    if detect_primary_lan; then
        printf '%-27s %s\n' "Primary LAN interface:" "$LAN_IF"
        printf '%-27s %s\n' "Primary LAN subnet:" "$PRIMARY_SUBNET"
    else
        printf '%-27s %s\n' "Primary LAN detection:" "failed"
    fi

    if [ -x "$SCRIPT_PATH" ]; then
        printf '%-27s %s\n' "Universal script:" "installed"
    else
        printf '%-27s %s\n' "Universal script:" "missing"
    fi

    for hook_name in wan-event nat-start firewall-start; do
        hook_file="$HOOK_DIR/$hook_name"

        if [ -f "$hook_file" ] &&
           grep -Fq "$BEGIN_MARKER" "$hook_file"; then

            printf '%-27s %s\n' "$hook_name hook:" "installed"
        else
            printf '%-27s %s\n' "$hook_name hook:" "missing"
        fi
    done

    if ip -4 addr show dev "$ONT_IF" 2>/dev/null |
       grep -Fq "inet $ONT_ALIAS_IP/$ONT_PREFIX "; then

        printf '%-27s %s\n' "Management address:" "present"
    else
        printf '%-27s %s\n' "Management address:" "missing"
    fi

    if iptables -t nat -L "$NAT_CHAIN" \
        -n >/dev/null 2>&1; then

        printf '%-27s %s\n' "NAT chain:" "present"
    else
        printf '%-27s %s\n' "NAT chain:" "missing"
    fi

    if iptables -t nat -C POSTROUTING \
        -j "$NAT_CHAIN" 2>/dev/null; then

        printf '%-27s %s\n' "NAT chain hook:" "present"
    else
        printf '%-27s %s\n' "NAT chain hook:" "missing"
    fi

    if iptables -L "$FORWARD_CHAIN" \
        -n >/dev/null 2>&1; then

        printf '%-27s %s\n' "Forwarding chain:" "present"
    else
        printf '%-27s %s\n' "Forwarding chain:" "missing"
    fi

    if iptables -C FORWARD \
        -j "$FORWARD_CHAIN" 2>/dev/null; then

        printf '%-27s %s\n' "Forwarding chain hook:" "present"
    else
        printf '%-27s %s\n' "Forwarding chain hook:" "missing"
    fi

    printf '\nRoute lookup:\n'
    ip route get "$ONT_IP" 2>&1

    printf '\nConnectivity test:\n'
    if ping -I "$ONT_ALIAS_IP" \
        -c 1 -W 2 "$ONT_IP" >/dev/null 2>&1; then

        printf '%-27s %s\n' "WAS-110 ping:" "successful"
    else
        printf '%-27s %s\n' "WAS-110 ping:" "failed"
    fi

    printf '\nNAT chain rules:\n'
    iptables -t nat -vnL "$NAT_CHAIN" \
        --line-numbers 2>&1

    printf '\nForwarding chain rules:\n'
    iptables -vnL "$FORWARD_CHAIN" \
        --line-numbers 2>&1
}

###############################################################################
# Help
###############################################################################

usage() {
    cat <<EOF_USAGE
Usage: $0 [install|uninstall|apply|status]

  install
      Install or update this universal script and register all hooks.
      This is the default when no argument is supplied.

  uninstall
      Remove only this installation's hook entries, dedicated chains,
      management address, temporary files, and installed script.

  apply
      Verify or safely repair only missing/changed management address,
      NAT chain, and forwarding chain (serialized with Merlin hooks).

  status
      Show primary-LAN detection, installation, chains, route, and
      connectivity status.
EOF_USAGE
}

###############################################################################
# Command dispatcher
###############################################################################

case "${1:-install}" in
    install)
        install_self
        ;;

    uninstall)
        uninstall_all
        ;;

    apply)
        apply_with_lock manual
        ;;

    status)
        show_status
        ;;

    hook)
        # Only primary WAN "connected" requires a wan-event reapply.
        # Do not modify vlan4094 while PPPoE is tearing down or discovering.
        case "${2:-}" in
            wan-event)
                if [ "${3:-}" != 0 ] || [ "${4:-}" != connected ]; then
                    log_msg "WAN event ignored: unit=${3:-unknown} event=${4:-unknown}"
                    exit 0
                fi
                ;;
            nat-start|firewall-start) : ;;
            *) log_msg "Unknown hook ignored: ${2:-empty}"; exit 0 ;;
        esac
        apply_with_lock "${2:-unknown}:${3:-}:${4:-}"
        ;;

    -h|--help|help)
        usage
        ;;

    *)
        usage >&2
        exit 2
        ;;
esac