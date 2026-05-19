#!/usr/bin/env bash
# Provision a single variant VM on Proxmox via the API.
#
# Usage: ./scripts/provision-vm.sh --variant=a|b [--vmid=110]
#
# Steps:
#   1. Allocate a VMID (auto, unless --vmid given).
#   2. Clone the Ubuntu cloud-init template (config.UBUNTU_TEMPLATE_VMID).
#   3. Attach the rendered seed ISO from build/<variant>/seed.iso.
#   4. Resize the disk, set CPU/RAM/network, enable QGA.
#   5. Start the VM; wait for QGA; wait for /var/lib/uptest.done.
#   6. Print {vmid, ip, ready_secs}.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_cmd jq curl

VARIANT=""
VMID=""
for arg in "$@"; do
    case "${arg}" in
        --variant=*) VARIANT="${arg#--variant=}";;
        --vmid=*)    VMID="${arg#--vmid=}";;
        *) echo "unknown arg: ${arg}"; exit 2;;
    esac
done
[[ -z "${VARIANT}" ]] && { echo "missing --variant=a|b" >&2; exit 2; }
[[ "${VARIANT}" != "a" && "${VARIANT}" != "b" ]] && { echo "variant must be a or b" >&2; exit 2; }

SEED="${REPO_ROOT}/build/variant-${VARIANT}/seed.iso"
if [[ ! -f "${SEED}" ]]; then
    echo "missing ${SEED} — run scripts/build-images.sh first" >&2
    exit 3
fi

[[ -z "${VMID}" ]] && VMID=$(next_vmid)
NAME="uptest-${VARIANT}-${VMID}"
echo ">> Provisioning ${NAME} (vmid=${VMID})..."

# 1. Clone the Ubuntu template.
pveapi POST "/nodes/${PROXMOX_NODE}/qemu/${UBUNTU_TEMPLATE_VMID}/clone" \
    -d "newid=${VMID}&name=${NAME}&full=1&storage=${PROXMOX_STORAGE}" \
    | jq -r '.data' > /tmp/clone-task.id
sleep 5  # wait for clone task to register

# 2. Upload the seed.iso to Proxmox (use the API node disk store).
ISO_REMOTE="seed-${NAME}.iso"
echo ">> Uploading ${SEED} as ${ISO_REMOTE}..."
curl --silent --show-error --fail \
    -k \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN}" \
    -F "content=iso" \
    -F "filename=@${SEED};filename=${ISO_REMOTE}" \
    "https://${PROXMOX_HOST}/api2/json/nodes/${PROXMOX_NODE}/storage/${PROXMOX_STORAGE}/upload" \
    > /tmp/upload.json
SEED_VOLID="${PROXMOX_STORAGE}:iso/${ISO_REMOTE}"

# 3. Wire the seed ISO into the VM as a CDROM, set cpu/ram/QGA.
pveapi PUT "/nodes/${PROXMOX_NODE}/qemu/${VMID}/config" \
    -d "ide2=${SEED_VOLID},media=cdrom" \
    -d "cores=4" \
    -d "memory=8192" \
    -d "agent=1" \
    -d "boot=order=scsi0;ide2" \
    -d "net0=virtio,bridge=${PROXMOX_BRIDGE}"

# 4. Resize root disk to 32G if it's smaller.
pveapi PUT "/nodes/${PROXMOX_NODE}/qemu/${VMID}/resize" \
    -d "disk=scsi0&size=32G" || true

# 5. Start. Record start timestamp; everything after is boot time.
START_TS=$(date +%s)
pveapi POST "/nodes/${PROXMOX_NODE}/qemu/${VMID}/status/start" >/dev/null

echo ">> Waiting for QGA..."
wait_for_qga "${VMID}" 600

IP=$(vm_ip "${VMID}")
echo ">> VM ${VMID} has IP ${IP}"

# 6. Poll /var/lib/uptest.done via QGA file-read.
echo ">> Waiting for uptest-install.sh to finish..."
DONE_DEADLINE=$(( $(date +%s) + 1800 ))
while true; do
    if (( $(date +%s) > DONE_DEADLINE )); then
        echo "uptest-install.sh did not finish in 30 minutes" >&2
        exit 6
    fi
    if pveapi POST "/nodes/${PROXMOX_NODE}/qemu/${VMID}/agent/file-read" \
        --data-urlencode "file=/var/lib/uptest.done" >/dev/null 2>&1; then
        break
    fi
    sleep 5
done
READY_TS=$(date +%s)

cat <<EOF
{
  "variant": "${VARIANT}",
  "vmid": ${VMID},
  "name": "${NAME}",
  "ip": "${IP}",
  "ready_secs_wallclock": $((READY_TS - START_TS))
}
EOF
