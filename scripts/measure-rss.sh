#!/usr/bin/env bash
# Measure RSS of every interesting control-plane process.
#
# Usage: ./scripts/measure-rss.sh --vmid=110

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"
require_cmd jq

VMID=""
for arg in "$@"; do
    case "${arg}" in --vmid=*) VMID="${arg#--vmid=}";; esac
done
[[ -z "${VMID}" ]] && { echo "missing --vmid" >&2; exit 2; }

guest_exec() {
    local cmd="$1"
    local pid
    pid=$(pveapi POST "/nodes/${PROXMOX_NODE}/qemu/${VMID}/agent/exec" \
        --data-urlencode "command=bash -c \"${cmd}\"" \
        | jq -r '.data.pid')
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

REPORT=$(guest_exec '
for pattern in "etcd \\|fastetcd " "kube-apiserver" "kube-controller-manager" "kube-scheduler" "kubelet"; do
    pids=$(pgrep -f "${pattern}" || true)
    for p in $pids; do
        if [ -r /proc/$p/status ]; then
            comm=$(awk -F: '"'"'/^Name:/ {gsub(/^ +/, "", $2); print $2}'"'"' /proc/$p/status)
            rss=$(awk '"'"'/^VmRSS:/ {print $2}'"'"' /proc/$p/status)
            echo "{\"pid\":$p,\"comm\":\"$comm\",\"rss_kib\":$rss,\"match\":\"$pattern\"}"
        fi
    done
done | jq -s .
')

cat <<EOF
{
  "vmid": ${VMID},
  "rss": ${REPORT}
}
EOF
