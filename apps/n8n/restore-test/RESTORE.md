# n8n-db: restore test and disaster recovery

Backups: Barman Cloud plugin v0.15.1 to R2, `s3://n8n-backup/shawn/n8n-db/` (base backups weekly + WAL
continuously). This folder is NOT part of GitOps: nothing references it. `cluster-restore-test.yaml` is applied by
hand, checked, and deleted. ArgoCD neither syncs nor prunes it.

## Quota (check before applying)

On 2026-10-20 the namespace used 2Gi of the 2560Mi `limits.memory`, 2 of 3 PVCs and 6Gi of 10Gi of storage. The
recovery job pod, and then the first instance pod, each have Postgres (256Mi) plus the barman-cloud sidecar
(256Mi): 512Mi of limits at a time (the finished job pod no longer counts). That's 2560Mi, an **exact fit**, and
the PVC is the 3rd of 3. If `kubectl -n n8n get resourcequota` shows more in use than that, or the job never
starts (`kubectl -n n8n get events | grep -i quota`), lower the test Cluster's memory limit to 192Mi and
`shared_buffers` to 16MB, then re-apply it. Don't run two restore Clusters at once.

## Restore test

1. **Before: record counts and the time** on the live database (read-only):

   ```bash
   date -u
   kubectl -n n8n exec n8n-db-1 -c postgres -- psql -d n8n -At -c \
     'SELECT (SELECT count(*) FROM workflow_entity) AS workflows,
             (SELECT count(*) FROM credentials_entity) AS credentials,
             (SELECT count(*) FROM "user") AS users,
             (SELECT max("updatedAt") FROM workflow_entity) AS last_workflow_change;'
   ```

   (Tables from n8n 2.43.8's `packages/@n8n/db/src/entities`: WorkflowEntity, CredentialsEntity, User. If
   `"updatedAt"` errors, drop that column from the query.)

2. **Optional: an on-demand base backup**, so the test also proves a fresh one. WAL archiving already ships changes
   within ~5 minutes, so this isn't needed for the counts to match.

   ```yaml
   # kubectl apply -f - ; then: kubectl -n n8n get backup n8n-db-pre-restore-test -w   (until "completed")
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata:
     name: n8n-db-pre-restore-test
     namespace: n8n
   spec:
     cluster:
       name: n8n-db
     method: plugin
     pluginConfiguration:
       name: barman-cloud.cloudnative-pg.io
   ```

3. **Restore:**

   ```bash
   kubectl apply -f apps/n8n/restore-test/cluster-restore-test.yaml
   kubectl -n n8n get pods -l cnpg.io/cluster=n8n-db-restore-test -w     # ...-full-recovery-..., then ...-1
   kubectl -n n8n get cluster n8n-db-restore-test -w                     # until "Cluster in healthy state"
   ```

   If it fails, read the job's log: `kubectl -n n8n logs -l cnpg.io/jobRole=full-recovery --all-containers`.
   R2 needs the `AWS_*_CHECKSUM_*` env from the ObjectStore on the restore sidecar too. Check
   `kubectl -n n8n get pod -l cnpg.io/jobRole=full-recovery -o yaml | grep AWS_`.

4. **Compare:** run step 1's query against `n8n-db-restore-test-1`. The counts must match.
   `last_workflow_change` minus the step 1 time is the RPO you observed.

5. **Delete and confirm nothing was written:**

   ```bash
   kubectl -n n8n delete cluster n8n-db-restore-test     # its PVC, Secrets and Services go with it
   kubectl -n n8n get pvc                                # only n8n-data and n8n-db-1 remain
   ```

   In the Cloudflare dashboard, R2 > `n8n-backup` > `shawn/` must still hold only `n8n-db/`, with no
   `n8n-db-restore-test/`. The test Cluster has no `plugins:` section, so it had no WAL archiver.

6. **Record** the date, restore duration (apply to healthy), observed RPO and backup used in
   `apps/n8n/REQUIREMENTS.md`, replacing the "Restore test" open item.

## Disaster recovery: n8n-db's volume or agent-1's disk is lost

The same restore, but under the real name `n8n-db`, so n8n's `DB_POSTGRESDB_HOST` (`n8n-db-rw`) and Secret
`n8n-db-app` keep their names. ArgoCD manages that Cluster, so the change goes through Git:

1. In `apps/n8n/base/postgres-cluster.yaml`, replace `bootstrap.initdb` and add the source. The plugin
   gets a **new serverName** for archiving:

   ```yaml
   bootstrap:
     recovery:
       source: n8n-db-backup
       database: n8n
       owner: n8n
   externalClusters:
     - name: n8n-db-backup
       plugin:
         name: barman-cloud.cloudnative-pg.io
         parameters:
           barmanObjectName: n8n-backup-store
           serverName: n8n-db          # read the old backups
   plugins:
     - name: barman-cloud.cloudnative-pg.io
       isWALArchiver: true
       parameters:
         barmanObjectName: n8n-backup-store
         serverName: n8n-db-r1       # write somewhere NEW
   ```

   Why the new serverName: the plugin archives under the Cluster's name by default (`serverName :=
   cluster.Name`, plugin config.go). `shawn/n8n-db/` is not empty, so the archiver's empty-archive check fails the
   restore (plugin-barman-cloud issue #411: its last comment found this was the real cause, and the fix was a
   different serverName). Don't use the `skipEmptyWalArchiveCheck` annotation: it would let two timelines mix in
   one folder.
2. Push. Then `kubectl -n n8n delete cluster n8n-db`. Its `Delete=false` means ArgoCD won't delete it,
   and the data is gone anyway. ArgoCD (selfHeal) recreates it, and it bootstraps from R2.
3. CNPG generates a **new** `n8n-db-app` password. n8n reads it only at start:
   `kubectl -n n8n rollout restart deploy/n8n` once the Cluster is healthy.
4. n8n must start with the **same `N8N_ENCRYPTION_KEY`** (SOPS file in Git, copy in the password manager). With
   any other key, every stored credential is unreadable.
5. Afterwards: keep `serverName: n8n-db-r1`. The ScheduledBackup now writes there too. Leave `bootstrap` as
   recovery (CNPG reads it only when it creates a Cluster). Once `n8n-db-r1/` has a base backup and is older than the
   14-day retention, delete the old `shawn/n8n-db/` folder by hand: retention no longer prunes it.

The NetworkPolicies already cover this: the Postgres rules select `cnpg.io/cluster`, so they cover the recovery
job pod and the new instance.
