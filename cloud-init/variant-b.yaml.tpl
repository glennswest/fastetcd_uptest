#cloud-config
# Variant B — upstream Kubernetes with etcd replaced by fastetcd.
#
# Identical to variant A up to and including `kubeadm init`. After
# init succeeds, a post-step rewrites the etcd static-pod manifest
# to launch the fastetcd container image with the same TLS cert
# set kubeadm generated for stock etcd.
#
# kubelet watches /etc/kubernetes/manifests/, so swapping the
# manifest causes it to terminate the stock etcd pod and start
# fastetcd in its place — kube-apiserver doesn't notice the
# change; it keeps dialing 127.0.0.1:2379 over TLS as always.

hostname: ${HOSTNAME}
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ubuntu
    ssh_authorized_keys: []

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

  - path: /usr/local/bin/uptest-install.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euxo pipefail

      swapoff -a
      sed -i.bak '/ swap / s/^/#/' /etc/fstab || true

      modprobe overlay
      modprobe br_netfilter
      sysctl --system

      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
          containerd ca-certificates curl gpg jq qemu-guest-agent
      mkdir -p /etc/containerd
      containerd config default > /etc/containerd/config.toml
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      systemctl restart containerd
      systemctl enable --now qemu-guest-agent

      install -d -m 0755 /etc/apt/keyrings
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key \
        | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
          kubelet=${K8S_VERSION} kubeadm=${K8S_VERSION} kubectl=${K8S_VERSION}
      apt-mark hold kubelet kubeadm kubectl

      kubeadm init \
          --pod-network-cidr=${POD_CIDR} \
          --service-cidr=${SERVICE_CIDR} \
          --ignore-preflight-errors=NumCPU,Mem

      # --- the variant B difference: swap etcd for fastetcd ----
      # The kubeadm-generated etcd manifest lives at
      # /etc/kubernetes/manifests/etcd.yaml. We rewrite it to run
      # the fastetcd container with the same hostPaths and certs.
      cat > /etc/kubernetes/manifests/etcd.yaml <<'YAML'
      apiVersion: v1
      kind: Pod
      metadata:
        name: etcd
        namespace: kube-system
        labels:
          component: etcd
          tier: control-plane
      spec:
        priorityClassName: system-node-critical
        hostNetwork: true
        containers:
          - name: etcd
            image: ${FASTETCD_IMAGE}
            command:
              - /usr/local/bin/fastetcd
              - --name=swap-node
              - --data-dir=/var/lib/etcd
              - --listen-client-urls=https://127.0.0.1:2379
              - --advertise-client-urls=https://127.0.0.1:2379
              - --listen-peer-urls=https://127.0.0.1:2380
              - --initial-advertise-peer-urls=https://127.0.0.1:2380
              - --initial-cluster=swap-node=https://127.0.0.1:2380
              - --cert-file=/etc/kubernetes/pki/etcd/server.crt
              - --key-file=/etc/kubernetes/pki/etcd/server.key
              - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
              - --client-cert-auth
              - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
              - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
              - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
              - --peer-client-cert-auth
              - --listen-metrics-url=http://127.0.0.1:2381
            volumeMounts:
              - name: etcd-certs
                mountPath: /etc/kubernetes/pki/etcd
                readOnly: true
              - name: etcd-data
                mountPath: /var/lib/etcd
            livenessProbe:
              grpc:
                port: 2379
            readinessProbe:
              grpc:
                port: 2379
        volumes:
          - name: etcd-certs
            hostPath:
              path: /etc/kubernetes/pki/etcd
              type: DirectoryOrCreate
          - name: etcd-data
            hostPath:
              path: /var/lib/etcd
              type: DirectoryOrCreate
      YAML
      # kubelet picks the new manifest up automatically.

      mkdir -p /home/ubuntu/.kube
      cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
      chown -R ubuntu:ubuntu /home/ubuntu/.kube

      KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
      KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f \
        https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

      touch /var/lib/uptest.done

runcmd:
  - /usr/local/bin/uptest-install.sh > /var/log/uptest-install.log 2>&1
