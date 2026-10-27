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
# Render any directory an Application points at (only works for dirs WITHOUT a KSOPS `generators:` entry)
kubectl kustomize infrastructure/cert-manager

# Dirs with SOPS secrets (apps/portfolio, apps/rag-api, apps/monitoring/prometheus): plain `kubectl kustomize`
# fails on the KSOPS plugin. Copy the dir to a scratch folder, delete its `generators:` block, then render and
# dry-run that copy. A full `kustomize build --enable-alpha-plugins --enable-exec` (needs kustomize + ksops on
# the Mac) prints DECRYPTED values, so never show its output; pipe it through `grep -E '^kind:|^  name:'`.
scripts/check-sops-encrypted.sh   # every *.enc.yaml is really encrypted (and has no CHANGE_ME, if a key is set)

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
- Enabled now: `portfolio`, `cert-manager`, `cert-manager-config`, `argocd-config`, `kube-prometheus-stack` +
  `monitoring-config`, `rag-api` (enabled 2026-10-14; image pin is in `apps/rag-api/kustomization.yaml`), and
  (added 2026-10-19) `cnpg-operator` (chart cloudnative-pg 0.29.1, ns `cnpg-system`), `cnpg-barman-plugin`
  (plugin-barman-cloud 0.8.1, same ns) and `n8n` (`apps/n8n/tenants/shawn`: a Kustomize base plus a tenant
  overlay, laid out so another tenant is a new overlay). See "n8n" below. Added 2026-10-27: `cloudflared` (ns
  `cloudflared`, 2 replicas on `agent-1`, locally managed tunnel `k8s-cluster`, wildcard ingress in
  `infrastructure/cloudflared/config.yaml`, `protocol: http2` because the pod MTU of 1230 breaks QUIC; change
  record `clusters/homelab/bootstrap/CHANGE-2026-10-26-tunnel-blue-green.md`).
  - rag-api's Secrets are SOPS-encrypted in `apps/rag-api/secrets/`. The portfolio's chat key is in
    `apps/portfolio/secrets/rag-api-key.enc.yaml` and is switched on separately (step 7 in the Application's
    header).
  - Releases come from rag-api GitHub Releases: its CI opens a PR bumping the one `images:` newTag line in
    `apps/rag-api/kustomization.yaml`. Keep that entry's shape.
  - rag-api's non-secret settings are in `apps/rag-api/config.env`, generated into a ConfigMap whose name
    carries a content hash (`configMapGenerator`), so any edit rolls the pods on its own.
- Parked: `elk` (**never enable on this hardware**: ~2.6 GiB of requests).
- cert-manager was adopted by ArgoCD on 2026-10-04 (chart v1.21.2, no reissue of the wildcard cert). A stale
  Helm release (revision 1) is still recorded; never run helm against cert-manager again (`helm upgrade`
  would fight ArgoCD; `helm uninstall` deletes the live resources). The ArgoCD UI IngressRoutes
  (`argocd-server` websecure, `argocd-server-http` web) were adopted by `argocd-config` on 2026-10-04 with no
  spec change. Deleting or renaming them in `infrastructure/argocd` makes ArgoCD prune them and the UI becomes
  unreachable (kubectl still works).
- ArgoCD's in-cluster cluster Secret (`clusters/homelab/bootstrap/cluster-in-cluster.yaml`, hand-applied, not
  synced) limits ArgoCD to the namespaces argocd, portfolio, cert-manager, kube-system, monitoring, rag-api,
  cnpg-system, n8n and cloudflared (cloudflared added 2026-10-27; file and live cluster matched on 2026-10-24). Before enabling an Application that
  deploys into any other namespace (media, soc-lab, ...), add the namespace
  there and `kubectl apply -f` it, or the app fails with `namespace "X" is not managed`.
- On disk with **no** Application (so not deployed): `infrastructure/longhorn` (ingress + cert only, no chart),
  `infrastructure/vault` (values only), `apps/homarr` (values only, chart unidentified), `apps/mealie`,
  `apps/postgres` (a CloudNativePG `Cluster`; the CNPG operator IS installed now, so giving it an Application
  would really bring the database up, don't enable it casually). Don't assume they are live.
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
- `agent-1`: always-on, InterServer 3 slices since 2026-10-10: **2 vCPU**, ~5.4 GiB, labelled `node-role=cloud`
  (needed by the portfolio's required affinity). Resized by draining it (shubmedia temporarily labelled
  `node-role=cloud` so the site stayed up), then uncordon, unlabel and `rollout restart`. After the reboot the host's
  DNS broke: Tailscale's DNS (100.100.100.100) stopped answering, so it couldn't pull images and chrony couldn't sync
  (the clock was 4h behind). agent-1 now runs with `--accept-dns=false`. Incident report and copy-paste fix:
  `clusters/homelab/bootstrap/INCIDENT-2026-10-10-agent1-dns.md`. Ubuntu 26.04 uses chrony, not systemd-timesyncd.
  Kernel is now 7.0.0-38. `shubmedia`: a laptop, 4 CPU, 3.5 GiB, may go offline; it
  hosts the heavy monitoring pods and ArgoCD's application controller (the public site no longer depends on it). All nodes are amd64 and join via
  Tailscale (internal IPs are `100.x`).
- About 5.5 GiB is free across the two workers. Every workload needs requests and a memory limit.

## Networking / ingress

- No MetalLB. K3s's built-in ServiceLB exposes the **built-in Traefik** (kube-system, installed by K3s, not
  managed here) on ports 80/443 of every node's Tailscale IP.
- Public traffic enters through the in-cluster `cloudflared` Deployment (ns `cloudflared`, 2 replicas on
  `agent-1`), the locally managed tunnel `k8s-cluster` (since 2026-10-27). Its wildcard ingress
  (`infrastructure/cloudflared/config.yaml`) sends everything to `http://traefik.kube-system.svc.cluster.local:80`,
  Traefik's `web` entrypoint; it runs `protocol: http2` because the pod MTU of 1230 (flannel over Tailscale)
  breaks QUIC. TLS ends at Cloudflare and admin UIs sit behind Cloudflare Access. DNS records are proxied CNAMEs
  to `<tunnel-id>.cfargotunnel.com`, and Access apps are managed by hand in the Cloudflare dashboard, not in
  this repo. To move a hostname, edit its CNAME target; never delete a route on a dashboard-managed tunnel (that
  also deletes the DNS record). Direct Tailscale access uses `websecure` with the wildcard cert. The old
  dashboard tunnel `k8s_cloud` and its laptop connector are kept only for one SSH route to the laptop node
  (open item R8: confirm it sits behind an Access app or replace it with Tailscale SSH, then retire both and
  delete `kube-system/tunnel-token`). Change record: `clusters/homelab/bootstrap/CHANGE-2026-10-26-tunnel-blue-green.md`.
- Public traffic depends on `server-1`: the single Traefik pod runs there, so if server-1 is down or
  rebooting the site is unreachable even though the portfolio pods on `agent-1` keep running.
- A hostname cannot be both a proxied tunnel name and a DNS-only Tailscale address, so where both are wanted
  the tailnet one gets its own name (e.g. `grafana.` public via Access, `grafana-ts.` direct).
- cert-manager issues via `ClusterIssuer cloudflare-clusterissuer` (DNS-01). One wildcard `Certificate`
  (`*.shubhrajitpallob.dev`) lives in `kube-system` and is Traefik's default through `TLSStore default`, so
  apps just set `tls: {}`; they do not create their own certificates.
- Default StorageClass is K3s `local-path` (node-local, not replicated). Longhorn is not deployed.

## Things that live only in the cluster (not in Git)

- App Secrets are in Git, SOPS-encrypted (age) in `apps/<app>/secrets/*.enc.yaml` and decrypted by ArgoCD with
  KSOPS: `rag-api-secrets`, `rag-api-key`, `portfolio-views`, `grafana-supabase`, `grafana-admin`,
  `alertmanager-config`, n8n's `n8n-r2-backup`, `n8n-encryption`, `n8n-runners`, and (since 2026-10-26)
  `cloudflare-api-token-secret` (ns `cert-manager`, `infrastructure/cert-manager/secrets/`, carries `Prune=false`)
  and `tunnel-credentials` (ns `cloudflared`, `infrastructure/cloudflared/secrets/`, the green tunnel's
  credentials JSON). Runbook (change, add,
  rotate, break-glass, ArgoCD upgrade): `clusters/homelab/bootstrap/SECRETS-SOPS.md`. Never read the age private
  key or print decrypted values.
- `alertmanager-config` holds the WHOLE Alertmanager config (routing, Gmail address and app password) as one
  encrypted value, so `scripts/check-sops-encrypted.sh` can't see a placeholder inside it. Check with
  `sops -d <file> | grep -c CHANGE_ME` (output is a count only). A redacted copy for review is
  `apps/monitoring/prometheus/secrets/alertmanager.example.yaml`; keep the two in step.
- Only in the cluster: `argocd/sops-age` (the age private key, "secret zero"; also in the user's password
  manager), the KSOPS patches on `argocd-cm` and `argocd-repo-server` (re-apply after any ArgoCD upgrade), and
  the old hand-made `kube-system/tunnel-token` (the blue tunnel's token, no longer used; delete it by hand).
  No other Secret is created by hand; change record `clusters/homelab/bootstrap/CHANGE-2026-10-26-secrets-to-sops.md`.
  `apps/postgres/secrets.yaml` is plaintext and gitignored.
- ArgoCD's `server.insecure: "true"` in the `argocd-cmd-params-cm` ConfigMap was patched in by hand.
- **The remote is public and earlier history contains leaked credentials** (Postgres passwords, a Traefik
  dashboard htpasswd hash, a Grafana password). Treat them as compromised and never put a secret in a committed
  file.

## n8n and the rag-api reindex workflow (added 2026-10-24)

Detail lives in `apps/n8n/REQUIREMENTS.md`, `apps/n8n/restore-test/RESTORE.md` and
`apps/n8n/workflows/README.md`; this is only what a session must not get wrong.

- n8n runs in ns `n8n` on `agent-1` with `n8n-db`, a CNPG cluster (1 instance). WAL archiving (Barman Cloud
  plugin) and a weekly base backup (Sundays 03:00 UTC, 14d retention) go to R2 (`s3://n8n-backup/shawn/`).
  **The restore has never been tested** (RESTORE.md; the user deferred it). Don't call the backups proven.
- Access: the hostname is behind Cloudflare Access, plus a separate Access app that BYPASSES `/webhook/*` only
  (set in the Cloudflare dashboard, not in this repo; verified 2026-10-24 by curl route test + GitHub ping). GitHub webhook signatures are
  verified by n8n's GitHub Trigger node itself.
- ns `n8n` is default-deny (NetworkPolicies). Egress allowed: n8n-db, rag-api:8000, portfolio:9090 (internal
  port, never public) and the internet on 443 + 465 (Gmail SMTP). A new destination needs a policy change,
  and rag-api / portfolio need a matching ingress rule. ns `monitoring` has NO NetworkPolicies.
- Workflow `rag-reindex`: a merged portfolio release PR in this repo fires a GitHub webhook; the workflow
  filters to releases that change the site's data, waits for the rollout, POSTs the documents
  (`/internal/rag-documents`, with `/internal/version`, on the portfolio's port 9090) to rag-api, deletes
  removed IDs and emails a summary. A manual `rag_export` is no longer needed (it stays as the manual
  fallback). The endpoints have been live since portfolio `sha-435907b` (Homelab release PR #18).
- Exports in `apps/n8n/workflows/` are NOT GitOps (nothing applies them). Follow its README: sanitize with the
  jq filter, run its grep check before committing. `.gitignore` has `!apps/n8n/workflows/*.json` as an
  exception to the blanket `*.json` rule.
- Lessons: (1) a PVC on `local-path` (WaitForFirstConsumer) must be in the SAME sync wave as its consumer, or
  the sync deadlocks (it did, for n8n). (2) Alpine/musl images plus agent-1's host search domains give
  ENOTFOUND, so n8n sets `dnsConfig ndots: "1"`; use short names or full `.svc.cluster.local` FQDNs, never
  `svc.ns`. (3) `argocd app get` in core mode needs the kubectl context namespace set to `argocd`.

## Current status and next steps (as of 2026-10-27; update or delete when stale)

Older bullets below are history from 2026-10-04 and earlier; where they conflict with the sections above
(enabled apps, Alertmanager, n8n), the sections above win.

- **ArgoCD is live (since 2026-09-29)**; it now runs the apps listed under "Enabled now". It was brought up per
  `clusters/homelab/bootstrap/README.md`: a namespace-scoped in-cluster Secret, lower parallelism, a 600s
  reconciliation interval (so merges deploy within ~10 min, or press Refresh), and dex/applicationset-
  controller/notifications-controller kept at 0. Only argocd-application-controller runs on `shubmedia` (the
  laptop); argocd-server, repo-server and redis run on `agent-1`. If shubmedia is offline, reconciliation
  stops (the controller is there) and monitoring stops, but the public site stays up (cloudflared runs
  in-cluster; laptop-off test passed 2026-10-27). A 2026-09-28 OOM-thrash incident on
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
  $200 credits. cert-manager + cert-manager-config enabled 2026-10-04 (see Architecture); cert-manager pods
  prefer agent-1 (preferred affinity on node-role=cloud). `argocd-config` enabled 2026-10-04.
  `kube-prometheus-stack` + `monitoring-config` enabled 2026-10-04 (see Monitoring).
- **Apex fixed 2026-10-04:** `shubhrajitpallob.dev` returned Cloudflare 522 because the apex `@` was a proxied
  A record pointing at a leftover Namecheap parking IP from the domain move. It's now a proxied CNAME to the
  `k8s-cluster` tunnel, like `www`. Two `NS` records for `registrar-servers.com` are also left over in the
  Cloudflare zone; harmless for now, but the user should confirm the Namecheap account's nameservers point to
  Cloudflare.
- **Media server (planned 2026-10-04, nothing provisioned):** Jellyfin on a new InterServer 2-slice Storage
  VPS (Secaucus, NJ; 1 core, 4 GB, 2 TB SATA, 4 TB transfer/mo), joined as a tainted K3s node
  (`node-role=media`), media via read-only hostPath at `/srv/media`, direct play only (no transcoding on 1
  core), Tailscale-only access (`jellyfin-ts.`), never through the Cloudflare tunnel (Cloudflare's terms
  don't allow video). Keep it portable for a possible future local server. Its namespace must be added to the
  cluster Secret first.
- **Monitoring enabled 2026-10-04:** kube-prometheus-stack 91.7.0 + `monitoring-config`. Prometheus, Grafana,
  operator and kube-state-metrics are pinned to shubmedia; node-exporter runs on all 3 nodes. Alertmanager has been
  enabled since 2026-10-22: pinned to shubmedia, 1Gi PVC, email through Gmail SMTP, config from the SOPS Secret
  `alertmanager-config`, port-forward only. Rules: `apps/monitoring/prometheus/n8n-alerts.yaml` (n8n and n8n-db
  down, WAL archiving, backup too old or failed) and a NodeMemoryHigh 75% warning in `node-alerts.yaml`. **No
  dead man's switch**: monitoring lives on the laptop node, so it can't alert about its own outage. Retention 7d / 4GB on a 5Gi local-path PVC (node-local). The 10 CRDs
  (~4.4 MB) were pre-applied by hand one at a time with server-side apply while watching server-1 memory;
  repeat that on any rebuild. Grafana 13 needs ~400Mi steady (now 384Mi/640Mi, sidecars 64Mi/128Mi; 256Mi
  caused liveness kills on startup). Measured after: server-1 ~53%, agent-1 ~27%, shubmedia ~58%; ArgoCD
  controller ~152Mi -> ~337Mi; Prometheus ~115k series. Not cAdvisor (~3k): ~51k were K3s control-plane metrics duplicated on server-1's
  kubelet `/metrics`; dropped there on 2026-10-17 (`kubelet.serviceMonitor.metricRelabelings` in values.yaml). Grafana is
  public via a tunnel hostname behind Cloudflare Access; `grafana-ts.` waits on the Tailscale port issue.
  Our alert rules aggregate away scrape labels (`max by (...)`) so email subjects stay short; the subject comes
  from `headers.Subject` on the email receiver in `alertmanager-config` (template in
  `alertmanager.example.yaml`; paste it into the Secret with `sops edit`). `CloudflaredDown` (<1 ready replica
  for 5m, critical) is in `cloudflared-alerts.yaml`.
- **SOC lab:** planning only. See `apps/soc-lab/PLAN.md` (same cluster, isolated namespaces, mandatory
  guardrails, AWS credits for temporary lab resources with budget guardrails). Phase 0 is next: secure the
  AWS account, set up budget alerts, and write (not apply) the namespace/NetworkPolicy/quota manifests.
  Open questions are listed at the end of the plan.
- **Portfolio site (portfolio repo, not here):** on 2026-10-05 the `/work/homelab` case study was updated to
  show GitOps and monitoring as live, and a blog series started (Post 1 `hybrid-k3s-homelab`, with a new
  staircase diagram). Public-content rules: no IPs, tailnet or admin hostnames; role names instead of node
  names; no unfixed weaknesses or leaked-credential history.
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
- Move Application files with `git mv` (or `git add -A <dir>`) and check `git status` before pushing. A plain
  `mv` plus `git commit -a` commits only the deletion (this happened on 2026-10-04).
- After changing a file in `clusters/homelab/applications/`, hard-refresh the `root` app, not the child app:
  the child keeps its old spec until root syncs.
