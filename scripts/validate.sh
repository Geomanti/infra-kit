#!/usr/bin/env bash
# Static checks: formatting and per-module validation.
#
# `terraform validate` runs per directory because it only inspects the
# configuration in its own working directory — a single root-level call would
# miss every module. CI runs exactly this script.
#
# Two details that matter on CI:
#   * A shared plugin cache. Without it, eleven directories each download the AWS
#     and Google providers at the same time, which gets throttled by the registry
#     and fails init on the largest providers. With it, each provider version is
#     fetched once and reused.
#   * Init output is NOT suppressed. A silent init failure is undiagnosable.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v terraform >/dev/null 2>&1 || {
  echo "terraform not found on PATH" >&2
  exit 127
}

export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$ROOT/.terraform-plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

status=0

printf '=== terraform fmt (check)\n'
if ! terraform -chdir="$ROOT" fmt -check -recursive -no-color; then
  printf 'unformatted files listed above; run: terraform fmt -recursive\n'
  status=1
fi

init_dir() {
  local dir="$1"
  local label="${dir#"$ROOT"/}"
  # Retry: provider resolution is a network call and CI runners do occasionally
  # hit a transient registry error.
  local attempt
  for attempt in 1 2 3; do
    if (cd "$dir" && terraform init -backend=false -input=false -no-color >/tmp/tf-init.log 2>&1); then
      return 0
    fi
    printf '  init attempt %d failed for %s\n' "$attempt" "$label"
    sleep 5
  done
  printf 'INIT FAILED: %s\n' "$label"
  sed -n '1,40p' /tmp/tf-init.log
  return 1
}

for dir in "$ROOT"/modules/*/ "$ROOT"/stacks/*/; do
  [ -d "$dir" ] || continue
  label="${dir#"$ROOT"/}"
  printf '\n=== validate %s\n' "$label"
  if ! init_dir "$dir"; then
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
