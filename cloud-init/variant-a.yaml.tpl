#cloud-config
# Variant A — vanilla upstream Kubernetes.
#
# Installs containerd + kubeadm + kubelet + kubectl from the
# upstream pkgs.k8s.io repo, runs `kubeadm init`, deploys flannel
# as a minimal CNI, untaints the control-plane node so workloads
# can land on it.

hostname: ${HOSTNAME}
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ubuntu       # development only; rotate in production
    ssh_authorized_keys: []          # add your pubkey to this list for SSH

package_update: true
package_upgrade: false

write_files:
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter

  - path: /etc/sysctl.d/k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1

  - path: /etc/apt/keyrings/kubernetes-apt-keyring.asc
    permissions: '0644'
    content: |
      # Placeholder — replaced at runtime by `curl ... | tee` below.
      key-goes-here

  - path: /usr/local/bin/uptest-install.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euxo pipefail

      # Disable swap (kubeadm requires).
      swapoff -a
      sed -i.bak '/ swap / s/^/#/' /etc/fstab || true

      # Kernel modules + sysctl.
      modprobe overlay
      modprobe br_netfilter
      sysctl --system

      # containerd.
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
          containerd ca-certificates curl gpg jq qemu-guest-agent
      mkdir -p /etc/containerd
      containerd config default > /etc/containerd/config.toml
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      systemctl restart containerd
      systemctl enable --now qemu-guest-agent

      # kubeadm/kubelet/kubectl from upstream pkgs.k8s.io.
      install -d -m 0755 /etc/apt/keyrings
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key \
        | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
          kubelet=${K8S_VERSION} kubeadm=${K8S_VERSION} kubectl=${K8S_VERSION}
      apt-mark hold kubelet kubeadm kubectl

      # kubeadm init.
      kubeadm init \
          --pod-network-cidr=${POD_CIDR} \
          --service-cidr=${SERVICE_CIDR} \
          --ignore-preflight-errors=NumCPU,Mem

      # Make kubectl usable as the ubuntu user.
      mkdir -p /home/ubuntu/.kube
      cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
      chown -R ubuntu:ubuntu /home/ubuntu/.kube

      # Untaint so workloads can land on the control-plane.
      KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

      # Flannel CNI (small, no operator).
      KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f \
        https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

      # Mark "uptest done" so measure scripts know the node is ready.
      touch /var/lib/uptest.done

runcmd:
  - /usr/local/bin/uptest-install.sh > /var/log/uptest-install.log 2>&1
