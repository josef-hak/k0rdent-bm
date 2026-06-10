#!/usr/bin/env bash
#
# install.sh - build the single-VM k0rdent bare-metal demo into an AMI.
#
# Run ONCE on a KVM-capable EC2 instance as root, then power off and snapshot.
# Everything here is pinned to the static provisioning network (config.env) so
# the resulting image survives clone + reboot. See k0rdent-bm-ami-PLAN.md.
#
# Re-running is safe: each step guards against already-done state.
#
# All charts pull ANONYMOUSLY from registry.mirantis.com (k0rdent Enterprise
# + the public k0rdent-bm provider charts). No credentials are required.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${REPO_DIR}/config.env"
CONFIG_DST="/etc/k0rdent-bm/config.env"

log()  { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install][WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install][FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

# Auto-export so envsubst can substitute config vars into manifest templates.
set -a
# shellcheck disable=SC1090
source "${CONFIG_SRC}"
set +a

# --------------------------------------------------------------------------- #
# 0. Preflight
# --------------------------------------------------------------------------- #
preflight() {
  [[ $EUID -eq 0 ]] || die "must run as root"
  [[ -e /dev/kvm ]] || die "/dev/kvm not present - this host is not KVM-capable"
  # Charts pull anonymously; creds are optional (login only if both are set).

  local total_mb
  total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  local need_mb=$(( VM_RAM_MB * 2 + 4096 ))
  if (( total_mb < need_mb )); then
    warn "host RAM ${total_mb}MiB < est. need ${need_mb}MiB (2x VM ${VM_RAM_MB} + ~4G cluster)."
    warn "Cluster or VMs may OOM. Lower VM_RAM_MB in config.env. (PLAN open-risk #2)"
  fi

  # fd / inotify limits for k0rdent. tune_host sets these; here we just report
  # and warn if still below threshold (non-fatal - run 'make tune' to fix).
  local nofile watches instances
  nofile=$(ulimit -n)
  watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
  instances=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
  (( nofile    >= 65535  )) || warn "ulimit -n ${nofile} < 65535 (run 'make tune')"
  (( watches   >= 524288 )) || warn "fs.inotify.max_user_watches ${watches} < 524288 (run 'make tune')"
  (( instances >= 512    )) || warn "fs.inotify.max_user_instances ${instances} < 512 (run 'make tune')"
  log "fd/inotify: nofile=${nofile} watches=${watches} instances=${instances}"

  log "preflight ok (RAM ${total_mb}MiB, kvm present)"
}

# --------------------------------------------------------------------------- #
# 1. Packages
# --------------------------------------------------------------------------- #
install_packages() {
  log "installing apt packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients virtinst \
    ovmf bridge-utils \
    apache2-utils openssl \
    curl ca-certificates jq gettext-base python3-yaml

  # Docker (for the sushy-tools container).
  if ! command -v docker >/dev/null; then
    log "installing docker"
    curl -fsSL https://get.docker.com | sh
  fi

  # Helm.
  if ! command -v helm >/dev/null; then
    log "installing helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi

  # kubectl (standalone; k0s also ships one but the plan wants it on PATH).
  if ! command -v kubectl >/dev/null; then
    log "installing kubectl"
    local ver
    ver=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl
  fi

  # k0s.
  if ! command -v k0s >/dev/null; then
    log "installing k0s"
    curl -fsSL https://get.k0s.sh | sh
  fi

  systemctl enable --now libvirtd
  systemctl enable --now docker
}

# --------------------------------------------------------------------------- #
# 2. Install shared config to /etc
# --------------------------------------------------------------------------- #
install_config() {
  log "installing config to ${CONFIG_DST}"
  install -d -m 0755 /etc/k0rdent-bm
  install -m 0644 "${CONFIG_SRC}" "${CONFIG_DST}"
}

# --------------------------------------------------------------------------- #
# 2b. Host tuning for k0rdent: inotify limits + open file descriptors.
#     k0rdent/k0s controllers watch a lot of files; stock limits are too low.
#     sysctl.d + limits.d persist across reboot; the k0scontroller drop-in makes
#     the nofile bump actually apply (systemd ignores limits.conf for services).
#     Idempotent: re-running just rewrites the same drop-in files.
# --------------------------------------------------------------------------- #
tune_host() {
  log "tuning host: inotify watches/instances + nofile limits"

  # inotify (applied live + persisted; auto-reapplied each boot from sysctl.d).
  cat >/etc/sysctl.d/99-k0rdent-inotify.conf <<EOF
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF
  sysctl -p /etc/sysctl.d/99-k0rdent-inotify.conf >/dev/null

  # open files for interactive/login sessions (PAM).
  cat >/etc/security/limits.d/99-k0rdent-nofile.conf <<EOF
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

  # open files for the k0s controller (systemd services ignore limits.conf).
  install -d -m 0755 /etc/systemd/system/k0scontroller.service.d
  cat >/etc/systemd/system/k0scontroller.service.d/10-nofile.conf <<EOF
[Service]
LimitNOFILE=65535
EOF
  systemctl daemon-reload 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# 3. Provisioning network: netplan host bridge + libvirt bridge-mode network
#    netplan OWNS 172.22.0.1 (re-asserted each boot); libvirt just attaches
#    VMs to the bridge. DHCP is OFF - Ironic owns DHCP on this subnet.
# --------------------------------------------------------------------------- #
setup_provisioning_net() {
  log "configuring netplan host bridge '${PROV_BRIDGE}' (${HOST_IP})"
  cat >/etc/netplan/99-${PROV_BRIDGE}.yaml <<EOF
network:
  version: 2
  bridges:
    ${PROV_BRIDGE}:
      dhcp4: false
      dhcp6: false
      addresses: [${HOST_IP}/24]
      parameters:
        stp: false
        forward-delay: 0
EOF
  chmod 600 /etc/netplan/99-${PROV_BRIDGE}.yaml
  netplan apply
  # Wait for the bridge to come up.
  for _ in $(seq 1 10); do
    ip link show "${PROV_BRIDGE}" &>/dev/null && break; sleep 1
  done
  ip link show "${PROV_BRIDGE}" &>/dev/null || die "bridge ${PROV_BRIDGE} did not appear"

  log "defining libvirt network '${PROV_BRIDGE}' (forward mode=bridge, no dhcp)"
  cat >/tmp/${PROV_BRIDGE}-net.xml <<EOF
<network>
  <name>${PROV_BRIDGE}</name>
  <forward mode='bridge'/>
  <bridge name='${PROV_BRIDGE}'/>
</network>
EOF
  if ! virsh net-info "${PROV_BRIDGE}" &>/dev/null; then
    virsh net-define /tmp/${PROV_BRIDGE}-net.xml
  fi
  virsh net-autostart "${PROV_BRIDGE}"
  virsh net-start "${PROV_BRIDGE}" 2>/dev/null || true
  rm -f /tmp/${PROV_BRIDGE}-net.xml
}

# --------------------------------------------------------------------------- #
# 4. virt-power SSH key (sushy-tools -> qemu+ssh://root@127.0.0.1/system)
#    Reuses the metal3-dev-env virt-power pattern: a dedicated keypair that
#    lets the sushy container drive libvirt over localhost SSH.
# --------------------------------------------------------------------------- #
setup_virtpower_key() {
  local key=/root/.ssh/k0rdent-bm-virtpower
  log "setting up virt-power ssh key"
  install -d -m 0700 /root/.ssh
  if [[ ! -f ${key} ]]; then
    ssh-keygen -t ed25519 -N '' -f "${key}" -C k0rdent-bm-virtpower
  fi
  # Authorize it for root@localhost.
  touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
  grep -qF "$(cat "${key}.pub")" /root/.ssh/authorized_keys \
    || cat "${key}.pub" >> /root/.ssh/authorized_keys
  # Trust localhost host key so the container's ssh is non-interactive.
  ssh-keyscan -H 127.0.0.1 2>/dev/null >> /root/.ssh/known_hosts || true
  sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts
  # Ensure sshd allows root key login from localhost (key-only).
  if ! sshd -T 2>/dev/null | grep -q '^permitrootlogin\(.*\)\?\(prohibit-password\|without-password\|yes\)'; then
    echo 'PermitRootLogin prohibit-password' >/etc/ssh/sshd_config.d/99-virtpower.conf
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  fi
}

# --------------------------------------------------------------------------- #
# 5. sushy-tools config: conf.py + htpasswd + self-signed TLS cert.
#    Runs later as a --net host --restart=always container (runtime unit).
# --------------------------------------------------------------------------- #
setup_sushy() {
  log "writing sushy-tools config to ${SUSHY_CONF_DIR}"
  install -d -m 0755 "${SUSHY_CONF_DIR}"

  # htpasswd (bcrypt) for Redfish basic auth.
  htpasswd -B -b -c "${SUSHY_CONF_DIR}/htpasswd" "${SUSHY_USER}" "${SUSHY_PASS}"

  # Self-signed cert for https on the VIP-less host IP.
  if [[ ! -f ${SUSHY_CONF_DIR}/cert.pem ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${SUSHY_CONF_DIR}/key.pem" -out "${SUSHY_CONF_DIR}/cert.pem" \
      -days 3650 -subj "/CN=${HOST_IP}" \
      -addext "subjectAltName=IP:${HOST_IP},IP:127.0.0.1"
  fi

  # conf.py - drive libvirt over localhost SSH using the virt-power key.
  cat >"${SUSHY_CONF_DIR}/conf.py" <<EOF
import os
SUSHY_EMULATOR_LISTEN_IP = u'${HOST_IP}'
SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_PORT}
SUSHY_EMULATOR_SSL_CERT = u'/conf/cert.pem'
SUSHY_EMULATOR_SSL_KEY = u'/conf/key.pem'
SUSHY_EMULATOR_AUTH_FILE = u'/conf/htpasswd'
# Drive the host's libvirt over localhost SSH (virt-power pattern).
SUSHY_EMULATOR_LIBVIRT_URI = u'qemu+ssh://root@127.0.0.1/system?keyfile=/root/.ssh/k0rdent-bm-virtpower&no_verify=1&no_tty=1'
# Virtual media: store inserted ISOs under the conf dir.
SUSHY_EMULATOR_VMEDIA_VERIFY_SSL = False
EOF

  log "pre-pulling sushy-tools image ${SUSHY_IMAGE}"
  docker pull "${SUSHY_IMAGE}"
}

# --------------------------------------------------------------------------- #
# 6. Two UEFI libvirt VMs (bmh-0/bmh-1) with FIXED uuid + mac, autostart off.
#    Empty disks - the OS is provisioned later by Ironic via virtual media.
# --------------------------------------------------------------------------- #
define_vm() {
  local name="$1" uuid="$2" mac="$3"
  local disk="/var/lib/libvirt/images/${name}.qcow2"
  local nvram="/var/lib/libvirt/qemu/nvram/${name}_VARS.fd"

  if virsh dominfo "${name}" &>/dev/null; then
    log "VM ${name} already defined, skipping"
    return
  fi
  log "creating VM ${name} (uuid=${uuid} mac=${mac})"

  [[ -f ${disk} ]] || qemu-img create -f qcow2 "${disk}" "${VM_DISK_GB}G" >/dev/null
  install -d -m 0755 /var/lib/libvirt/qemu/nvram
  # Per-domain UEFI varstore from the OVMF template.
  cp -n /usr/share/OVMF/OVMF_VARS_4M.fd "${nvram}"

  cat >/tmp/${name}.xml <<EOF
<domain type='kvm'>
  <name>${name}</name>
  <uuid>${uuid}</uuid>
  <memory unit='MiB'>${VM_RAM_MB}</memory>
  <currentMemory unit='MiB'>${VM_RAM_MB}</currentMemory>
  <vcpu>${VM_VCPUS}</vcpu>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>
    <nvram template='/usr/share/OVMF/OVMF_VARS_4M.fd'>${nvram}</nvram>
    <boot dev='hd'/>
    <boot dev='cdrom'/>
    <bootmenu enable='yes'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <!-- OS disk on SATA so it enumerates as /dev/sda - Metal3/Ironic's default
         rootDeviceHint is {name: /dev/sda}; a virtio disk (/dev/vda) wouldn't
         match and deploy.write_image fails with "No suitable device". -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${disk}'/>
      <target dev='sda' bus='sata'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <target dev='sdb' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <mac address='${mac}'/>
      <source network='${PROV_BRIDGE}'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <graphics type='vnc' port='-1' listen='127.0.0.1'/>
    <video><model type='virtio'/></video>
  </devices>
</domain>
EOF
  virsh define /tmp/${name}.xml
  virsh autostart --disable "${name}"
  rm -f /tmp/${name}.xml
}

# sushy-tools stores inserted virtual-media ISOs in a libvirt storage pool
# named 'default'. Ubuntu's libvirt doesn't create it automatically, so
# VirtualMedia.InsertMedia fails with "Storage pool not found ... 'default'".
# Define a dir-pool at the images dir, autostart so it survives reboot.
ensure_libvirt_pool() {
  if virsh pool-info default &>/dev/null; then
    log "libvirt 'default' storage pool already exists"
  else
    log "creating libvirt 'default' storage pool (for sushy virtual media)"
    virsh pool-define-as default dir --target /var/lib/libvirt/images
    virsh pool-build default 2>/dev/null || true
  fi
  virsh pool-autostart default 2>/dev/null || true
  virsh pool-start default 2>/dev/null || true
}

define_vms() {
  ensure_libvirt_pool
  log "defining fake bare-metal VMs"
  define_vm "${BMH0_NAME}" "${BMH0_UUID}" "${BMH0_MAC}"
  define_vm "${BMH1_NAME}" "${BMH1_UUID}" "${BMH1_MAC}"
}

# --------------------------------------------------------------------------- #
# 7. k0s single-node controller + k0rdent + bare-metal templates.
#    Split into three independently-runnable steps (install_k0s / install_kcm /
#    install_bm). install brings the cluster up to install charts, then install_bm
#    stops it; runtime restarts k0scontroller on every boot.
# --------------------------------------------------------------------------- #

# Start k0scontroller (if not already up) and block until the API is ready.
# Shared by all three steps so each works when run on its own.
wait_k0s_api() {
  export KUBECONFIG="${KUBECONFIG_PATH}"
  systemctl start k0scontroller
  log "waiting for k0s API"
  for _ in $(seq 1 60); do
    k0s kubectl get --raw='/readyz' &>/dev/null && return 0; sleep 5
  done
  die "k0s API never became ready"
}

# Copy the k0s admin kubeconfig to the invoking user's ~/.kube/config so plain
# `kubectl` works without sudo. Runs under sudo, so target SUDO_USER's home
# (not root's). admin.conf already points at https://localhost:6443.
export_kubeconfig() {
  local user="${SUDO_USER:-root}"
  local home grp dst
  home="$(getent passwd "${user}" | cut -d: -f6)"; [[ -n "${home}" ]] || home="${HOME}"
  grp="$(id -gn "${user}" 2>/dev/null || echo "${user}")"
  dst="${home}/.kube/config"
  log "exporting kubeconfig to ${dst} (owner ${user})"
  install -d -m 0700 -o "${user}" -g "${grp}" "${home}/.kube"
  install -m 0600 -o "${user}" -g "${grp}" "${KUBECONFIG_PATH}" "${dst}"
}

# 7a. k0s single-node controller. Leaves k0scontroller running for 7b/7c.
install_k0s() {
  log "installing k0s single-node controller"
  if [[ ! -f /etc/k0s/k0s.yaml ]]; then
    install -d -m 0755 /etc/k0s
    k0s config create >/etc/k0s/k0s.yaml
    # Pin API + etcd to the static lab IP, never eth0. `k0s config create`
    # bakes the current eth0 IP into spec.api.address AND
    # spec.storage.etcd.peerAddress; on a snapshot clone that gets a new eth0 IP
    # both would fail to bind. 172.22.0.1 (HOST_IP) is asserted by netplan on the
    # lab bridge every boot, so it's stable across reboot + clone.
    python3 - "$K0S_API_SANS" "$HOST_IP" <<'PY'
import sys, yaml
sans = sys.argv[1].split(',')
host_ip = sys.argv[2]
p = '/etc/k0s/k0s.yaml'
d = yaml.safe_load(open(p))
api = d.setdefault('spec', {}).setdefault('api', {})
api['address'] = host_ip
api['sans'] = sans
storage = d['spec'].setdefault('storage', {})
if storage.get('type', 'etcd') == 'etcd':
    storage.setdefault('etcd', {})['peerAddress'] = host_ip
yaml.safe_dump(d, open(p, 'w'))
PY
  fi
  # Guard on the unit file k0s itself checks ("Init already exists"), not on
  # `systemctl list-unit-files` (which can disagree before a daemon-reload).
  if [[ ! -f /etc/systemd/system/k0scontroller.service ]]; then
    k0s install controller --single -c /etc/k0s/k0s.yaml
  else
    log "k0scontroller.service already installed, skipping k0s install"
  fi
  wait_k0s_api
  export_kubeconfig
}

# 7a'. Traefik ingress controller (DaemonSet, host ports 80/443) so the
#      k0rdent UI and other services can be exposed. Mirrors
#      josef-hak/kube-sol scripts/install_traefik.sh + helm/traefik.yaml.
install_ingress() {
  wait_k0s_api
  log "installing Traefik ingress"
  helm upgrade --install traefik \
    oci://ghcr.io/k0rdent/catalog/charts/traefik \
    --version 39.0.8 \
    -n traefik \
    --create-namespace \
    -f "${REPO_DIR}/helm/traefik.yaml" \
    || warn "traefik install returned non-zero"
}

# 7b. k0rdent Enterprise management cluster (kcm) from the public Enterprise OCI
#     registry. Mirrors josef-hak/kube-sol install_kcm.sh. The chart's
#     controller.createManagement=true creates the "kcm" Management object that
#     runtime patches for Ironic.
install_kcm() {
  wait_k0s_api
  log "installing k0rdent Enterprise (kcm)"
  helm upgrade --install kcm \
    oci://registry.mirantis.com/k0rdent-enterprise/charts/k0rdent-enterprise \
    --version 1.3.2 \
    -n kcm-system \
    --create-namespace \
    -f "${REPO_DIR}/helm/kcm.yaml" \
    --wait --timeout 20m \
    || warn "kcm install returned non-zero"

  k0s kubectl apply -f "${REPO_DIR}/manifests/ingress-ui.yaml"
  k0s kubectl apply -f "${REPO_DIR}/manifests/k0rdent-catalog.yaml"
}

# 7c. Bare-metal provider templates + artifact pre-pull. Last cluster step, so
#     it stops k0scontroller (runtime restarts it on boot).
install_bm() {
  wait_k0s_api
  log "creating bare-metal HelmRepository + Provider/Cluster templates"
  envsubst <"${REPO_DIR}/manifests/bm-templates.yaml" | k0s kubectl apply -f -

  # No artifact pre-pull: the ironic 0.5.0 subchart fetches the IPA ramdisk
  # (images_ipa) and target OS image (images_target) itself at runtime and
  # serves them from its in-cluster httpd. The provider Helm chart is pulled by
  # the CAPM3 install. (The old get.mirantis.com/images/* URLs were wrong - the
  # chart's real image URLs live under get.mirantis.com/k0rdent-enterprise/...)

  # log "stopping k0scontroller (runtime restarts it on boot)"
  # systemctl stop k0scontroller
}

# --------------------------------------------------------------------------- #
# 8. Install runtime systemd units + setup script + manifests
# --------------------------------------------------------------------------- #
install_runtime() {
  log "installing runtime units, setup script and manifests"
  install -d -m 0755 /opt/k0rdent-bm/manifests
  install -m 0755 "${REPO_DIR}/runtime/k0rdent-bm-setup.sh" /opt/k0rdent-bm/k0rdent-bm-setup.sh
  install -m 0755 "${REPO_DIR}/runtime/lab-nat.sh"   /opt/k0rdent-bm/lab-nat.sh
  install -m 0644 "${REPO_DIR}/manifests/management-patch.yaml" /opt/k0rdent-bm/manifests/
  install -m 0644 "${REPO_DIR}/manifests/bmh.yaml"             /opt/k0rdent-bm/manifests/

  install -m 0644 "${REPO_DIR}/runtime/sushy-tools.service" /etc/systemd/system/
  install -m 0644 "${REPO_DIR}/runtime/k0rdent-bm-setup.service" /etc/systemd/system/
  install -m 0644 "${REPO_DIR}/runtime/lab-nat.service"     /etc/systemd/system/

  # Persist IPv4 forwarding (lab-nat.sh also sets it live each boot).
  echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-k0rdent-bm.conf

  systemctl daemon-reload
  systemctl enable libvirtd docker k0scontroller \
    sushy-tools.service lab-nat.service k0rdent-bm-setup.service
  log "runtime units enabled"
}

# --------------------------------------------------------------------------- #
# 9. Final
# --------------------------------------------------------------------------- #
finish() {
  log "install complete."
  log "Verify: 'virsh list --all' shows ${BMH0_NAME}/${BMH1_NAME} (shut off);"
  log "        'systemctl is-enabled k0scontroller sushy-tools k0rdent-bm-setup' all enabled."
  log "Before snapshot run 'make prep-ami' to strip login SSH keys."
  log "Then power off and create the AMI:  sudo poweroff"
}

# --------------------------------------------------------------------------- #
# AMI hygiene - run ONCE as the last step before poweroff/snapshot. NOT part of
# main(): it strips login SSH keys that would otherwise be baked into the AMI
# and leak to every clone.
# --------------------------------------------------------------------------- #
prep_ami() {
  local vpk=/root/.ssh/k0rdent-bm-virtpower.pub
  log "prep-ami: sanitizing SSH keys + resetting cloud-init state"

  # root: keep ONLY the virt-power key - sushy-tools needs it on every clone
  # (qemu+ssh://root@127.0.0.1). Drop any human/login keys that leaked in.
  if [[ -f ${vpk} ]]; then
    install -m 0600 -o root -g root "${vpk}" /root/.ssh/authorized_keys
    log "root authorized_keys reduced to the virt-power key only"
  else
    warn "virt-power pubkey ${vpk} missing - leaving root authorized_keys as-is"
  fi

  # human users: cloud-init re-injects the new instance's launch key on first boot.
  rm -f /home/*/.ssh/authorized_keys
  log "removed login authorized_keys under /home/*"

  # reset per-instance state: the clone re-runs cloud-init -> new launch key
  # injected + SSH host keys regenerated (ssh_deletekeys defaults true) + logs cleared.
  cloud-init clean --logs 2>/dev/null || warn "cloud-init clean failed/absent"

  log "prep-ami done. Now: sudo poweroff  -> create the AMI"
}

main() {
  preflight
  install_packages
  install_config
  tune_host
  setup_provisioning_net
  setup_virtpower_key
  setup_sushy
  define_vms
  install_k0s
  install_ingress
  install_kcm
  install_bm
  install_runtime
  finish
}

# Run the full install only when executed directly. When this file is *sourced*
# (e.g. by the Makefile, to call one step at a time), the functions are defined
# but main() does not run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
