#!/usr/bin/env bash
# Fail if a *.enc.yaml file is not really SOPS-encrypted. Plan: clusters/homelab/bootstrap/SECRETS-SOPS.md (step 8).
#
# Usage: scripts/check-sops-encrypted.sh [file ...]
#   With no arguments, checks every *.enc.yaml in the repo.
#
# A file fails when:
#   - it has no top-level `sops:` block, or
#   - any entry under the top-level `data:` / `stringData:` maps has a value that is not ENC[...].
# Placeholder guard: when SOPS_AGE_KEY_FILE is set and readable (and sops is installed), each file is also
# decrypted IN MEMORY (sops -d into a shell variable, never to disk) and fails if any value is the placeholder
# CHANGE_ME. Values are never printed, only the key name. Without a key this check is skipped with a note.
# Exit status is 1 if any file fails, 0 otherwise. Needs bash and awk (no YAML parser); sops only for the guard.
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

placeholder_check=0
if [ -n "${SOPS_AGE_KEY_FILE:-}" ] && [ -r "$SOPS_AGE_KEY_FILE" ] && command -v sops >/dev/null 2>&1; then
  placeholder_check=1
else
  echo "note: SOPS_AGE_KEY_FILE unset or unreadable, or sops not installed; skipping the CHANGE_ME placeholder check"
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
    done <<<"$problems"
  else
    placeholders=""
    if [ "$placeholder_check" -eq 1 ]; then
      if decrypted="$(sops -d "$f" 2>/dev/null)"; then
        # Same section walk as above; reports key names only. Also catches CHANGE_ME in base64 under data:.
        placeholders="$(printf '%s\n' "$decrypted" | awk '
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
            if (value == "CHANGE_ME" || value == "Q0hBTkdFX01F") {
              printf "placeholder CHANGE_ME in %s\n", name
            }
          }
        ')"
      else
        placeholders="cannot decrypt with SOPS_AGE_KEY_FILE (wrong key?)"
      fi
      unset decrypted
    fi
    if [ -n "$placeholders" ]; then
      failed=1
      while IFS= read -r p; do
        echo "FAIL $f: $p"
      done <<<"$placeholders"
    else
      echo "ok   $f"
    fi
  fi
done

exit "$failed"
