# jepsen-k8s-setup (MVP)

A simple **host setup + kind + MetalLB** harness to prepare a Kubernetes environment suitable for running Jepsen-style tests.
For example, [ScalarDB Cluster tests](https://github.com/scalar-labs/scalar-jepsen).
This repo **does not provision VMs**. Bring your own Linux VM and SSH into it.

## Requirements

- Linux VM (Ubuntu 24.04 recommended; should work on Debian/Ubuntu-family distros)
- `sudo` access
- Internet connectivity
- CPU/RAM: recommended 4 vCPU / 8GB+ for anything non-trivial

## Quick start

```bash
git clone https://github.com/yito88/jepsen-k8s-setup.git
cd jepsen-k8s-setup

./scripts/host-setup.sh
./scripts/cluster.sh up

./scripts/cluster.sh status

./scripts/cluster.sh down
```

## What this does

- Installs: Docker Engine, kubectl, Helm, kind, Java, Leiningen
- Creates a kind cluster (name: `jepsen`)
- Installs MetalLB (native manifests)
- Auto-detects a safe IP pool from the kind Docker network and configures MetalLB

## Version pinning

Edit `versions.env` to pin tool versions. You can also override them via env vars.

## Notes

- If IP pool detection fails, set `METALLB_POOL_CIDR` (range format: `A.B.C.D-E.F.G.H`) and re-run:

```bash
export METALLB_POOL_CIDR="172.18.255.200-172.18.255.250"
./scripts/cluster.sh up
```
