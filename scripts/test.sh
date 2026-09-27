#!/usr/bin/env bash
# Run every Terraform test suite in this repo.
#
# No cloud credentials are required and nothing is ever applied to a real
# account: every suite runs against a mock provider, so the assertions execute
# locally in seconds. CI runs exactly this script.
#
# Usage:
#   ./scripts/test.sh              # all suites
#   ./scripts/test.sh modules      # module suites only
#   ./scripts/test.sh stacks       # stack integration suites only

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOPE="${1:-all}"

command -v terraform >/dev/null 2>&1 || {
  echo "terraform not found on PATH" >&2
  exit 127
}

pass=0
fail=0
failed_suites=()

run_suite() {
  local dir="$1"
  local label="${dir#"$ROOT"/}"
  printf '\n=== %s\n' "$label"

  # init is quiet: the provider is already in the plugin cache in CI, and the
  # first run's download noise buries the test output.
  if ! (cd "$dir" && terraform init -backend=false -input=false -no-color >/dev/null 2>&1); then
    printf 'INIT FAILED: %s\n' "$label"
    fail=$((fail + 1))
    failed_suites+=("$label (init)")
    return
  fi

  if (cd "$dir" && terraform test -no-color); then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_suites+=("$label")
  fi
}

# Every module that ships a test file.
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "modules" ]; then
  for t in "$ROOT"/modules/*/*.tftest.hcl; do
    [ -e "$t" ] || continue
    run_suite "$(dirname "$t")"
  done
fi

# Stack-level integration suites.
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "stacks" ]; then
  for t in "$ROOT"/stacks/*/*.tftest.hcl; do
    [ -e "$t" ] || continue
    run_suite "$(dirname "$t")"
  done
fi

printf '\n========================================\n'
printf 'suites passed: %d\n' "$pass"
printf 'suites failed: %d\n' "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'failed:\n'
  for s in "${failed_suites[@]}"; do printf '  - %s\n' "$s"; done
  exit 1
fi
printf 'all suites green\n'
