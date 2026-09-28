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
clusters/homelab/bootstrap/           hand-applied ArgoCD tuning (ConfigMap/Secret), not synced by ArgoCD
```

- To enable a component, move its Application file from `parked/` into `applications/`; to park it, move it
  back. Every Application syncs either a directory of this repo (with its own `kustomization.yaml`), or a
  Helm chart with values kept in this repo (multi-source, `$values/...`, e.g. kube-prometheus-stack).
- Adding a manifest file to a synced directory requires adding it to that directory's `kustomization.yaml`.
  Adding a new directory requires a new Application file.
- Ordering uses sync waves (cert-manager wave 0 first). Applications that use CRDs installed by another chart
  (`cert-manager-config`, `monitoring-config`) add `retry` and `SkipDryRunOnMissingResource=true`.
- Enabled now: `portfolio` only.
- Parked: `cert-manager` (jetstack chart, values inline), `cert-manager-config` (`infrastructure/cert-manager`),
  `argocd-config` (`infrastructure/argocd`, the ArgoCD web-UI routes), `cloudflared` (needs a tunnel cutover,
  see its header), `kube-prometheus-stack` + `monitoring-config`, and `elk` (**never enable on this
  hardware**: ~2.6 GiB of requests).
- cert-manager (a plain `helm install`, not an ArgoCD-managed release) and the argocd IngressRoutes are live
  in the cluster but were applied by hand, with no ArgoCD tracking labels on either — parking their
  Application files doesn't change what's currently running.
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

## Current status and next steps (as of 2026-09-28; update or delete when stale)

- **ArgoCD is still scaled to 0** (all its deployments and the `argocd-application-controller` statefulset).
  Two incidents so far: applying `root-app.yaml` with all child apps enabled choked K3s's SQLite datastore on
  CRD writes; then on 2026-09-28, with ArgoCD already at 0, `server-1` ran out of memory (no swap), the kernel
  thrashed, SQLite queries took ~18s, and the API server stopped responding — likely triggered by a
  server-side dry-run against the large Application CRD. Fixed with a 2 GiB swapfile (`vm.swappiness=10`,
  recreate on any rebuild) and a k3s restart. Bring-up is on hold until server-1 has been stable for a while
  or is upgraded; the steps are in `clusters/homelab/bootstrap/README.md`.
- **Portfolio is live but was applied by hand** (`kubectl apply -k apps/portfolio`, 2/2 pods on `agent-1`,
  public at the apex and `www` through the tunnel). `applications/portfolio.yaml` is enabled in Git, but
  ArgoCD isn't running yet. Live matches Git (sha-898ea70).
- **Portfolio releases:** the portfolio repo's CI job `propose-homelab-release` opens a PR here bumping the
  `sha-` image tag and `APP_VERSION` in `apps/portfolio/deployment.yaml` (it never pushes). The
  `HOMELAB_REPO_TOKEN` secret now exists, but no real PR has been opened yet, so the flow is untested end to end.
- **Control-plane upgrade next month, on Interserver** (resize or rebuild `server-1`). Moving it to AWS was
  rejected: the AWS free-plan account closes after 6 months and a 24/7 node would burn most of the $200
  credits. After the upgrade: follow `clusters/homelab/bootstrap/README.md` (portfolio is the only enabled
  app, so the first sync should be a no-op adoption), prove a release PR syncs through ArgoCD, then re-enable
  `cert-manager` + `cert-manager-config` (ArgoCD will adopt the hand-installed Helm release, so check the
  diff before syncing), then `argocd-config`, then consider `kube-prometheus-stack` (its CRD burst is why it
  waits).
- **Monitoring:** the full stack waits for the upgrade. A lighter Prometheus + node-exporter with no operator
  or CRDs was offered as a stopgap; the user hasn't decided yet.
- **SOC lab:** planning only. See `apps/soc-lab/PLAN.md` (same cluster, isolated namespaces, mandatory
  guardrails, AWS credits for temporary lab resources with budget guardrails). Phase 0 is next: secure the
  AWS account, set up budget alerts, and write (not apply) the namespace/NetworkPolicy/quota manifests.
  Open questions are listed at the end of the plan.
- **Portfolio architecture diagram:** built in the portfolio repo, not here. The user is briefing the portfolio
  agent directly. Facts already given to that agent: GitOps path shown as "built, paused"; release-PR job not
  yet proven; monitoring/in-cluster cloudflared/ELK written but not running; no Terraform/Ansible; V1 = commit
  `97f26fc`, V2 = `981ccd7`; no IPs, tailnet or admin hostnames; role names instead of node names.
- **Lower priority:** rotate the Postgres password leaked in Git history; review
  `scripts/argocd-setup-interserver.sh` (it patches ArgoCD nodeSelectors to `workload: gitops`); the user's
  K3s install flags (`ExecStart` in `k3s.service` / `k3s-agent.service`) are still needed for the upgrade.

## Working with this repo's current state

- `README.md` and `WARP.md` are stale boilerplate (they describe folders that don't exist); trust this file.
- The restructure from `apps/base/<app>` and `infrastructure/controllers/<c>` to `apps/<app>` and
  `infrastructure/<c>` may show old paths as deleted and new ones as untracked in `git status`. That is the
  migration, not something to revert.
