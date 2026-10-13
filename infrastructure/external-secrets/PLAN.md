# Plan: External Secrets Operator + Pulumi ESC (written 2026-10-12, nothing built yet)

## Goal

Stop creating Kubernetes Secrets by hand. Secret **values** live in Pulumi ESC. Git holds only **references**
(`ExternalSecret` manifests). External Secrets Operator (ESO), run by ArgoCD, fetches the values and writes
normal Kubernetes Secrets into each namespace. Apps don't change: the Secret names and keys stay the same.

```
Pulumi ESC  (environment homelab/prod: the real values)
   ▲  HTTPS, one Pulumi access token
ESO controller (ns external-secrets, ArgoCD app, Helm chart pinned)
   │  ClusterSecretStore "pulumi-esc" (in Git, no secret in it)
   │  ExternalSecret per Secret (in Git, next to each app)
   ▼
Secret rag-api-secrets (ns rag-api), rag-api-key + portfolio-views (ns portfolio), grafana-supabase (ns monitoring)
```

## Facts this plan builds on (checked 2026-10-12)

- Chart `external-secrets/external-secrets` **2.12.0** (app v2.12.0), repo `https://charts.external-secrets.io`.
  The cluster is K3s v1.36.4.
- With defaults the chart renders **25 CRDs, about 2 MB**. `secretstores` and `clustersecretstores` are about
  703 KiB each. They're over the client-side apply size limit, so the Application needs `ServerSideApply=true`,
  the same as kube-prometheus-stack.
- The CRDs we don't use can be turned off with `crds.create*: false` plus the matching `process*: false`:
  SecretStore, ClusterExternalSecret, PushSecret, ClusterPushSecret, ClusterGenerator. That leaves about 1 MB.
  The small generator CRDs stay.
- By default it runs 3 Deployments: the controller, the webhook and the cert-controller. The webhook only
  validates ESO's own objects, so it and the cert-controller can be turned off to save memory
  (`webhook.create: false`, `certController.create: false`). **Check that this renders cleanly in phase 1;**
  if the chart objects, keep them with small limits.
- Pulumi provider (ESO docs): a ClusterSecretStore with
  `provider.pulumi.{organization, project, environment, auth.accessToken.secretRef{name,key,namespace}}`.
  - ExternalSecret `remoteRef.key` uses Pulumi path syntax (`ragApi.queryApiKey`).
  - Only **one level of nesting** is supported, so use `group.key`, not deeper. Use camelCase, not hyphens.
  - OIDC auth exists but needs Pulumi to reach the cluster's OIDC issuer. Our API server is private, so we use
    an access token.
- ArgoCD may only touch the namespaces listed in `clusters/homelab/bootstrap/cluster-in-cluster.yaml`, so
  `external-secrets` must be added there. `clusterResources: "true"` already allows CRDs and the
  cluster-scoped store.
- The existing pattern to copy: a chart Application (like `kube-prometheus-stack.yaml`, multi-source with
  `$values`), plus a `-config` Application for objects that need its CRDs. Those use `cert-manager-config.yaml`'s
  `SkipDryRunOnMissingResource=true` + `retry`.
- None of the 4 target Secrets exist in the cluster yet, so ESO creates them fresh and nothing needs adopting.

## Decisions

| # | Decision | Proposed | Status |
|---|---|---|---|
| D1 | Secret store | Pulumi ESC | **agreed 2026-10-12** |
| D2 | ESC layout | one project `homelab`, one environment `prod` | proposed |
| D3 | Auth | Pulumi access token in one hand-made Secret (the "secret zero") | proposed |
| D4 | Token type | the least-privileged token your Pulumi plan allows; ideally read-only on `homelab/prod` | **you check** what your plan offers |
| D5 | Store scope | one `ClusterSecretStore` (every namespace can use it) | proposed |
| D6 | Refresh | `refreshInterval: 1h` (force sooner with an annotation, see runbook) | proposed |
| D7 | Ownership | `creationPolicy: Owner`: removing an ExternalSecret from Git deletes its Secret | proposed (see risks) |
| D8 | Order | ESO goes live **before** rag-api, so rag-api's Secrets are never made by hand | proposed |
| D9 | Existing hand-made Secrets (grafana-admin, cloudflare token, tunnel token) | leave them alone now; migrate later, one at a time | proposed |

## ESC environment layout (`homelab/prod`)

Values are marked secret in ESC (`fn::secret`). The names are the contract with the ExternalSecrets below.

```yaml
values:
  ragApi:
    queryApiKey:    {fn::secret: ...}   # also feeds the portfolio's rag-api-key: one value, two Secrets
    adminApiKey:    {fn::secret: ...}
    voyageApiKey:   {fn::secret: ...}
    anthropicApiKey: {fn::secret: ...}
    databaseUrl:    {fn::secret: ...}   # rag_api user, session pooler 5432, sslmode=require
  portfolio:
    viewsDatabaseUrl: {fn::secret: ...} # portfolio_views user (INSERT only)
    viewsHashSecret:  {fn::secret: ...} # openssl rand -hex 32
  grafana:
    supabasePgHost:     <pooler-host>:5432
    supabasePgUser:     grafana_reader.<project-ref>
    supabasePgPassword: {fn::secret: ...}
  smoke:
    hello: world                        # phase 4 test only; delete afterwards
```

| Kubernetes Secret (ns) | Key | ← ESC path |
|---|---|---|
| `rag-api-secrets` (rag-api) | RAG_QUERY_API_KEY, RAG_ADMIN_API_KEY, VOYAGE_API_KEY, ANTHROPIC_API_KEY, DATABASE_URL | `ragApi.*` |
| `rag-api-key` (portfolio) | RAG_API_KEY | `ragApi.queryApiKey` |
| `portfolio-views` (portfolio) | VIEWS_DATABASE_URL, VIEWS_HASH_SECRET | `portfolio.*` |
| `grafana-supabase` (monitoring) | SUPABASE_PG_HOST, SUPABASE_PG_USER, SUPABASE_PG_PASSWORD | `grafana.*` |

The admin key ends up only in the rag-api namespace (and your Mac for `rag_export`), never in portfolio.

## Step-by-step

Who does each step: **You** (the user) or **Me** (the Homelab planner session, which edits files and runs
read-only checks). Git work and cluster-changing kubectl are always yours.

### Phase 0: Pulumi side (You)
1. Create or sign in to a Pulumi Cloud account. Note the **organization** name; on an individual account it's
   your username.
2. Create the ESC environment `homelab/prod` (project `homelab`, env `prod`) and fill it with the layout above.
   Generate the two rag-api keys and the hash secret with `openssl rand -hex 32`. Don't paste values into chat.
3. Create an access token (D4). Store it in your password manager.
4. Check from the Mac that it reads: `esc env open homelab/prod` should print the values (secrets shown as
   `[secret]` unless `--show-secrets`).
5. Tell me the organization name (it's not a secret).

### Phase 1: Write the manifests (Me; nothing applied)
6. `infrastructure/external-secrets/values.yaml`:
   - turn off the unused CRDs and processors (see Facts);
   - try `webhook.create: false` and `certController.create: false`;
   - pin to agent-1 (`node-role=cloud`);
   - requests/limits on every pod (controller about 20m/64Mi, limit 128Mi; measure afterwards);
   - `serviceMonitor.enabled: true` so Prometheus scrapes ESO's sync metrics.
7. `clusters/homelab/parked/external-secrets.yaml`: chart Application, sync-wave 1 (after cert-manager, before
   the apps):
   - multi-source with `$values`, `targetRevision: 2.12.0`;
   - `CreateNamespace=true`, `ServerSideApply=true`;
   - header listing the prerequisites.
8. `infrastructure/external-secrets-config/`: `kustomization.yaml` + `cluster-secret-store.yaml`
   (ClusterSecretStore `pulumi-esc`, organization/project/environment, token ref
   `external-secrets/pulumi-esc-token` key `accessToken`).
   Plus `clusters/homelab/parked/external-secrets-config.yaml`: wave 2, `SkipDryRunOnMissingResource=true`,
   `retry`.
9. Add `external-secrets` to the namespaces in `cluster-in-cluster.yaml`.
10. Checks (read-only):
    - `helm template` with the values: CRD count/size and pods as expected;
    - `kubectl kustomize` on the config dir;
    - `kubectl apply --dry-run=server` on both Application files.
    You review and commit.

### Phase 2: Install ESO (You run, I verify)
11. `kubectl apply -f clusters/homelab/bootstrap/cluster-in-cluster.yaml`.
12. Create the namespace and the token Secret by hand (the one secret that stays manual):
    ```bash
    kubectl create namespace external-secrets
    read -rs PULUMI_TOKEN   # paste, Enter; nothing is echoed or saved in history
    kubectl -n external-secrets create secret generic pulumi-esc-token --from-literal=accessToken="$PULUMI_TOKEN"
    unset PULUMI_TOKEN
    ```
13. `git mv` `external-secrets.yaml` from parked to applications, push, and hard-refresh `root`. Watch
    server-1 memory while the CRDs apply (`kubectl top nodes`); they are about 1 MB after trimming.
14. I verify:
    - the ESO pods are Running on agent-1;
    - the CRDs are `Established`;
    - the app is Synced/Healthy;
    - node memory before and after.

### Phase 3: Connect the store (You run, I verify)
15. `git mv` `external-secrets-config.yaml` into applications, push.
16. I verify: `kubectl get clustersecretstore pulumi-esc` shows `Valid` / `Ready=True`. If not, the
    condition message says whether it's the token, the org, or the environment name.

### Phase 4: Smoke test (Me write, You commit, I verify, then remove)
17. A throwaway ExternalSecret in `external-secrets-config` that makes Secret `eso-smoke` from `smoke.hello`.
18. I verify the Secret exists with value `world`. Then I check rotation: you change the value in ESC and
    force a refresh (`kubectl -n external-secrets annotate externalsecret eso-smoke force-sync=$(date +%s) --overwrite`),
    and I confirm the new value lands.
19. Remove the smoke test from Git; confirm ArgoCD prunes it and the Secret goes too (proves D7). Delete
    `smoke` from ESC.

### Phase 5: The real Secrets (Me write, You commit, I verify)
20. Write one ExternalSecret per Secret, each next to its app and added to that app's kustomization:
    - `apps/portfolio/externalsecrets.yaml`: `rag-api-key` and `portfolio-views`. The env refs stay
      `optional: true`, so pods start even if a fetch fails.
    - `apps/monitoring/prometheus/externalsecret-grafana-supabase.yaml`: `grafana-supabase`.
    - `apps/rag-api/externalsecret.yaml`: `rag-api-secrets`. It arrives when rag-api is unparked.

    Each gets the per-resource annotation `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`.
21. Replace every "create it by hand" comment (portfolio deployment, rag-api deployment, Grafana values,
    parked rag-api checklist step 5) with "comes from ESO, see infrastructure/external-secrets".
22. After merge, I verify:
    - each ExternalSecret is `SecretSynced`;
    - the Secrets exist with the right **key names** (I won't print values);
    - Grafana's Supabase datasource works after a restart;
    - the view counter writes rows after the portfolio restarts.

### Phase 6: Docs (Me)
23. `infrastructure/external-secrets/README.md` runbook:
    - add a secret;
    - rotate a value;
    - force a refresh;
    - what happens when Pulumi is unreachable;
    - rebuilding the cluster (only the token Secret is re-made by hand);
    - rotating the Pulumi token;
    - break-glass: create a Secret by hand if ESO is down.
24. CLAUDE.md:
    - ESO enabled, with the namespace;
    - "Things that live only in the cluster" shrinks to the token plus the three not-yet-migrated Secrets;
    - drop "There is no SOPS or sealed-secrets".

### Phase 7: Later, optional, one at a time
25. Migrate `grafana-admin`, then `cloudflare-api-token-secret`, then `tunnel-token`. These Secrets already
    exist, so each needs care: put the value in ESC; delete the hand-made Secret and let ESO recreate it (or use
    `creationPolicy: Merge`); restart the consumer; verify. Do the cloudflare token **last**, because cert
    renewals depend on it.
26. A Grafana panel and, once Alertmanager is on, an alert on ExternalSecrets that aren't Ready.

## Risks and how the plan handles them

| Risk | Handling |
|---|---|
| Pulumi Cloud down or token revoked | Existing Secrets stay (ESO doesn't delete on a failed fetch); only updates stop. The store shows Not Ready. Break-glass in the runbook. |
| Token leaks | Least-privilege token (D4); it lives only in the cluster and your password manager; rotation steps in the runbook. |
| Removing an ExternalSecret deletes its Secret (D7) | Shown deliberately in phase 4. Portfolio refs are `optional`; for rag-api, removing its Secret is the same as removing the app. |
| CRD apply strains server-1 (about 1 MB after trimming; 4.4 MB took care with kube-prometheus) | Trimmed CRDs, ServerSideApply, watch memory in step 13. If it struggles, pre-apply the CRDs one at a time as before. |
| Running without the webhook | ESO objects aren't validated on apply; mistakes show up as a not-Ready status instead. Fine at this size. If the chart doesn't support it cleanly, keep the webhook. |
| Free-plan limits on Pulumi ESC | **You check** the current limits on Pulumi's pricing page before phase 0 (not verified here). |
| Old leaked credentials in Git history | Not solved by this; still need rotating (CLAUDE.md "Lower priority"). |

## Effect on the rag-api go-live

rag-api stays parked until both its image is published and phase 5 is done (D8). Its checklist step 5 ("create
Secret rag-api-secrets by hand") becomes "its ExternalSecret is SecretSynced".
