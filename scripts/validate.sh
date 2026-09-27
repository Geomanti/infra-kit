#!/usr/bin/env bash
# Static checks: formatting and per-module validation.
#
# `terraform validate` runs per directory because it only inspects the
# configuration in its own working directory — a single root-level call would
# miss every module. CI runs exactly this script.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v terraform >/dev/null 2>&1 || {
  echo "terraform not found on PATH" >&2
  exit 127
}

status=0

printf '=== terraform fmt (check)\n'
if ! terraform -chdir="$ROOT" fmt -check -recursive -no-color; then
  printf 'unformatted files listed above; run: terraform fmt -recursive\n'
  status=1
fi

for dir in "$ROOT"/modules/*/ "$ROOT"/stacks/*/; do
  [ -d "$dir" ] || continue
  label="${dir#"$ROOT"/}"
  printf '\n=== validate %s\n' "$label"
  if ! (cd "$dir" && terraform init -backend=false -input=false -no-color >/dev/null 2>&1); then
    printf 'INIT FAILED: %s\n' "$label"
    status=1
    continue
  fi
  if ! (cd "$dir" && terraform validate -no-color); then
    status=1
  fi
done

printf '\n'
if [ "$status" -eq 0 ]; then
  printf 'fmt + validate: clean\n'
else
  printf 'fmt + validate: FAILED\n'
fi
exit "$status"
