# CLAUDE.md — fastetcd_uptest

Project-specific context. Cross-project rules live in `../CLAUDE.md`.

## Project summary

End-to-end harness that compares vanilla upstream Kubernetes
(stock etcd) against the same upstream stack with etcd replaced
by fastetcd. Builds + provisions two VMs on Proxmox at
`pvex.g8.lo` via the API, measures boot time + RSS + API p99 +
pod-start tail, and emits a side-by-side report.

## Version

**`0.0.1`** — initial scaffolding.

## Architecture

The harness is shell + cloud-init, not Rust. Rationale:
- Most of the value is in **what** gets provisioned + **how** we
  measure, not in code we write.
- cloud-init is the right tool to bootstrap K8s nodes from cloud
  images.
- Proxmox API is HTTP/JSON; curl + jq are sufficient.
- Measurement scripts are short and shell-based.

Two cloud-init configs:
- `cloud-init/variant-a.yaml.tpl` — vanilla kubeadm init.
- `cloud-init/variant-b.yaml.tpl` — kubeadm init, then a
  post-init hook that swaps the etcd static pod manifest for a
  fastetcd static pod using the same TLS certs kubeadm generates.

Both are templates with `${VAR}` placeholders for IPs, names,
versions; `scripts/build-images.sh` renders them into seed ISOs.

## Work plan

1. Scaffolding (this commit): README, CLAUDE.md, design doc,
   directory layout, .gitignore.
2. cloud-init templates for both variants.
3. Proxmox provisioning script using the API.
4. Measurement scripts (boot / RSS / API p99 / pod-start).
5. `run-comparison.sh` orchestrator.
6. Initial run against real `pvex.g8.lo`, iterate.

## Constraints

- **Don't bake credentials into the repo.** Proxmox API token
  goes in `proxmox/config.env` which `.gitignore`s.
- **Variant B should be a single change from Variant A** — only
  the etcd → fastetcd swap, so the comparison is fair.
- **All measurements should be reproducible** — same workload,
  same warm-up time, same scrape window.

## Sibling project

- `../fastetcd` — the etcd replacement under test. Container
  image: `ghcr.io/glennswest/fastetcd:latest` published by
  fastetcd's CI on tag push.
