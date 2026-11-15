#!/usr/bin/env bash
# Decide which binding test suites a CI run needs, and write one
# `<binding>=true|false` line per binding to $GITHUB_OUTPUT (or stdout).
#
# Only a pull_request run is narrowed. Every other event — a push to main, a
# release's workflow_call, a manual dispatch — runs every suite, so a rule
# below that misses a dependency shows up red on main instead of staying hidden.
#
# On a pull request, a changed file selects suites as follows:
#
#   * Inside a binding's test fixtures (pkg/*/test/fixtures, pkg/*/tests/fixtures,
#     pkg/*/testdata): EVERY suite. Fixtures are what the bindings read across
#     package lines — EarthSciAST.jl and earthsci-ast-py load
#     earthsci-ast-rs/tests/fixtures/pushdown/, earthsci-ast-rs include_str!s
#     EarthSciAST.jl/test/fixtures/ — so any fixture edit is treated as shared.
#   * Anywhere else inside one binding's directory: that binding's suite.
#   * Anything else (tests/, scripts/, workflows, the spec and schema, the
#     narrative and typst packages, ...): EVERY suite.
#
# Usage: ci-changed-bindings.sh            (reads GITHUB_EVENT_NAME, PR_NUMBER,
#                                            GITHUB_REPOSITORY; lists files via gh)
#        ci-changed-bindings.sh --files F  (pull-request mode over the paths in F,
#                                            one per line; for local checks)
set -euo pipefail

BINDINGS=(julia typescript python rust go)
declare -A DIR=(
  [julia]=pkg/EarthSciAST.jl
  [typescript]=pkg/earthsci-ast-ts
  [python]=pkg/earthsci-ast-py
  [rust]=pkg/earthsci-ast-rs
  [go]=pkg/earthsci-ast-go
)
declare -A RUN=()

emit() {
  local out=${GITHUB_OUTPUT:-/dev/stdout} b
  for b in "${BINDINGS[@]}"; do
    echo "$b=${RUN[$b]:-false}" >>"$out"
  done
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Binding suites selected"
      for b in "${BINDINGS[@]}"; do echo "- $b: ${RUN[$b]:-false}"; done
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

run_all() {
  local b
  echo "$1 — running every binding suite."
  for b in "${BINDINGS[@]}"; do RUN[$b]=true; done
  emit
  exit 0
}

files=""
if [ "${1:-}" = "--files" ]; then
  files=$(cat "$2")
else
  [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || run_all "Event '${GITHUB_EVENT_NAME:-unknown}' is not a pull request"
  [ -n "${PR_NUMBER:-}" ] || run_all "No pull request number"
  # The pull-request files API stops at 3000 files; past that the list is
  # incomplete, so it cannot be used to skip anything.
  files=$(gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files" --jq '.[].filename') \
    || run_all "Could not list the pull request's files"
  [ "$(printf '%s\n' "$files" | grep -c .)" -lt 3000 ] || run_all "3000 or more changed files"
fi
[ -n "$files" ] || run_all "No changed files listed"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    pkg/*/test/fixtures/* | pkg/*/tests/fixtures/* | pkg/*/testdata/*)
      run_all "Shared test fixture changed: $f" ;;
  esac
  owner=""
  for b in "${BINDINGS[@]}"; do
    case "$f" in "${DIR[$b]}"/*) owner=$b ;; esac
  done
  [ -n "$owner" ] || run_all "Change outside any one binding: $f"
  RUN[$owner]=true
done <<<"$files"

emit
