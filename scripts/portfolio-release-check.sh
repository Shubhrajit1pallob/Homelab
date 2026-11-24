#!/usr/bin/env bash
# Portfolio release checker (pull model).
#
# Follows the `latest` tag of the portfolio image on GHCR (only builds on the portfolio's main branch
# move it), and when it points at a commit other than the one pinned in apps/portfolio/deployment.yaml,
# opens (or updates) ONE pull request that bumps the image tag and APP_VERSION together.
# Nothing is pushed to main; merging the PR is the human step.
#
# Run by .github/workflows/portfolio-release.yml. Can also be run locally with DRY_RUN=1.
#
# Env (all optional):
#   IMAGE        image without tag   (default ghcr.io/shubhrajit1pallob/portfolio_website)
#   DEPLOYMENT   path to deployment.yaml (default apps/portfolio/deployment.yaml)
#   DRY_RUN=1    show the diff and stop; never commits or pushes
#   CI=true      set by GitHub Actions; enables git checkout/commit/push/PR. Without it the script
#                never touches git state (it edits DEPLOYMENT in place, so point DEPLOYMENT at a
#                temp copy for local tests).
#   GH_TOKEN     needed for the PR step (CI only)
#   BRANCH       PR branch (default portfolio-release/auto)
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/shubhrajit1pallob/portfolio_website}"
DEPLOYMENT="${DEPLOYMENT:-apps/portfolio/deployment.yaml}"
BRANCH="${BRANCH:-portfolio-release/auto}"
DRY_RUN="${DRY_RUN:-0}"
PORTFOLIO_REPO="Shubhrajit1pallob/portfolio_website"

in_ci=0
[ "${CI:-}" = "true" ] && in_ci=1

# a. The commit behind `latest`, from the amd64 image config label.
rev="$(crane config --platform linux/amd64 "${IMAGE}:latest" | jq -r '.config.Labels["org.opencontainers.image.revision"] // ""')"
if ! [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: revision label of ${IMAGE}:latest is not a 40-hex sha (got: '${rev}')" >&2
  exit 1
fi
echo "latest is commit ${rev}"

# b. The sha tag must exist and be the same index digest as latest (guards against a half-published build).
latest_digest="$(crane digest "${IMAGE}:latest")"
if ! sha_digest="$(crane digest "${IMAGE}:sha-${rev}" 2>/dev/null)"; then
  echo "Tag sha-${rev} does not exist yet; will try again next run."
  exit 0
fi
if [ "$latest_digest" != "$sha_digest" ]; then
  echo "latest (${latest_digest}) and sha-${rev} (${sha_digest}) differ; will try again next run."
  exit 0
fi

# c. Currently pinned sha.
image_re="image: ${IMAGE//./\\.}:sha-[0-9a-f]{40}\$"
if [ "$(grep -cE "$image_re" "$DEPLOYMENT")" != "1" ]; then
  echo "ERROR: expected exactly one pinned image line in ${DEPLOYMENT}" >&2
  exit 1
fi
current="$(grep -E "$image_re" "$DEPLOYMENT" | sed -E 's/.*:sha-([0-9a-f]{40})$/\1/')"
if [ "$current" = "$rev" ]; then
  echo "up to date (pinned ${current:0:7})"
  exit 0
fi
echo "pinned ${current:0:7}, latest ${rev:0:7}: bumping"

# Churn guard (CI only): an open PR from $BRANCH that already proposes this release needs no new push.
short="${rev:0:7}"
if [ "$in_ci" = 1 ]; then
  existing="$(gh pr list --head "$BRANCH" --base main --state open --json number --jq '.[0].number // empty')"
  if [ -n "$existing" ] && git fetch -q origin "$BRANCH" 2>/dev/null; then
    branch_file="$(git show "origin/${BRANCH}:${DEPLOYMENT}" 2>/dev/null || true)"
    if grep -qE "image: ${IMAGE//./\\.}:sha-${rev}\$" <<<"$branch_file" \
      && grep -qE "^ *value: \"sha-${short}\"\$" <<<"$branch_file"; then
      echo "PR #${existing} already proposes ${short}"
      exit 0
    fi
  fi
fi

# d. Edit both lines in $DEPLOYMENT (image tag and the APP_VERSION line right after its name line).
apply_edit() {
  local tmp
  tmp="$(mktemp)"
  sed -E "s#^( *image: ${IMAGE//./\\.}:sha-)[0-9a-f]{40}\$#\1${rev}#" "$DEPLOYMENT" \
    | awk -v short="$short" '
      /^ *- name: APP_VERSION$/ { print; getline; sub(/"sha-[0-9a-f]{7,40}"/, "\"sha-" short "\""); print; next }
      { print }' > "$tmp"
  cat "$tmp" > "$DEPLOYMENT"
  rm -f "$tmp"
}

orig="$(mktemp)"
cp "$DEPLOYMENT" "$orig"
trap 'rm -f "$orig"' EXIT
apply_edit

changed="$(diff "$orig" "$DEPLOYMENT" | grep -cE '^[<>]' || true)"
if [ "$changed" != "4" ]; then # 2 removed + 2 added
  echo "ERROR: expected exactly 2 changed lines, diff shows ${changed} diff lines" >&2
  diff "$orig" "$DEPLOYMENT" >&2 || true
  cp "$orig" "$DEPLOYMENT"
  exit 1
fi
grep -qE "^ *value: \"sha-${short}\"\$" "$DEPLOYMENT" || { echo "ERROR: APP_VERSION not updated" >&2; cp "$orig" "$DEPLOYMENT"; exit 1; }

# e. Dry run: show and restore.
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY_RUN: would make this change:"
  diff -u "$orig" "$DEPLOYMENT" || true
  if [ "$in_ci" = 1 ]; then git checkout -- "$DEPLOYMENT"; else cp "$orig" "$DEPLOYMENT"; fi
  exit 0
fi

if [ "$in_ci" != 1 ]; then
  echo "Not running in CI and DRY_RUN is not 1: leaving the edited file in place, no git actions."
  exit 0
fi

# f. Build the commit on a fresh origin/main (never on the checked-out ref), force-push, open or update the PR.
git config user.name "github-actions[bot]"
git config user.email "41898283+github-actions[bot]@users.noreply.github.com"
git fetch -q origin main
git checkout -- "$DEPLOYMENT"       # clean tree so the branch switch cannot conflict
git checkout -q -B "$BRANCH" origin/main
# Re-apply the edit on main's own copy of the file; do not carry over the checked-out ref's version.
if [ "$(grep -cE "$image_re" "$DEPLOYMENT")" != "1" ]; then
  echo "ERROR: expected exactly one pinned image line in origin/main:${DEPLOYMENT}" >&2
  exit 1
fi
current="$(grep -E "$image_re" "$DEPLOYMENT" | sed -E 's/.*:sha-([0-9a-f]{40})$/\1/')"
if [ "$current" = "$rev" ]; then
  echo "origin/main already pins ${short}; nothing to do"
  exit 0
fi
apply_edit
git add -- "$DEPLOYMENT"
nstat="$(git diff --cached --numstat | awk '{a+=$1; d+=$2; f++} END {print f" "a" "d}')"
if [ "$nstat" != "1 2 2" ] || [ "$(git diff --cached --name-only)" != "$DEPLOYMENT" ]; then
  echo "ERROR: staged change is not exactly 2+/2- lines in ${DEPLOYMENT}: ${nstat}" >&2
  git diff --cached --stat >&2
  exit 1
fi

title="portfolio: release sha-${short}"
body="$(cat <<EOF
Proposes deploying the portfolio commit [\`${short}\`](https://github.com/${PORTFOLIO_REPO}/commit/${rev}).

Full sha: \`${rev}\`
Changes: https://github.com/${PORTFOLIO_REPO}/compare/${current}...${rev}

This PR changes only the image tag and \`APP_VERSION\` in \`apps/portfolio/deployment.yaml\`.
**Merging it deploys the site**: ArgoCD syncs \`main\` to the cluster.

Opened automatically by the release checker workflow (\`.github/workflows/portfolio-release.yml\`), which follows the \`latest\` tag on GHCR. If a newer build lands before you merge, this PR is updated in place.
EOF
)"

git commit -q -m "$title" -m "Opened by the portfolio release checker. Full sha: ${rev}"
git push --force origin "$BRANCH"

if [ -n "${existing:-}" ]; then
  gh pr edit "$existing" --title "$title" --body "$body"
  echo "Updated PR #${existing}"
else
  gh pr create --base main --head "$BRANCH" --title "$title" --body "$body"
fi
