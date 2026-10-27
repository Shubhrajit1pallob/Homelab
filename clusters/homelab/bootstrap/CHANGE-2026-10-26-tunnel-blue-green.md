# Change record: blue/green Cloudflare Tunnel cutover (prepared 2026-10-26)

Prepared 2026-10-26. Nothing is applied or synced: the `cloudflared` Application stays in `parked/` until phase 1
is done. This replaces the "tunnel cutover" idea in the old parked header and makes the secrets record's
`tunnel-token` plan obsolete (the blue tunnel's token is no longer kept in Git).

## Goal

Today the only Cloudflare Tunnel connector runs on the shubmedia host (a laptop), so a laptop outage takes the
public site down. Run the connector in the cluster instead (2 replicas on agent-1), without ever having two
connectors serving the same tunnel with different `localhost` meanings.

## Design

| | Blue (existing) | Green (new) |
|---|---|---|
| Tunnel | dashboard-managed `k8s_cloud` | locally-managed `k8s-cluster`, created with `cloudflared tunnel create` |
| Connector | shubmedia host, routes -> `http://localhost:80` | this repo's `cloudflared` Deployment, 2 replicas, agent-1 |
| Ingress config | Cloudflare dashboard | `infrastructure/cloudflared/config.yaml` (ConfigMap) |
| Credentials | tunnel token on the host | `tunnel-credentials` Secret, SOPS-encrypted in `infrastructure/cloudflared/secrets/` |
| Role | **left untouched as the rollback** | takes over one hostname at a time |

- Cutover is flipping each hostname's DNS CNAME from `<old-UUID>.cfargotunnel.com` to `<new-UUID>.cfargotunnel.com`,
  one at a time, in the dashboard. Rollback = flip the CNAME back (proxied records take effect at the edge within about a minute).
- Green's ingress uses **wildcards only**: `shubhrajitpallob.dev` and `*.shubhrajitpallob.dev` ->
  `http://traefik.kube-system.svc.cluster.local:80`, then `http_status:404`. No admin hostname appears in the public
  repo. Which names are public or behind Cloudflare Access stays in the dashboard (DNS records, Access apps), and
  Access keys on hostname, so it keeps working after a flip. The n8n `/webhook/*` Access bypass is likewise untouched.
- Traffic reaches Traefik's `web` entrypoint, exactly as the blue tunnel's does.

## What was prepared (all in Git, none applied)

| Piece | File |
|---|---|
| Namespace `cloudflared`, Pod Security `restricted` (enforce, audit, warn) | `infrastructure/cloudflared/namespace.yaml` |
| Config (`tunnel: TUNNEL_UUID_CHANGE_ME`, metrics `0.0.0.0:2000`, `no-autoupdate`), generated as a hashed ConfigMap so edits roll the pods | `infrastructure/cloudflared/config.yaml` + `configMapGenerator` |
| Hardened Deployment: image `cloudflare/cloudflared:2026.10.0` pinned by tag and digest, `tunnel --config ... run`, 2 replicas, `node-role=cloud`, `/ready` probes on 2000, non-root 65532, read-only root FS, no privilege escalation, drop ALL, seccomp RuntimeDefault, no ServiceAccount token | `infrastructure/cloudflared/deployment.yaml` |
| PodDisruptionBudget `minAvailable: 1` | `infrastructure/cloudflared/pdb.yaml` |
| NetworkPolicies: default-deny both ways; egress to kube-dns, to Traefik pods on **8000**, to the internet on TCP 7844 and TCP 443 (UDP dropped, see "Found during phase 1") (private, tailnet and link-local ranges excluded); ingress on 2000 from ns `monitoring` only | `infrastructure/cloudflared/networkpolicy.yaml` |
| Secret generator for `tunnel-credentials` (the encrypted file does not exist yet) | `infrastructure/cloudflared/secrets/ksops-generator.yaml` |
| PodMonitor for `:2000/metrics` and PrometheusRule `CloudflaredDown` (<1 ready replica for 5m, critical) | `apps/monitoring/prometheus/cloudflared-{podmonitor,alerts}.yaml` |

These two monitoring files sync as soon as this is merged (`monitoring-config` is enabled). They are inert until the
cloudflared pods exist.

Findings behind the choices:
- **Traefik pod port.** The Service `traefik` maps 80 -> `web` and 443 -> `websecure`; in the pod `web` is **8000**
  (`websecure` 8443, metrics 9100, dashboard 8080). A NetworkPolicy matches the pod port, so the rule allows 8000. Traefik's
  pods carry `app.kubernetes.io/name=traefik`, and `kube-system` has no NetworkPolicies, so nothing blocks cloudflared there.
- **Image.** 2026.10.0 (published 2026-10-05) is the newest release at least 2 weeks old on 2026-10-26; 2026.10.1 (10-15)
  and later are too new. It is a multi-arch image on a distroless `nonroot` base (uid 65532).
- **Memory.** Cloudflare's published sizing is per host (4 GB / 4 cores for large deployments), with no per-container
  number, so there is no documented basis for 96Mi. Requests 10m / 48Mi, limit 128Mi for headroom. Measure with
  `kubectl top pod -n cloudflared` after cutover and tighten or raise it.

## Phase 0: prep (before any change)

- The user keeps the hostname inventory (every name currently on `k8s_cloud` and which are behind Access) in
  **private notes, not in this repo**.
- Confirm that every record to flip is proxied (orange cloud) and that the Access apps (including the n8n `/webhook/*` bypass) are listed in the dashboard.
- Note the blue tunnel's health in the dashboard as the baseline.

## Phase 1: build green (traffic unchanged)

1. User, on the Mac: `cloudflared tunnel login`, then `cloudflared tunnel create k8s-cluster`. This prints the UUID and
   writes `~/.cloudflared/<UUID>.json` (the credentials, a secret) and `~/.cloudflared/cert.pem`.
2. Worker, only after the user OKs it in the worker's session: create `secrets/tunnel-credentials.enc.yaml` by piping the
   JSON straight into `sops -e` (nothing printed), e.g.
   `kubectl create secret generic tunnel-credentials -n cloudflared --from-file=credentials.json=$HOME/.cloudflared/<UUID>.json --dry-run=client -o json | jq '{apiVersion,kind,metadata:{name:.metadata.name,namespace:.metadata.namespace},type,data}' | sops -e --filename-override infrastructure/cloudflared/secrets/tunnel-credentials.enc.yaml --input-type json --output-type yaml /dev/stdin > ...`
   then check the decrypted `credentials.json` hash against the file (MATCH/DIFFER only).
3. User: put the JSON in the password manager, then delete `~/.cloudflared/<UUID>.json` and `~/.cloudflared/cert.pem` from
   the Mac.
4. Worker/user: replace `TUNNEL_UUID_CHANGE_ME` in `config.yaml` (the UUID is an identifier, not a secret).
5. User commits (branch + PR), merges.
6. User adds `cloudflared` to the namespaces in `clusters/homelab/bootstrap/cluster-in-cluster.yaml` and
   `kubectl apply -f` it, then moves the app `parked/` -> `applications/` (`git mv`) and merges.
7. Test without touching real hostnames. DNS is done in the Cloudflare dashboard only (`cert.pem` was deleted in step 3, and
   `cloudflared tunnel route dns` needs it): create a **proxied CNAME** `cutover-test` -> `<UUID>.cfargotunnel.com` by hand.
   Expect Traefik's 404 for `cutover-test.shubhrajitpallob.dev` (Traefik has no route for it), and the dashboard shows the green tunnel with
   2 healthy connectors. Also check `kubectl get pods -n cloudflared` (2/2 Ready), `kubectl top pod -n cloudflared`, and that
   the `CloudflaredDown` rule is loaded and not firing.

## Phase 2: flip DNS, one hostname at a time

Order: Grafana, then `www`, then the apex, then n8n. For each hostname: in the Cloudflare dashboard, edit that record's CNAME
target to `<new-UUID>.cfargotunnel.com` (dashboard only; no `cloudflared tunnel route dns`, since `cert.pem` is gone). Proxied
records need no client TTL wait: the edge picks the change up within seconds to a minute, so give it a minute, then check:
- the page loads;
- admin names still show the Cloudflare Access prompt;
- for n8n: a GitHub webhook redelivery comes back green.

**Rollback for any name:** set its CNAME back to `<old-UUID>.cfargotunnel.com`. The blue tunnel and host connector are untouched.

## Phase 3: laptop-off test, then retire blue

1. Stop or power off shubmedia (or stop its connector) and confirm the public site, admin names and the n8n webhook still work.
2. After about a week of clean running: on shubmedia `systemctl disable --now cloudflared`; delete the old tunnel `k8s_cloud` in
   the dashboard; `kubectl -n kube-system delete secret tunnel-token`; delete the `cutover-test` DNS record.
3. Update CLAUDE.md (ingress and single-point-of-failure text, ArgoCD namespace list, the Secrets list) with the user's OK.

## Found during phase 1

- **Symptom:** after enabling green, both cloudflared pods stayed 0/1 and restarted about every 60 s (killed by the liveness
  probe on `/ready`, which stayed 503).
- **Cause:** the pod MTU on this cluster is 1230 (flannel VXLAN over `tailscale0`). cloudflared's default protocol tries QUIC
  first; QUIC sends about 1252-byte initial packets with Don't Fragment set, which never leave the pod network, so UDP 7844
  timed out. DNS, TCP 7844 and the API on 443 all worked. With `protocol: auto`, QUIC is retried with backoff (4, 8, 16, 32 s)
  and the probe killed the pod before it fell back to HTTP/2. It was not the NetworkPolicy.
- **Fix:** `protocol: http2` in `config.yaml` (connects in seconds over TCP 7844), and the now-unused UDP 7844 egress rule was
  dropped from `networkpolicy.yaml` (least privilege). The probes were left as they are.
- **Impact:** none. Blue carried all traffic throughout; no hostname had been flipped yet.

## Risks and known gaps

- **agent-1 now carries the whole site path** (connectors, plus the portfolio pods). Both replicas share agent-1 because it
  is the only `node-role=cloud` node, so this protects against a pod failure, not a node failure. Accepted.
- **Traefik is still a single pod on server-1.** If server-1 reboots, the site is down whatever tunnel is used. Next change.
- **Draining agent-1 will wait on the PDB** (both replicas are on that node and `minAvailable: 1`). Before a resize, scale
  cloudflared to 0 or temporarily point a hostname back at blue, as with the earlier agent-1 resize.
- **Liveness on `/ready`** restarts a replica after about 60 s without an edge connection. A Cloudflare edge outage could
  restart both replicas in turn; the pods come straight back.
- **Alerting limits.** Prometheus runs on shubmedia, so `CloudflaredDown` can't fire while the laptop is the thing that is
  down, and it watches the connector pods, not the public site. An external uptime check would cover that (not done).
- The credentials JSON exists briefly on the Mac in `~/.cloudflared/`; step 3 of phase 1 removes it.
- Pod Security `restricted` is enforced; the Deployment satisfies it. A future sidecar must too.

## Pre-checks done at preparation

See the worker's report: `scripts/check-sops-encrypted.sh`, and a scratch render with the generators block removed
plus a server-side dry-run (the Namespace does not exist yet, so objects in it only fail the dry-run for that reason).
