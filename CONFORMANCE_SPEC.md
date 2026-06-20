# ESM Format Conformance Test Specification

**Version 1.0 — Test Fixture Format and Execution Protocol**

This document specifies the structure, format, and execution model for ESM Format conformance test fixtures. It defines how test cases are organized, what outputs are expected, and how cross-language consistency is verified.

## 1. Overview

The ESM Format conformance testing system ensures that Julia, TypeScript, Python, and Rust implementations produce consistent results when processing the same ESM files. This specification defines:

- **Test fixture organization** and directory structure
- **Test case formats** for validation, display, substitution, and graph generation
- **Expected output formats** that all implementations must produce
- **Execution protocols** for running conformance tests
- **Error reporting standards** for validation failures

## 2. Test Fixture Organization

### 2.1 Directory Structure

Test fixtures are organized by test category under the `tests/` directory:

```
tests/
├── valid/                    # ESM files that should parse and validate successfully
├── invalid/                  # ESM files that should fail validation with specific errors
├── display/                  # Display formatting test cases (Unicode, LaTeX, ASCII)
├── substitution/             # Expression substitution test cases
├── graphs/                   # Graph generation test cases and expected outputs
├── simulation/               # Simulation test cases with expected trajectories
├── version_compatibility/    # Version migration and compatibility tests
├── conformance/              # Cross-language comparison results and analysis
└── [other categories]/       # Additional test categories as needed
```

### 2.2 Test Categories

#### 2.2.1 Validation Tests (`tests/valid/` and `tests/invalid/`)

**Purpose:** Verify schema and structural validation consistency across implementations.

**Structure:**
- **`tests/valid/`**: ESM files that should parse successfully and pass all validation checks
- **`tests/invalid/`**: ESM files that should fail validation with documented error codes

**File naming convention:**
```
<category>_<description>.esm
```

Examples:
- `minimal_chemistry.esm` - Baseline valid file exercising core features
- `events_all_types.esm` - Comprehensive event type coverage
- `circular_coupling.esm` - Invalid file with circular dependency
- `equation_count_mismatch.esm` - Invalid file with state/equation imbalance

#### 2.2.2 Display Format Tests (`tests/display/`)

**Purpose:** Verify consistent pretty-printing across implementations.

**File format:** JSON arrays with test case objects:

```json
[
  {
    "input": "O3",
    "unicode": "O₃",
    "latex": "\\mathrm{O_3}",
    "reasoning": "O is oxygen, 3 becomes subscript"
  },
  {
    "input": {"op": "D", "args": ["O3"], "wrt": "t"},
    "unicode": "∂O₃/∂t",
    "latex": "\\frac{\\partial \\mathrm{O_3}}{\\partial t}",
    "reasoning": "Partial derivative with respect to time"
  }
]
```

**Test case structure:**
- `input`: The expression to format (string for variables, object for AST nodes)
- `unicode`: Expected Unicode mathematical output
- `latex`: Expected LaTeX output
- `ascii`: Expected ASCII output (optional)
- `reasoning`: Human-readable explanation of formatting rules applied

#### 2.2.3 Substitution Tests (`tests/substitution/`)

**Purpose:** Verify expression substitution behavior across implementations.

**File format:** JSON arrays with substitution test cases:

```json
[
  {
    "input": {"op": "+", "args": ["T", {"op": "*", "args": ["k", "A"]}]},
    "substitutions": {"T": 298.15, "k": 1.5e-3},
    "expected": {"op": "+", "args": [298.15, {"op": "*", "args": [1.5e-3, "A"]}]},
    "description": "Simple parameter substitution"
  },
  {
    "input": {"op": "D", "args": ["_var"], "wrt": "t"},
    "substitutions": {"_var": "O3"},
    "expected": {"op": "D", "args": ["O3"], "wrt": "t"},
    "description": "Placeholder variable substitution"
  }
]
```

**Test case structure:**
- `input`: Expression AST to modify
- `substitutions`: Variable/parameter bindings to apply
- `expected`: Expected result after substitution
- `description`: Test case explanation

**Substitution semantics (normative):**

All implementations MUST implement `substitute` with the following behavior:

1. **Single-pass (non-transitive).** Bindings are applied once; replacements
   are not themselves re-substituted. Given bindings `{x -> y, y -> x}`,
   substituting `x` yields `y` (not `x` again). This guarantees termination
   for self-referential and mutually-referential bindings without requiring
   explicit cycle detection.
2. **Recursive over AST structure.** Substitution descends into every
   `args` child of an operator node. Nesting is bounded only by the host
   language's native stack; implementations SHOULD support at least 200
   levels of structural nesting in typical configurations.
3. **Operator-node metadata is preserved.** Fields such as `wrt`, `dim`
   (and other sidecar fields like `arrayop`'s `expr`, `output_idx`,
   `ranges`, `reduce`) are carried through unchanged.
4. **Empty-args operator nodes are valid inputs.** A node with `"op": "+"`
   and no `args` (or `args: []`) MUST NOT panic or raise; it is returned
   structurally equivalent.
5. **Unbound variables are passed through.** A variable not present in the
   substitutions map is returned unchanged.
6. **Empty substitutions map is the identity.** The output is structurally
   equal to the input.
7. **Null / missing inputs.** Dynamically-typed implementations (Python)
   MAY accept `None`/`null` and return it verbatim. Statically-typed
   implementations (Rust, Julia) use closed expression types where `null`
   is not representable, so this case does not apply and no conformance
   test is required.

These semantics are exercised by:
- Python: `packages/earthsci_toolkit/tests/test_substitute.py`
  (class `TestSubstitutionErrorHandling`)
- Rust: `packages/earthsci-toolkit-rs/tests/substitution.rs`
  (the `edge cases and error handling` section)
- Julia: `packages/EarthSciSerialization.jl/test/expression_test.jl`
  (`@testset "substitute edge cases"`)

#### 2.2.4 Graph Generation Tests (`tests/graphs/`)

**Purpose:** Verify system and expression graph generation consistency.

**Structure:**
- `*.json` files with graph generation test cases
- `expected_dot/`, `expected_mermaid/`, `expected_graphml/` subdirectories with reference outputs

**Graph test case format:**
```json
{
  "file": "path/to/test.esm",
  "graph_type": "system|expression",
  "options": {
    "merge_coupled": true,
    "include_parameters": false
  },
  "expected_nodes": [
    {"id": "SimpleOzone", "type": "reaction_system", "metadata": {...}},
    {"id": "Advection", "type": "model", "metadata": {...}}
  ],
  "expected_edges": [
    {
      "source": "SimpleOzone",
      "target": "Advection",
      "type": "operator_compose",
      "label": "composition",
      "metadata": {...}
    }
  ]
}
```

#### 2.2.5 Simulation Tests (inline in `.esm` files)

**Purpose:** Verify numerical simulation consistency (for runtime-capable implementations).

Simulation tests are carried **inline** inside each `Model` and `ReactionSystem` under a `tests` array field. Reference trajectories are no longer stored as a parallel filesystem hierarchy — each test is a small run specification plus a handful of scalar `(variable, time, expected)` assertion points that travel with the model in the `.esm` document itself.

See `esm-spec.md` Sections 6.6 (tests) and 6.7 (examples) for the full schema.

**Structure:**
- Component-level tests live at `models.<name>.tests[]` and `reaction_systems.<name>.tests[]`.
- Each test object contains `id`, `time_span`, `assertions[]`, and optional `description`, `initial_conditions`, `parameter_overrides`, and `tolerance`.
- Assertions are per-`(variable, time)` scalar checks against an `expected` value, with flexible multi-level tolerance (per-assertion → per-test → per-model → runtime default).
- Tests are **per-component** — they exercise a single model or reaction system in isolation. Cross-system / coupled tests are out of scope for this feature.
- Because a test lives inside its parent component, the target model is implicit from document location; there is no `model_ref` field.

**Example (abbreviated):**

```json
{
  "models": {
    "AtmosphericChemistry": {
      "variables": { "...": "..." },
      "equations": [ "..." ],
      "tolerance": { "abs": 1e-06, "rel": 1e-05 },
      "tests": [
        {
          "id": "photostationary_approach",
          "description": "Approach to photostationary state from NO=10, NO2=20, O3=50 ppbv.",
          "initial_conditions": { "NO": 10.0, "NO2": 20.0, "O3": 50.0 },
          "parameter_overrides": { "j_NO2": 0.008, "k_NO_O3": 1.8e-5 },
          "time_span": { "start": 0.0, "end": 3600.0 },
          "assertions": [
            { "variable": "NO",  "time":    0.0, "expected": 10.0 },
            { "variable": "NO",  "time": 1140.0, "expected": 26.114863 },
            { "variable": "O3",  "time": 3600.0, "expected": 66.115137,
              "tolerance": { "abs": 1e-4 } }
          ]
        }
      ]
    }
  }
}
```

**Why inline.** Reference CSVs under `expected/` live far from their parent `.esm` and must be kept in lock-step with any change to variables, parameters, or initial conditions. Inline tests make the run configuration and its expected outputs a single editable unit and let a parser verify test structural correctness at load time using the normal JSON schema. Tests are intentionally small (a handful of assertion points) — full trajectories belong in implementation-side regression suites, not in the portable document format.

**Runtime tolerance default:** when no `tolerance` is given at the assertion, test, or component level, conforming runtimes should use `rel = 1e-6` and no `abs` bound. If both `abs` and `rel` are given, passing either bound counts as a pass (standard numerical convention).

**Inline examples.** Alongside `tests`, each `Model` and `ReactionSystem` may carry an `examples` array — illustrative run configurations (optionally including Cartesian parameter sweeps) paired with structural plot specifications (line, scatter, heatmap). Examples produce trajectories and plots, not pass/fail outcomes. See `esm-spec.md` Section 6.7.

> **Note:** Earlier versions of this document described filesystem-based simulation tests (`tests/simulation/*.esm` + `tests/simulation/expected/*.csv`). That convention has been retired. The existing `tests/simulation/*.esm` fixtures now carry their reference behavior inline as `tests[]` arrays; the `expected/` CSV directory has been removed. Validation-error fixtures under `tests/invalid/` are unrelated to simulation tests and are unaffected by this change.

### 2.3 Test Fixture Metadata

Each test category may include a `README.md` file documenting:
- Test case descriptions and rationale
- Known limitations or implementation differences
- Tolerance thresholds for numerical comparisons
- Category-specific validation rules

## 3. Expected Output Formats

### 3.1 Validation Results

All implementations must produce validation results in this standard format:

```json
{
  "language": "julia|typescript|python|rust",
  "timestamp": "2026-02-18T10:30:00Z",
  "file_path": "tests/valid/minimal_chemistry.esm",
  "validation_result": {
    "is_valid": true,
    "schema_errors": [],
    "structural_errors": [],
    "unit_warnings": [
      {
        "path": "/reaction_systems/SimpleOzone/reactions/0/rate",
        "message": "Unit consistency check failed",
        "lhs_units": "mol/mol/s",
        "rhs_units": "cm^3/molec/s"
      }
    ]
  }
}
```

### 3.2 Display Results

Display formatting tests expect this output structure:

```json
{
  "language": "julia|typescript|python|rust",
  "timestamp": "2026-02-18T10:30:00Z",
  "test_file": "tests/display/chemical_subscripts.json",
  "results": [
    {
      "input": "O3",
      "output_unicode": "O₃",
      "output_latex": "\\mathrm{O_3}",
      "output_ascii": "O3",
      "success": true,
      "error": null
    },
    {
      "input": {"op": "D", "args": ["O3"], "wrt": "t"},
      "output_unicode": "∂O₃/∂t",
      "output_latex": "\\frac{\\partial \\mathrm{O_3}}{\\partial t}",
      "output_ascii": "d(O3)/dt",
      "success": true,
      "error": null
    }
  ],
  "summary": {
    "total_tests": 15,
    "passed": 14,
    "failed": 1
  }
}
```

### 3.3 Substitution Results

```json
{
  "language": "julia|typescript|python|rust",
  "timestamp": "2026-02-18T10:30:00Z",
  "test_file": "tests/substitution/simple_var_replace.json",
  "results": [
    {
      "input": {"op": "+", "args": ["T", "k"]},
      "substitutions": {"T": 298.15},
      "expected": {"op": "+", "args": [298.15, "k"]},
      "actual": {"op": "+", "args": [298.15, "k"]},
      "success": true,
      "error": null
    }
  ],
  "summary": {
    "total_tests": 8,
    "passed": 8,
    "failed": 0
  }
}
```

### 3.4 Graph Results

```json
{
  "language": "julia|typescript|python|rust",
  "timestamp": "2026-02-18T10:30:00Z",
  "test_file": "tests/graphs/system_graph.json",
  "results": [
    {
      "input_file": "tests/valid/minimal_chemistry.esm",
      "graph_type": "system",
      "nodes": [
        {"id": "SimpleOzone", "type": "reaction_system", "properties": {...}},
        {"id": "Advection", "type": "model", "properties": {...}},
        {"id": "GEOSFP", "type": "data_loader", "properties": {...}}
      ],
      "edges": [
        {
          "source": "SimpleOzone",
          "target": "Advection",
          "type": "operator_compose",
          "properties": {...}
        }
      ],
      "formats": {
        "dot": "digraph G { ... }",
        "json": "{\"nodes\": [...], \"edges\": [...]}",
        "mermaid": "graph TD\n  A[SimpleOzone] --> B[Advection]"
      },
      "success": true,
      "error": null
    }
  ]
}
```

## 4. Test Execution Protocol

### 4.1 Language-Specific Test Runners

Each language implementation provides a test runner script that:

1. **Discovers test fixtures** in the appropriate directories
2. **Executes tests** using the language's native ESM library
3. **Produces standardized output** in the formats specified above
4. **Writes results** to designated output directories
5. **Returns appropriate exit codes** (0 = success, non-zero = failure)

### 4.2 Test Runner Interface

All test runners must support this command-line interface:

```bash
# Run all conformance tests
<runner> --output-dir <path> [--categories <list>] [--verbose]

# Run specific test categories
<runner> --output-dir <path> --categories validation,display

# Run tests on specific files
<runner> --output-dir <path> --files tests/valid/minimal_chemistry.esm
```

**Parameters:**
- `--output-dir`: Directory to write test results (JSON files)
- `--categories`: Comma-separated list of test categories to run
- `--files`: Specific test files to process (overrides category-based discovery)
- `--verbose`: Include debug output and timing information

### 4.3 Test Execution Sequence

1. **Pre-validation**: Verify the language implementation passes its native test suite
2. **Fixture Discovery**: Scan test directories for applicable fixtures
3. **Individual Tests**: Process each test case and capture results
4. **Output Generation**: Write standardized JSON results to output directory
5. **Summary Report**: Generate test execution summary and statistics

### 4.4 Result File Naming

Test runners write results using this naming convention:

```
<output-dir>/
├── <language>_validation_results.json      # Validation test results
├── <language>_display_results.json         # Display formatting results
├── <language>_substitution_results.json    # Substitution test results
├── <language>_graph_results.json           # Graph generation results
├── <language>_simulation_results.json      # Simulation results (Julia/Python)
└── <language>_summary.json                 # Overall test summary
```

### 4.5 Running the Test Suite

Run the full cross-language conformance suite:

```bash
./scripts/test-conformance.sh
```

Outputs land in `conformance-results/`:
- `conformance-results/<language>/` — per-language result JSON
- `conformance-results/comparison/analysis.json` — cross-language comparison
- `conformance-results/reports/conformance_report_*.html` — HTML report

The comparison step requires at least two passing language implementations; it is skipped otherwise with the message "Need at least 2 successful language implementations to perform comparison."

Debug a failing run with shell tracing:

```bash
bash -x ./scripts/test-conformance.sh
```

Re-run only the comparison against existing per-language results:

```bash
python3 scripts/compare-conformance-outputs.py \
  --output-dir conformance-results \
  --languages julia typescript python \
  --comparison-output analysis.json
```

The pass/warn/fail thresholds used by the comparison are defined in `scripts/compare-conformance-outputs.py` — adjust them there if the overall consistency policy changes.

## 5. Cross-Language Comparison

### 5.1 Comparison Protocol

After individual language test runners complete, a comparison script analyzes results for consistency:

1. **Load results** from all language implementations
2. **Compare outputs** for identical test cases
3. **Identify divergences** and categorize their severity
4. **Generate compatibility report** with detailed analysis
5. **Determine pass/fail status** based on consistency thresholds

### 5.2 Consistency Thresholds

| Test Category | Pass Threshold | Description |
|---|---|---|
| **Validation** | 100% | All implementations must agree on valid/invalid status and error codes |
| **Display Unicode** | 98% | Minor differences in number formatting acceptable |
| **Display LaTeX** | 95% | Syntax variations acceptable if mathematically equivalent |
| **Substitution** | 100% | Expression substitution must be deterministic |
| **Graph Structure** | 95% | Node/edge sets must match; property differences acceptable |
| **Simulation** | 90% | Numerical tolerance for ODE solutions |
| **Relational index sets / dense IDs** | 100% (byte-identical) | Outputs of the value-invention primitives (`distinct`, `skolem`, `rank`) and group-by / value-equality joins. Governed by the **§5.5 cross-binding determinism contract** and **NOT** subject to the "minor formatting differences" tolerances above — these outputs are consumed by other nodes, so a divergence is a different *model*, not different formatting. |

> **Note.** The thresholds above for display/graph/simulation deliberately
> tolerate cosmetic and numerical differences. The determinism contract in
> **§5.5** is the exception: relational index sets and dense-ID arrays must be
> **byte-identical** across bindings. See §5.5 for the normative rules and the
> adversarial harness that enforces them.

### 5.3 Divergence Analysis

The comparison system categorizes divergences as:

- **Critical**: Different validation results, expression structure changes, **any
  byte-level difference in a relational index set or any difference in a
  dense-ID array** (the §5.5 determinism contract — these are never "minor")
- **Major**: Significant display formatting differences, graph topology changes
- **Minor**: Cosmetic differences in formatting, property metadata
- **Acceptable**: Known implementation limitations or language-specific constraints

### 5.4 Compatibility Report Format

```json
{
  "analysis_timestamp": "2026-02-18T10:45:00Z",
  "languages_compared": ["julia", "typescript", "python", "rust"],
  "test_categories": {
    "validation": {
      "total_tests": 45,
      "consistent_results": 45,
      "consistency_score": 1.0,
      "status": "PASS",
      "divergences": []
    },
    "display": {
      "total_tests": 120,
      "consistent_results": 118,
      "consistency_score": 0.983,
      "status": "PASS",
      "divergences": [
        {
          "test_case": "scientific_notation_formatting",
          "severity": "minor",
          "description": "Julia uses × symbol, others use x",
          "affected_languages": ["julia"]
        }
      ]
    }
  },
  "overall_status": "PASS|WARN|FAIL",
  "overall_score": 0.976,
  "recommendations": [
    "Review scientific notation formatting standards",
    "Consider harmonizing LaTeX fraction spacing"
  ]
}
```

### 5.5 Cross-Binding Determinism Contract (normative)

> This is the normative form of RFC `semiring-faq-unified-ir` §5.7. The RFC's
> Appendix A.5 retains the per-language rationale and the hash-randomization
> footguns; **the rules below are the contract.** They are exercised by the
> adversarial harness in `tests/conformance/determinism/` (see §5.5.4).

`earthsci-toolkit` is **parallel native implementations** (Julia, Rust,
Python, …) verified by this suite — not one core behind FFI. The
value-invention primitives `distinct`, `skolem`, and `rank`, together with
value-equality and group-by joins, produce **index sets and dense IDs that
other nodes consume**. Two bindings that disagree on the *order* or *numbering*
of those outputs produce **different models**, not merely different formatting.
This determinism is therefore **normative spec**, not an implementation detail,
and the §5.2 "minor formatting differences" tolerances explicitly do **not**
apply to it (§5.2, §5.3).

**Governing principle.** Every emitted set, key, and dense ID MUST be a **pure
function of a defined total order over tuples**. No observable output may depend
on hash-table iteration order or a language-native hash value.

#### 5.5.1 The rules

1. **Total order.** Lexicographic over tuple fields: integers by value; strings
   by **Unicode code-point order, equivalently UTF-8 byte order**, *not* locale
   collation. (For valid UTF-8 the two orders coincide; e.g. `"B"` (U+0042) <
   `"Z"` (U+005A) < `"a"` (U+0061) — a case-insensitive locale would interleave
   them, which is forbidden.) **Floats are forbidden in keys** — keep keys
   integer / categorical IDs. If a float is genuinely unavoidable it MUST be
   normalized (`-0.0`→`0.0`, `NaN` rejected) via the existing `canonicalize`
   float formatting before comparison, never compared as a raw native float.

2. **`distinct`** = sort by the total order, then drop **adjacent** duplicates.
   The output order **is** the sorted order. It MUST NOT be first-seen /
   insertion order, which is non-portable (Rust `HashSet` is randomly seeded,
   Julia `Dict`/`Set` order is unspecified, Python `set` order is
   `PYTHONHASHSEED`-sensitive — see §5.5.2).

3. **`rank`** = dense IDs assigned by position in the sorted `distinct`
   sequence. Conformance asserts on the **canonical 0-based numbering** (position
   in the sequence, language-neutral). Each binding emits in its own base and
   converts at the boundary; the conformance adapter declares its base and the
   harness normalizes reported IDs via `canonical = reported − emission_base`.
   The bases are **pinned**:

   | Binding | Emission base | Role |
   |---|---|---|
   | **Conformance (canonical)** | **0** | The numbering the suite asserts on. |
   | Julia | 1 | Native 1-based arrays; converts +1 at its boundary. |
   | Rust | 0 | Native 0-based. |
   | Python | 0 | Native 0-based. |
   | Go, TypeScript | — | Additive schema only; no evaluator/producer (N/A). |

4. **`skolem`** = a canonical **tuple**, never a hash. For a **symmetric**
   relation, sort the components (an undirected edge is `(min(u,v), max(u,v))`);
   for a **directed** relation, preserve order (so `(1,2)` and `(2,1)` are
   distinct). The dense ID then comes from `rank`. Hashing stays off the
   determinism-critical path entirely. *If* a fixed-width fingerprint is ever
   genuinely required, it MUST be a **portable, seed-pinned, non-cryptographic
   hash** (e.g. XXH3-64 seed 0) over a **canonical byte serialization** (fixed
   field order, little-endian ints, length-prefixed UTF-8 strings) — **never** a
   native `hash()` / `Base.hash` / `DefaultHasher`.

5. **`join` / group-by aggregate.** Hashing MAY be used only to *bucket*; the
   emitted result MUST be **sorted by the canonical key**. The semiring `⊕` used
   to combine duplicates MUST be associative + commutative (every registry `⊕` —
   sum, product, min, max, count, boolean-or — is), so input and parallel order
   cannot change the result. For a **floating-point** `⊕`, the per-bucket
   reduction MUST be done sequentially in canonical order to avoid last-ULP
   drift.

#### 5.5.2 The hash-randomization footguns this neutralizes

| Binding | Footgun | Effect |
|---|---|---|
| Rust | `HashMap`/`HashSet` default to SipHash-1-3 with a per-instance random seed | "arbitrary" iteration order |
| Python | `hash()` of `str`/`bytes` is SipHash keyed by per-process `PYTHONHASHSEED` | set/dict order varies per run |
| Julia | `Dict`/`Set` iteration order is an unspecified implementation detail; `Base.hash` is process-seeded and not cross-version / cross-language stable | order varies; hashes not portable |

Each footgun affects **only** hash-table iteration order and runtime hash
values. Sorting every output (rules 2, 5) and using content-defined keys (rule
4) makes every primitive a pure function of its input multiset, immune to all
three.

#### 5.5.3 Canonical serialization

"Byte-identical serialized index set" means the canonical byte form: **compact
JSON** (`,` and `:` separators, no spaces), **UTF-8** (no `\uXXXX` escaping),
tuples serialized as arrays, in the §5.5.1-rule-2 sorted order. This is the same
canonical-JSON discipline the round-trip idempotence contract relies on
(`tests/conformance/README.md`). Two conforming bindings MUST produce
byte-for-byte identical serialized index sets and identical dense-ID arrays
(after rule-3 base normalization).

#### 5.5.4 Conformance requirement and the adversarial harness

The suite MUST feed **identical** mesh / table inputs to every producing binding
and assert **byte-identical serialized index sets and identical dense-ID
arrays** — including adversarial inputs designed to break order-dependence:
**duplicate** edges/rows, **reversed orientation**, and **permuted input
order**. All such variants MUST collapse to the identical canonical output.

This is implemented by `scripts/run-determinism-conformance.py` against the
golden example in `tests/conformance/determinism/manifest.json`, in two phases:

- **Now** (parallel to M1, before any producer exists): `--self-test` asserts
  the contract against an embedded reference implementation of the primitives —
  byte-identity to the committed golden, adversarial-variant collapse, rank
  base-pin round-trip, and negative controls (it must *reject* unsorted output
  and float keys). Wired into `scripts/test-conformance.sh`.
- **Later** (M2 value-equality joins, M3 relational engine): each binding ships
  a thin adapter (discovered via `$EARTHSCI_DETERMINISM_ADAPTER_<BINDING>` or on
  `PATH`); the runner asserts every adapter's output byte-identical to the golden
  and to each other. See `tests/conformance/determinism/README.md` for the
  adapter contract.

### 5.6 Closed Semiring Registry (normative)

> This is the normative form of RFC `semiring-faq-unified-ir` §5.1 / §5.2 / §5.6.
> The `aggregate` node (canonical tag for the former `arrayop`) is a **semiring
> FAQ**: a reduction `⊕_C ⊗_k factor_k` over a set of index ranges. The semiring
> fixes the two operators and — critically for cross-binding agreement — their
> **identity elements**. These rules are exercised by the worked-example fixtures
> in `tests/valid/aggregate/` and the per-binding evaluator suites (see §5.6.4).

**Governing principle.** The `(⊕, ⊗)` operators and **both** identity elements
(`0̄`, the value of an empty `⊕`-reduction; `1̄`, the value of an empty
`⊗`-product) are fixed by the registry table below and **MUST NOT be written
into the file**. Two bindings that disagree on an identity disagree on the value
of an empty or degenerate contraction — a different model, not different
formatting — so the §5.2 tolerances do **not** apply to the identity contract
(an empty `sum_product` is exactly `0`, an empty `min_sum` is exactly `+∞`).

#### 5.6.1 The registry

`semiring` is a **closed enum** (adding a row is a spec change, never a
per-file extension). The five rows, with their normative identities:

| `semiring` | ⊕ (reduce) | `0̄` (empty ⊕) | ⊗ | `1̄` (empty ⊗) | Domain | Role |
|---|---|---|---|---|---|---|
| `sum_product` *(default)* | `+` | `0` | `×` | `1` | ℝ | einsum / FVM-diffusion & ESD discretization |
| `max_product` | `max` | `−∞` | `×` | `1` | ℝ≥0 | best-path / saturation |
| `min_sum` *(tropical)* | `min` | `+∞` | `+` | `0` | ℝ∪{+∞} | shortest-path / least-cost |
| `max_sum` | `max` | `−∞` | `+` | `0` | ℝ∪{−∞} | longest-path |
| `bool_and_or` *(relational)* | `∨` (or) | `false` (`0`) | `∧` (and) | `true` (`1`) | 𝔹 | existence / `distinct` / join |

The enum spelling is normative: `"sum_product"`, `"max_product"`, `"min_sum"`,
`"max_sum"`, `"bool_and_or"`. The schema (`esm-schema.json`, the `semiring`
property on `ExpressionNode`) restates the identities inline and pins the
`default` to `sum_product`. `bool_and_or` is the only index-set-producing
semiring (it drives `distinct` / `skolem`, §5.5); the M1 numeric evaluators
reject it for array-valued reductions.

#### 5.6.2 Identity resolution and back-compat

1. **`semiring` is authoritative** and supersedes a legacy `reduce` field when
   both are present (`semiring: "min_sum"` reduces with `min` even if
   `reduce: "+"` is also written).
2. **Legacy `reduce`-only shorthand** maps to the same `⊕` / `0̄`: `"+"`→`0`,
   `"max"`→`−∞`, `"min"`→`+∞`, `"*"`→`1`. A pre-semiring `reduce: "+"` file is
   therefore identical to `semiring: "sum_product"` — back-compatible by
   construction. Absent both, the default is `sum_product`.
3. **An unregistered `semiring` is a hard error** in every binding (the enum is
   closed); it is also a schema violation (enum constraint), so non-evaluating
   bindings reject it at validation time
   (`tests/invalid/aggregate/unregistered_semiring.esm`).

#### 5.6.3 Empty / degenerate reductions

Every binding MUST return the registry `0̄` for an empty `⊕`-reduction, sourced
from the table and **never** hardcoded from the file. This holds for a fixed
empty range (`{"j": [1, 0]}`), an empty categorical set, and a per-cell dynamic
bound that resolves to zero (e.g. an isolated mesh cell with no neighbours). An
unmatched value-equality `join` row and a `filter`-false combination likewise
contribute `0̄` (they add nothing under any `⊕`). Concretely: an empty
`sum_product` is `0`, an empty `min_sum` is `+∞`, an empty `max_product` /
`max_sum` is `−∞`. (The non-finite identities are not integrable as ODE rates,
so they are asserted at the per-binding unit level rather than through a solve.)

#### 5.6.4 Index-set registry and the `aggregate` tag

A `ranges` entry MAY be a dense `[lo, hi]` / `[lo, step, hi]` tuple **or** an
index-set reference `{"from": <name>}` / `{"from": <name>, "of": [<parents>]}`
resolved against the document `index_sets` registry (RFC §5.2): `interval` →
`[1, size]`, `categorical` → `[1, |members|]`, `ragged` → a per-cell dynamic
bound. An undeclared `from` name is a hard error — no implicit interval is
inferred. The canonical `op: "aggregate"` tag and the deprecated `op: "arrayop"`
alias are evaluated identically (§5.6).

#### 5.6.5 Conformance requirement

The shared fixtures under `tests/valid/aggregate/` carry inline `tests`
assertions that **all evaluating bindings check against the same `expected`
values**, so agreement is the cross-binding semiring-equivalence proof:

| Fixture | Exercises |
|---|---|
| `fvm_diffusion_sum_product.esm` | default `sum_product` contraction (§7.1) + the empty-range `0̄` identity (`0`) |
| `min_sum_tropical.esm` | `min_sum` `⊕ = min` over an additive body |
| `max_product_saturation.esm` | `max_product` `⊕ = max` over a product body |
| `categorical_index_set.esm` | a `categorical` `{from}` contraction (cardinality = member count) |

- **Julia, Rust, Python** evaluate every fixture and match its inline
  `expected` (`packages/EarthSciSerialization.jl/test/aggregate_conformance_test.jl`,
  `packages/earthsci-toolkit-rs/tests/aggregate_conformance_tests.rs`,
  `packages/earthsci_toolkit/tests/test_aggregate_conformance.py`), and each
  asserts the full `0̄` / `1̄` identity table (including the non-finite rows) in
  its evaluator unit suite.
- **Go, TypeScript** parse + schema-validate every valid fixture and reject the
  invalid ones, covering the additive fields (`op:"aggregate"`, the `semiring`
  enum, `ranges` `{from}` references, the `index_sets` registry) with no
  evaluator (`packages/esm-format-go/pkg/esm/aggregate_fixtures_test.go`,
  `packages/earthsci-toolkit/src/aggregate-fixtures.test.ts`).

## 6. CI Integration

### 6.1 GitHub Actions Workflow

The `.github/workflows/conformance-testing.yml` workflow:

1. **Individual Tests**: Runs each language's test suite independently
2. **Conformance Tests**: Cross-language comparison (only if individual tests pass)
3. **Results Upload**: Stores conformance results as artifacts
4. **PR Comments**: Posts conformance status on pull requests
5. **Failure Detection**: Fails if critical divergences detected

### 6.2 Triggering

Conformance tests run automatically on:
- Pushes to `main` or `develop` branches
- Pull requests affecting `packages/`, `tests/`, or `scripts/`
- Manual workflow dispatch

### 6.3 Workflow Dependencies

```yaml
conformance-testing:
  needs: [julia-tests, typescript-tests, python-tests, rust-tests]
```

Only runs cross-language tests if individual language tests pass.

## 7. Error Handling and Reporting

### 7.1 Standard Error Codes

Validation tests must use these standardized error codes:

| Code | Category | Description |
|---|---|---|
| `schema_validation_failed` | Schema | JSON Schema validation error |
| `equation_count_mismatch` | Structural | State variables vs ODE equations mismatch |
| `undefined_variable` | Structural | Equation references undeclared variable |
| `undefined_species` | Structural | Reaction references undeclared species |
| `undefined_parameter` | Structural | Rate expression references undeclared parameter |
| `undefined_system` | Structural | Coupling references nonexistent system |
| `unresolved_scoped_ref` | Structural | Invalid scoped reference path |
| `null_reaction` | Structural | Reaction with both null substrates and products |
| `missing_observed_expr` | Structural | Observed variable missing expression |
| `event_var_undeclared` | Structural | Event affects undeclared variable |
| `unit_dimension_mismatch` | Units | Dimensional analysis failure |
| `unit_parse_error` | Units | Unrecognized unit string |
| `E_UNREWRITTEN_PDE_OP` | Discretization | `discretize()` output still contains a PDE op (`grad`, `div`, `laplacian`, `D`, `bc`) after the rule engine runs (RFC §11 Step 7). |
| `E_RULES_NOT_CONVERGED` | Discretization | Rule engine hit `max_passes` without reaching a fixed point (RFC §5.2.5). |
| `E_NO_DAE_SUPPORT` | Discretization | `discretize()` output contains algebraic equations alongside differential ones, and DAE support is disabled in the binding (RFC §12). The error message must name at least one algebraic-equation path and the enabling knob. |
| `E_NONTRIVIAL_DAE` | Discretization | Binding with trivial-DAE-only strategy (Go, Rust) found algebraic equations that could not be factored symbolically — cyclic observed equations, implicit residuals, or genuine algebraic constraints remain after observed-style `y ~ f(...)` substitution (RFC §12, `docs/rfcs/dae-binding-strategies.md`). The error message must name each residual equation path and point the user at a full-DAE-capable binding (Julia). |

### 7.2 Error Message Format

```json
{
  "code": "undefined_variable",
  "path": "/models/SuperFast/equations/0/rhs",
  "message": "Variable 'O4' referenced in equation but not declared in variables",
  "details": {
    "variable_name": "O4",
    "equation_index": 0,
    "available_variables": ["O3", "NO", "NO2"]
  }
}
```

### 7.3 Test Failure Reporting

When a test case fails, implementations must report:

- **Input**: The test case that caused the failure
- **Expected**: What output was expected
- **Actual**: What output was produced
- **Error**: Exception message or error description
- **Context**: Additional debugging information

## 8. Test Fixture Authoring Guidelines

### 8.1 Fixture Creation Process

1. **Design test case** targeting specific functionality or edge case
2. **Author baseline fixture** in appropriate category directory
3. **Generate reference outputs** using a designated reference implementation
4. **Review outputs** for correctness and cross-language applicability
5. **Document rationale** in fixture metadata or README
6. **Commit to repository** after peer review

### 8.2 Fixture Quality Standards

- **Minimal**: Each fixture should test one specific aspect or behavior
- **Comprehensive**: Edge cases and boundary conditions should be covered
- **Documented**: Include reasoning for expected outputs
- **Reproducible**: Results should be deterministic across implementations
- **Maintainable**: Fixtures should be easy to update when specifications change

### 8.3 Version Control

- Test fixtures are version-controlled alongside the ESM schema
- Changes to expected outputs require review and approval
- Breaking changes must be coordinated across all language implementations
- Deprecated fixtures should be marked but preserved for historical testing

## 9. Implementation Requirements

### 9.1 Minimum Conformance

To claim conformance with this specification, an implementation must:

1. **Pass all validation tests** in `tests/valid/` and `tests/invalid/`
2. **Achieve 95% consistency** on display formatting tests
3. **Pass all substitution tests** with 100% accuracy
4. **Generate correct graph structures** for system and expression graphs
5. **Produce standardized output formats** as specified in Section 3

### 9.2 Test Coverage Requirements

Implementations must provide test coverage for:

- All ESM format sections (models, reaction_systems, coupling, domain, etc.)
- All expression operators and functions
- All validation error codes
- All coupling types and transformations
- All event types (continuous, discrete, functional)

### 9.3 Performance Guidelines

While not strictly required for conformance, implementations should:

- Complete the full test suite in under 60 seconds on standard hardware
- Handle large ESM files (1000+ equations) without excessive memory usage
- Provide progress reporting for long-running test operations

## 10. Future Extensions

### 10.1 Planned Additions

- **MathML output format** tests for web/academic publishing
- **Code generation tests** for Julia/Python output quality verification
- **Migration tests** for ESM format version compatibility
- **Performance benchmarks** with standardized timing measurements
- **Fuzzing test cases** for robustness testing

### 10.2 Extensibility

The test fixture format is designed to accommodate:

- New test categories via additional subdirectories
- Extended output formats through additional fields in result objects
- Custom validation rules through metadata in test fixture files
- Language-specific test extensions while maintaining core compatibility

## 11. Reference Implementation

The Julia `EarthSciSerialization.jl` library serves as the reference implementation for conformance test development. When adding new test fixtures:

1. Verify behavior using `EarthSciSerialization.jl`
2. Generate expected outputs using Julia implementation
3. Validate that other implementations produce equivalent results
4. Document any acceptable implementation differences

New conformance tests should be developed iteratively with input from all language implementation maintainers to ensure realistic and achievable standards.

---

This specification establishes the foundation for rigorous cross-language testing of ESM Format implementations. By following these protocols, we ensure that ESM files can be processed consistently across Julia, TypeScript, Python, and Rust, enabling reliable interoperability in the EarthSciML ecosystem.