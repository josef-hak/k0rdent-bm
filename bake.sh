#!/usr/bin/env bash
#
# bake.sh - Phase A: build the single-VM k0rdent bare-metal demo into an AMI.
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

log()  { printf '\033[1;32m[bake]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bake][WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bake][FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

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
    qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
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
#    Runs later as a --net host --restart=always container (Phase B unit).
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
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${disk}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <target dev='sda' bus='sata'/>
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

define_vms() {
  log "defining fake bare-metal VMs"
  define_vm "${BMH0_NAME}" "${BMH0_UUID}" "${BMH0_MAC}"
  define_vm "${BMH1_NAME}" "${BMH1_UUID}" "${BMH1_MAC}"
}

# --------------------------------------------------------------------------- #
# 7. k0s single-node controller + k0rdent + bare-metal templates.
#    Split into three independently-runnable steps (install_k0s / install_kcm /
#    install_bm). bake brings the cluster up to install charts, then install_bm
#    stops it; Phase B restarts k0scontroller on every boot.
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

# 7a. k0s single-node controller. Leaves k0scontroller running for 7b/7c.
install_k0s() {
  log "installing k0s single-node controller"
  if [[ ! -f /etc/k0s/k0s.yaml ]]; then
    install -d -m 0755 /etc/k0s
    k0s config create >/etc/k0s/k0s.yaml
    # Pin API SANs to loopback + static host IP (never eth0).
    python3 - "$K0S_API_SANS" <<'PY'
import sys, yaml
sans = sys.argv[1].split(',')
p = '/etc/k0s/k0s.yaml'
d = yaml.safe_load(open(p))
d.setdefault('spec', {}).setdefault('api', {})['sans'] = sans
yaml.safe_dump(d, open(p, 'w'))
PY
  fi
  if ! systemctl list-unit-files | grep -q '^k0scontroller'; then
    k0s install controller --single -c /etc/k0s/k0s.yaml
  fi
  wait_k0s_api
}

# 7b. k0rdent Enterprise management cluster (kcm) from the public Enterprise OCI
#     registry. Mirrors josef-hak/kube-sol install_kcm.sh. The chart's
#     controller.createManagement=true creates the "kcm" Management object that
#     Phase B patches for Ironic.
install_kcm() {
  wait_k0s_api
  log "installing k0rdent Enterprise (kcm) ${KCM_VERSION}"
  local kcm_values; kcm_values="$(mktemp)"
  envsubst <"${REPO_DIR}/helm/${KCM_VALUES}" >"${kcm_values}"
  helm upgrade --install kcm "${KCM_OCI_REPO}/${KCM_CHART}" \
    --version "${KCM_VERSION}" \
    --namespace "${KCM_NAMESPACE}" --create-namespace \
    -f "${kcm_values}" \
    --wait --timeout 20m \
    || warn "kcm install returned non-zero - verify chart/version (KCM_* in config.env)"
  rm -f "${kcm_values}"
}

# 7c. Bare-metal provider templates + artifact pre-pull. Last cluster step, so
#     it stops k0scontroller (Phase B restarts it on boot).
install_bm() {
  wait_k0s_api
  log "creating bare-metal HelmRepository + Provider/Cluster templates"
  envsubst <"${REPO_DIR}/manifests/bm-templates.yaml" | k0s kubectl apply -f -

  log "pre-pulling chart + IPA + target-image artifacts"
  helm pull "${BM_OCI_REPO}/cluster-api-provider-metal3" --version "${CAPM3_VERSION}" \
    -d /var/lib/k0rdent-bm/charts 2>/dev/null || warn "capm3 chart pre-pull skipped"
  # IPA ramdisk + target OS image cached locally so Phase B has no internet dep.
  install -d -m 0755 /var/lib/k0rdent-bm/images
  ( cd /var/lib/k0rdent-bm/images
    curl -fsSLO https://get.mirantis.com/images/ironic-python-agent.kernel || warn "IPA kernel pull skipped"
    curl -fsSLO https://get.mirantis.com/images/ironic-python-agent.initramfs || warn "IPA initramfs pull skipped"
  )

  log "stopping k0scontroller (Phase B restarts it on boot)"
  systemctl stop k0scontroller
}

# --------------------------------------------------------------------------- #
# 8. Install Phase-B systemd units + bootstrap.sh + manifests
# --------------------------------------------------------------------------- #
install_phase_b() {
  log "installing Phase-B units, bootstrap.sh and manifests"
  install -d -m 0755 /opt/k0rdent-bm/manifests
  install -m 0755 "${REPO_DIR}/phase-b/bootstrap.sh" /opt/k0rdent-bm/bootstrap.sh
  install -m 0644 "${REPO_DIR}/manifests/management-patch.yaml" /opt/k0rdent-bm/manifests/
  install -m 0644 "${REPO_DIR}/manifests/bmh.yaml"             /opt/k0rdent-bm/manifests/

  install -m 0644 "${REPO_DIR}/phase-b/sushy-tools.service" /etc/systemd/system/
  install -m 0644 "${REPO_DIR}/phase-b/bootstrap.service"   /etc/systemd/system/

  systemctl daemon-reload
  systemctl enable libvirtd docker k0scontroller sushy-tools.service bootstrap.service
  log "Phase-B units enabled"
}

# --------------------------------------------------------------------------- #
# 9. Final
# --------------------------------------------------------------------------- #
finish() {
  log "bake complete."
  log "Verify: 'virsh list --all' shows ${BMH0_NAME}/${BMH1_NAME} (shut off);"
  log "        'systemctl is-enabled k0scontroller sushy-tools bootstrap' all enabled."
  log "Now power off and create the AMI:  sudo poweroff"
}

main() {
  preflight
  install_packages
  install_config
  setup_provisioning_net
  setup_virtpower_key
  setup_sushy
  define_vms
  install_k0s
  install_kcm
  install_bm
  install_phase_b
  finish
}

# Run the full bake only when executed directly. When this file is *sourced*
# (e.g. by the Makefile, to call one step at a time), the functions are defined
# but main() does not run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
