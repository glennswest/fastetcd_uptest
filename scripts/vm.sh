#!/usr/bin/env bash
# Proxmox VM helpers (over SSH to pve.g8.lo). Idempotent:
# create_vm fails-noisy if VMID exists; destroy_vm is safe to
# call on missing VMIDs.

set -euo pipefail

PVE_HOST="${PVE_HOST:-root@pve.g8.lo}"
PVE_STORAGE="${PVE_STORAGE:-local-lvm}"
PVE_BRIDGE="${PVE_BRIDGE:-vmbr0}"
PVE_IMG="${PVE_IMG:-/var/lib/vz/template/iso/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2}"
PVE_SNIPPETS="${PVE_SNIPPETS:-/var/lib/vz/snippets}"

vm_exists() {
    local vmid="$1"
    ssh "${PVE_HOST}" "qm status ${vmid} >/dev/null 2>&1"
}

destroy_vm() {
    local vmid="$1"
    if vm_exists "${vmid}"; then
        echo "VM ${vmid}: stopping + destroying"
        ssh "${PVE_HOST}" "qm stop ${vmid} --skiplock 1 --timeout 30 2>/dev/null || true; sleep 2; qm destroy ${vmid} --purge --destroy-unreferenced-disks 1"
    else
        echo "VM ${vmid}: already absent"
    fi
}

# create_vm <vmid> <name> <ip>
#
# Builds a Fedora-43 cloud-init VM with minimal user-data (just
# enable QGA + create the fedora user with our SSH key). No
# kubeadm install in cloud-init — that's done over SSH afterwards.
create_vm() {
    local vmid="$1"
    local name="$2"
    local ip="$3"

    if vm_exists "${vmid}"; then
        echo "VM ${vmid} already exists; refuse to recreate without destroy_vm first" >&2
        return 1
    fi

    # Render minimal cloud-init snippets.
    local tmp
    tmp=$(mktemp -d)
    cat > "${tmp}/${name}-user-data.yaml" <<EOF
#cloud-config
hostname: ${name%%.*}
fqdn: ${name}
prefer_fqdn_over_hostname: true
users:
  - name: fedora
    groups: [wheel, adm, systemd-journal]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDWUsb0I159v27vSBuOOyQMX54iD2zuKZOOy+e5GRCJ3yONNr3Mkdyng67BNfsnvlf8kpgSi0yiaVGeXKSjkrY9YPHe0wkVW0UHZ9uZqYqgVdEzSG3Z0NNkrd/zp3jCztPad+q6iWb1R0iFlK7/h8NihOky9HXOustrtDwnvTgONwJnluxQp1zl86deKP0W9xx3Ky/Jobr3dbfOhJVK3qzF6OL6KaNjpT+hDYjh1OISzrx1jWLxFvZ4r7X2wbRhcNRyD5sTrxcs3z5Xdz/KRT0UhIj47CF4Heoiqtl/aQ5kdjpRqlmC2spJ9WZinsqbb6HhZ1i8Yd2ZycDQZF+S8n1n gwest@Glenns-MacBook-Pro.local
ssh_pwauth: false
package_update: false
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
final_message: "${name} cloud-init complete in \$UPTIME seconds"
EOF
    cat > "${tmp}/${name}-network-config.yaml" <<EOF
version: 2
ethernets:
  ens18:
    match:
      name: "en*"
    dhcp4: false
    dhcp6: false
    addresses:
      - ${ip}/24
    gateway4: 192.168.8.1
    nameservers:
      addresses: [192.168.8.252, 192.168.1.252]
      search: [g8.lo]
EOF

    scp -q "${tmp}/${name}-user-data.yaml" "${tmp}/${name}-network-config.yaml" \
        "${PVE_HOST}:${PVE_SNIPPETS}/"
    rm -rf "${tmp}"

    ssh "${PVE_HOST}" "set -e
        qm create ${vmid} --name ${name} --memory 8192 --cores 4 --sockets 1 \
            --cpu host --machine q35 --bios ovmf --ostype l26 \
            --net0 virtio,bridge=${PVE_BRIDGE} --agent enabled=1 \
            --scsihw virtio-scsi-single --serial0 socket --vga serial0
        qm set ${vmid} --efidisk0 ${PVE_STORAGE}:0,efitype=4m,pre-enrolled-keys=0,size=4M
        qm importdisk ${vmid} ${PVE_IMG} ${PVE_STORAGE} --format raw
        qm set ${vmid} --scsi0 ${PVE_STORAGE}:vm-${vmid}-disk-1,discard=on,iothread=1,ssd=1
        qm resize ${vmid} scsi0 32G
        qm set ${vmid} --ide2 ${PVE_STORAGE}:cloudinit
        qm set ${vmid} --cicustom \"user=local:snippets/${name}-user-data.yaml,network=local:snippets/${name}-network-config.yaml\"
        qm set ${vmid} --ipconfig0 ip=${ip}/24,gw=192.168.8.1
        qm set ${vmid} --boot order=scsi0"
    echo "VM ${vmid} (${name} @ ${ip}) created"
}

start_vm() {
    local vmid="$1"
    ssh "${PVE_HOST}" "qm start ${vmid}"
    echo "VM ${vmid} started"
}

# Wait for SSH to answer as fedora@${host}, up to deadline seconds.
wait_for_ssh() {
    local host="$1"
    local deadline_secs="${2:-300}"
    local start=$(date +%s)
    while true; do
        if (( $(date +%s) - start > deadline_secs )); then
            echo "wait_for_ssh: ${host} did not answer in ${deadline_secs}s" >&2
            return 1
        fi
        if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "fedora@${host}" 'echo ok' >/dev/null 2>&1; then
            echo "${host}: SSH ready after $(($(date +%s) - start))s"
            return 0
        fi
        sleep 5
    done
}
