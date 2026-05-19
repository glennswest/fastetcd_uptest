#!/usr/bin/env bash
# Measure boot-time breakdown inside a running uptest VM. Returns
# JSON with wall-clock-ready + systemd-analyze numbers.
#
# Usage: ./scripts/measure-boot.sh --vmid=110

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"
require_cmd jq

VMID=""
for arg in "$@"; do
    case "${arg}" in
        --vmid=*) VMID="${arg#--vmid=}";;
        *) echo "unknown arg: ${arg}"; exit 2;;
    esac
done
[[ -z "${VMID}" ]] && { echo "missing --vmid" >&2; exit 2; }

# Run a shell command in the guest via QGA exec.
guest_exec() {
    local cmd="$1"
    local pid
    pid=$(pveapi POST "/nodes/${PROXMOX_NODE}/qemu/${VMID}/agent/exec" \
        --data-urlencode "command=bash -c \"${cmd}\"" \
        | jq -r '.data.pid')
    # Poll for exit-status.
    while true; do
        local r
        r=$(pveapi GET "/nodes/${PROXMOX_NODE}/qemu/${VMID}/agent/exec-status?pid=${pid}")
        if [[ "$(jq -r '.data.exited' <<<"${r}")" == "1" ]]; then
            jq -r '.data.["out-data"] // ""' <<<"${r}"
            return
        fi
        sleep 1
    done
}

ANALYZE=$(guest_exec "systemd-analyze --no-pager")
BLAME=$(guest_exec "systemd-analyze blame --no-pager | head -20")
KUBELET_READY=$(guest_exec "systemctl show kubelet -p ActiveEnterTimestamp --value")
APISERVER_READY=$(guest_exec "kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw /healthz 2>&1 && echo OK || echo NOT_READY")

cat <<EOF
{
  "vmid": ${VMID},
  "systemd_analyze": $(jq -Rs . <<<"${ANALYZE}"),
  "systemd_blame_top20": $(jq -Rs . <<<"${BLAME}"),
  "kubelet_active_timestamp": $(jq -Rs . <<<"${KUBELET_READY}"),
  "apiserver_healthz": $(jq -Rs . <<<"${APISERVER_READY}")
}
EOF
