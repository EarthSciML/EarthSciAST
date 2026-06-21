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
JULIA_DIR="$PROJECT_ROOT/packages/EarthSciSerialization.jl"
TYPESCRIPT_DIR="$PROJECT_ROOT/packages/earthsci-toolkit"
PYTHON_DIR="$PROJECT_ROOT/packages/earthsci_toolkit"
RUST_DIR="$PROJECT_ROOT/packages/earthsci-toolkit-rs"
GO_DIR="$PROJECT_ROOT/packages/esm-format-go"

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
    mkdir -p "$JULIA_OUTPUT" "$TYPESCRIPT_OUTPUT" "$PYTHON_OUTPUT" "$RUST_OUTPUT"
    mkdir -p "$OUTPUT_DIR/comparison" "$OUTPUT_DIR/reports"
}

# Check if language implementation exists and can be tested
check_language_availability() {
    local language=$1
    local dir=$2

    case $language in
        "julia")
            if [ -d "$dir" ] && [ -f "$dir/Project.toml" ]; then
                if command -v julia &> /dev/null; then
                    return 0
                else
                    warning "Julia command not found, skipping Julia tests"
                    return 1
                fi
            fi
            ;;
        "typescript")
            if [ -d "$dir" ] && [ -f "$dir/package.json" ]; then
                if command -v npm &> /dev/null; then
                    return 0
                else
                    warning "npm command not found, skipping TypeScript tests"
                    return 1
                fi
            fi
            ;;
        "python")
            if [ -d "$dir" ] && [ -f "$dir/pyproject.toml" ]; then
                if command -v python3 &> /dev/null; then
                    return 0
                else
                    warning "python3 command not found, skipping Python tests"
                    return 1
                fi
            fi
            ;;
        "rust")
            if [ -d "$dir" ] && [ -f "$dir/Cargo.toml" ]; then
                if command -v cargo &> /dev/null; then
                    return 0
                else
                    warning "cargo command not found, skipping Rust tests"
                    return 1
                fi
            fi
            ;;
        "go")
            if [ -d "$dir" ] && [ -f "$dir/go.mod" ]; then
                if command -v go &> /dev/null; then
                    return 0
                else
                    warning "go command not found, skipping Go tests"
                    return 1
                fi
            fi
            ;;
    esac
    return 1
}

# Run Go tests. The Go binding has no separate conformance-output runner;
# this exercises the binding's `go test ./...` suite, which includes the
# function_tables lowering harness (esm-spec §9.5.6, esm-lhm).
run_go_tests() {
    log "Running Go conformance tests..."

    if ! check_language_availability "go" "$GO_DIR"; then
        warning "Go implementation not available, skipping"
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
    return 0
}

# Run Julia tests and generate conformance outputs
run_julia_tests() {
    log "Running Julia conformance tests..."

    if ! check_language_availability "julia" "$JULIA_DIR"; then
        warning "Julia implementation not available, skipping"
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
    julia --project=. "$SCRIPT_DIR/run-julia-conformance.jl" "$JULIA_OUTPUT"

    return $?
}

# Run TypeScript tests and generate conformance outputs
run_typescript_tests() {
    log "Running TypeScript conformance tests..."

    if ! check_language_availability "typescript" "$TYPESCRIPT_DIR"; then
        warning "TypeScript implementation not available, skipping"
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
    node "$SCRIPT_DIR/run-typescript-conformance.js" "$TYPESCRIPT_OUTPUT"

    return $?
}

# Run Python tests and generate conformance outputs
run_python_tests() {
    log "Running Python conformance tests..."

    if ! check_language_availability "python" "$PYTHON_DIR"; then
        warning "Python implementation not available, skipping"
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
    python3 "$SCRIPT_DIR/run-python-conformance.py" "$PYTHON_OUTPUT"

    return $?
}

# Run Rust tests and generate conformance outputs
run_rust_tests() {
    log "Running Rust conformance tests..."

    if ! check_language_availability "rust" "$RUST_DIR"; then
        warning "Rust implementation not available, skipping"
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
    cargo run --bin esm -- conformance-test "$RUST_OUTPUT"

    return $?
}

# Compare outputs between languages and detect divergence
compare_outputs() {
    log "Comparing cross-language outputs..."

    python3 "$SCRIPT_DIR/compare-conformance-outputs.py" \
        --output-dir "$OUTPUT_DIR" \
        --languages julia typescript python rust \
        --comparison-output "$OUTPUT_DIR/comparison/analysis.json"

    return $?
}

# Generate HTML conformance report
generate_report() {
    log "Generating conformance report..."

    python3 "$SCRIPT_DIR/generate-conformance-report.py" \
        --analysis-file "$OUTPUT_DIR/comparison/analysis.json" \
        --output-file "$OUTPUT_DIR/reports/conformance_report_${TIMESTAMP}.html"

    success "Conformance report generated: $OUTPUT_DIR/reports/conformance_report_${TIMESTAMP}.html"
}

# Run the property-corpus cross-binding round-trip check (gt-3fbf). Each
# binding reads the shared hypothesis-generated corpus, parses and
# re-serializes each expression, and the runner diffs the outputs. Writes
# a per-fixture divergence report alongside the per-language conformance
# outputs so reviewers can see which expression shapes cause divergence.
# Sanity-check the family-agnostic grid conformance runner (gt-usme).
# The runner consumes ESD-side family suites; here we only verify that
# the runner's own plumbing — manifest loading, adapter dispatch,
# diff classification, exit codes — is intact. Real family suites are
# exercised by ESD's CI when its per-family generators land.
run_grid_conformance_self_test() {
    log "Running grid-conformance runner self-test..."
    if python3 "$SCRIPT_DIR/run-grid-conformance.py" --self-test; then
        success "Grid-conformance runner self-test passed"
        return 0
    else
        error "Grid-conformance runner self-test failed"
        return 1
    fi
}

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
        warning "Julia unavailable — skipping Julia determinism producer check"
        return 0
    fi
    log "Running determinism conformance with the Julia relational engine..."
    EARTHSCI_DETERMINISM_ADAPTER_JULIA="julia --project=$JULIA_DIR $JULIA_DIR/scripts/determinism_adapter.jl" \
        python3 "$SCRIPT_DIR/run-determinism-conformance.py" \
            --bindings julia \
            --output "$OUTPUT_DIR/determinism/julia_report.json"
}

run_determinism_conformance_rust() {
    if ! check_language_availability "rust" "$RUST_DIR"; then
        warning "Rust unavailable — skipping Rust determinism producer check"
        return 0
    fi
    log "Running determinism conformance with the Rust relational engine..."
    EARTHSCI_DETERMINISM_ADAPTER_RUST="cargo run --quiet --manifest-path $RUST_DIR/Cargo.toml --bin earthsci-determinism-adapter-rust --" \
        python3 "$SCRIPT_DIR/run-determinism-conformance.py" \
            --bindings rust \
            --output "$OUTPUT_DIR/determinism/rust_report.json"
}

run_determinism_conformance_python() {
    if ! check_language_availability "python" "$PYTHON_DIR"; then
        warning "Python unavailable — skipping Python determinism producer check"
        return 0
    fi
    log "Running determinism conformance with the Python relational engine..."
    EARTHSCI_DETERMINISM_ADAPTER_PYTHON="python3 -m earthsci_toolkit.cli.determinism_adapter" \
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
# the adapter (packages/EarthSciSerialization.jl/scripts/cadence_adapter.jl) runs
# EarthSciSerialization.Cadence over the three §6.1 fixtures and the runner
# asserts its class map, materialization set, and CONST-folded buffers are
# byte-identical to the golden. Julia is `bindings_optional` in the manifest, so
# a missing adapter (no julia) is skipped, but a MISMATCH fails. Rust/Python
# siblings register the same way as they land.
run_cadence_conformance_julia() {
    if ! check_language_availability "julia" "$JULIA_DIR"; then
        warning "Julia unavailable — skipping Julia cadence-partition producer check"
        return 0
    fi
    log "Running cadence-partition conformance with the Julia partition pass..."
    EARTHSCI_CADENCE_ADAPTER_JULIA="julia --project=$JULIA_DIR $JULIA_DIR/scripts/cadence_adapter.jl" \
        python3 "$SCRIPT_DIR/run-cadence-conformance.py" \
            --bindings julia \
            --output "$OUTPUT_DIR/cadence/julia_report.json"
}

# Drive the REAL Rust partition pass (ess-my4.3.8) through the cadence harness:
# the adapter binary (packages/earthsci-toolkit-rs/src/bin/earthsci-cadence-adapter-rust.rs)
# runs the Rust Cadence module over the §6.1 fixtures and the runner asserts its
# class map, materialization set, and CONST-folded buffers are byte-identical to
# the golden. Rust is `bindings_optional`, so a missing adapter is skipped but a
# MISMATCH fails. (Mirrors run_cadence_conformance_julia; ess-my4.3.10.)
run_cadence_conformance_rust() {
    if ! check_language_availability "rust" "$RUST_DIR"; then
        warning "Rust unavailable — skipping Rust cadence-partition producer check"
        return 0
    fi
    log "Running cadence-partition conformance with the Rust partition pass..."
    EARTHSCI_CADENCE_ADAPTER_RUST="cargo run --quiet --manifest-path $RUST_DIR/Cargo.toml --bin earthsci-cadence-adapter-rust --" \
        python3 "$SCRIPT_DIR/run-cadence-conformance.py" \
            --bindings rust \
            --output "$OUTPUT_DIR/cadence/rust_report.json"
}

# Drive the REAL Python partition pass (ess-my4.3.9) through the cadence harness:
# the adapter (packages/earthsci_toolkit/src/earthsci_toolkit/cli/cadence_adapter.py)
# runs the Python Cadence module over the §6.1 fixtures and the runner asserts the
# same golden. Python is `bindings_optional` — missing adapter skipped, mismatch
# fails. (Mirrors run_cadence_conformance_julia; ess-my4.3.10.)
run_cadence_conformance_python() {
    if ! check_language_availability "python" "$PYTHON_DIR"; then
        warning "Python unavailable — skipping Python cadence-partition producer check"
        return 0
    fi
    log "Running cadence-partition conformance with the Python partition pass..."
    EARTHSCI_CADENCE_ADAPTER_PYTHON="python3 -m earthsci_toolkit.cli.cadence_adapter" \
        python3 "$SCRIPT_DIR/run-cadence-conformance.py" \
            --bindings python \
            --output "$OUTPUT_DIR/cadence/python_report.json"
}

run_property_corpus() {
    log "Running property-corpus round-trip across bindings..."
    local corpus="$PROJECT_ROOT/tests/property_corpus/expressions"
    if [ ! -d "$corpus" ] || [ -z "$(ls "$corpus"/expr_*.json 2>/dev/null)" ]; then
        warning "Property corpus empty or missing at $corpus — regenerating"
        python3 "$SCRIPT_DIR/generate-property-corpus.py" --count 50 --out "$corpus"
    fi

    # --require-divergence guards against the corpus regressing to a shape
    # where every binding agrees trivially; the phase-2 corpus is meant to
    # surface divergence. Zero divergences should prompt a corpus refresh.
    python3 "$SCRIPT_DIR/run-property-corpus-conformance.py" \
        --corpus "$corpus" \
        --output "$OUTPUT_DIR/property_corpus_report.json" \
        --require-divergence
}

# Main execution
main() {
    log "Starting cross-language conformance testing..."
    log "Project root: $PROJECT_ROOT"

    setup_output_dirs

    # Track which languages succeeded
    declare -a successful_languages=()
    declare -a failed_languages=()

    # Run tests for each language
    if run_julia_tests; then
        successful_languages+=("julia")
    else
        failed_languages+=("julia")
    fi

    if run_typescript_tests; then
        successful_languages+=("typescript")
    else
        failed_languages+=("typescript")
    fi

    if run_python_tests; then
        successful_languages+=("python")
    else
        failed_languages+=("python")
    fi

    if run_rust_tests; then
        successful_languages+=("rust")
    else
        failed_languages+=("rust")
    fi

    if run_go_tests; then
        successful_languages+=("go")
    else
        failed_languages+=("go")
    fi

    # Report summary
    log "Test execution summary:"
    if [ ${#successful_languages[@]} -gt 0 ]; then
        success "Successful languages: ${successful_languages[*]}"
    fi
    if [ ${#failed_languages[@]} -gt 0 ]; then
        error "Failed languages: ${failed_languages[*]}"
    fi

    # Only proceed with comparison if we have at least 2 successful languages
    if [ ${#successful_languages[@]} -ge 2 ]; then
        log "Proceeding with cross-language comparison..."

        if compare_outputs; then
            success "Cross-language comparison completed"
        else
            error "Cross-language comparison failed"
            exit 1
        fi

        if generate_report; then
            success "Conformance report generated successfully"
        else
            error "Report generation failed"
            exit 1
        fi

        if run_property_corpus; then
            success "Property-corpus round-trip completed"
        else
            error "Property-corpus round-trip failed"
            exit 1
        fi

        if run_grid_conformance_self_test; then
            success "Grid-conformance runner self-test completed"
        else
            error "Grid-conformance runner self-test failed"
            exit 1
        fi

        if run_determinism_conformance_self_test; then
            success "Determinism-conformance harness self-test completed"
        else
            error "Determinism-conformance harness self-test failed"
            exit 1
        fi

        if run_determinism_conformance_julia; then
            success "Determinism Julia producer check completed"
        else
            error "Determinism Julia producer check failed"
            exit 1
        fi

        if run_determinism_conformance_rust; then
            success "Determinism Rust producer check completed"
        else
            error "Determinism Rust producer check failed"
            exit 1
        fi

        if run_determinism_conformance_python; then
            success "Determinism Python producer check completed"
        else
            error "Determinism Python producer check failed"
            exit 1
        fi

        if run_geometry_conformance_self_test; then
            success "Geometry-conformance harness self-test completed"
        else
            error "Geometry-conformance harness self-test failed"
            exit 1
        fi

        if run_cadence_conformance_self_test; then
            success "Cadence-partition conformance harness self-test completed"
        else
            error "Cadence-partition conformance harness self-test failed"
            exit 1
        fi

        if run_cadence_conformance_julia; then
            success "Cadence-partition Julia producer check completed"
        else
            error "Cadence-partition Julia producer check failed"
            exit 1
        fi

        if run_cadence_conformance_rust; then
            success "Cadence-partition Rust producer check completed"
        else
            error "Cadence-partition Rust producer check failed"
            exit 1
        fi

        if run_cadence_conformance_python; then
            success "Cadence-partition Python producer check completed"
        else
            error "Cadence-partition Python producer check failed"
            exit 1
        fi

        success "Cross-language conformance testing completed successfully!"
        log "Results available in: $OUTPUT_DIR"

    else
        error "Need at least 2 successful language implementations to perform comparison"
        exit 1
    fi
}

# Check if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi