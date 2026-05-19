# 01 — Design

## Goal

Quantify, on identical hardware and identical workloads, the cost
of running stock upstream Kubernetes vs. the same upstream stack
with `etcd` replaced by `fastetcd`. Targeting:

- Same kernel + same OS image
- Same `kubeadm` version + same Kubernetes release
- Same `kube-apiserver` / `kube-controller-manager` /
  `kube-scheduler` config
- Same TLS cert set (kubeadm generates it once; both variants
  use it)
- **Only difference**: the etcd binary

Anything else moving between the two runs is a confounding
variable.

## Variants

### Variant A — baseline

`kubeadm init` on a fresh Ubuntu 24.04 cloud image, default
configuration. Stock etcd runs as a static pod managed by
kubelet (`/etc/kubernetes/manifests/etcd.yaml` written by
kubeadm; image is `registry.k8s.io/etcd:<version>`).

### Variant B — fastetcd

Identical install up to and including `kubeadm init`. Then a
post-init hook:

1. Reads the etcd static-pod manifest written by kubeadm.
2. Replaces the `image:` with `ghcr.io/glennswest/fastetcd:vX.Y.Z`.
3. Rewrites the `command:` to fastetcd's flag shape (etcd's plural
   URL forms are accepted thanks to the etcd-compat flag aliases
   in fastetcd >=v0.5.0).
4. Mounts the same `/etc/kubernetes/pki/etcd/` cert directory.
5. Re-applies the manifest to `/etc/kubernetes/manifests/etcd.yaml`.

kubelet picks up the change automatically (it watches that
directory). kube-apiserver doesn't notice — it just keeps talking
to `127.0.0.1:2379` over TLS as it always did.

## Provisioning

Both VMs are provisioned via the Proxmox REST API onto
`pvex.g8.lo`. Each:

- 4 vCPU, 8 GiB RAM, 32 GiB disk, virtio-net on the host bridge.
- Boots from a clone of an Ubuntu 24.04 cloud-init template.
- Receives a per-variant `user-data` blob via a seed-ISO drive.

## Measurements

All measurements are taken **after** the cluster has been Ready
for 60 seconds (warm-up to let initial pull/init churn settle).

### Boot time

- **Wall clock**: timestamp `qm start` and poll
  `kube-apiserver` `/healthz` from outside the VM (via the
  bridge); time delta is the user-visible boot.
- **Internal breakdown**: `systemd-analyze` and
  `systemd-analyze blame` inside the VM gives per-service
  startup cost. Particularly:
  - `kubelet.service`
  - The static-pod startup time for `etcd` / `fastetcd`
  - `kube-apiserver` static-pod ready time

### RSS at idle

After the 60s warm-up, run inside the VM:

```
crictl ps --name etcd      -q -o json | jq ...  # or read /proc
ps -p $(pgrep -f 'fastetcd\|etcd ') -o pid,comm,rss,vsz
ps -p $(pgrep -f kube-apiserver) -o pid,comm,rss,vsz
ps -p $(pgrep -f kube-controller-manager) -o ...
ps -p $(pgrep -f kube-scheduler) -o ...
```

Sum the etcd-or-fastetcd RSS; report alongside the rest.

### API p99

Drive a known workload:
- Phase 1: 100 `kubectl create` + `kubectl delete` against a
  small Deployment with replica fan-out
- Phase 2: a `while true; do kubectl get pods --all-namespaces;
  done` loop running for 60s in parallel

Scrape `kube-apiserver`'s own
`apiserver_request_duration_seconds_bucket` histogram before and
after; compute p99 by RPC kind.

### Pod-start tail latency

100 pods, run as one `Job` with parallelism 10, body:
`sh -c 'echo $(date +%s%N); exit 0'`.

End-to-end time per pod = `pod.status.containerStatuses[0]
.state.terminated.startedAt` − scheduling timestamp. Report
p50/p90/p99/max.

## Reporting

Each run drops a `reports/<timestamp>/` directory containing:
- `variant-a/` and `variant-b/` subdirectories with raw measurements
- `compare.json` — diffed values
- `compare.md` — human-readable summary table

## Non-goals

- Multi-node clusters. Variant A and B are both single-node
  control planes. Multi-node fastetcd is tested in fastetcd's own
  test suite; the goal here is K8s integration, not Raft
  scalability.
- Workload performance under load that saturates the node. We're
  measuring control-plane overhead and tail latency, not
  application throughput.
- Network performance. Both variants run in the same bridge
  config; CNI is the same; we don't tune.
