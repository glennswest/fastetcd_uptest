#!/usr/bin/env bash
# Create 100 pods (via a Job with parallelism 10), record per-pod
# end-to-end time from creation to Ready. Report p50/p90/p99/max.
#
# Usage: ./scripts/measure-pod-start.sh --vmid=110

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

# Apply the test Job + wait for completion + pull per-pod
# StartedAt - CreationTimestamp.
RESULTS=$(guest_exec '
export KUBECONFIG=/etc/kubernetes/admin.conf
cat > /tmp/pod-burst.yaml <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: uptest-burst
spec:
  parallelism: 10
  completions: 100
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: c
          image: busybox:1.36
          command: ["sh", "-c", "exit 0"]
YAML
kubectl apply -f /tmp/pod-burst.yaml >/dev/null
# Wait for all 100 pods to terminate.
for i in $(seq 1 300); do
    success=$(kubectl get job uptest-burst -o jsonpath="{.status.succeeded}" 2>/dev/null || echo 0)
    [ "${success:-0}" = "100" ] && break
    sleep 1
done
# Collect per-pod (creationTimestamp, status.startTime).
kubectl get pods -l job-name=uptest-burst \
    -o jsonpath='"'"'{range .items[*]}{.metadata.creationTimestamp}{"\t"}{.status.containerStatuses[0].state.terminated.startedAt}{"\n"}{end}'"'"'
kubectl delete job uptest-burst --wait=false >/dev/null
')

cat <<EOF
{
  "vmid": ${VMID},
  "pod_start_pairs_creation_started": $(jq -Rs . <<<"${RESULTS}")
}
EOF
