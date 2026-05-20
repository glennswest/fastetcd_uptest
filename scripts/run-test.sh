#!/usr/bin/env bash
# End-to-end test cycle, designed to be run 100x:
#
#   ./scripts/run-test.sh --variant=a [--name=kubetest] [--vmid=113]
#                          [--ip=192.168.8.153] [--keep-on-failure]
#
# Steps (every step idempotent):
#   1. Ensure DNS A record name.g8.lo → ip
#   2. Destroy any existing VM at that VMID
#   3. Create + start a fresh Fedora 43 cloud-init VM
#   4. Wait for SSH
#   5. SCP + run install-k8s-baseline.sh OR install-k8s-fastetcd.sh
#   6. Print the per-phase wall-clock timings to stdout
#
# Exit status mirrors success of the install script. With
# --keep-on-failure, leaves the VM behind for inspection.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dns.sh
source "${HERE}/dns.sh"
# shellcheck source=vm.sh
source "${HERE}/vm.sh"

VARIANT="a"
NAME="kubetest"
VMID="113"
IP="192.168.8.153"
KEEP_ON_FAILURE=0
for arg in "$@"; do
    case "${arg}" in
        --variant=*)         VARIANT="${arg#--variant=}";;
        --name=*)            NAME="${arg#--name=}";;
        --vmid=*)            VMID="${arg#--vmid=}";;
        --ip=*)              IP="${arg#--ip=}";;
        --keep-on-failure)   KEEP_ON_FAILURE=1;;
        -h|--help)
            grep -E '^#' "$0" | head -25; exit 0;;
        *) echo "unknown arg: ${arg}" >&2; exit 2;;
    esac
done
[[ "${VARIANT}" != "a" && "${VARIANT}" != "b" ]] && { echo "variant must be a or b" >&2; exit 2; }

INSTALL_SCRIPT="install-k8s-baseline.sh"
[[ "${VARIANT}" == "b" ]] && INSTALL_SCRIPT="install-k8s-fastetcd.sh"

FQDN="${NAME}.g8.lo"
START_TS=$(date +%s)
log() { echo "[run-test variant=${VARIANT} ${NAME}@${IP}] $*" >&2; }

trap '_rc=$?
if (( _rc != 0 )) && (( KEEP_ON_FAILURE == 0 )); then
    log "failure (rc=${_rc}); cleaning up VM ${VMID}"
    destroy_vm "${VMID}" || true
fi
exit ${_rc}' EXIT

# ----- 1. DNS ----------------------------------------------------
log "ensure DNS"
ensure_a_record "${NAME}" "${IP}"

# ----- 2. wipe + 3. create + 4. start ----------------------------
DESTROY_START=$(date +%s)
destroy_vm "${VMID}"
log "destroy took $(( $(date +%s) - DESTROY_START ))s"

CREATE_START=$(date +%s)
create_vm "${VMID}" "${FQDN}" "${IP}"
start_vm "${VMID}"
log "create+start took $(( $(date +%s) - CREATE_START ))s"

# ----- 5. wait for SSH -------------------------------------------
SSH_WAIT_START=$(date +%s)
# Clear any stale host key from prior runs.
ssh-keygen -R "${FQDN}" >/dev/null 2>&1 || true
ssh-keygen -R "${IP}"   >/dev/null 2>&1 || true
wait_for_ssh "${FQDN}" 600
log "ssh ready after $(( $(date +%s) - SSH_WAIT_START ))s"

# ----- 6. push + run install script ------------------------------
INSTALL_START=$(date +%s)
log "pushing ${INSTALL_SCRIPT}"
scp -q "${HERE}/install-k8s-baseline.sh" "fedora@${FQDN}:/tmp/install-k8s-baseline.sh"
if [[ "${VARIANT}" == "b" ]]; then
    scp -q "${HERE}/install-k8s-fastetcd.sh" "fedora@${FQDN}:/tmp/install-k8s-fastetcd.sh"
fi
ssh "fedora@${FQDN}" "chmod +x /tmp/install-k8s-*.sh && sudo /tmp/${INSTALL_SCRIPT}"
log "install completed in $(( $(date +%s) - INSTALL_START ))s"

TOTAL=$((  $(date +%s) - START_TS ))
log "TOTAL wall-clock: ${TOTAL}s"

# Stay-on-success: trap exits with the script's rc and the trap
# leaves the VM in place when rc==0.
echo
echo "kubeconfig retrieval:"
echo "  ssh fedora@${FQDN} sudo cat /etc/kubernetes/admin.conf"
