#!/usr/bin/env bash
#
# k0rdent-bm-setup.sh - runtime oneshot, runs on every boot after k0scontroller.
#
# 1. Wait for the k0s API + kcm CRDs.
# 2. Patch the Management object so Ironic uses the static provisioning net.
# 3. Apply per-host BMC Secrets + BareMetalHost CRs (rendered from config.env).
#
# Idempotent: kubectl apply / patch converge to the same state every boot.
#
set -euo pipefail

CONFIG=/etc/k0rdent-bm/config.env
MANIFESTS=/opt/k0rdent-bm/manifests
# Auto-export every config var so envsubst (which only sees exported vars) can
# substitute them into the manifest templates.
set -a
# shellcheck disable=SC1090
source "${CONFIG}"
set +a

export KUBECONFIG="${KUBECONFIG_PATH}"
KUBECTL="k0s kubectl"

log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup][FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

# Wait for a condition, polling. wait_for <desc> <retries> <sleep> <cmd...>
wait_for() {
  local desc="$1" tries="$2" naptime="$3"; shift 3
  log "waiting for ${desc} (<= $((tries*naptime))s)"
  for _ in $(seq 1 "${tries}"); do
    if "$@" &>/dev/null; then log "ok: ${desc}"; return 0; fi
    sleep "${naptime}"
  done
  die "timed out waiting for ${desc}"
}

# --------------------------------------------------------------------------- #
# 1. API + CRDs
# --------------------------------------------------------------------------- #
wait_for "k0s API readyz" 60 5 ${KUBECTL} get --raw=/readyz
wait_for "Management CRD" 60 5 \
  ${KUBECTL} get crd managements.k0rdent.mirantis.com
wait_for "BareMetalHost CRD" 60 5 \
  ${KUBECTL} get crd baremetalhosts.metal3.io

# --------------------------------------------------------------------------- #
# 2. Patch the Management object (Ironic networking on the provisioning net).
#    The Management object created by the kcm install is named "kcm".
# --------------------------------------------------------------------------- #
MGMT_NAME="kcm"
wait_for "Management/${MGMT_NAME}" 60 5 \
  ${KUBECTL} get management.k0rdent.mirantis.com "${MGMT_NAME}"

log "rendering + applying Management patch"
rendered_patch="$(mktemp)"
envsubst <"${MANIFESTS}/management-patch.yaml" >"${rendered_patch}"
${KUBECTL} patch management.k0rdent.mirantis.com "${MGMT_NAME}" \
  --type merge --patch-file "${rendered_patch}"
rm -f "${rendered_patch}"

# --------------------------------------------------------------------------- #
# 3. Apply BMC Secrets + BareMetalHost CRs (one rendered doc per host).
# --------------------------------------------------------------------------- #
apply_bmh() {
  local name="$1" uuid="$2" mac="$3"
  log "applying BareMetalHost ${name}"
  BMH_NAME="${name}" BMH_UUID="${uuid}" BMH_MAC="${mac}" \
    envsubst <"${MANIFESTS}/bmh.yaml" | ${KUBECTL} apply -f -
}

# Ensure target namespace exists.
${KUBECTL} get ns "${BMH_NAMESPACE}" &>/dev/null \
  || ${KUBECTL} create ns "${BMH_NAMESPACE}"

apply_bmh "${BMH0_NAME}" "${BMH0_UUID}" "${BMH0_MAC}"
apply_bmh "${BMH1_NAME}" "${BMH1_UUID}" "${BMH1_MAC}"

log "setup complete - BMHs should move Registering -> Inspecting -> Available"
