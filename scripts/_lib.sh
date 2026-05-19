#!/usr/bin/env bash
# Shared helpers for fastetcd_uptest scripts. Sourced via `source _lib.sh`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load proxmox/config.env (required by every script).
CONFIG="${REPO_ROOT}/proxmox/config.env"
if [[ ! -f "${CONFIG}" ]]; then
    echo "missing ${CONFIG} — copy from proxmox/config.sample.env" >&2
    exit 2
fi
# shellcheck source=/dev/null
source "${CONFIG}"

require_cmd() {
    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            echo "required command not found: ${cmd}" >&2
            exit 3
        fi
    done
}

# Curl wrapper that authenticates with the Proxmox API token and
# refuses unknown CAs by default — set PROXMOX_INSECURE=1 to skip
# verification (only for self-signed CA bring-up).
pveapi() {
    local method="$1"; shift
    local path="$1"; shift
    local extra_curl=("$@")
    local insecure_arg=()
    if [[ "${PROXMOX_INSECURE:-0}" == "1" ]]; then
        insecure_arg=(-k)
    fi
    curl --silent --show-error --fail \
        "${insecure_arg[@]}" \
        -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN}" \
        -X "${method}" \
        "https://${PROXMOX_HOST}/api2/json${path}" \
        "${extra_curl[@]}"
}

# Pick the next available VMID inside the configured range that
# Proxmox doesn't already have a VM for.
next_vmid() {
    local existing
    existing=$(pveapi GET "/cluster/resources?type=vm" \
        | jq -r '.data[].vmid' | sort -u)
    for vmid in $(seq "${VMID_RANGE_START}" "${VMID_RANGE_END}"); do
        if ! grep -qx "${vmid}" <<<"${existing}"; then
            echo "${vmid}"
            return 0
        fi
    done
    echo "no free VMID in range ${VMID_RANGE_START}-${VMID_RANGE_END}" >&2
    exit 4
}

# Poll until the named cloud-init Qemu Guest Agent reports the VM
# is up, or until `deadline_secs` elapses.
wait_for_qga() {
    local vmid="$1"
    local deadline_secs="${2:-300}"
    local start=$(date +%s)
    while true; do
        local now=$(date +%s)
        if (( now - start > deadline_secs )); then
            echo "VM ${vmid} did not respond on QGA in ${deadline_secs}s" >&2
            return 5
        fi
        if pveapi POST "/nodes/${PROXMOX_NODE}/qemu/${vmid}/agent/ping" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
}

# Fetch the VM's primary IP via QGA.
vm_ip() {
    local vmid="$1"
    pveapi GET "/nodes/${PROXMOX_NODE}/qemu/${vmid}/agent/network-get-interfaces" \
        | jq -r '.data.result[] | select(.name != "lo") | .["ip-addresses"][]
                 | select(.["ip-address-type"] == "ipv4") | .["ip-address"]' \
        | head -1
}
