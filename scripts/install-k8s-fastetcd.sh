#!/usr/bin/env bash
# Variant B: identical to install-k8s-baseline.sh through
# kubeadm init, then rewrite the etcd static-pod manifest to
# launch the fastetcd container image using kubeadm's existing
# /etc/kubernetes/pki/etcd/ cert set.

set -euo pipefail

FASTETCD_IMAGE="${FASTETCD_IMAGE:-ghcr.io/glennswest/fastetcd:latest}"

# 1. Run the baseline install first.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/install-k8s-baseline.sh"

echo "[install-k8s-fastetcd] swapping etcd for fastetcd"

# 2. Rewrite the etcd static-pod manifest. kubelet watches
#    /etc/kubernetes/manifests/ and will terminate the stock etcd
#    pod + start fastetcd in its place.
cat > /etc/kubernetes/manifests/etcd.yaml <<YAML
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
        grpc: { port: 2379 }
      readinessProbe:
        grpc: { port: 2379 }
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

echo "[install-k8s-fastetcd] DONE — kubelet will roll the etcd pod over to fastetcd"
