# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A GitOps repository for a personal 3-node K3s homelab, reconciled by **ArgoCD** (Flux was removed). It is
pure Kubernetes YAML: raw manifests, Kustomize directories, Helm values, and ArgoCD `Application` CRs (which
also install Helm charts). There is no application source code, build step, test suite or CI. ArgoCD pulls the
public GitHub remote (`https://github.com/Shubhrajit1pallob/Homelab.git`, branch `main`); nothing takes effect
until it is committed and pushed, and nothing is deployed to the cluster by this repo directly.

## Validating changes

```bash
# Render any directory an Application points at
kubectl kustomize apps/portfolio
kubectl kustomize infrastructure/cert-manager

# Validate Application files against the live cluster's CRDs (server-side dry-run changes nothing)
kubectl apply --dry-run=server -f clusters/homelab/root-app.yaml -f clusters/homelab/applications/

# Check chart values render (no cluster contact). The user's global helm repo config has a stale entry that
# breaks `helm template --repo`, so isolate helm's config in a scratch dir first:
export HELM_REPOSITORY_CONFIG=$SCRATCH/repos.yaml HELM_REPOSITORY_CACHE=$SCRATCH/cache HELM_CACHE_HOME=$SCRATCH/cache
helm template <release> <chart> --repo <url> --version <v> -f <values.yaml>

# Live state
kubectl get applications -n argocd
kubectl top nodes
```

## Architecture: app-of-apps

```
clusters/homelab/root-app.yaml        applied ONCE by hand (kubectl apply -f); watches applications/
clusters/homelab/applications/        Application files ArgoCD syncs (the "enabled" set)
clusters/homelab/parked/              Application files NOT synced - root only reads applications/
```

- To enable a component, move its Application file from `parked/` into `applications/`; to park it, move it
  back. Every Application syncs either a directory of this repo (with its own `kustomization.yaml`), or a
  Helm chart with values kept in this repo (multi-source, `$values/...`, e.g. kube-prometheus-stack).
- Adding a manifest file to a synced directory requires adding it to that directory's `kustomization.yaml`.
  Adding a new directory requires a new Application file.
- Ordering uses sync waves (cert-manager wave 0 first). Applications that use CRDs installed by another chart
  (`cert-manager-config`, `monitoring-config`) add `retry` and `SkipDryRunOnMissingResource=true`.
- Enabled now: `cert-manager` (jetstack chart, values inline), `cert-manager-config`
  (`infrastructure/cert-manager`), `argocd-config` (`infrastructure/argocd`, the ArgoCD web-UI routes).
- Parked: `cloudflared` (needs a tunnel cutover, see its header), `kube-prometheus-stack` + `monitoring-config`,
  `portfolio`, and `elk` (**never enable on this hardware**: ~2.6 GiB of requests).
- On disk with **no** Application (so not deployed): `infrastructure/longhorn` (ingress + cert only, no chart),
  `infrastructure/vault` (values only), `apps/homarr` (values only, chart unidentified), `apps/mealie`,
  `apps/postgres` (a CloudNativePG `Cluster` with no operator installed). Don't assume they are live.
- The portfolio site's image is built and published to GHCR by the separate `portfolio_website` repo; its
  deployment manifests live here in `apps/portfolio/` with the image pinned to a `sha-<commit>` tag.

## Cluster and resource constraints

- `server-1`: tainted control-plane, 1.6 GiB RAM and already ~64% used. Keep workloads off it (only
  node-exporter tolerates the taint). `agent-1`: always-on, **1 vCPU**, 3.3 GiB, labelled `node-role=cloud`
  (needed by the portfolio's required affinity). `shubmedia`: a laptop, 4 CPU, 3.5 GiB, may go offline; it
  hosts the heavy monitoring pods and the Cloudflare tunnel connector. All nodes are amd64 and join via
  Tailscale (internal IPs are `100.x`).
- About 5.5 GiB is free across the two workers. Every workload needs requests and a memory limit.

## Networking / ingress

- No MetalLB. K3s's built-in ServiceLB exposes the **built-in Traefik** (kube-system, installed by K3s, not
  managed here) on ports 80/443 of every node's Tailscale IP.
- Public traffic uses the Cloudflare Tunnel `k8s_cloud`: published routes point at `http://localhost:80`
  (connector on the `shubmedia` host), TLS ends at Cloudflare, and admin UIs sit behind Cloudflare Access.
  Tunnel routes and Access apps are configured in the Cloudflare dashboard, not in this repo. Tunnel traffic
  arrives on Traefik's `web` entrypoint; direct Tailscale access uses `websecure` with the wildcard cert.
- A hostname cannot be both a proxied tunnel name and a DNS-only Tailscale address, so where both are wanted
  the tailnet one gets its own name (e.g. `grafana.` public via Access, `grafana-ts.` direct).
- cert-manager issues via `ClusterIssuer cloudflare-clusterissuer` (DNS-01). One wildcard `Certificate`
  (`*.shubhrajitpallob.dev`) lives in `kube-system` and is Traefik's default through `TLSStore default`, so
  apps just set `tls: {}`; they do not create their own certificates.
- Default StorageClass is K3s `local-path` (node-local, not replicated). Longhorn is not deployed.

## Things that live only in the cluster (not in Git)

- Secrets created by hand: `cloudflare-api-token-secret` (ns `cert-manager`, key `api-token`), `tunnel-token`
  (ns `kube-system`, key `token`), `grafana-admin` (ns `monitoring`). There is no SOPS or sealed-secrets.
  `apps/postgres/secrets.yaml` is plaintext and gitignored.
- ArgoCD's `server.insecure: "true"` in the `argocd-cmd-params-cm` ConfigMap was patched in by hand.
- **The remote is public and earlier history contains leaked credentials** (Postgres passwords, a Traefik
  dashboard htpasswd hash, a Grafana password). Treat them as compromised and never put a secret in a committed
  file.

## Working with this repo's current state

- `README.md` and `WARP.md` are stale boilerplate (they describe folders that don't exist); trust this file.
- The restructure from `apps/base/<app>` and `infrastructure/controllers/<c>` to `apps/<app>` and
  `infrastructure/<c>` may show old paths as deleted and new ones as untracked in `git status`. That is the
  migration, not something to revert.
