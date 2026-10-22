# Secrets in Git with SOPS + age, decrypted by ArgoCD (KSOPS)

Live since 2026-10-14. The **Runbook** below is for day-to-day use; the plan and build log after it record how
it was set up and why.

## Goal

Stop creating Kubernetes Secrets by hand. Each Secret lives in this repo as a normal Secret manifest whose
**values** are encrypted with SOPS (age). The name, namespace and key names stay readable. ArgoCD decrypts the
values at sync time with the KSOPS kustomize plugin and applies a normal Secret. There's no outside service.
The only hand-made secret left is the age private key ("secret zero"), stored once in the cluster and once in
your password manager.

```
Your Mac: sops edit apps/rag-api/secrets/rag-api-secrets.enc.yaml   (age key decrypts, edit, re-encrypts)
   │ git push (only ENC[...] values leave the Mac)
   ▼
ArgoCD repo-server: kustomize build → KSOPS generator → sops decrypts with the age key in Secret argocd/sops-age
   ▼
normal Secret rag-api-secrets in ns rag-api (and the others)
```

## Runbook

Every command runs from the repo root on the Mac, with `SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt`
set (it's in `~/.zshrc`; if `sops` says "no identity matched", that variable is missing in this terminal).
Never write a decrypted file to disk; `*.dec.yaml` and `*.plain.yaml` are gitignored as a safety net only.

**Encrypted Secrets today:**

| Secret | Namespace | File | Read by |
|---|---|---|---|
| `rag-api-secrets` (5 keys) | rag-api | `apps/rag-api/secrets/rag-api-secrets.enc.yaml` | rag-api Deployment, keepalive CronJob |
| `rag-api-key` (query key) | portfolio | `apps/portfolio/secrets/rag-api-key.enc.yaml` | portfolio Deployment |
| `portfolio-views` | portfolio | `apps/portfolio/secrets/portfolio-views.enc.yaml` | portfolio Deployment |
| `grafana-supabase` | monitoring | `apps/monitoring/prometheus/secrets/grafana-supabase.enc.yaml` | Grafana |
| `grafana-admin` (since 2026-10-17) | monitoring | `apps/monitoring/prometheus/secrets/grafana-admin.enc.yaml` | Grafana |
| `n8n-r2-backup` (R2 token, since 2026-10-19) | n8n | `apps/n8n/tenants/shawn/secrets/n8n-r2-backup.enc.yaml` | ObjectStore `n8n-backup-store` (barman-cloud sidecar in the Postgres pod) |
| `n8n-encryption` (since 2026-10-19) | n8n | `apps/n8n/tenants/shawn/secrets/n8n-encryption.enc.yaml` | n8n Deployment |
| `n8n-runners` (since 2026-10-19) | n8n | `apps/n8n/tenants/shawn/secrets/n8n-runners.enc.yaml` | n8n Deployment (n8n and its task-runners sidecar) |
| `alertmanager-config` (key `alertmanager.yaml`, since 2026-10-21) | monitoring | `apps/monitoring/prometheus/secrets/alertmanager-config.enc.yaml` | Alertmanager (`alertmanagerSpec.configSecret` in values.yaml) |

`N8N_ENCRYPTION_KEY` must ALSO be kept in the password manager: n8n encrypts every saved credential with it, so
if it's lost (or a database restore is paired with a different key), every stored n8n credential is unreadable.

`alertmanager-config` is ONE value, the whole Alertmanager config, so the routing is encrypted too. Its redacted
twin `apps/monitoring/prometheus/secrets/alertmanager.example.yaml` (placeholders, not deployed) is what to
review; change both in the same commit. Its 4 placeholders (the Gmail address x3, the app password) sit INSIDE
that value, so `scripts/check-sops-encrypted.sh`'s placeholder check (a whole value equal to `CHANGE_ME`) can't
see them: after `sops edit`, check with `sops -d <file> | grep -c CHANGE_ME` (prints only a count; must be 0).
The operator reloads Alertmanager on its own when the Secret changes (config-reloader), so no restart is needed.

Still hand-made (phase 6): `tunnel-token`, `cloudflare-api-token-secret`.

### Change a value
1. `sops edit <file>.enc.yaml` (opens the decrypted copy in your editor; saving re-encrypts it).
2. `scripts/check-sops-encrypted.sh`, then commit and push.
3. After ArgoCD syncs (~10 min, or press Refresh on the app), **restart the consumer**: env vars are read only
   when a pod starts, and these Secrets have no hash suffix, so nothing restarts on its own. For example
   `kubectl -n rag-api rollout restart deploy/rag-api`. Grafana:
   `kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana`.

### Add a new Secret
1. Write it as `apps/<app>/secrets/<name>.enc.yaml`: a normal `kind: Secret` with `stringData:` and the value
   `CHANGE_ME` for every key. The `.enc.yaml` name is what makes `.sops.yaml` match it.
2. `sops -e -i apps/<app>/secrets/<name>.enc.yaml` (encrypting needs only the public key in `.sops.yaml`).
3. `sops edit` it and put in the real values. `scripts/check-sops-encrypted.sh` fails while any `CHANGE_ME`
   is left (when your key is set).
4. Add it to the app's `secrets/ksops-generator.yaml` under `files:`, as `./secrets/<name>.enc.yaml`. The path
   is relative to the **kustomization root**, not to the generator file. If the app has no generator yet,
   copy one from `apps/rag-api/secrets/`, give it a new `metadata.name`, and list it under `generators:` in
   the app's `kustomization.yaml`.
5. If the app deploys into a new namespace, that namespace must be in `cluster-in-cluster.yaml` first.
6. Commit, push, and check the Secret exists with the right **key names**:
   `kubectl -n <ns> get secret <name> -o jsonpath='{.data}' | python3 -c 'import json,sys;print(sorted(json.load(sys.stdin)))'`

### Check a change before pushing
- `scripts/check-sops-encrypted.sh` (every `*.enc.yaml` is encrypted, no placeholders).
- Render without decrypting: copy the app folder to a scratch dir, delete its `generators:` block, then
  `kubectl kustomize . | kubectl apply --dry-run=server -f -`. Plain `kubectl kustomize` on the real folder
  fails, because it can't run the KSOPS plugin.
- A full build needs `kustomize` and `ksops` on the Mac (`brew install kustomize`, plus the KSOPS release
  binary). Its output **contains the decrypted values**, so never print it:
  `kustomize build --enable-alpha-plugins --enable-exec apps/rag-api | grep -E '^kind:|^  name:'`

### If a sync fails with a KSOPS / sops error
Running pods are not affected; only apps with a generator stop syncing. Check, in order:
1. The repo-server pod has the `install-ksops` init container and it exited 0:
   `kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].status.initContainerStatuses[*].state}'`
2. `argocd-cm` still has the build options:
   `kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.kustomize\.buildOptions}'` (expect
   `--enable-alpha-plugins --enable-exec`).
3. Secret `argocd/sops-age` exists with the key `keys.txt`.
4. The file was encrypted for the current public key (`.sops.yaml`); a file encrypted for another key gives
   "no identity matched" in the app's sync error.

If 1 or 2 is missing, re-apply the patches (next section). Restart the repo-server after fixing 3:
`kubectl -n argocd rollout restart deploy/argocd-repo-server`.

**Break-glass** (a Secret must change NOW and KSOPS can't be fixed quickly): apply it straight from the
encrypted file, so the plaintext only exists in the pipe:
`sops -d apps/<app>/secrets/<name>.enc.yaml | kubectl apply -f -`. ArgoCD sees the same content once KSOPS
works again, so there's nothing to undo. Don't use `kubectl create secret` by hand; it drifts from Git.

### After an ArgoCD upgrade (or any re-apply of the upstream install manifests)
The install overwrites the repo-server Deployment and can reset `argocd-cm`, which removes KSOPS. Right after
the upgrade:
```bash
kubectl -n argocd patch configmap argocd-cm --type merge --patch-file clusters/homelab/bootstrap/argocd-cm-ksops-patch.yaml
kubectl -n argocd patch deployment argocd-repo-server --patch-file clusters/homelab/bootstrap/argocd-repo-server-ksops-patch.yaml
```
Then run the checks above and confirm every app is Synced/Healthy. Also re-apply the other hand-made ArgoCD
tuning in this folder (see `README.md` here). Before a major upgrade, check the KSOPS README for the supported
ArgoCD/kustomize versions and bump the init container's image tag if needed.

### Rebuilding the cluster
After ArgoCD is installed and before `root-app.yaml` is applied:
1. `kubectl -n argocd create secret generic sops-age --from-file=keys.txt="$SOPS_AGE_KEY_FILE"`
   (the key is also in your password manager).
2. Apply both patches as above, and wait for the new repo-server pod.
3. Apply `cluster-in-cluster.yaml`, then `root-app.yaml`.

### Rotating the age key
Do this if the private key might have leaked, or on a schedule you choose.
1. `age-keygen -o ~/.config/sops/age/new-keys.txt`, and note the new public key.
2. Put the new public key in `.sops.yaml` in place of the old one.
3. Make sops able to read with BOTH keys for now:
   `cat ~/.config/sops/age/keys.txt ~/.config/sops/age/new-keys.txt > ~/.config/sops/age/both.txt`, then
   `SOPS_AGE_KEY_FILE=~/.config/sops/age/both.txt sops updatekeys -y <file>` for every `*.enc.yaml`.
4. Replace the cluster copy with the **new** key and restart the repo-server:
   `kubectl -n argocd create secret generic sops-age --from-file=keys.txt=$HOME/.config/sops/age/new-keys.txt --dry-run=client -o yaml | kubectl apply -f -`,
   then `kubectl -n argocd rollout restart deploy/argocd-repo-server`.
5. Commit and push the re-keyed files; hard-refresh the apps and check they're Synced.
6. Make `new-keys.txt` your `keys.txt`, delete `both.txt`, update the password manager.
7. **If the old key leaked, also change every secret value** (API keys, DB passwords): old commits in the
   public history are still readable with the old key.

## Facts this plan builds on (checked 2026-10-13)

- **How ArgoCD is installed:** v3.5.3 (`quay.io/argoproj/argocd:v3.5.3`), from the plain upstream manifests.
  - There's no Helm release, and ArgoCD does not manage its own install. The repo-server and `argocd-cm` are
    therefore changed by **hand-applied patches kept in this folder**, like `argocd-cmd-params-cm.yaml`.
  - The repo-server uses about 135 Mi today.
  - `argocd-cm` has no `kustomize.buildOptions` yet.
- **Versions:** KSOPS latest is **v4.5.1** (image `viaductoss/ksops:v4.5.1`); SOPS latest is **v3.13.3**.
- **The documented ArgoCD integration** (KSOPS README) has two parts:
  1. `argocd-cm` gets `kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"`.
  2. The repo-server Deployment gets a patch: an init container running `ksops install ... /custom-tools`,
     an emptyDir, and a mount of the `ksops` binary into `/usr/local/bin/ksops`.

  We do **not** replace ArgoCD's bundled kustomize (no `--with-kustomize`), so its version doesn't change.
  **Verified in phase 1:**
  - `ksops install /custom-tools`, without that flag, copies only `ksops`.
  - The image is distroless (it has no shell), so the command must be `["ksops","install","/custom-tools"]`.
  - The image's user is the name `nonroot`, so the init container needs `runAsUser/runAsGroup: 65532`.
  - KSOPS v4 has SOPS built in, so ArgoCD needs no separate `sops` binary.
  - ArgoCD's bundled kustomize is v5.8.1, which supports the plugin flags.
- **The KSOPS generator** (v4, exec style) is a file with `apiVersion: viaduct.ai/v1`, `kind: ksops`, the
  annotation `config.kubernetes.io/function: exec: path: ksops`, and `files:`. It's listed under
  `generators:` in the app's kustomization.
  - **Paths in `files:` are relative to the kustomization root, not to the generator file** (found in
    phase 3). So `apps/<app>/secrets/ksops-generator.yaml` lists `./secrets/<name>.enc.yaml`.
- **Which keys get encrypted:** `.sops.yaml` creation rules choose which files and keys are encrypted. We encrypt
  only `data`/`stringData` (`encrypted_regex: ^(data|stringData)$`), so metadata stays readable for review.
- **Where the key comes from:** sops in the repo-server finds the age key through `SOPS_AGE_KEY_FILE`.
- **macOS:** sops's default key path is `~/Library/Application Support/sops/age/keys.txt`, not `~/.config`.
  Setting `SOPS_AGE_KEY_FILE` in your shell avoids the confusion.
- **Encrypting needs only the public key.** So the worker can create encrypted placeholder files, and only you
  (with the private key) can see or set the real values.

## Decisions

| # | Decision | Choice |
|---|---|---|
| D1 | Tool | SOPS + age, KSOPS in ArgoCD (agreed 2026-10-13) |
| D2 | Where encrypted files live | this repo, next to each app, in `apps/<app>/secrets/*.enc.yaml` |
| D3 | Keys | one age key pair for the cluster. Private: password manager + Secret `argocd/sops-age` (key `keys.txt`) |
| D4 | What gets encrypted | only `data`/`stringData` values |
| D5 | Order | SOPS goes live **before** rag-api, so its Secrets are never made by hand |
| D6 | Existing hand-made Secrets (grafana-admin, cloudflare token, tunnel token) | migrate later, one at a time |

## Files

```
.sops.yaml                                           # creation rule: *.enc.yaml, age public key, data/stringData only
clusters/homelab/bootstrap/argocd-cm-ksops-patch.yaml          # merge patch for argocd-cm (applied by hand)
clusters/homelab/bootstrap/argocd-repo-server-ksops-patch.yaml # strategic patch: init container, ksops, age key mount
scripts/check-sops-encrypted.sh                      # refuses a commit with a *.enc.yaml that isn't encrypted
apps/rag-api/secrets/{rag-api-secrets.enc.yaml, ksops-generator.yaml}
apps/portfolio/secrets/{rag-api-key.enc.yaml, portfolio-views.enc.yaml, ksops-generator.yaml}
apps/monitoring/prometheus/secrets/{grafana-supabase.enc.yaml, grafana-admin.enc.yaml, alertmanager-config.enc.yaml,
                                   alertmanager.example.yaml (redacted, not deployed), ksops-generator.yaml}
```

## Build log (phases 0-4 done 2026-10-13/14, phase 5 done 2026-10-17, phase 6 open)

**Who does each step:**
- **You** do the git work, run any `kubectl` that changes the cluster, and handle every real secret value.
- **Worker** (the homelab-e2 session) writes files and runs read-only checks.
- **Me** (the planner) writes the briefs and reviews the results.

### Phase 0: Tools and the key (You, about 5 min)
1. Install the tools on the Mac: `brew install sops age kustomize`, then KSOPS v4.5.1 (its README's install
   script, or the release binary on your PATH).
2. Make the key. Keep it out of chat and out of the repo:
   ```bash
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt      # prints "Public key: age1..."
   chmod 600 ~/.config/sops/age/keys.txt
   echo 'export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt' >> ~/.zshrc
   ```
3. Save the whole `keys.txt` content in your password manager. **If it's lost, nothing can be decrypted.**
4. Send me the **public** key (`age1...`). It's safe to share.

### Phase 1: Scaffolding (Worker; nothing applied)
5. `.sops.yaml` at the repo root:
   - `path_regex: \.enc\.yaml$`;
   - `encrypted_regex: ^(data|stringData)$`;
   - `age: <your public key>`.
6. `clusters/homelab/bootstrap/argocd-cm-ksops-patch.yaml`: only `data.kustomize.buildOptions`. It's applied
   with `kubectl patch --type merge`, **not** `kubectl apply`, so the other `argocd-cm` keys are kept.
7. `clusters/homelab/bootstrap/argocd-repo-server-ksops-patch.yaml`:
   - an init container `viaductoss/ksops:v4.5.1` that copies ksops (only) into an emptyDir;
   - a mount at `/usr/local/bin/ksops`;
   - Secret `sops-age` mounted read-only at `/sops-age`;
   - env `SOPS_AGE_KEY_FILE=/sops-age/keys.txt`;
   - small requests/limits on the init container.
8. `scripts/check-sops-encrypted.sh`: fails if any `*.enc.yaml` lacks a `sops:` block or still has a
   plaintext value under `data`/`stringData`. Plus `.gitignore` entries for `*.dec.yaml` and `*.plain.yaml`.
9. Validate everything locally with a **throwaway** age key in a scratch dir, never the real one:
   - encrypt a sample Secret;
   - `kustomize build --enable-alpha-plugins --enable-exec` decrypts it through KSOPS;
   - the check script passes for it and fails for a plaintext copy;
   - `kubectl patch --dry-run=server` accepts both patches.
10. You review and commit. This step changes nothing in the cluster.

### Phase 2: Turn KSOPS on in ArgoCD (You run, Worker verifies)
11. Put the private key into the cluster:
    ```bash
    kubectl -n argocd create secret generic sops-age --from-file=keys.txt="$SOPS_AGE_KEY_FILE"
    ```
12. Apply both patches:
    ```bash
    kubectl -n argocd patch configmap argocd-cm --type merge --patch-file clusters/homelab/bootstrap/argocd-cm-ksops-patch.yaml
    kubectl -n argocd patch deployment argocd-repo-server --patch-file clusters/homelab/bootstrap/argocd-repo-server-ksops-patch.yaml
    ```
13. The Worker verifies:
    - the new repo-server pod is Running;
    - the init container exited 0;
    - `ksops` is on PATH inside it;
    - **all existing apps are still Synced/Healthy** (the build flags apply to every kustomize app);
    - repo-server memory before and after.

    **Rollback:** `kubectl -n argocd rollout undo deploy/argocd-repo-server`, and remove the
    `kustomize.buildOptions` key.

### Phase 3: Smoke test (Worker writes, You commit, Worker verifies, then remove)
14. `infrastructure/argocd/secrets/sops-smoke.enc.yaml` (Secret `sops-smoke`, ns argocd, `hello: world`) plus a
    generator, added to `infrastructure/argocd/kustomization.yaml`. A failure here only blocks `argocd-config`
    (two IngressRoutes, which keep running).
15. After the push, the Worker verifies:
    - `argocd-config` is Synced;
    - Secret `sops-smoke` exists;
    - its value decodes to `world`.
16. Rotation test: you run `sops edit` to change the value and push; the Worker confirms the new value.
17. Remove the smoke files. The Worker confirms ArgoCD prunes the Secret.

### Phase 4: The real Secrets (Worker creates placeholders, You fill the values)
18. The Worker writes each Secret with `CHANGE_ME` values, encrypts it with the public key, adds a generator,
    and adds it to the app's kustomization:
    - `rag-api-secrets`, 5 keys, in `apps/rag-api` (that app is parked, so nothing happens yet);
    - `rag-api-key` (the **query** key) and `portfolio-views`, in `apps/portfolio`;
    - `grafana-supabase`, in `apps/monitoring/prometheus`.
19. You run `sops edit <file>` on each and replace `CHANGE_ME` with the real values. Use the same query key in
    `rag-api-secrets` and `rag-api-key`. Then run `scripts/check-sops-encrypted.sh` and commit.
20. **Hold `apps/portfolio` until phase 3 passed.** If KSOPS breaks, the portfolio app can't sync, so no
    releases deploy (the running site stays up).
21. Replace every "create it by hand" comment with "encrypted in `secrets/`, see
    clusters/homelab/bootstrap/SECRETS-SOPS.md". These comments are in:
    - the portfolio deployment;
    - the rag-api deployment;
    - the Grafana values;
    - step 5 of the parked rag-api checklist.
22. After the push, the Worker verifies:
    - each Secret exists with the right **key names** (it never prints values);
    - after you restart Grafana and the portfolio, the Supabase datasource works and the view counter writes
      rows.

### Phase 5: Docs (done 2026-10-17: the Runbook above, and CLAUDE.md)
23. Turn this file into the runbook:
    - add a secret;
    - rotate a value;
    - rotate the age key (`sops updatekeys`);
    - rebuild the cluster (re-create `sops-age`, re-apply both patches);
    - **ArgoCD upgrade:** re-applying the upstream install can drop the patches, so re-apply and re-check them;
    - break-glass: a hand-made Secret if KSOPS is down.
24. CLAUDE.md:
    - the validation command for apps with secrets (`kustomize build --enable-alpha-plugins --enable-exec`;
      plain `kubectl kustomize` will fail on them);
    - "Things that live only in the cluster" becomes `sops-age` plus the three not-yet-migrated Secrets;
    - remove "There is no SOPS".

### Phase 6: Later, one at a time (open)
25. Migrate `grafana-admin`, then `tunnel-token`, then `cloudflare-api-token-secret` (last, because cert renewals
    depend on it). For each: encrypt it into Git, let ArgoCD take over the existing Secret, restart the consumer,
    verify.

## Risks

| Risk | Handling |
|---|---|
| The age private key is lost | Every encrypted file becomes unreadable. Keep it in the password manager (step 3). It's also in the cluster Secret. |
| The age private key leaks | Make a new key, run `sops updatekeys` on every file, **and rotate the secret values themselves**, because old Git history stays decryptable with the old key. |
| A plaintext secret gets committed | `.sops.yaml` path rule + check script + `.gitignore` for `*.dec.yaml`/`*.plain.yaml`. A slip in a public repo means rotating that value. |
| KSOPS or the key breaks in ArgoCD | Apps that use a generator can't sync, but running pods are untouched. Rollback in step 13; break-glass in the runbook. Smoke test before the portfolio. |
| `--enable-exec` lets a kustomization run programs on the repo-server | Only this repo is connected, and only you can push to it. Note it if more repos are ever added. |
| An ArgoCD upgrade drops the hand-applied patches | Upgrade checklist in the runbook (step 23). |
| Old leaked credentials in Git history | Not solved by this. They still need rotating. |
