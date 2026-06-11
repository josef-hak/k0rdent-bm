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

# Retry a command until it succeeds. For transient admission-webhook errors
# right after boot/provider install (the k0rdent/metal3 webhooks may not be
# serving yet). retry <desc> <tries> <sleep> <cmd...>
retry() {
  local desc="$1" tries="$2" naptime="$3"; shift 3
  local i
  for i in $(seq 1 "${tries}"); do
    if "$@"; then return 0; fi
    log "retry ${desc} ${i}/${tries} (transient error - webhook not ready?)"
    sleep "${naptime}"
  done
  die "gave up: ${desc}"
}

# --------------------------------------------------------------------------- #
# 1. Wait for the k0s API + the Management object (created by the kcm install).
# --------------------------------------------------------------------------- #
wait_for "k0s API readyz" 60 5 ${KUBECTL} get --raw=/readyz
wait_for "Management CRD" 60 5 \
  ${KUBECTL} get crd managements.k0rdent.mirantis.com

MGMT_NAME="kcm"
wait_for "Management/${MGMT_NAME}" 60 5 \
  ${KUBECTL} get management.k0rdent.mirantis.com "${MGMT_NAME}"

# --------------------------------------------------------------------------- #
# 2. Patch the Management object (enable Ironic + pin networking to `lab`).
#    This is what makes k0rdent install the CAPM3/Ironic/BMO provider, which in
#    turn registers the BareMetalHost CRD. So the patch MUST come BEFORE we wait
#    for that CRD (step 3) - otherwise we'd deadlock waiting for a CRD that only
#    appears as a result of this patch.
# --------------------------------------------------------------------------- #
log "rendering + applying Management patch"
rendered_patch="$(mktemp)"
envsubst <"${MANIFESTS}/management-patch.yaml" >"${rendered_patch}"
retry "Management patch" 60 5 \
  ${KUBECTL} patch management.k0rdent.mirantis.com "${MGMT_NAME}" \
    --type merge --patch-file "${rendered_patch}"
rm -f "${rendered_patch}"

# --------------------------------------------------------------------------- #
# 3. Wait for the provider to register the BareMetalHost CRD (provider install
#    pulls charts/images, so allow up to 10m), then apply the BMC Secrets +
#    BareMetalHost CRs (one rendered doc per host).
# --------------------------------------------------------------------------- #
wait_for "BareMetalHost CRD" 120 5 \
  ${KUBECTL} get crd baremetalhosts.metal3.io

apply_bmh() {
  local name="$1" uuid="$2" mac="$3"
  log "applying BareMetalHost ${name}"
  local rendered; rendered="$(mktemp)"
  BMH_NAME="${name}" BMH_UUID="${uuid}" BMH_MAC="${mac}" \
    envsubst <"${MANIFESTS}/bmh.yaml" >"${rendered}"
  # Render to a file (not a pipe) so retry can re-run apply if the metal3
  # admission webhook isn't serving yet.
  retry "apply BMH ${name}" 30 5 ${KUBECTL} apply -f "${rendered}"
  rm -f "${rendered}"
}

# Ensure target namespace exists.
${KUBECTL} get ns "${BMH_NAMESPACE}" &>/dev/null \
  || ${KUBECTL} create ns "${BMH_NAMESPACE}"

apply_bmh "${BMH0_NAME}" "${BMH0_UUID}" "${BMH0_MAC}"
apply_bmh "${BMH1_NAME}" "${BMH1_UUID}" "${BMH1_MAC}"

# --------------------------------------------------------------------------- #
# 4. BM Credential (Secret + Credential + resource-template ConfigMap) so a
#    ClusterDeployment can reference 'bm-credential'. Static (no envsubst);
#    retry for the Credential admission webhook on boot.
# --------------------------------------------------------------------------- #
log "applying BM credential (bm-credential)"
retry "apply credential" 30 5 ${KUBECTL} apply -f "${MANIFESTS}/cred.yaml"

log "setup complete - BMHs should move Registering -> Inspecting -> Available"
