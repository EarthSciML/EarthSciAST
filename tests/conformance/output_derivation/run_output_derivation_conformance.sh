#!/usr/bin/env bash
#
# Cross-language OUTPUT-DERIVATION conformance driver
# (streaming-output-sinks RFC §7–§9, §16.12).
#
# Runs both bindings' runners over `tests/conformance/output_derivation/`. Each
# derives an output plan from the same .esm fixtures + flat slot names and
# asserts the same committed golden, so golden agreement IS cross-binding
# agreement (`CONFORMANCE_SPEC.md` §5.7.7's rule) — there is no separate
# comparator to keep in step with the goldens.
#
# This is the UPSTREAM half of the output chain. Its output type is the input
# type of EarthSciIO's write conformance (`conformance/run_write_conformance.sh`),
# which starts from an already-derived schema:
#
#   .esm ──[derivation, here]──▶ OutputSchema ──[writers, EarthSciIO]──▶ Zarr
#
# Usage:
#   tests/conformance/output_derivation/run_output_derivation_conformance.sh
#
# Toolchain overrides:
#   JULIA  julia launcher (default: julia)
#   CARGO  cargo launcher (default: cargo)
#
# A binding whose toolchain is unavailable is SKIPPED with a logged reason, never
# silently dropped, and the run then fails unless at least one binding ran.
#
# Exit status: 0 = every available binding reproduced the goldens.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$REPO_ROOT"

JULIA="${JULIA:-julia}"
CARGO="${CARGO:-cargo}"

ran=0
failed=0

echo "=== Cross-language OUTPUT-DERIVATION conformance (RFC §7–§9, §16.12) ==="
echo "corpus: tests/conformance/output_derivation"
echo

if command -v "$JULIA" >/dev/null 2>&1; then
  echo "--- julia ---"
  if "$JULIA" --project=pkg/EarthSciAST.jl -e '
      using Test
      include(joinpath("pkg", "EarthSciAST.jl", "test",
                       "output_derivation_conformance_test.jl"))'; then
    ran=$((ran + 1))
  else
    echo "FAIL: julia runner"
    failed=$((failed + 1))
  fi
  echo
else
  echo "SKIP julia: '$JULIA' not on PATH"
  echo
fi

if command -v "$CARGO" >/dev/null 2>&1; then
  echo "--- rust ---"
  if (cd pkg/earthsci-ast-rs && "$CARGO" test --test output_derivation_conformance); then
    ran=$((ran + 1))
  else
    echo "FAIL: rust runner"
    failed=$((failed + 1))
  fi
  echo
else
  echo "SKIP rust: '$CARGO' not on PATH"
  echo
fi

echo "=== summary ==="
if [ "$ran" -eq 0 ]; then
  echo "RESULT: FAIL — no binding could run (need julia and/or cargo)"
  exit 1
fi
if [ "$failed" -gt 0 ]; then
  echo "RESULT: FAIL ($failed of $((ran + failed)) binding(s) diverged from the goldens)"
  exit 1
fi
echo "RESULT: PASS — $ran binding(s) reproduced every golden plan"
