# n8n: requirements

Status (2026-10-19): phase 1 (database) written, parked in `clusters/homelab/parked/n8n.yaml`. Nothing deployed.

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
| Postgres `n8n-db` | 50m / 128Mi | 512Mi | - |
| barman-cloud sidecar (in the Postgres pod) | 10m / 32Mi | 256Mi | - |
| n8n (phase 2) | - / 256Mi | 1Gi | - |

The namespace's `ResourceQuota` (`base/quota.yaml`) caps one tenant at 500m / 768Mi requested and 2Gi of limits.

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
  - `N8N_ENCRYPTION_KEY`. Also keep it in the password manager: without it, a restored database's stored
    credentials can't be decrypted.
  - GitHub token (fine-grained, only the repos and permissions the workflows need).
  - A separate Anthropic API key with a spend limit, not rag-api's.
  - Gmail OAuth client.
  - The rag-api admin key, for the reindex workflow.

## Exposure

- `n8n.shubhrajitpallob.dev` through the Cloudflare tunnel (the tunnel route already exists).
- **A Cloudflare Access application for that hostname MUST exist before n8n is deployed**: the first visitor to
  a fresh n8n becomes its owner.
- No public webhook path in phase 1 or 2.

## Known availability limits

- The only Cloudflare Tunnel connector runs on the shubmedia laptop: if it is offline, n8n's UI is unreachable.
- Traefik runs only on server-1: if server-1 is down or rebooting, the same.
- Scheduled workflows keep running in both cases; only the UI and any inbound traffic stop.

## Phases

1. **Database** (this): CNPG Cluster, ObjectStore, weekly ScheduledBackup, quota, R2 Secret.
2. **n8n app**: Deployment, Service, IngressRoute, Cloudflare Access first.
3. **NetworkPolicies + a restore test.** NetworkPolicies are left out of phases 1-2 on purpose, so the database
   and backups are proven working first and two new things are never debugged at once.
4. **Workflows**, in the order listed under Purpose.

## Open items

- **Restore test** (phase 3): restore into a Cluster with a NEW name (for example `n8n-db-restore`) and point it
  at the old backups as its source. Restoring under the same name fails because its WAL archive path isn't
  empty (plugin-barman-cloud issue #411).
- **Alerting:** Alertmanager is disabled, so a failing backup or WAL archive alerts nobody. Until that changes,
  check `kubectl -n n8n get backups` and the Cluster's status by hand.
