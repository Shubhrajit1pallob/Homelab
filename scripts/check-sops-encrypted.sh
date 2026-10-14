#!/usr/bin/env bash
# Fail if a *.enc.yaml file is not really SOPS-encrypted. Plan: clusters/homelab/bootstrap/SECRETS-SOPS.md (step 8).
#
# Usage: scripts/check-sops-encrypted.sh [file ...]
#   With no arguments, checks every *.enc.yaml in the repo.
#
# A file fails when:
#   - it has no top-level `sops:` block, or
#   - any entry under the top-level `data:` / `stringData:` maps has a value that is not ENC[...].
# Exit status is 1 if any file fails, 0 otherwise. Needs only bash and awk (no YAML parser).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$repo_root" -name '*.enc.yaml' -not -path '*/.git/*' | sort)
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "no *.enc.yaml files found; nothing to check"
  exit 0
fi

failed=0
for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FAIL $f: file not found"
    failed=1
    continue
  fi

  problems="$(awk '
    BEGIN { has_sops = 0; section = "" }
    /^sops:/ { has_sops = 1 }
    # A line starting in column 0 that is not a comment or document marker opens a new top-level key.
    /^[^ \t#-]/ {
      key = $0
      sub(/:.*/, "", key)
      section = (key == "data" || key == "stringData") ? key : ""
      next
    }
    section != "" && /^[ \t]+[^ \t#]/ {
      line = $0
      sub(/^[ \t]+/, "", line)
      name = line
      sub(/:.*/, "", name)
      value = line
      sub(/^[^:]*:[ \t]*/, "", value)
      gsub(/^["\x27]|["\x27]$/, "", value)
      if (value !~ /^ENC\[/) {
        printf "plaintext value under %s: key \"%s\"\n", section, name
      }
    }
    END { if (!has_sops) print "no top-level sops: block (file is not SOPS-encrypted)" }
  ' "$f")"

  if [ -n "$problems" ]; then
    failed=1
    while IFS= read -r p; do
      echo "FAIL $f: $p"
    done <<< "$problems"
  else
    echo "ok   $f"
  fi
done

exit "$failed"
