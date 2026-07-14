#!/bin/bash

# Cross-language conformance testing script for ESM Format implementations
# Tests Julia, TypeScript, Python, and Rust implementations against the same test fixtures
# Generates comparable outputs and detects divergence across languages

set -e  # Exit on any error

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$PROJECT_ROOT/tests"
OUTPUT_DIR="$PROJECT_ROOT/conformance-results"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Language implementation directories
JULIA_DIR="$PROJECT_ROOT/pkg/EarthSciAST.jl"
TYPESCRIPT_DIR="$PROJECT_ROOT/pkg/earthsci-ast-ts"
PYTHON_DIR="$PROJECT_ROOT/pkg/earthsci-ast-py"
RUST_DIR="$PROJECT_ROOT/pkg/earthsci-ast-rs"
GO_DIR="$PROJECT_ROOT/pkg/earthsci-ast-go"

# Prefer the Python binding's virtualenv if it exists, so every `python3` call in
# this script (the pytest suite, the conformance runners, and the per-binding
# producers) resolves to an interpreter that has the toolkit and its deps
# (pytest, jsonschema, scipy, numpy) installed. A bare system `python3` (e.g.
# Homebrew) typically lacks these. Falls back to whatever `python3` is on PATH
# when the venv is absent (e.g. a CI image where the deps are provisioned
# globally). Create it with:  cd pkg/earthsci-ast-py && python3 -m venv
# .venv && .venv/bin/pip install -e '.[test]'
PYVENV_BIN="$PYTHON_DIR/.venv/bin"
if [ -x "$PYVENV_BIN/python3" ]; then
    export PATH="$PYVENV_BIN:$PATH"
fi

# Test categories
VALID_TESTS_DIR="$TESTS_DIR/valid"
INVALID_TESTS_DIR="$TESTS_DIR/invalid"
DISPLAY_TESTS_DIR="$TESTS_DIR/display"
SUBSTITUTION_TESTS_DIR="$TESTS_DIR/substitution"
GRAPHS_TESTS_DIR="$TESTS_DIR/graphs"

# Output directories for each language
JULIA_OUTPUT="$OUTPUT_DIR/julia"
TYPESCRIPT_OUTPUT="$OUTPUT_DIR/typescript"
PYTHON_OUTPUT="$OUTPUT_DIR/python"
RUST_OUTPUT="$OUTPUT_DIR/rust"
GO_OUTPUT="$OUTPUT_DIR/go"

# The shared CORPUS MANIFEST: the ONE recursive sweep of tests/valid, tests/invalid
# and lib, plus the expanded display / substitution case lists. Every producer is
# handed this file and emits a record per entry; the comparator then asserts that
# each binding covered every entry. Producers no longer enumerate the corpus
# themselves — four hand-rolled non-recursive walks are what let 69 fixtures go
# unswept in every binding at once (audit F5).
CORPUS_MANIFEST="$OUTPUT_DIR/corpus_manifest.json"

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Clean and setup output directories
setup_output_dirs() {
    log "Setting up output directories..."
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$JULIA_OUTPUT" "$TYPESCRIPT_OUTPUT" "$PYTHON_OUTPUT" "$RUST_OUTPUT" "$GO_OUTPUT"
    mkdir -p "$OUTPUT_DIR/comparison" "$OUTPUT_DIR/reports"
}

# Build the shared corpus manifest. Every producer reads it; if it cannot be
# built there is nothing to test, so this is fatal.
build_corpus_manifest() {
    log "Building the shared corpus manifest..."
    if python3 "$SCRIPT_DIR/conformance_corpus.py" --output "$CORPUS_MANIFEST"; then
        export ESM_CONFORMANCE_MANIFEST="$CORPUS_MANIFEST"
        return 0
    fi
    error "Could not build the corpus manifest"
    return 1
}

# Every binding in this repo is REQUIRED. A missing toolchain is a broken
# environment, not a smaller test run.
#
# This used to `return 1` with a warning, and every caller treated that as
# "skip" — so a box without Julia produced a fully GREEN run with ZERO Julia
# coverage, and a `bindings_required` gate silently became a no-op (audit F10).
# There is no way to express "I could not check this" in an exit code, so the
# only honest answer is failure.
check_language_availability() {
    local language=$1
    local dir=$2
    local tool
    local marker

    case $language in
        "julia")      tool="julia";   marker="Project.toml" ;;
        "typescript") tool="npm";     marker="package.json" ;;
        "python")     tool="python3"; marker="pyproject.toml" ;;
        "rust")       tool="cargo";   marker="Cargo.toml" ;;
        "go")         tool="go";      marker="go.mod" ;;
        *)
            error "Unknown language: $language"
            return 1
            ;;
    esac

    if [ ! -d "$dir" ] || [ ! -f "$dir/$marker" ]; then
        error "$language implementation not found at $dir (no $marker)"
        return 1
    fi
    if ! command -v "$tool" &> /dev/null; then
        error "$tool not found on PATH — $language is a REQUIRED binding, not an optional one"
        return 1
    fi
    return 0
}

# Run the Go test suite and generate Go conformance outputs.
#
# Go had NO conformance producer at all (audit F9): this ran `go test ./...` and
# stopped, and `compare_outputs` hardcoded `--languages julia typescript python
# rust`, so the most conformant binding in the repo contributed nothing to the
# cross-language comparison.
run_go_tests() {
    log "Running Go conformance tests..."

    if ! check_language_availability "go" "$GO_DIR"; then
        return 1
    fi

    cd "$GO_DIR"

    log "Running Go test suite..."
    if go test ./...; then
        success "Go tests passed"
    else
        error "Go tests failed"
        return 1
    fi

    log "Generating Go conformance outputs..."
    go run ./cmd/esm-conformance "$GO_OUTPUT" "$CORPUS_MANIFEST"

    return $?
}

# Run Julia tests and generate conformance outputs
run_julia_tests() {
    log "Running Julia conformance tests..."

    if ! check_language_availability "julia" "$JULIA_DIR"; then
        return 1
    fi

    cd "$JULIA_DIR"

    # First run the basic tests to ensure everything works
    log "Running Julia test suite..."
    if julia --project=. -e 'using Pkg; Pkg.test()'; then
        success "Julia tests passed"
    else
        error "Julia tests failed"
        return 1
    fi

    # Generate conformance test outputs
    log "Generating Julia conformance outputs..."
    julia --project=. "$SCRIPT_DIR/run-julia-conformance.jl" "$JULIA_OUTPUT" "$CORPUS_MANIFEST"

    return $?
}

# Run TypeScript tests and generate conformance outputs
run_typescript_tests() {
    log "Running TypeScript conformance tests..."

    if ! check_language_availability "typescript" "$TYPESCRIPT_DIR"; then
        return 1
    fi

    cd "$TYPESCRIPT_DIR"

    # Install dependencies if needed
    if [ ! -d "node_modules" ]; then
        log "Installing TypeScript dependencies..."
        npm install
    fi

    # Run the test suite
    log "Running TypeScript test suite..."
    if npm test -- --run; then
        success "TypeScript tests passed"
    else
        error "TypeScript tests failed"
        return 1
    fi

    # Build the TypeScript package so the conformance runner can import dist/esm/index.js
    log "Building TypeScript package for conformance runner..."
    npm run build

    # Generate conformance outputs
    log "Generating TypeScript conformance outputs..."
    node "$SCRIPT_DIR/run-typescript-conformance.js" "$TYPESCRIPT_OUTPUT" "$CORPUS_MANIFEST"

    return $?
}

# Run Python tests and generate conformance outputs
run_python_tests() {
    log "Running Python conformance tests..."

    if ! check_language_availability "python" "$PYTHON_DIR"; then
        return 1
    fi

    cd "$PYTHON_DIR"

    # Run pytest to verify implementation
    log "Running Python test suite..."
    if python3 -m pytest tests/ -v; then
        success "Python tests passed"
    else
        error "Python tests failed"
        return 1
    fi

    # Generate conformance outputs
    log "Generating Python conformance outputs..."
    python3 "$SCRIPT_DIR/run-python-conformance.py" "$PYTHON_OUTPUT" "$CORPUS_MANIFEST"

    return $?
}

# Run Rust tests and generate conformance outputs
run_rust_tests() {
    log "Running Rust conformance tests..."

    if ! check_language_availability "rust" "$RUST_DIR"; then
        return 1
    fi

    cd "$RUST_DIR"

    # Run cargo test
    log "Running Rust test suite..."
    if cargo test; then
        success "Rust tests passed"
    else
        error "Rust tests failed"
        return 1
    fi

    # Generate conformance outputs
    log "Generating Rust conformance outputs..."
    cargo run --bin esm -- conformance-test "$RUST_OUTPUT" "$CORPUS_MANIFEST"

    return $?
}

# Compare outputs between languages and detect divergence.
#
# ALL FIVE bindings are compared (Go was missing entirely — audit F9), and the
# comparator now asserts each fixture against its DECLARED outcome and its pinned
# error codes/paths, not merely against the other bindings. Any divergence exits
# non-zero: there is no longer a threshold band that passes at 70% (audit C2).
compare_outputs() {
    log "Comparing cross-language outputs..."

    python3 "$SCRIPT_DIR/compare-conformance-outputs.py" \
        --output-dir "$OUTPUT_DIR" \
        --languages julia typescript python rust go \
        --manifest "$CORPUS_MANIFEST" \
        --comparison-output "$OUTPUT_DIR/comparison/analysis.json"

    return $?
}

# Generate HTML conformance report.
#
# The `return $?` is load-bearing: without it this function fell off the end with
# the exit status of the `success` echo, so a CRASHING report generator still
# printed "Conformance report generated successfully" (audit F8).
generate_report() {
    log "Generating conformance report..."

    if python3 "$SCRIPT_DIR/generate-conformance-report.py" \
        --analysis-file "$OUTPUT_DIR/comparison/analysis.json" \
        --output-file "$OUTPUT_DIR/reports/conformance_report_${TIMESTAMP}.html"; then
        success "Conformance report generated: $OUTPUT_DIR/reports/conformance_report_${TIMESTAMP}.html"
        return 0
    fi
    error "Report generation FAILED"
    return 1
}

# Run the property-corpus cross-binding round-trip check (gt-3fbf). Each
# binding reads the shared hypothesis-generated corpus, parses and
# re-serializes each expression, and the runner diffs the outputs. Writes
# a per-fixture divergence report alongside the per-language conformance
# outputs so reviewers can see which expression shapes cause divergence.
# Sanity-check the cross-binding determinism harness (ess-my4.5). Until the M2
# join impls and M3 relational engine land per-binding producers, the harness
# asserts the §5.5 determinism contract against an embedded reference
# implementation and the static golden example
# (tests/conformance/determinism/manifest.json): byte-identity to the golden,
# adversarial-variant collapse, rank base-pin round-trip, and negative controls.
# When producers exist, the same golden is asserted byte-for-byte across bindings.
run_determinism_conformance_self_test() {
    log "Running determinism-conformance harness self-test..."
    if python3 "$SCRIPT_DIR/run-determinism-conformance.py" --self-test; then
        success "Determinism-conformance harness self-test passed"
        return 0
    else
        error "Determinism-conformance harness self-test failed"
        return 1
    fi
}

# Drive the REAL value-invention primitives (skolem / distinct / rank + group-by,
# ess-my4.3.3/.4/.5) through the determinism harness: each binding's adapter runs
# the relational engine over the golden fixtures and EVERY adversarial variant
# (permuted / duplicated / reversed), and the runner asserts the serialized index
# sets + base-normalized dense IDs are byte-identical to the golden — proving
# cross-binding byte-identity AND per-binding order-independence (§5.5.4, bead
# ess-my4.3.11). The three bindings are `bindings_required`, so a MISMATCH or a
# missing producer (when the language is available) fails.
run_determinism_conformance_julia() {
    if ! check_language_availability "julia" "$JULIA_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running determinism conformance with the Julia relational engine..."
    EARTHSCI_DETERMINISM_ADAPTER_JULIA="julia --project=$JULIA_DIR $JULIA_DIR/scripts/determinism_adapter.jl" \
        python3 "$SCRIPT_DIR/run-determinism-conformance.py" \
            --bindings julia \
            --output "$OUTPUT_DIR/determinism/julia_report.json"
}

run_determinism_conformance_rust() {
    if ! check_language_availability "rust" "$RUST_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running determinism conformance with the Rust relational engine..."
    EARTHSCI_DETERMINISM_ADAPTER_RUST="cargo run --quiet --manifest-path $RUST_DIR/Cargo.toml --bin earthsci-determinism-adapter-rust --" \
        python3 "$SCRIPT_DIR/run-determinism-conformance.py" \
            --bindings rust \
            --output "$OUTPUT_DIR/determinism/rust_report.json"
}

run_determinism_conformance_python() {
    if ! check_language_availability "python" "$PYTHON_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running determinism conformance with the Python relational engine..."
    # PYTHONPATH pins the adapter to THIS worktree's src (mirrors the cadence /
    # PDE-sim Python producers). Without it, `python3 -m earthsci_ast...`
    # can't import the package (the venv carries only deps, not an editable
    # install), so the adapter emits no output and the producer fails.
    EARTHSCI_DETERMINISM_ADAPTER_PYTHON="python3 -m earthsci_ast.cli.determinism_adapter" \
    PYTHONPATH="$PYTHON_DIR/src:${PYTHONPATH:-}" \
        python3 "$SCRIPT_DIR/run-determinism-conformance.py" \
            --bindings python \
            --output "$OUTPUT_DIR/determinism/python_report.json"
}

# Sanity-check the cross-binding conservative-regridding geometry harness
# (ess-my4.4.8) — the tolerance-mode analogue of the determinism gate. The
# --self-test asserts the §5.8 geometry contract against an embedded reference
# (bin-Skolem broad phase + planar Sutherland–Hodgman clip + shoelace area) and
# the static golden (tests/conformance/geometry/manifest.json): the candidate
# overlap-pair set is byte-identical, every permuted variant collapses to it,
# planar areas + invariants reproduce the golden, and the harness rejects
# non-conforming output (reorder/missing-pair/float-in-key/area-off/partition-of-
# unity negative controls). Runs green parallel to the producers.
run_geometry_conformance_self_test() {
    log "Running geometry-conformance harness self-test..."
    if python3 "$SCRIPT_DIR/run-geometry-conformance.py" --self-test; then
        success "Geometry-conformance harness self-test passed"
        return 0
    else
        error "Geometry-conformance harness self-test failed"
        return 1
    fi
}

# The per-binding geometry PRODUCER + cross-binding drain (ess-my4.4.8) have been
# RETIRED (bead ess-3lj.3): the imperative conservative-regridding assemblies and
# their §5.8.6 adapters (geometry_adapter.jl / cli.geometry_adapter) were deleted
# in favor of a single end-to-end-evaluable document
# (tests/valid/geometry/conservative_regrid_overlap_join.esm) driven through the
# evaluator (Julia: test/geometry_overlap_join_conformance_test.jl; the broad
# phase + polygon_area FAQ are exercised per-binding in Julia/Python/Rust). The
# harness self-test above still guards the §5.8 contract against the embedded
# reference + static golden.

# Sanity-check the cross-binding cadence-partition harness (ess-my4.3.6). Until
# the per-binding partition-pass implementations land (ess-my4.3.7 Julia +
# Rust/Python siblings), the harness asserts the §5.7 cadence contract against an
# embedded reference classifier + folder and the static golden
# (tests/conformance/cadence/manifest.json): class agreement (reference ==
# expect_cadence == golden) over the three §6.1 fixtures, the materialization-
# point set + hot-tree/handler emptiness, byte-identical CONST-folded buffers,
# and negative controls (wrong expect_cadence, continuous relational, from_faq
# cycle). When producers exist, the same golden is asserted across bindings.
run_cadence_conformance_self_test() {
    log "Running cadence-partition conformance harness self-test..."
    if python3 "$SCRIPT_DIR/run-cadence-conformance.py" --self-test; then
        success "Cadence-partition conformance harness self-test passed"
        return 0
    else
        error "Cadence-partition conformance harness self-test failed"
        return 1
    fi
}

# Drive the REAL Julia partition pass (ess-my4.3.7) through the cadence harness:
# the adapter (pkg/EarthSciAST.jl/scripts/cadence_adapter.jl) runs
# EarthSciAST.Cadence over the three §6.1 fixtures and the runner
# asserts its class map, materialization set, and CONST-folded buffers are
# byte-identical to the golden. Julia is `bindings_optional` in the manifest, so
# a missing adapter (no julia) is skipped, but a MISMATCH fails. Rust/Python
# siblings register the same way as they land.
run_cadence_conformance_julia() {
    if ! check_language_availability "julia" "$JULIA_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running cadence-partition conformance with the Julia partition pass..."
    EARTHSCI_CADENCE_ADAPTER_JULIA="julia --project=$JULIA_DIR $JULIA_DIR/scripts/cadence_adapter.jl" \
        python3 "$SCRIPT_DIR/run-cadence-conformance.py" \
            --bindings julia \
            --output "$OUTPUT_DIR/cadence/julia_report.json"
}

# Drive the REAL Rust partition pass (ess-my4.3.8) through the cadence harness:
# the adapter binary (pkg/earthsci-ast-rs/src/bin/earthsci-cadence-adapter-rust.rs)
# runs the Rust Cadence module over the §6.1 fixtures and the runner asserts its
# class map, materialization set, and CONST-folded buffers are byte-identical to
# the golden. Rust is `bindings_optional`, so a missing adapter is skipped but a
# MISMATCH fails. (Mirrors run_cadence_conformance_julia; ess-my4.3.10.)
run_cadence_conformance_rust() {
    if ! check_language_availability "rust" "$RUST_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running cadence-partition conformance with the Rust partition pass..."
    EARTHSCI_CADENCE_ADAPTER_RUST="cargo run --quiet --manifest-path $RUST_DIR/Cargo.toml --bin earthsci-cadence-adapter-rust --" \
        python3 "$SCRIPT_DIR/run-cadence-conformance.py" \
            --bindings rust \
            --output "$OUTPUT_DIR/cadence/rust_report.json"
}

# Drive the REAL Python partition pass (ess-my4.3.9) through the cadence harness:
# the adapter (pkg/earthsci-ast-py/src/earthsci_ast/cli/cadence_adapter.py)
# runs the Python Cadence module over the §6.1 fixtures and the runner asserts the
# same golden. Python is `bindings_optional` — missing adapter skipped, mismatch
# fails. (Mirrors run_cadence_conformance_julia; ess-my4.3.10.)
run_cadence_conformance_python() {
    if ! check_language_availability "python" "$PYTHON_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running cadence-partition conformance with the Python partition pass..."
    # PYTHONPATH pins the adapter to THIS worktree's src (mirrors the PDE-sim
    # adapter below). Without it, `python3 -m earthsci_ast...` imports
    # whatever earthsci_ast is globally installed — an editable install
    # points at a FIXED path (another worktree), so the adapter runs stale code
    # and emits no conforming output for any branch that changed cadence.py.
    EARTHSCI_CADENCE_ADAPTER_PYTHON="python3 -m earthsci_ast.cli.cadence_adapter" \
    PYTHONPATH="$PYTHON_DIR/src:${PYTHONPATH:-}" \
        python3 "$SCRIPT_DIR/run-cadence-conformance.py" \
            --bindings python \
            --output "$OUTPUT_DIR/cadence/python_report.json"
}

# === PDE-simulation conformance (ess-fmw) ===
# The simulation analogue of the byte-identity gates. Julia (reference), Python,
# and Rust evaluate the SAME pre-discretized method-of-lines fixtures
# (tests/conformance/pde_simulation/) and must agree, within numeric tolerance,
# on the discretized RHS f(u,t) (tight arithmetic check) AND the integrated
# trajectory (compared to the Julia golden cross-binding, and to the exact
# matrix-exponential / manufactured solution). Go and TS are out of scope — they
# implement only the rewrite half (no makearray lowering, no simulator). The
# self-test asserts the committed Julia golden reproduces the INDEPENDENT
# analytic anchors and that the harness rejects perturbed output; the producers
# re-run each binding and gate it against the golden + analytic, failing loudly
# on any divergence.
run_pde_simulation_conformance_self_test() {
    log "Running PDE-simulation conformance harness self-test..."
    if python3 "$SCRIPT_DIR/run-pde-simulation-conformance.py" --self-test; then
        success "PDE-simulation conformance harness self-test passed"
        return 0
    else
        error "PDE-simulation conformance harness self-test failed"
        return 1
    fi
}

# Julia is the reference binding. Its adapter (self-bootstrapping the dedicated
# scripts/pde_sim_adapter env with OrdinaryDiffEqTsit5 + JSON3) re-evaluates the
# fixtures via the tree-walk evaluator + Tsit5 and the runner asserts a match to
# the committed golden (golden it produced) AND the analytic anchors.
run_pde_simulation_conformance_julia() {
    if ! check_language_availability "julia" "$JULIA_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running PDE-simulation conformance with the Julia reference simulator..."
    EARTHSCI_PDE_SIM_ADAPTER_JULIA="julia $JULIA_DIR/scripts/pde_simulation_adapter.jl" \
        python3 "$SCRIPT_DIR/run-pde-simulation-conformance.py" \
            --bindings julia \
            --output "$OUTPUT_DIR/pde_simulation/julia_report.json"
}

# Rust drives the vectorized arrayop evaluator (ArrayCompiled::debug_eval_rhs) +
# diffsol. `cargo run` provisions the s2bindings shim lib path. ess-fmw.
run_pde_simulation_conformance_rust() {
    if ! check_language_availability "rust" "$RUST_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running PDE-simulation conformance with the Rust vectorized simulator..."
    EARTHSCI_PDE_SIM_ADAPTER_RUST="cargo run --quiet --manifest-path $RUST_DIR/Cargo.toml --bin earthsci-pde-sim-adapter-rust --" \
        python3 "$SCRIPT_DIR/run-pde-simulation-conformance.py" \
            --bindings rust \
            --output "$OUTPUT_DIR/pde_simulation/rust_report.json"
}

# Python drives evaluate_rhs (NumPy interpreter) + SciPy solve_ivp. PYTHONPATH is
# pinned to the repo's package src so the adapter (and the new evaluate_rhs hook)
# resolve from this checkout, not a stray editable install. ess-fmw.
run_pde_simulation_conformance_python() {
    if ! check_language_availability "python" "$PYTHON_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running PDE-simulation conformance with the Python simulator..."
    EARTHSCI_PDE_SIM_ADAPTER_PYTHON="python3 -m earthsci_ast.cli.pde_simulation_adapter" \
    PYTHONPATH="$PYTHON_DIR/src:${PYTHONPATH:-}" \
        python3 "$SCRIPT_DIR/run-pde-simulation-conformance.py" \
            --bindings python \
            --output "$OUTPUT_DIR/pde_simulation/python_report.json"
}

# === Full-pipeline PDE conformance (pde_simulation_pipeline; DESIGN.md) ===
# Sibling to the pre-discretized tier above, for fixtures that require the FULL
# lowering pipeline (reaction-gen -> template match -> operator_compose ->
# pointwise-lift -> scoped-`ic`) with loaded IC/BC/wind fields injected through
# each binding's data-Provider seam from the manifest `inputs`. The system is
# nonlinear (mass-action), so there is NO matrix-exponential trajectory anchor:
# each binding's trajectory is gated against BOTH the Julia golden and an
# INDEPENDENT reference integrator (tests/conformance/pde_simulation_pipeline/
# reference/), while the discretized RHS is gated tightly against that same
# reference. Julia/Python/Rust are all bindings_required; Go and TS are out of
# scope. The self-test asserts the Julia golden reproduces the independent
# reference (Gate-G0 equivalent) and that the harness rejects perturbed output.
PDE_PIPELINE_MANIFEST="$PROJECT_ROOT/tests/conformance/pde_simulation_pipeline/manifest.json"

run_pde_pipeline_conformance_self_test() {
    log "Running full-pipeline PDE conformance harness self-test..."
    if python3 "$SCRIPT_DIR/run-pde-simulation-conformance.py" \
            --manifest "$PDE_PIPELINE_MANIFEST" --self-test; then
        success "Full-pipeline PDE conformance harness self-test passed"
        return 0
    else
        error "Full-pipeline PDE conformance harness self-test failed"
        return 1
    fi
}

# Julia is the reference binding. Its adapter runs the fixture through the full
# provider-injected pipeline (Tsit5) and the runner asserts a match to the
# committed golden (golden it produced) AND the independent reference.
run_pde_pipeline_conformance_julia() {
    if ! check_language_availability "julia" "$JULIA_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running full-pipeline PDE conformance with the Julia reference simulator..."
    EARTHSCI_PDE_SIM_ADAPTER_JULIA="julia $JULIA_DIR/scripts/pde_simulation_adapter.jl" \
        python3 "$SCRIPT_DIR/run-pde-simulation-conformance.py" \
            --manifest "$PDE_PIPELINE_MANIFEST" \
            --bindings julia \
            --output "$OUTPUT_DIR/pde_simulation_pipeline/julia_report.json"
}

# Rust drives the vectorized arrayop evaluator (ArrayCompiled::from_flattened +
# debug_eval_rhs) + diffsol, with the provider forcing installed into the
# compiled instance. `cargo run` provisions the s2bindings shim lib path.
run_pde_pipeline_conformance_rust() {
    if ! check_language_availability "rust" "$RUST_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running full-pipeline PDE conformance with the Rust vectorized simulator..."
    EARTHSCI_PDE_SIM_ADAPTER_RUST="cargo run --quiet --manifest-path $RUST_DIR/Cargo.toml --bin earthsci-pde-sim-adapter-rust --" \
        python3 "$SCRIPT_DIR/run-pde-simulation-conformance.py" \
            --manifest "$PDE_PIPELINE_MANIFEST" \
            --bindings rust \
            --output "$OUTPUT_DIR/pde_simulation_pipeline/rust_report.json"
}

# Python drives the NumPy interpreter (_build_numpy_rhs) + SciPy solve_ivp with
# loaded fields injected through the `providers=` seam. PYTHONPATH is pinned to
# the repo's package src so the adapter resolves from this checkout.
run_pde_pipeline_conformance_python() {
    if ! check_language_availability "python" "$PYTHON_DIR"; then
        error "A REQUIRED binding\'s toolchain is missing — this gate cannot run, so it FAILS (it must never silently pass)"
        return 1
    fi
    log "Running full-pipeline PDE conformance with the Python simulator..."
    EARTHSCI_PDE_SIM_ADAPTER_PYTHON="python3 -m earthsci_ast.cli.pde_simulation_adapter" \
    PYTHONPATH="$PYTHON_DIR/src:${PYTHONPATH:-}" \
        python3 "$SCRIPT_DIR/run-pde-simulation-conformance.py" \
            --manifest "$PDE_PIPELINE_MANIFEST" \
            --bindings python \
            --output "$OUTPUT_DIR/pde_simulation_pipeline/python_report.json"
}

run_property_corpus() {
    log "Running property-corpus round-trip across bindings..."
    local corpus="$PROJECT_ROOT/tests/property_corpus/expressions"
    if [ ! -d "$corpus" ] || [ -z "$(ls "$corpus"/expr_*.json 2>/dev/null)" ]; then
        warning "Property corpus empty or missing at $corpus — regenerating"
        python3 "$SCRIPT_DIR/generate-property-corpus.py" --count 50 --out "$corpus"
    fi

    # THE gate: bindings that re-serialize the same expression differently do not
    # implement one format, so any divergence fails.
    #
    # This used to pass `--require-divergence`, which exits 1 **iff
    # diverged_count == 0** — so real divergence could never fail the harness and
    # fixing every divergence would have turned the build RED (audit F7). The
    # corpus-quality question that flag answers is real, but it belongs to the
    # corpus generator's own acceptance check, not to the conformance gate.
    python3 "$SCRIPT_DIR/run-property-corpus-conformance.py" \
        --corpus "$corpus" \
        --output "$OUTPUT_DIR/property_corpus_report.json" \
        --fail-on-divergence \
        --require-all-bindings
}

# Main execution
#
# EVERY gate runs, and EVERY failure is collected, so one run produces the whole
# failure list rather than the first one. The run then exits NON-ZERO if anything
# failed.
#
# What this replaces (audit C1): `failed_languages` was printed via `error()` and
# then never consulted. `main` proceeded whenever >= 2 languages succeeded and
# ended on an unconditional `success` echo — so the command CLAUDE.md tells
# developers to run printed "Cross-language conformance testing completed
# successfully!" and **exited 0 with Julia, Rust and Go all failing**. There is no
# ">= 2 succeeded" clause any more: all five bindings are required.
declare -a FAILED_STAGES=()

run_stage() {
    local name="$1"
    shift
    if "$@"; then
        success "$name"
    else
        error "$name FAILED"
        FAILED_STAGES+=("$name")
    fi
}

main() {
    log "Starting cross-language conformance testing..."
    log "Project root: $PROJECT_ROOT"

    setup_output_dirs

    # Nothing can be tested without the corpus manifest, so this one IS fatal.
    if ! build_corpus_manifest; then
        error "Corpus manifest could not be built — nothing to test"
        exit 1
    fi

    declare -a successful_languages=()
    declare -a failed_languages=()

    for lang in julia typescript python rust go; do
        if "run_${lang}_tests"; then
            successful_languages+=("$lang")
        else
            failed_languages+=("$lang")
            FAILED_STAGES+=("binding:$lang")
        fi
        cd "$PROJECT_ROOT"
    done

    log "Test execution summary:"
    if [ ${#successful_languages[@]} -gt 0 ]; then
        success "Successful languages: ${successful_languages[*]}"
    fi
    if [ ${#failed_languages[@]} -gt 0 ]; then
        error "Failed languages: ${failed_languages[*]}"
    fi

    # The cross-language gates run even when a binding failed: a binding whose
    # test suite is red may still have produced results.json, and the comparator
    # reports a MISSING results.json as a coverage failure. Either way the run
    # already exits non-zero — running the rest just makes the report complete.
    log "Running cross-language gates..."

    run_stage "cross-language comparison" compare_outputs
    run_stage "conformance report" generate_report
    run_stage "property-corpus round-trip" run_property_corpus

    run_stage "determinism self-test" run_determinism_conformance_self_test
    run_stage "determinism producer (julia)" run_determinism_conformance_julia
    run_stage "determinism producer (rust)" run_determinism_conformance_rust
    run_stage "determinism producer (python)" run_determinism_conformance_python

    run_stage "geometry self-test" run_geometry_conformance_self_test

    run_stage "cadence self-test" run_cadence_conformance_self_test
    run_stage "cadence producer (julia)" run_cadence_conformance_julia
    run_stage "cadence producer (rust)" run_cadence_conformance_rust
    run_stage "cadence producer (python)" run_cadence_conformance_python

    run_stage "PDE-simulation self-test" run_pde_simulation_conformance_self_test
    run_stage "PDE-simulation producer (julia)" run_pde_simulation_conformance_julia
    run_stage "PDE-simulation producer (rust)" run_pde_simulation_conformance_rust
    run_stage "PDE-simulation producer (python)" run_pde_simulation_conformance_python

    run_stage "full-pipeline PDE self-test" run_pde_pipeline_conformance_self_test
    run_stage "full-pipeline PDE producer (julia)" run_pde_pipeline_conformance_julia
    run_stage "full-pipeline PDE producer (rust)" run_pde_pipeline_conformance_rust
    run_stage "full-pipeline PDE producer (python)" run_pde_pipeline_conformance_python

    echo
    if [ ${#FAILED_STAGES[@]} -eq 0 ]; then
        success "Cross-language conformance testing PASSED"
        log "Results available in: $OUTPUT_DIR"
        exit 0
    fi

    error "Cross-language conformance testing FAILED — ${#FAILED_STAGES[@]} stage(s):"
    for stage in "${FAILED_STAGES[@]}"; do
        error "  · $stage"
    done
    log "Results available in: $OUTPUT_DIR"
    exit 1
}

# Check if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi