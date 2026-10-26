# Change record: the last two hand-made Secrets move to SOPS (2026-10-26)

Prepared 2026-10-26. Nothing is synced or applied yet; the user commits and merges.

## Scope

| Secret | Namespace | Encrypted file | Live risk |
|---|---|---|---|
| `tunnel-token` (key `token`) | `cloudflared` (was `kube-system`) | `infrastructure/cloudflared/secrets/tunnel-token.enc.yaml` | none: only the PARKED `cloudflared` app uses it, and no cloudflared pod runs in the cluster |
| `cloudflare-api-token-secret` (key `api-token`) | `cert-manager` (unchanged) | `infrastructure/cert-manager/secrets/cloudflare-api-token.enc.yaml` | **live**: `ClusterIssuer cloudflare-clusterissuer` reads it for DNS-01, so the wildcard cert's renewal depends on it |

Files changed: `infrastructure/cloudflared/{kustomization,deployment}.yaml` and `secrets/`,
`infrastructure/cert-manager/kustomization.yaml` and `secrets/`, `clusters/homelab/parked/cloudflared.yaml`,
`clusters/homelab/bootstrap/SECRETS-SOPS.md`, this file.

## Why

Secrets belong in Git, encrypted (see SECRETS-SOPS.md). After this the only Secret that lives only in the cluster
is `argocd/sops-age` (secret zero, also in the password manager). Rebuilding the cluster no longer needs these two
re-created by hand.

## Decisions

- **The API token stays in `cert-manager`.** A ClusterIssuer reads Secrets from cert-manager's own namespace
  (the "cluster resource namespace"), so it can't move.
- **`tunnel-token` moves to a new namespace `cloudflared`** (the parked Application has `CreateNamespace=true`).
  `cloudflared` must be added to `clusters/homelab/bootstrap/cluster-in-cluster.yaml` and applied by hand before the
  app is enabled (step added to the parked Application's header). The file was not edited here.
- **The cert-manager Secret carries `argocd.argoproj.io/sync-options: Prune=false`**, so a later kustomization
  mistake can't make ArgoCD delete it and break renewals.
- The values were copied from the live Secrets straight into `sops -e` (never printed). Only `data` is encrypted.

## Pre-checks done (2026-10-26)

- `scripts/check-sops-encrypted.sh`: all files ok.
- sha256 of each decrypted `token` / `api-token` against the live Secret: **MATCH** (both files, and the backup).
- Scratch copy of each directory with the `generators:` block removed renders with `kubectl kustomize`, and
  `kubectl apply --dry-run=server` accepts it.
- Encrypted backup of the live cert-manager Secret, OUTSIDE the repo:
  `~/homelab-backups/2026-10-26-cloudflare-api-token-secret.enc.yaml` (mode 600, directory 700).

## After the merge: verify

1. ArgoCD: `cert-manager-config` is Synced and Healthy (hard-refresh `root` first if it was edited, then the child).
2. `kubectl get clusterissuer cloudflare-clusterissuer` shows Ready=True.
3. The wildcard `Certificate` in `kube-system` shows Ready=True (`kubectl get certificate -n kube-system`).
4. The Secret now carries ArgoCD tracking:
   `kubectl -n cert-manager get secret cloudflare-api-token-secret -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'`
   and the key name is still `api-token`
   (`kubectl -n cert-manager get secret cloudflare-api-token-secret -o jsonpath='{.data}' | python3 -c 'import json,sys;print(sorted(json.load(sys.stdin)))'`).
5. Nothing needs restarting: cert-manager reads the Secret at each challenge.

## Rollback

- Put the old content back (the values are identical, so this is only needed if the Secret was damaged):
  `sops -d ~/homelab-backups/2026-10-26-cloudflare-api-token-secret.enc.yaml | kubectl apply -f -`
- Revert the commit (`git revert`) and let ArgoCD sync. Because of `Prune=false`, reverting does not delete the Secret.
- If KSOPS itself fails, `cert-manager-config` stops syncing but the running Secret and certificate are untouched
  (SECRETS-SOPS.md, "If a sync fails with a KSOPS / sops error").

## Later cleanup

- When the `cloudflared` app is enabled and healthy: `kubectl -n kube-system delete secret tunnel-token`
  (the old copy; the Deployment now reads the one in `cloudflared`).
- Propose to the user: remove the two Secrets from CLAUDE.md's "two Secrets still created by hand" bullet
  (needs the user's OK).
