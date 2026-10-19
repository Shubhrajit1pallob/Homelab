# Plan: keep metrics longer than Prometheus's 7 days

Written 2026-10-17. Nothing is built yet. Three phases, in this order: **0** trim, **1** long-term trends in
Supabase, **2** weekly full archive in object storage (Cloudflare R2). Phase 1 and 2 don't depend on each
other, but both are cheaper after phase 0.

**Who does what:**
- **You:** git, every `kubectl` that changes the cluster, the Supabase SQL editor, the Cloudflare dashboard, and
  every secret value (`sops edit`).
- **Planner (this session):** writes the files and runs read-only checks.

## Facts this plan builds on (measured 2026-10-17)

- Prometheus: kube-prometheus-stack 91.7.0, on shubmedia.
  - Retention is 7d, capped at 4 GB, on a 5Gi `local-path` volume (a plain folder on shubmedia's disk).
  - It scrapes every 1m and stores about 2,070 samples/s, around 1 byte each: **~2 GB/week**.
  - It holds **116,865 series**, and uses **629 MiB of its 768 MiB limit**.
- Where the series come from:

  | Source (`job`) | Series | Note |
  |---|---|---|
  | `kubelet` `/metrics` | 60,234 | **52,325 of them are control-plane metrics from server-1** (see below) |
  | `apiserver` | 38,850 | the same control-plane metrics again; 28,747 are histogram buckets |
  | `kubelet` `/metrics/cadvisor` | 2,847 | per-container stats: **small, not the problem** (CLAUDE.md wrongly says it is) |
  | everything else | ~14,900 | Grafana, node-exporter, kube-state-metrics, portfolio, ... |

  K3s runs the apiserver, kine/etcd, controllers and the kubelet in **one process**, so server-1's kubelet
  endpoint also exports every `apiserver_*`, `etcd_*`, `workqueue_*`... metric. Prometheus stores them twice.
- shubmedia has 446 GB of free disk; the monitoring namespace has **no NetworkPolicies**.
- Supabase free plan: a 500 MB database in total, shared with the view counter, rag-api's documents and its
  answer cache. Grafana already has a Supabase datasource ("Supabase analytics", role `grafana_reader`).
- The AWS account closes after 6 months (CLAUDE.md), so the archive goes to **Cloudflare R2**. It speaks the
  S3 API, has 10 GB free, charges nothing for downloads, and you already use Cloudflare.

## Phase 0: Trim the duplicated control-plane series

**Status (2026-10-17):** written in `values.yaml`, rendered (`helm template`, drop lands on the kubelet
`/metrics` endpoint only) and server dry-run OK. Re-measured before the push: the regex matches **50,807** of
**117,692** series. The chart's default `metricRelabelings` entry is kept in the list (a values list replaces
the chart's, it doesn't merge). Every chart rule/dashboard using these families selects `job="apiserver"`.
**Done 2026-10-19** (pushed in `177ed65`): head series 117,254 → 66,321, Prometheus memory 629 → 404 MiB,
ingest ~2,070 → ~1,220 samples/s, no restart, no duplicates left on any node. Spot checks of the API server,
Kubelet and Compute Resources dashboards' queries all return data. Old copies on disk age out with retention.

1. In `apps/monitoring/prometheus/values.yaml`, `kubelet.serviceMonitor.metricRelabelings`:
   - Drop by `__name__`, **only on the kubelet job's `/metrics` endpoint**:
     `(apiserver|etcd|workqueue|apiextensions|aggregator|authentication|authorization|admission|field_validation|flowcontrol|kine|serviceaccount|node_authorizer|watch_cache|grpc)_.*`.
   - Keep `kubelet_*`, `rest_client_*`, `storage_operation_*`, `process_*` and `go_*`; the built-in Kubelet
     dashboard uses them.
   - The `apiserver` job is left alone; the chart's apiserver rules and dashboards read it.
2. Before pushing, render with `helm template` (CLAUDE.md) and check that the relabel landed on the right
   endpoint.
3. After the push, check that:
   - the series drop to **~65k**, and memory drops from ~629 MiB (expect ~400 MiB);
   - the built-in dashboards still render: API server, Kubelet, Compute Resources, Node Exhaustion.
   - **Rollback:** remove the relabel and push.
4. Fix the "mostly cAdvisor" line in CLAUDE.md.

## Phase 1: Long-term trends in Supabase (daily)

**Design:**
- About 40 hand-picked series, at **1-hour resolution**, kept indefinitely: ~1,000 rows/day, roughly 15–25 MB
  a year.
- A daily CronJob reads them from Prometheus's HTTP API (`query_range`, step 1h) and upserts them into
  Supabase.
- It's **idempotent and self-healing**: for each metric it starts at the last hour already stored, or 7 days
  back if there's none, and ends at the last complete hour. A missed run is filled in by the next one, as
  long as the gap is shorter than retention.

**Metrics** (draft, for you to change):

| Group | Series |
|---|---|
| Nodes (×3) | CPU utilisation %, memory available %, root disk used %, network rx/tx bytes/s, load1, up |
| Namespaces | memory working set, CPU used, container restarts (per namespace) |
| Portfolio | requests/s by status class (2xx/4xx/5xx), p95 latency, views recorded/h, view flush errors |
| Prometheus | series count, storage bytes (to watch the trim hold) |
| rag-api | added when its metrics release ships (questions, outcomes, tokens, cache hit ratio) |

**Steps:**
1. **Supabase SQL (you):** add `db/metrics_history.sql` (in this repo, `apps/monitoring/prometheus/db/`) to the
   SQL editor. It's idempotent like `page_views.sql`:
   - schema `metrics_history`;
   - table `samples (metric text, series text, ts timestamptz, value double precision, primary key (metric, series, ts))`;
     `series` is a stable label string such as `node=agent-1`;
   - role `metrics_writer` (LOGIN, password from `openssl rand -hex 32`), which can select, insert and update
     only this table;
   - `grafana_reader` can select it;
   - RLS policies for both roles (Supabase enables RLS on new tables; see the page_views lesson).
2. **Secret:** `apps/monitoring/prometheus/secrets/metrics-history.enc.yaml` holds `DATABASE_URL` for
   `metrics_writer`, through the session pooler like the others.
   - The planner makes a `CHANGE_ME` placeholder, and you fill it with `sops edit`.
   - Add it to the existing generator.
3. **Job files** in `apps/monitoring/prometheus/metrics-history/`:
   - `metrics.yaml`, a ConfigMap with the PromQL list above: name, expression, how to build `series` from the
     labels;
   - `export.py`, a ConfigMap with the script (stdlib `urllib` for Prometheus, `psycopg` for Supabase);
   - `cronjob.yaml`:
     - schedule `"17 2 * * *"` Etc/UTC, `concurrencyPolicy: Forbid`, `startingDeadlineSeconds: 21600`;
     - requests 50m/64Mi, limit 192Mi;
     - non-root, read-only root filesystem, no service account token;
     - prefer agent-1 (always on); never server-1.
   - **Image:** reuse the public rag-api image, pinned to a `sha-` tag (it already has Python and psycopg; the
     keepalive CronJob does the same). It's pinned separately, so rag-api releases never change this job. A
     tiny dedicated image is the cleaner later option.
4. **Dashboard:** `metrics-history-dashboard.yaml`, a ConfigMap labelled `grafana_dashboard: "1"`, reading the
   Supabase datasource. It has time pickers for months and years, with one panel per group above.
5. **Verify:**
   - run the job by hand (`kubectl create job --from=cronjob/metrics-history mh-test`);
   - check its log for the rows upserted per metric;
   - run it again: 0 new rows and no duplicates;
   - the dashboard shows the last 7 days of backfill;
   - check the database size after a week.

## Phase 2: Weekly full archive to R2 ("monthly batches" = one folder per month)

**Why weekly:** Prometheus only holds 7 days, so a monthly snapshot would miss ~23 days. Retention goes to
**9 days**, so each weekly snapshot overlaps the previous one by 2 days. A late or failed run loses nothing,
and Prometheus merges overlapping blocks on restore.

**Design:**
1. **Prometheus** (`values.yaml`):
   - `retention: 9d`; `retentionSize` stays at 4 GB, and after phase 0 nine days is ~1.5 GB;
   - `enableAdminAPI: true`, which is needed for `POST /api/v1/admin/tsdb/snapshot`.
     - The admin API can also **delete** data, so before enabling it, add a NetworkPolicy in `monitoring`. It
       lets only pods in the `monitoring` namespace (Grafana, the jobs) reach Prometheus on 9090.
     - Check that the kubelet's probes still pass.
     - `kubectl port-forward` is not affected.
2. **R2 (you, in the Cloudflare dashboard):**
   - a bucket `homelab-metrics-archive`;
   - an API token with **Object Read & Write on that bucket only**;
   - a lifecycle rule that deletes objects after N months (your choice; 12 months is about 60–80 GB, roughly
     $1/month after the 10 GB free).
   - The token goes in `apps/monitoring/prometheus/secrets/metrics-archive.enc.yaml` (SOPS).
3. **CronJob** `prometheus-archive`, weekly (`"40 3 * * 0"` UTC):
   - It must run **on shubmedia** (required affinity), because it mounts Prometheus's own volume to read the
     snapshot. `local-path` is ReadWriteOnce, which allows other pods on the same node.
   - It runs as Prometheus's UID/GID, so it can delete the snapshot afterwards.
   - **Image:** `rclone/rclone`, pinned. Its busybox has `wget` and `tar`.
   - **Steps:**
     1. Take the snapshot (`wget --post-data`).
     2. `tar czf - snapshots/<name> | rclone rcat r2:homelab-metrics-archive/prometheus/YYYY-MM/<date>.tar.gz`.
        This streams, so nothing extra is written to disk.
     3. Check the uploaded size.
     4. **Delete the snapshot folder.** Snapshots are hard links, so a forgotten one keeps old blocks on disk
        forever.
4. **Verify:**
   - run it by hand: the object is in R2, its size is reasonable, and the snapshot folder is gone;
   - **do one test restore:** download it, run `prometheus --storage.tsdb.path=<extracted>` locally on the
     Mac, and query a week-old metric;
   - write the restore steps into this file.

## Open choices (defaults in brackets)
- The metric list for phase 1 [the draft table].
- How long R2 keeps archives [12 months].
- Phase 1 schedule [daily; every 5 days also works, with a 2-day margin instead of 6].
- Retention for phase 2 [9 days].

## Risks
| Risk | Handling |
|---|---|
| The trim drops something a dashboard needs | Drop only on the kubelet job, keep kubelet/rest_client/storage metrics, check the dashboards, roll back by removing the relabel |
| Admin API misuse (delete series) | NetworkPolicy: only the monitoring namespace can reach 9090 |
| A forgotten snapshot fills the disk | The job deletes it; the 446 GB free and 4 GB retention cap give lots of margin; the job fails loudly if the delete fails |
| Supabase free plan fills | ~20 MB/yr from phase 1; check the DB size monthly; drop resolution to 6h if ever needed |
| shubmedia offline on archive night | 2-day overlap; and the next run picks up anything still inside retention |
| The R2 token leaks | Scoped to one bucket; rotate it in Cloudflare and `sops edit` |
