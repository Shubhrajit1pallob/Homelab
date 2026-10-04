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

- `server-1`: tainted control-plane, InterServer 2 slices since 2026-10-04: 1 core, ~3.3 GiB RAM, 80 GB disk
  (`/` is 77G), swap = 2 GiB `/swapfile` + 1 GiB partition (`sda3`), `vm.swappiness=10`. About 2.2-2.3 GiB is
  used (~67%), mostly by K3s's own system pods, which tolerate the taint and run there: Traefik, CoreDNS,
  metrics-server, local-path-provisioner, svclb-traefik. Before the resize this demand didn't fit in 1.6 GiB
  and ~900 MB sat in swap. Keep your own workloads off it; node-exporter is the only app workload meant to
  tolerate the taint. K3s flags: `--node-ip=<server-1 Tailscale IP>` and `--flannel-iface=tailscale0`;
  datastore is SQLite (`/var/lib/rancher/k3s/server/db/state.db`).
- `agent-1`: always-on, **1 vCPU**, 3.3 GiB, labelled `node-role=cloud`
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
- Public traffic depends on `server-1`: the single Traefik pod runs there, so if server-1 is down or
  rebooting the site is unreachable even though the portfolio pods on `agent-1` keep running.
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

## Current status and next steps (as of 2026-10-04; update or delete when stale)

- **ArgoCD is live (since 2026-09-29)**, running only `portfolio`. It was brought up per
  `clusters/homelab/bootstrap/README.md`: a namespace-scoped in-cluster Secret, lower parallelism, a 600s
  reconciliation interval (so merges deploy within ~10 min, or press Refresh), and dex/applicationset-
  controller/notifications-controller kept at 0. Only argocd-application-controller runs on `shubmedia` (the
  laptop); argocd-server, repo-server and redis run on `agent-1`. If shubmedia is offline, reconciliation
  stops (the controller is there) but the site keeps serving. A 2026-09-28 OOM-thrash incident on
  server-1 (no swap) preceded this; fixed with a 2 GiB swapfile (`vm.swappiness=10`, recreate on any rebuild).
- **Portfolio is live and managed by ArgoCD** (the no-op adoption on 2026-09-29), 2/2 pods on `agent-1`,
  public at the apex and `www` through the tunnel.
- **Portfolio releases:** the flow is proven end to end. The portfolio repo's CI job
  `propose-homelab-release` opens a PR here bumping the `sha-` image tag and `APP_VERSION` in
  `apps/portfolio/deployment.yaml` (it never pushes); merging it makes ArgoCD roll it out on its own. Proven
  with PR #2 (`sha-c67d6c7`, new content and mobile fixes): merge to live took ~4m13s.
- **Control-plane upgrade done 2026-10-04**: in-place resize of `server-1` to 2 slices (runbook and results
  in `clusters/homelab/bootstrap/UPGRADE.md`). The Tailscale IP, taint and swap survived; the kernel moved to
  7.0.0-34 (7.0.0-38 is available; not yet applied). All nodes Ready, ArgoCD Synced/Healthy. Portfolio pods
  kept running; public traffic likely dropped while server-1 (which hosts Traefik) rebooted — not measured.
  Backups of the token and SQLite datastore were taken beforehand and kept off-repo. Moving the control plane
  to AWS was rejected: the AWS free-plan account closes after 6 months and a 24/7 node would burn most of the
  $200 credits. Next: re-enable `cert-manager` + `cert-manager-config` (ArgoCD will adopt the hand-installed
  Helm release, so check the diff before syncing), then `argocd-config`, then consider
  `kube-prometheus-stack` (its CRD burst is why it waits).
- **Apex fixed 2026-10-04:** `shubhrajitpallob.dev` returned Cloudflare 522 because the apex `@` was a proxied
  A record pointing at a leftover Namecheap parking IP from the domain move. It's now a public hostname on the
  `k8s_cloud` tunnel, like `www`. Two `NS` records for `registrar-servers.com` are also left over in the
  Cloudflare zone; harmless for now, but the user should confirm the Namecheap account's nameservers point to
  Cloudflare.
- **Media server (planned 2026-10-04, nothing provisioned):** Jellyfin on a new InterServer 2-slice Storage
  VPS (Secaucus, NJ; 1 core, 4 GB, 2 TB SATA, 4 TB transfer/mo), joined as a tainted K3s node
  (`node-role=media`), media via read-only hostPath at `/srv/media`, direct play only (no transcoding on 1
  core), Tailscale-only access (`jellyfin-ts.`), never through the Cloudflare tunnel (Cloudflare's terms
  don't allow video). Keep it portable for a possible future local server.
- **Monitoring:** the upgrade is done; the full stack now waits for cert-manager to be re-enabled. A lighter
  Prometheus + node-exporter with no operator or CRDs was offered as a stopgap; the user hasn't decided yet.
- **SOC lab:** planning only. See `apps/soc-lab/PLAN.md` (same cluster, isolated namespaces, mandatory
  guardrails, AWS credits for temporary lab resources with budget guardrails). Phase 0 is next: secure the
  AWS account, set up budget alerts, and write (not apply) the namespace/NetworkPolicy/quota manifests.
  Open questions are listed at the end of the plan.
- **Portfolio architecture diagram:** built in the portfolio repo, not here. The user is briefing the portfolio
  agent directly. Facts already given to that agent: GitOps path shown as "built, paused"; release-PR job not
  yet proven; monitoring/in-cluster cloudflared/ELK written but not running; no Terraform/Ansible; V1 = commit
  `97f26fc`, V2 = `981ccd7`; no IPs, tailnet or admin hostnames; role names instead of node names. GitOps is
  now live, not paused. Tell the portfolio agent so the diagram's "built, paused" label can be updated.
- **Lower priority:** rotate the Postgres password leaked in Git history; review
  `scripts/argocd-setup-interserver.sh` (it patches ArgoCD nodeSelectors to `workload: gitops`); harden SSH on
  server-1 (it currently allows root password login on its public IP; move to key-only and ideally
  Tailscale-only); from the Mac, port 80 on every node's Tailscale IP times out (kubectl over Tailscale works),
  so check the Tailscale ACLs / node firewall before relying on Tailscale-only ingress (needed for Jellyfin
  and `grafana-ts`).

## Working with this repo's current state

- `README.md` and `WARP.md` are stale boilerplate (they describe folders that don't exist); trust this file.
- The restructure from `apps/base/<app>` and `infrastructure/controllers/<c>` to `apps/<app>` and
  `infrastructure/<c>` may show old paths as deleted and new ones as untracked in `git status`. That is the
  migration, not something to revert.
