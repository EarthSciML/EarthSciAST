#!/usr/bin/env bash
# native-coverage-census.sh — run the native coverage census and check it
# against the committed ledgers (tests/conformance/native_coverage/).
#
# For each binding the census builds every corpus document through
# `esm_problem` under `native` and under `interpreter`:
#
#   julia  pkg/EarthSciAST.jl/scripts/compiler_census.jl, one sweep per
#          compiler, sharded over --jobs worker processes per sweep;
#   rust   pkg/earthsci-ast-rs/examples/compiler_census.rs (release build), one
#          process per document and compiler, --jobs documents at a time, each
#          under a wall-clock timeout and an address-space cap, so one
#          pathological document costs one record rather than the run.
#
# The corpus is every .esm under tests/ plus every .esm in the EarthSciModels
# checkout. Then scripts/native-coverage.py checks each census against its
# ledger; the exit status is non-zero when either binding's check is red.
#
# Usage:
#   scripts/native-coverage-census.sh --earthscimodels ../EarthSciModels --out <dir> \
#       [--bindings julia,rust] [--jobs 4] [--timeout 300] [--check-only]
#       [--write-ledger | --baseline]
#
#   --check-only    skip the sweeps and re-check the census already in <dir>
#   --write-ledger  rewrite the ledgers from the census instead of checking; a
#                   rewrite may drop entries and never add one
#   --baseline      --write-ledger for a first measurement, which may add entries
#                   (see tests/conformance/native_coverage/README.md)
#
# Re-running into the same --out directory reuses the Rust per-document records
# already there (a resume); start from an empty directory for a fresh census.
#
# Environment:
#   JULIA_CENSUS_ENV  the Julia environment the census runs in (default:
#                     pkg/EarthSciAST.jl/scripts/compiler_agreement_env, which
#                     must already be instantiated against this checkout)
#   CARGO_TARGET_DIR  where the Rust example is built (default: the crate's target/)
#   RUST_DOC_MEM_KB   the per-document address-space cap (default 16 GiB)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS=""
OUT=""
BINDINGS="julia,rust"
JOBS=4
TIMEOUT=300
CHECK_ONLY=false
WRITE_LEDGER=false
BASELINE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --earthscimodels) MODELS="$(cd "$2" && pwd)"; shift 2 ;;
    --out)            mkdir -p "$2"; OUT="$(cd "$2" && pwd)"; shift 2 ;;
    --bindings)       BINDINGS="$2"; shift 2 ;;
    --jobs)           JOBS="$2"; shift 2 ;;
    --timeout)        TIMEOUT="$2"; shift 2 ;;
    --check-only)     CHECK_ONLY=true; shift ;;
    --write-ledger)   WRITE_LEDGER=true; shift ;;
    --baseline)       WRITE_LEDGER=true; BASELINE=true; shift ;;
    -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "native-coverage-census.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [[ -z "$MODELS" || -z "$OUT" ]]; then
  echo "native-coverage-census.sh: --earthscimodels and --out are required" >&2
  exit 2
fi

TOOL="$REPO_ROOT/scripts/native-coverage.py"
CORPUS="$OUT/corpus.txt"
if [[ "$CHECK_ONLY" != true ]]; then
  python3 "$TOOL" corpus --earthscimodels "$MODELS" --out "$CORPUS"
  # What the census ran on, for the ledger's `measured` block.
  python3 - "$REPO_ROOT" "$MODELS" > "$OUT/provenance.json" <<'PY'
import json, subprocess, sys
from datetime import datetime, timezone
def git(d, *a):
    try:
        return subprocess.run(["git", "-C", d, *a], check=True, capture_output=True,
                              text=True).stdout.strip()
    except Exception:
        return None
repo, models = sys.argv[1], sys.argv[2]
print(json.dumps({
    "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
    "earthsciast_commit": git(repo, "rev-parse", "HEAD"),
    "earthsciast_dirty": bool(git(repo, "status", "--porcelain", "--untracked-files=no")),
    "earthscimodels_commit": git(models, "rev-parse", "HEAD"),
}))
PY
fi

# One Rust document. Each compiler runs in its own process, under its own
# timeout and address-space cap, so a half that dies is known to be that
# compiler's. A half that printed nothing (a timeout, the memory cap, an abort)
# is recorded as `<compiler>_killed`, with `<compiler>_timed_out` saying whether
# the wall clock is what stopped it: only a timeout depends on the machine's
# load. The two halves are merged into one record per document.
rust_one() {
  local bin="$1" outdir="$2" doc="$3" timeout_s="$4" mem_kb="$5"
  local key f tag rc t0
  key=$(printf '%s' "$doc" | md5sum | cut -c1-32)
  f="$outdir/$key.json"
  # A record from before the halves ran apart names no compiler in its kill:
  # run the document again rather than reuse it.
  [[ -s "$f" ]] && ! grep -qF '"killed": true' "$f" && return 0
  local halves=()
  for tag in native interpreter; do
    rc=0
    t0=$(date +%s)
    ( ulimit -v "$mem_kb" 2>/dev/null; timeout -k 5 "$timeout_s" "$bin" --only "$tag" "$doc" ) \
        > "$f.$tag" 2> "$f.$tag.err" || rc=$?
    halves+=("$tag" "$rc" "$(( $(date +%s) - t0 ))")
  done
  python3 - "$doc" "$f" "$timeout_s" "${halves[@]}" > "$f.part" <<'PY'
import json, sys
doc, f, timeout_s = sys.argv[1], sys.argv[2], int(sys.argv[3])
rec = {"path": doc}
h = sys.argv[4:]
for tag, rc, secs in zip(h[0::3], h[1::3], h[2::3]):
    rc, secs = int(rc), int(secs)
    line = open(f"{f}.{tag}", errors="replace").read().strip()
    if line:
        rec.update({k: v for k, v in json.loads(line).items() if k != "path"})
        continue
    # `timeout` answers 124 when its TERM stopped the process and 137 when its
    # KILL did; a 137 before the deadline is some other kill.
    rec[f"{tag}_killed"] = True
    rec[f"{tag}_rc"] = rc
    rec[f"{tag}_timed_out"] = rc == 124 or (rc == 137 and secs >= timeout_s)
    rec[f"{tag}_stderr_tail"] = open(f"{f}.{tag}.err", errors="replace").read()[-800:]
print(json.dumps(rec))
PY
  mv "$f.part" "$f"
  rm -f "$f.native" "$f.interpreter" "$f.native.err" "$f.interpreter.err"
}
export -f rust_one

census_julia() {
  local env="${JULIA_CENSUS_ENV:-$REPO_ROOT/pkg/EarthSciAST.jl/scripts/compiler_agreement_env}"
  local script="$REPO_ROOT/pkg/EarthSciAST.jl/scripts/compiler_census.jl"
  local pids=() c
  for c in native interpreter; do
    julia --project="$env" "$script" --manifest "$CORPUS" --out "$OUT/julia_$c.jsonl" \
      --compiler "$c" --jobs "$JOBS" --timeout "$TIMEOUT" --project "$env" \
      > "$OUT/julia_$c.log" 2>&1 &
    pids+=($!)
  done
  local status=0 p
  for p in "${pids[@]}"; do wait "$p" || status=1; done
  return $status
}

census_rust() {
  local target="${CARGO_TARGET_DIR:-$REPO_ROOT/pkg/earthsci-ast-rs/target}"
  (cd "$REPO_ROOT/pkg/earthsci-ast-rs" && cargo build --release --example compiler_census)
  local bin="$target/release/examples/compiler_census"
  mkdir -p "$OUT/rust_docs"
  xargs -a "$CORPUS" -P "$JOBS" -I{} bash -c 'rust_one "$@"' _ \
    "$bin" "$OUT/rust_docs" {} "$TIMEOUT" "${RUST_DOC_MEM_KB:-16777216}"
  cat "$OUT"/rust_docs/*.json > "$OUT/rust.jsonl"
}

check() {
  local binding="$1" mode=check
  [[ "$WRITE_LEDGER" == true ]] && mode=write-ledger
  local extra=()
  [[ "$BASELINE" == true ]] && extra+=(--baseline)
  local args=(--binding "$binding" --corpus "$CORPUS" --earthscimodels "$MODELS")
  if [[ "$binding" == julia ]]; then
    args+=(--census "$OUT/julia_native.jsonl" --census-interpreter "$OUT/julia_interpreter.jsonl")
  else
    args+=(--census "$OUT/rust.jsonl")
  fi
  if [[ "$mode" == check ]]; then
    args+=(--report "$OUT/${binding}_report.json")
  elif [[ -f "$OUT/provenance.json" ]]; then
    args+=(--provenance "$OUT/provenance.json")
  fi
  python3 "$TOOL" "$mode" "${args[@]}" "${extra[@]}"
}

status=0
IFS=',' read -r -a WANT <<< "$BINDINGS"
for b in "${WANT[@]}"; do
  case "$b" in
    julia|rust) ;;
    *) echo "native-coverage-census.sh: unknown binding '$b'" >&2; exit 2 ;;
  esac
  if [[ "$CHECK_ONLY" != true ]]; then
    echo "[$(date)] census ($b)"
    "census_$b" || { echo "census ($b) failed"; status=1; continue; }
  fi
  echo "[$(date)] check ($b)"
  check "$b" || status=1
done
exit $status
