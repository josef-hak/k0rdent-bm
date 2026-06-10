#!/usr/bin/env bash
#
# lab-nat.sh - runtime: give the isolated `lab` provisioning network outbound
# internet (so bare-metal nodes can pull images / cloud-init once deployed).
#
# Why this is needed: the libvirt `lab` net is forward mode=bridge (Ironic owns
# DHCP), so libvirt adds NO nat/forwarding; and docker (for sushy-tools) sets
# the FORWARD policy to DROP. So we add masquerade + forward rules ourselves.
#
# Runs every boot AFTER docker (idempotent: -C checks before adding), so the
# rules survive reboot/clone and docker resets. The gateway IP on the bridge
# (HOST_IP) is asserted by netplan, not here.
#
set -euo pipefail

# shellcheck disable=SC1091
source /etc/k0rdent-bm/config.env

log() { printf '\033[1;36m[lab-nat]\033[0m %s\n' "$*"; }

# Give the lab bridge a permanent carrier via an always-up dummy slave, so it
# stays UP even with no VMs running. Without a carrier the bridge is DOWN, and
# keepalived (in the Ironic pod) refuses to assign the VIP to it -> Ironic hangs
# waiting for ${IRONIC_VIP}. The VMs' tap interfaces only appear once Ironic
# powers them on, so we can't rely on them for the bridge to come up first.
ip link show "${PROV_BRIDGE}-up" &>/dev/null || ip link add "${PROV_BRIDGE}-up" type dummy
ip link set "${PROV_BRIDGE}-up" master "${PROV_BRIDGE}"
ip link set "${PROV_BRIDGE}-up" up
ip link set "${PROV_BRIDGE}" up
log "lab bridge ${PROV_BRIDGE} carrier ensured (via ${PROV_BRIDGE}-up)"

# IPv4 forwarding (re-asserted each boot; also dropped into sysctl.d at install).
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Idempotent helpers: add the rule only if an identical one isn't already there.
nat_ensure() { iptables -t nat -C POSTROUTING "$@" 2>/dev/null || iptables -t nat -A POSTROUTING "$@"; }
# FORWARD rules are INSERTED at the top so they win over docker's DROP.
fwd_ensure() { iptables -C FORWARD "$@" 2>/dev/null || iptables -I FORWARD "$@"; }

# NAT lab traffic that leaves the lab subnet, out via the default route (eth0).
nat_ensure -s "${PROV_SUBNET}" ! -d "${PROV_SUBNET}" -j MASQUERADE
# Allow forwarding in/out of the lab bridge (+ return traffic).
fwd_ensure -i "${PROV_BRIDGE}" -j ACCEPT
fwd_ensure -o "${PROV_BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT

log "NAT/forwarding for ${PROV_SUBNET} via ${PROV_BRIDGE} ensured"
