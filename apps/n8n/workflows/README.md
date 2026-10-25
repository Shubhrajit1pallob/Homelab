# n8n workflows (exported JSON)

This folder holds the n8n workflows as exported JSON, so they are reviewed and versioned in Git. It is **not
GitOps**: no `kustomization.yaml` and no Application references it, and ArgoCD neither applies nor prunes
anything here. The running copy lives in n8n's database (`n8n-db`, which the R2 backups cover). A workflow
changes only when someone imports it.

One file per workflow, named after it (e.g. `rag-api-reindex.json`). Re-export after every change made in the
UI, so Git matches what runs.

## The rule: credential IDs only, never secrets

An export references each credential by its n8n ID and name (`"credentials": {"httpHeaderAuth": {"id": "…",
"name": "…"}}`). The secret itself stays in n8n's database, encrypted with `N8N_ENCRYPTION_KEY`. So:

- Every key, token and password goes into an n8n **credential** (rag-api admin key, GitHub webhook secret,
  tokens). Never paste one into a node's parameters, a header value, a URL, a Code node or pinned data.
- Never export credentials into this folder, and never use `--decrypted`.
- A CLI export holds two more things that must not be committed, so the export steps below strip them:
  `staticData` (trigger state; the GitHub Trigger keeps its webhook **signing secret** there as
  `webhookSecret`) and `shared` (the owning project, whose name for a personal project is
  `First Last <email>`). Checked in n8n 2.43.8's source: `export:workflow` writes the whole workflow row with
  its `shared.project` relation (`packages/cli/src/commands/export/workflow.ts`), and `GithubTrigger.node.ts`
  stores the secret with `getWorkflowStaticData('node')`.
- An email address typed into a node (the Send Email node's From and To) is personal data, not a secret, but
  this repo is public, so the export steps replace `fromEmail`/`toEmail` with `CHANGE_ME@example.com`.
- **This repo is public.** Before every commit of an export, RUN the check below; don't just read the jq step
  and assume it worked (the first rag-reindex export still had a Gmail address in it, which this email pattern
  catches). Anything it prints must be explained, or moved into a credential and exported again.
  On a sanitized export it prints only the `CHANGE_ME@example.com` placeholders and an empty `"pinData"`.

```bash
grep -nEi '"(password|secret|webhooksecret|token|apikey|api_key|authorization|x-api-key|staticdata|shared)"|bearer |sk-ant-|ghp_|github_pat_|gh[opsu]_|"pinData"|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' apps/n8n/workflows/*.json
```

`pinData` is on the list because pinned test data can hold real responses (and so real values). Unpin it in
the editor before exporting. The email pattern catches the project name and any address typed into a node.

## Export

Use the CLI in the n8n container, which already has the database settings. The workflow's ID is the last part
of its URL (`…/workflow/<id>`). The output is a JSON **array** (even for one `--id`). Before anything reaches
the repo, `jq` drops `staticData` and `shared`, drops the fields that change on every save or run (`meta`,
`triggerCount`, version IDs and counters, timestamps) so diffs show only real edits, and replaces any email
address in a node's From/To with a placeholder. It keeps each node's `webhookId`, so a re-import keeps the same
webhook path (the GitHub Trigger path isn't a secret: n8n checks each delivery's HMAC signature).

```bash
kubectl -n n8n exec deploy/n8n -c n8n -- n8n export:workflow --id=<id> --output=/tmp/wf.json
kubectl -n n8n exec deploy/n8n -c n8n -- cat /tmp/wf.json | jq 'map(
    del(.staticData, .shared, .meta, .triggerCount, .versionCounter, .activeVersionId, .versionId,
        .versionMetadata, .updatedAt, .createdAt)
    | .nodes |= map(reduce ("fromEmail", "toEmail") as $k (.;
        if (.parameters // {}) | has($k) then .parameters[$k] = "CHANGE_ME@example.com" else . end)))' \
  > apps/n8n/workflows/<name>.json
kubectl -n n8n exec deploy/n8n -c n8n -- rm /tmp/wf.json
```

The repo ignores `*.json`, with an exception for `apps/n8n/workflows/*.json` (`.gitignore`), so files here
show up in `git status`. Any other JSON stays ignored.

The UI's `...` > **Download** works too, but run the grep check on it the same way (not checked whether the
editor's download includes `staticData`).

By default this exports the current draft. Add `--published` for the version that's actually live. Then run
the grep check above before `git add`.

## Import

From the UI: create a workflow, then `...` > **Import from File**, pick the JSON and save. Or with the CLI:

```bash
kubectl -n n8n cp apps/n8n/workflows/<name>.json "$(kubectl -n n8n get pod -l app.kubernetes.io/name=n8n,app.kubernetes.io/component=app -o name | cut -d/ -f2)":/tmp/wf.json -c n8n
kubectl -n n8n exec deploy/n8n -c n8n -- n8n import:workflow --input=/tmp/wf.json
kubectl -n n8n exec deploy/n8n -c n8n -- rm /tmp/wf.json
```

What to know (n8n docs, "Use the command line"):

- The export carries the workflow's ID. An import **overwrites** a workflow in the database with the same ID.
- `import:workflow` **deactivates** every workflow it imports. Activate it again in the UI.
- On a single instance like this one, the old version's schedule (cron) triggers keep running after an import
  until n8n restarts (a known n8n bug): `kubectl -n n8n rollout restart deploy/n8n`.
- A GitHub Trigger imported without `staticData` has no webhook ID or secret, so activating it registers a NEW
  webhook on the repo with a new secret. After re-importing over an existing workflow, delete the old webhook
  in the repo's Settings > Webhooks (n8n no longer tracks it).
- Email nodes come back with `CHANGE_ME@example.com` in From and To. Re-enter the real addresses in each Send
  Email node (e.g. "Reindex summary") before activating, or the mail goes nowhere.
- The credentials a workflow refers to must exist in this n8n. On a fresh instance (e.g. a new tenant), create
  them first, then re-select each one in the imported workflow's nodes and save.
