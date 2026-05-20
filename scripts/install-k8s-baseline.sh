#!/usr/bin/env bash
# Install upstream Kubernetes (kubeadm + kubelet + kubectl 1.31)
# on a fresh Fedora 43 cloud VM, then `kubeadm init`. Idempotent:
# safe to re-run on the same VM (does kubeadm reset first).
#
# Designed to be SCP'd to a target VM and executed as root via SSH.
# Logs go to stdout/stderr; touches /var/lib/kubetest.done at the
# end as the completion sentinel.

set -euo pipefail

K8S_MINOR="${K8S_MINOR:-1.31}"
K8S_VERSION="${K8S_VERSION:-1.31.4}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SVC_CIDR="${SVC_CIDR:-10.96.0.0/12}"
FLANNEL_URL="${FLANNEL_URL:-https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml}"

log() { echo "[install-k8s-baseline] $*" >&2; }

# 1. Swap off (Fedora 43 uses zram by default — mask it).
log "disabling swap"
systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl mask  systemd-zram-setup@zram0.service 2>/dev/null || true
swapoff -a || true
zramctl --reset /dev/zram0 2>/dev/null || true
sed -i.bak '/ swap / s/^/#/' /etc/fstab || true

# 2. selinux permissive (matches upstream kubeadm Fedora guidance).
log "selinux permissive"
setenforce 0 || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config || true

# 3. firewall ports.
log "open firewall ports"
if systemctl is-active --quiet firewalld; then
    for p in 6443/tcp 2379-2380/tcp 10250/tcp 10257/tcp 10259/tcp 2381/tcp; do
        firewall-cmd --permanent --add-port=$p >/dev/null
    done
    firewall-cmd --permanent --add-port=8472/udp >/dev/null
    firewall-cmd --reload >/dev/null
fi

# 4. Kernel modules + sysctl.
log "kernel modules + sysctl"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# 5. containerd.
log "installing containerd"
dnf install -y containerd jq iptables-services iproute-tc >/dev/null
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

# 6. Kubernetes pkg repo + install. dnf5 doesn't accept
#    --disableexcludes; strip the exclude line for install then
#    re-add it so subsequent upgrades stay pinned.
log "installing kubelet/kubeadm/kubectl ${K8S_VERSION}"
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/repodata/repomd.xml.key
EOF
dnf install -y kubelet-${K8S_VERSION} kubeadm-${K8S_VERSION} kubectl-${K8S_VERSION} >/dev/null
printf 'exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni\n' \
    >> /etc/yum.repos.d/kubernetes.repo

# 7. kubeadm reset + clean dirs (idempotent).
log "kubeadm reset (idempotent)"
kubeadm reset --force >/dev/null 2>&1 || true
rm -rf /etc/cni/net.d /var/lib/etcd /etc/kubernetes/manifests/* \
       /var/lib/kubelet/* /etc/kubernetes/pki/* /etc/kubernetes/*.conf
systemctl restart containerd
systemctl enable --now kubelet
systemctl restart kubelet
sleep 2

# 8. kubeadm init.
log "kubeadm init"
START_TS=$(date +%s)
kubeadm init \
    --pod-network-cidr=${POD_CIDR} \
    --service-cidr=${SVC_CIDR} \
    --ignore-preflight-errors=NumCPU,Mem >/var/log/kubeadm-init.log 2>&1
INIT_END_TS=$(date +%s)
log "kubeadm init completed in $((INIT_END_TS - START_TS))s"

# 9. kubeconfig.
mkdir -p /home/fedora/.kube /root/.kube
cp -f /etc/kubernetes/admin.conf /home/fedora/.kube/config
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown -R fedora:fedora /home/fedora/.kube

# 10. Untaint + Flannel CNI.
log "applying Flannel"
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
kubectl apply -f "${FLANNEL_URL}" >/dev/null

# 11. Wait for node Ready.
log "waiting for node Ready"
for i in $(seq 1 60); do
    if kubectl get nodes 2>/dev/null | tail -1 | grep -q ' Ready '; then
        READY_TS=$(date +%s)
        log "node Ready after $((READY_TS - START_TS))s (since kubeadm init start)"
        break
    fi
    sleep 5
done

# 12. Sentinel.
touch /var/lib/kubetest.done
echo "$(date -Is)" > /var/lib/kubetest.done

log "DONE"
kubectl get nodes -o wide
kubectl get pods -A
