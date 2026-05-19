# fastetcd_uptest

End-to-end validation harness for [`fastetcd`](../fastetcd): build
two Kubernetes VMs from upstream cloud images, one with stock etcd
and one with fastetcd swapped in, measure boot time + memory
footprint + API server latency, compare.

## What this does

Two variants:

| Variant | What's installed | Why |
|---|---|---|
| **A — baseline** | Upstream Ubuntu 24.04 cloud-img + upstream kubeadm + stock etcd (static pod managed by kubelet) | Establishes the baseline for comparison |
| **B — fastetcd** | Same image + kubeadm, then the etcd static pod is replaced with a fastetcd container using the same TLS cert set kubeadm generates | Same control plane, only etcd swapped — isolates the variable we care about |

Both VMs are provisioned via the Proxmox REST API onto `pvex.g8.lo`
and exercised by an identical workload. Results are emitted as a
side-by-side report.

## What's measured

- **Boot time**: wall-clock from `qm start` to `kube-apiserver`
  responding `200` on `/healthz`; plus `systemd-analyze` breakdown
  from inside the VM.
- **Control-plane RSS at idle**: `RSS` of the etcd/fastetcd
  process, plus `kube-apiserver` / `kube-controller-manager` /
  `kube-scheduler`, measured after the cluster has been Ready for
  60 seconds.
- **API server p99 under load**: drive
  `etcd-io/perf-tests/clusterloader2`-style workload (or a small
  curl-based generator), scrape `kube-apiserver`'s own
  `apiserver_request_duration_seconds` histogram, report p99.
- **Pod-start tail latency**: `kubectl apply` 100 pods, record
  end-to-end time to `Ready` per pod, report p50/p90/p99/max.

## Status

Pre-alpha scaffolding. Scripts are written; nothing has been run
against a real Proxmox yet. See `docs/01-design.md` for the
full plan and `CLAUDE.md` for the live work plan.

## Project layout

```
fastetcd_uptest/
├── docs/                 design + methodology
├── cloud-init/           cloud-config templates per variant
├── scripts/              orchestration / measurement
├── proxmox/              Proxmox API config + manifests
├── README.md / CLAUDE.md / CHANGELOG.md
```

## Prerequisites

- A Proxmox VE host reachable at `pvex.g8.lo` with API token auth
- An Ubuntu 24.04 cloud image uploaded as a Proxmox template
- A `ghcr.io/glennswest/fastetcd` image (built by fastetcd's CI on
  every tag push) for variant B
- Local: `curl`, `jq`, `genisoimage`/`xorrisofs` for cloud-init seed
  ISO generation

## Quick start

```
cp proxmox/config.sample.env proxmox/config.env
$EDITOR proxmox/config.env       # set PROXMOX_HOST, API_TOKEN, NODE, STORAGE, BRIDGE

# Provision both variants in parallel.
./scripts/run-comparison.sh

# Or one at a time:
./scripts/provision-vm.sh --variant=a
./scripts/provision-vm.sh --variant=b

# Pull measurements off a running VM:
./scripts/measure-boot.sh --vmid=110
./scripts/measure-rss.sh  --vmid=110
./scripts/measure-api-p99.sh --vmid=110
./scripts/measure-pod-start.sh --vmid=110
```

## License

Apache 2.0.
