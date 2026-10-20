# n8n: requirements

Status (2026-10-19): phase 1 (database) **done**, live through `clusters/homelab/applications/n8n.yaml`:
`n8n-db-1` 2/2 on agent-1 (~145Mi), first base backup completed, WAL archiving on, objects in R2. Cloudflare
Access is live on `n8n.shubhrajitpallob.dev`. Phase 2 (the n8n app, 2.43.8) is written in `base/` and the overlay;
it deploys on the next push, after the encryption key is filled in.

## Purpose

Scheduled automation for the homelab and its repos:

- **rag-api reindex** (first workflow): re-run the portfolio content export into rag-api on a schedule.
- **AI PR review comments** on this repo's and the app repos' pull requests.
- **Auto-merge of the two release PR types** (portfolio `sha-` bump, rag-api `newTag` bump), by fixed rules
  (author, branch name, files changed, checks green), never by an AI decision.
- **Gmail drafts**, never auto-send.
- GitHub events: poll first. Webhooks only later, and only through an authenticated path (see Exposure).

## Shape

- One n8n instance, for one user (tenant `shawn`).
- Tenant-ready layout: `base/` holds everything shared, `tenants/<name>/` sets the namespace, the R2 backup
  prefix and that tenant's SOPS Secrets. A new tenant = copy `tenants/shawn`, change those three, add one
  Application. Two or more tenants running at once is out of scope on this hardware.

## Resource budget (agent-1)

agent-1 has 2 vCPU and ~5.4 GiB. Measured 2026-10-19: ~2.1 GiB used (37%); 704Mi requested, 2.2 GiB of limits.

| Piece | Requests | Memory limit | Measured |
| --- | --- | --- | --- |
| cnpg-operator (cnpg-system) | 10m / 64Mi | 256Mi | ~26Mi |
| cnpg-barman-plugin (cnpg-system) | 10m / 32Mi | 128Mi | ~10Mi |
| Postgres `n8n-db` + barman-cloud sidecar (one pod) | 60m / 160Mi | 768Mi | ~145Mi |
| n8n (phase 2) | 100m / 256Mi | 1Gi | - |
| n8n task-runners sidecar (phase 2) | 50m / 64Mi | 256Mi | ~5Mi idle (launcher only) |

Namespace total with n8n: 210m / 480Mi requested, 2Gi of limits (quota 2.5Gi), 2 PVCs / 6Gi.

The namespace's `ResourceQuota` (`base/quota.yaml`) caps one tenant at 500m / 768Mi requested and 2.5Gi of limits.

**Fallback rule:** if agent-1's real memory stays above ~75% for a week after n8n is deployed, replace CNPG with
a plain Postgres StatefulSet (move the data with pg_dump/restore) and remove the operator and plugin.

## Database

- CNPG `Cluster` `n8n-db`, Postgres 18, **1 instance** on `local-path` (5Gi) on agent-1. No HA: if agent-1's
  disk is lost, the backups are the only copy.
- CNPG creates the database `n8n`, owner `n8n`, and Secret `n8n-db-app` with the password. We never write one.
- Backups through the Barman Cloud plugin to Cloudflare R2, bucket `n8n-backup`, prefix `shawn/`: WAL
  continuously (at least every 5 minutes while there's activity, CNPG's `archive_timeout`) plus a weekly base backup
  (Sundays 03:00 UTC, and one right after deploy). Retention 14 days, so point-in-time recovery to any moment in
  that window.
- The `Cluster` and the `Namespace` carry `Prune=false,Delete=false`: removing them from Git or deleting the
  Application never deletes the database (local-path's reclaim policy is Delete).

## Secrets (SOPS, `tenants/<name>/secrets/`)

- Now: R2 API token for `n8n-r2-backup` (`ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`; Object Read & Write, this
  bucket only).
- Phase 2 and later:
  - `N8N_ENCRYPTION_KEY` (`n8n-encryption`). Also keep it in the password manager: without it, a restored
    database's stored credentials can't be decrypted.
  - `N8N_RUNNERS_AUTH_TOKEN` (`n8n-runners`): shared by n8n and its task-runners sidecar. Regenerable at any time.
  - GitHub token (fine-grained, only the repos and permissions the workflows need).
  - A separate Anthropic API key with a spend limit, not rag-api's.
  - Gmail OAuth client.
  - The rag-api admin key, for the reindex workflow.

## Exposure

- `n8n.shubhrajitpallob.dev` through the Cloudflare tunnel (Traefik `web` entrypoint), plus `websecure` with the
  wildcard cert, same convention as Grafana (`tenants/shawn/n8n-ingressroute.yaml`).
- **A Cloudflare Access application for that hostname MUST exist before n8n is deployed**: the first visitor to
  a fresh n8n becomes its owner. Done 2026-10-19 (the hostname answers with a redirect to Cloudflare Access).
- No public webhook path in phase 1 or 2.

## DNS

- **Cause** (found 2026-10-19): n8n logged `getaddrinfo ENOTFOUND api.n8n.io`. The pod's search list ends with
  agent-1's host domains (`tail1693b1.ts.net is.cc trouble-free.net interserver.net`) under `ndots:5`. `is.cc` and
  `interserver.net` answer NOERROR with no record for names like `api.github.com.is.cc`. The n8n images are musl,
  and musl moves to the next search domain only on NXDOMAIN (`name_from_dns` in musl's
  `src/network/lookup_name.c`), so it stops there and never tries the real name. rag-api's image (glibc) resolves
  the same names on the same node.
- **Fix:** `dnsConfig` with `ndots: "1"` on the n8n pod (`base/n8n-deployment.yaml`), covering both containers.
  Reproduced with a throwaway `alpine:3.22` container, `search is.cc`: `getent hosts api.github.com` fails with
  ndots:5 and resolves with ndots:1.
- **Rule for workflows calling cluster services:** musl never applies the search list to a name with at least
  ndots dots ("those with at least as many dots as ndots are only tried in the global namespace (never falling
  back to search, which glibc would do ...)", musl wiki, *Functional differences from glibc*). So use either a
  short name with no dots (same namespace only, e.g. `n8n-db-rw`) or the full name. `rag-api.rag-api` fails.
  The rag-api reindex workflow uses `http://rag-api.rag-api.svc.cluster.local:8000` (Service `rag-api`, port
  `http` 8000; 9090 is metrics).

## Known availability limits

- The only Cloudflare Tunnel connector runs on the shubmedia laptop: if it is offline, n8n's UI is unreachable.
- Traefik runs only on server-1: if server-1 is down or rebooting, the same.
- Scheduled workflows keep running in both cases; only the UI and any inbound traffic stop.

## Phases

1. **Database** (done 2026-10-19): CNPG Cluster, ObjectStore, weekly ScheduledBackup, quota, R2 Secret.
2. **n8n app** (written): Deployment (n8n + task-runners sidecar), PVC, Service, ServiceMonitor, IngressRoutes,
   encryption-key and runner-token Secrets.
   Cloudflare Access was set up first.
3. **NetworkPolicies + a restore test.** NetworkPolicies are left out of phases 1-2 on purpose, so the database
   and backups are proven working first and two new things are never debugged at once.
4. **Workflows**, in the order listed under Purpose.

## Open items

- **Task runners: external mode** (decided 2026-10-19, before any GitHub, Anthropic or Gmail credentials are
  added). n8n's default internal mode runs Code node scripts in a child process of n8n, which the docs call
  "insecure by design": code that escapes the sandbox could read the encryption key, every stored credential and
  the database. Instead an `n8nio/runners:<same version>-distroless` sidecar runs them, as UID 65532 with a
  read-only root filesystem, holding only the runner auth token. Keep the runners image tag equal to n8n's on
  every upgrade. Code the workflows run that comes from outside (PR text, email bodies) should still be treated
  as untrusted input and never executed.

- **Restore test** (phase 3): restore into a Cluster with a NEW name (for example `n8n-db-restore`) and point it
  at the old backups as its source. Restoring under the same name fails because its WAL archive path isn't
  empty (plugin-barman-cloud issue #411).
- **agent-1 host search domains** (planned host change, not done): remove `is.cc`, `trouble-free.net` and
  `interserver.net` from agent-1's resolver (probably set by netplan, cloud-init or DHCP from InterServer), then
  check whether n8n's `ndots: "1"` can go. Write it up next to
  `clusters/homelab/bootstrap/INCIDENT-2026-10-10-agent1-dns.md` (same host's DNS, `--accept-dns=false`).
- **Alerting:** Alertmanager is disabled, so a failing backup or WAL archive alerts nobody. Until that changes,
  check `kubectl -n n8n get backups` and the Cluster's status by hand.
