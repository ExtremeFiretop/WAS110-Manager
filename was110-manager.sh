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
###############################################################################

###############################################################################
# USER Configuration
###############################################################################

ONT_IP="192.168.11.1"

###############################################################################
# SCRIPT Configuration (DO NOT TOUCH UNLESS SURE!)
###############################################################################

NAT_CHAIN="WAS110_NAT"
FORWARD_CHAIN="WAS110_FWD"

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

###############################################################################
# Logging
###############################################################################

log_msg() {
    logger -t "was110-manager" "$*" 2>/dev/null
}

print_msg() {
    printf '%s\n' "$*"
    log_msg "$*"
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
            ONT_IF=""
            ;;
    esac

    [ -n "$ONT_IF" ] || {
        log_msg "Could not determine the physical WAN interface"
        return 1
    }

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
###############################################################################

ensure_address() {
    # The physical WAN VLAN must exist before the alias can be added.
    ip link show "$ONT_IF" >/dev/null 2>&1 || return 1

    # Adds or refreshes:
    #
    # 192.168.11.2/24 on vlan4094
    #
    # This also creates:
    #
    # 192.168.11.0/24 dev vlan4094 src 192.168.11.2
    ip addr replace \
        "$ONT_ALIAS_IP/$ONT_PREFIX" \
        dev "$ONT_IF" >/dev/null 2>&1 || return 1

    return 0
}

ensure_nat_rules() {
    # Create this installation's dedicated NAT chain when absent.
    iptables -t nat -N "$NAT_CHAIN" 2>/dev/null || true

    # Rebuild only this installation's chain.
    iptables -t nat -F "$NAT_CHAIN" || return 1

    # Translate primary-LAN traffic to the WAS-110 management address.
    iptables -t nat -A "$NAT_CHAIN" \
        -s "$PRIMARY_SUBNET" \
        -d "$ONT_IP/32" \
        -o "$ONT_IF" \
        -j SNAT --to-source "$ONT_ALIAS_IP" || return 1

    # Add one jump from POSTROUTING to this installation's chain.
    iptables -t nat -C POSTROUTING \
        -j "$NAT_CHAIN" 2>/dev/null || \
    iptables -t nat -I POSTROUTING 1 \
        -j "$NAT_CHAIN" || return 1

    return 0
}

ensure_firewall_rules() {
    # Create this installation's dedicated forwarding chain when absent.
    iptables -N "$FORWARD_CHAIN" 2>/dev/null || true

    # Rebuild only this installation's chain.
    iptables -F "$FORWARD_CHAIN" || return 1

    # Permit clients entering through the primary LAN bridge and belonging
    # to the primary LAN subnet.
    iptables -A "$FORWARD_CHAIN" \
        -i "$LAN_IF" \
        -s "$PRIMARY_SUBNET" \
        -d "$ONT_IP/32" \
        -o "$ONT_IF" \
        -j ACCEPT || return 1

    # Permit established return traffic from the WAS-110 to the primary LAN.
    iptables -A "$FORWARD_CHAIN" \
        -i "$ONT_IF" \
        -s "$ONT_IP/32" \
        -d "$PRIMARY_SUBNET" \
        -o "$LAN_IF" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -j ACCEPT || return 1

    # Explicitly prevent guest bridges, guest VLANs, secondary LANs, VPN
    # clients, and any other routed interface from reaching the WAS-110.
    iptables -A "$FORWARD_CHAIN" \
        -d "$ONT_IP/32" \
        -j DROP || return 1

    # Prevent unsolicited traffic from the WAS-110 from being forwarded to
    # any interface other than permitted established primary-LAN sessions.
    iptables -A "$FORWARD_CHAIN" \
        -s "$ONT_IP/32" \
        -j DROP || return 1

    # Add one jump at the beginning of the main FORWARD chain so the explicit
    # WAS-110 restrictions are evaluated before general WAN/guest rules.
    iptables -C FORWARD \
        -j "$FORWARD_CHAIN" 2>/dev/null || \
    iptables -I FORWARD 1 \
        -j "$FORWARD_CHAIN" || return 1

    return 0
}

apply_all() {
    attempt=1

    # During boot, the interfaces or firewall tables may not be ready on the
    # first attempt. All operations are idempotent, so retries are safe.
    while [ "$attempt" -le 5 ]; do
        if detect_ont_settings &&
           detect_primary_lan &&
           ensure_address &&
           ensure_nat_rules &&
           ensure_firewall_rules; then

            log_msg \
                "Configuration applied: LAN=$LAN_IF subnet=$PRIMARY_SUBNET ONT=$ONT_IF"

            return 0
        fi

        attempt=$((attempt + 1))
        sleep 2
    done

    log_msg \
        "Configuration could not be completely applied after five attempts"

    return 1
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

    # Remove this installation's NAT chain.
    iptables -t nat -F "$NAT_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$NAT_CHAIN" 2>/dev/null || true

    # Remove every jump belonging to this installation's forwarding chain.
    while iptables -C FORWARD \
        -j "$FORWARD_CHAIN" 2>/dev/null; do

        iptables -D FORWARD \
            -j "$FORWARD_CHAIN" || break
    done

    # Remove this installation's forwarding chain.
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

    chmod 755 "$SCRIPT_PATH" || return 1

    # All three Merlin event points call the same universal script.
    install_hook wan-event || return 1
    install_hook nat-start || return 1
    install_hook firewall-start || return 1

    # Apply immediately; no reboot is required.
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
      Detect the primary LAN subnet and reapply this installation's
      management address, NAT chain, and forwarding chain.

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
        apply_all
        ;;

    status)
        show_status
        ;;

    hook)
        # $2 identifies which Merlin hook invoked this script.
        # Every Merlin hook runs the same idempotent configuration routine.
        log_msg "Triggered by ${2:-unknown hook}"
        apply_all
        ;;

    -h|--help|help)
        usage
        ;;

    *)
        usage >&2
        exit 2
        ;;
esac
