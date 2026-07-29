# WAS-110 Management Access for Asuswrt-Merlin

Provides persistent access to the WAS-110 management WebUI from the primary LAN of an Asuswrt-Merlin router.

This is the recommended approach when using **PPPoE**. On some ASUS PPPoE configurations, a normal GUI static route does not work because traffic to the ONT management subnet is routed through the logical `ppp0` interface and the ISP's PPPoE peer instead of the underlying physical WAN interface connected to the ONT.

This script detects the physical WAN interface beneath PPPoE and routes management traffic directly to the WAS-110.

The script automatically detects:

- The physical WAN interface connected to the ONT
- The primary LAN bridge
- The primary LAN subnet
- A suitable router-side management IP on the ONT subnet

It then creates the required management address, routing, NAT, and firewall rules. :contentReference[oaicite:0]{index=0}

## Features

- Access the WAS-110 WebUI from any device on the primary LAN
- Automatically detects the physical WAN interface
- Automatically detects the primary LAN subnet
- Excludes guest networks, secondary LANs, VPN clients, and other routed interfaces
- Supports PPPoE by using the underlying physical WAN interface instead of `ppp0`
- Reapplies configuration through Asuswrt-Merlin event hooks
- Uses dedicated `iptables` chains
- Includes install, apply, status, and uninstall commands
- Removes itself during uninstall

## Requirements

- ASUS router running Asuswrt-Merlin
- JFFS custom scripts enabled
- WAS-110 or compatible ONT connected upstream of the router
- Default ONT management address of `192.168.11.1`, or the script configuration updated accordingly

Enable custom scripts under:

```
Administration > System > Enable JFFS custom scripts and configs
```
## Installation

Copy `was110-manager.sh` to:

```text
/jffs/scripts/was110-manager.sh
```

Make the script executable:

```sh
chmod 755 /jffs/scripts/was110-manager.sh
```

Install the Asuswrt-Merlin hooks and apply the configuration:

```sh
/jffs/scripts/was110-manager.sh install
```

The script registers itself with:

- `wan-event`
- `nat-start`
- `firewall-start`

It also immediately creates the required management address, routing, NAT, and firewall rules.

After installation, open the WAS-110 WebUI at:

```text
https://192.168.11.1/
```

A browser certificate warning may appear because the WAS-110 uses a locally generated HTTPS certificate.

## Usage

### Check status

```sh
/jffs/scripts/was110-manager.sh status
```

This displays:

- Detected physical WAN interface
- ONT management address
- Router-side ONT address
- Primary LAN interface and subnet
- Hook installation status
- Management address status
- NAT and forwarding chain status
- Route lookup
- WAS-110 connectivity test
- Current NAT and firewall rules

### Reapply the configuration

```sh
/jffs/scripts/was110-manager.sh apply
```

This redetects the physical WAN interface, primary LAN interface, and primary LAN subnet, then reapplies the management address, NAT rules, and firewall rules.

This may be useful after restarting network services or changing the router's LAN configuration.

### Reinstall or refresh the hooks

```sh
/jffs/scripts/was110-manager.sh install
```

Running `install` again is safe. The script reapplies the configuration and ensures the required Asuswrt-Merlin hook entries exist.

### Uninstall

```sh
/jffs/scripts/was110-manager.sh uninstall
```

Uninstall removes:

- Entries added to `wan-event`
- Entries added to `nat-start`
- Entries added to `firewall-start`
- The dedicated `WAS110_NAT` chain
- The dedicated `WAS110_FWD` chain
- The router-side ONT management address
- `/jffs/scripts/was110-manager.sh`

The script deletes itself during uninstall, so the command will no longer exist afterward.
