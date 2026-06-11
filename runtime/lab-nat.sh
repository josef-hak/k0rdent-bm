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

# --------------------------------------------------------------------------- #
# Expose child-cluster services on the EC2's public interface (host DNAT).
# EXPOSE_PORTS = space-separated <extPort>:<childIP>:<dstPort> triples. For each
# we DNAT incoming extPort -> childIP:dstPort, allow the forward into the lab
# bridge, and masquerade so the child node replies via the host. Idempotent.
# Open the extPorts in the AWS Security Group too. (No '-i <iface>' so it works
# regardless of the cloud NIC name; extPorts must not clash with host services.)
# --------------------------------------------------------------------------- #
expose_ensure() {  # <extPort> <childIP> <dstPort>
  local ext="$1" ip="$2" dst="$3"
  iptables -t nat -C PREROUTING -p tcp --dport "${ext}" -j DNAT --to-destination "${ip}:${dst}" 2>/dev/null \
    || iptables -t nat -A PREROUTING -p tcp --dport "${ext}" -j DNAT --to-destination "${ip}:${dst}"
  iptables -C FORWARD -o "${PROV_BRIDGE}" -p tcp -d "${ip}" --dport "${dst}" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -o "${PROV_BRIDGE}" -p tcp -d "${ip}" --dport "${dst}" -j ACCEPT
  iptables -t nat -C POSTROUTING -o "${PROV_BRIDGE}" -p tcp -d "${ip}" --dport "${dst}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "${PROV_BRIDGE}" -p tcp -d "${ip}" --dport "${dst}" -j MASQUERADE
}

for triple in ${EXPOSE_PORTS:-}; do
  IFS=: read -r e_ext e_ip e_dst <<<"${triple}"
  if [[ -z "${e_ext}" || -z "${e_ip}" || -z "${e_dst}" ]]; then
    log "skipping malformed EXPOSE_PORTS entry '${triple}'"; continue
  fi
  expose_ensure "${e_ext}" "${e_ip}" "${e_dst}"
  log "exposed :${e_ext} -> ${e_ip}:${e_dst}"
done
