# bootstrap/

Files here are **not synced by ArgoCD** — `root-app.yaml` only watches `clusters/homelab/applications/`,
and this directory is deliberately outside that path. They exist so the control-plane upgrade/rebuild has
something to reapply by hand, without ArgoCD's controller doing any of this work itself.

**Why:** `server-1` is 1.6 GiB RAM / 1 vCPU. There have been two incidents: (a) applying `root-app.yaml` with
all child apps enabled choked K3s's SQLite datastore on CRD writes; (b) on 2026-09-28, with ArgoCD already at
0, `server-1` ran out of memory (no swap), the kernel thrashed, SQLite queries took ~18s, and the API server
timed out — likely triggered by a server-side dry-run against the large Application CRD. Fixed with a 2 GiB
swapfile and a k3s restart. These files trim the application-controller's watch scope and concurrency so a
future bring-up puts much less load on it.

**2026-09-28 swap note:** after the OOM-thrash outage, the user added a 2 GiB swapfile on `server-1`
(`vm.swappiness=10`). This isn't tracked in Git (it's host config, not a manifest) — **recreate it on any
rebuild of server-1**, including the control-plane upgrade.

## Bring-up order (after the control-plane upgrade, or once server-1 has been stable a while)

ArgoCD stays at 0 replicas until every step through 5 is done. Do not skip the pauses in step 5.

1. Apply the two manifests in this directory:
   ```
   kubectl apply -f clusters/homelab/bootstrap/cluster-in-cluster.yaml
   kubectl apply -f clusters/homelab/bootstrap/argocd-cmd-params-cm.yaml
   ```

2. Patch `argocd-cm` (don't replace it — it holds the standard `resource.exclusions` block):
   ```
   kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"600s"}}'
   ```

3. Set resource requests/limits on the main container of each ArgoCD workload (CLAUDE.md requires
   requests + a memory limit on every workload; no CPU limits — a limit only buys throttling on a
   single-core node):
   ```
   kubectl -n argocd set resources statefulset argocd-application-controller \
     --containers=argocd-application-controller --requests=cpu=100m,memory=256Mi --limits=memory=768Mi

   kubectl -n argocd set resources deployment argocd-repo-server \
     --containers=argocd-repo-server --requests=cpu=50m,memory=128Mi --limits=memory=384Mi

   kubectl -n argocd set resources deployment argocd-server \
     --containers=argocd-server --requests=cpu=50m,memory=64Mi --limits=memory=256Mi

   kubectl -n argocd set resources deployment argocd-redis \
     --containers=redis --requests=cpu=25m,memory=32Mi --limits=memory=128Mi
   ```

4. Leave `argocd-dex-server`, `argocd-applicationset-controller`, and `argocd-notifications-controller`
   at 0 replicas — nothing in this repo needs them yet.

5. Staged scale-up, checking `server-1` between each step (`kubectl top nodes`, plus `uptime; free -m` over
   SSH on server-1 if you can reach it directly): `argocd-redis` → `argocd-repo-server` → `argocd-server` →
   `argocd-application-controller` (StatefulSet last, since it's the one that does CRD-heavy work).
   **Abort — scale everything back to 0 — if load on server-1 stays above 3 for a couple of minutes, if
   available memory drops under ~200 MiB, or if any kubectl call takes more than 5s.**

Until the control plane is upgraded, don't run `--dry-run=server` against `Application` or other large CRDs
on this cluster — see incident (b) above.

6. Only once step 5's full stack is stable:
   ```
   kubectl apply -f clusters/homelab/root-app.yaml
   ```
   At that point `applications/` contains only `portfolio.yaml`, so this is a low-risk single-Application
   sync, not the full multi-app bring-up that caused the original outage.

## Files

- `cluster-in-cluster.yaml` — restricts the in-cluster server to the `argocd` and `portfolio` namespaces.
  No credentials; it's a Secret only because Argo CD reads cluster config from Secrets. The user applies it
  by hand.
- `argocd-cmd-params-cm.yaml` — full replacement for the live `argocd-cmd-params-cm`, adding concurrency
  limits on top of the existing hand-patched `server.insecure: "true"`.
