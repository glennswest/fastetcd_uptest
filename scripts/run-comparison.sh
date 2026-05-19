#!/usr/bin/env bash
# Top-level orchestrator: build seed ISOs, provision both
# variants in parallel, wait for both to be Ready, run all
# measurements, write reports/<timestamp>/.
#
# Usage: ./scripts/run-comparison.sh

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

TS=$(date +%Y%m%d-%H%M%S)
OUT="${REPO_ROOT}/reports/${TS}"
mkdir -p "${OUT}/variant-a" "${OUT}/variant-b"
echo ">> Reports will land in ${OUT}"

# 1. Build cloud-init seed ISOs.
"${HERE}/build-images.sh"

# 2. Provision both VMs in parallel.
echo ">> Provisioning both variants in parallel..."
"${HERE}/provision-vm.sh" --variant=a > "${OUT}/variant-a/provision.json" &
PID_A=$!
"${HERE}/provision-vm.sh" --variant=b > "${OUT}/variant-b/provision.json" &
PID_B=$!
wait ${PID_A}; wait ${PID_B}

VMID_A=$(jq -r '.vmid' "${OUT}/variant-a/provision.json")
VMID_B=$(jq -r '.vmid' "${OUT}/variant-b/provision.json")
echo ">> Variant A vmid=${VMID_A}, Variant B vmid=${VMID_B}"

# 3. Wait 60s warm-up so transient init churn dies down.
echo ">> Warm-up: 60s..."
sleep 60

# 4. Run measurements in parallel across both VMs.
for which in a b; do
    VMID="VMID_${which^^}"
    VMID="${!VMID}"
    "${HERE}/measure-boot.sh"      --vmid="${VMID}" > "${OUT}/variant-${which}/boot.json"     &
    "${HERE}/measure-rss.sh"       --vmid="${VMID}" > "${OUT}/variant-${which}/rss.json"      &
    "${HERE}/measure-api-p99.sh"   --vmid="${VMID}" > "${OUT}/variant-${which}/api-p99.json"  &
    "${HERE}/measure-pod-start.sh" --vmid="${VMID}" > "${OUT}/variant-${which}/pod-start.json" &
done
wait

# 5. Render compare.md (rough — refine after the first run).
{
    echo "# fastetcd_uptest run ${TS}"
    echo
    for which in a b; do
        echo "## Variant ${which^^}"
        VMID="VMID_${which^^}"
        VMID="${!VMID}"
        echo
        echo "- vmid: \`${VMID}\`"
        echo "- provision ready (wallclock secs): $(jq -r '.ready_secs_wallclock' "${OUT}/variant-${which}/provision.json")"
        echo "- systemd-analyze: see boot.json"
        echo "- rss: see rss.json"
        echo "- API p99 sample: see api-p99.json"
        echo "- pod-start pairs: see pod-start.json"
        echo
    done
} > "${OUT}/compare.md"

echo ">> Done. ${OUT}/compare.md is the entry point."
