#!/usr/bin/env bash
# Hit kube-apiserver with a known workload, then scrape its
# apiserver_request_duration_seconds histogram and report p99 by
# verb/resource.
#
# Usage: ./scripts/measure-api-p99.sh --vmid=110

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

# 1. Warm-up: create + delete a small deployment a few times.
echo ">> Driving workload (create/delete x 20 of nginx)..."
guest_exec '
export KUBECONFIG=/etc/kubernetes/admin.conf
for i in $(seq 1 20); do
    kubectl create deployment uptest-$i --image=nginx:alpine --replicas=2 >/dev/null
    kubectl delete deployment uptest-$i --wait=false >/dev/null
done
sleep 5
'

# 2. Scrape the apiserver metrics.
echo ">> Scraping kube-apiserver /metrics..."
METRICS=$(guest_exec 'curl -ks --cacert /etc/kubernetes/pki/ca.crt \
    --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
    --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
    https://127.0.0.1:6443/metrics 2>/dev/null \
    | grep "^apiserver_request_duration_seconds" \
    | head -100
')

cat <<EOF
{
  "vmid": ${VMID},
  "apiserver_request_duration_seconds_sample": $(jq -Rs . <<<"${METRICS}")
}
EOF
