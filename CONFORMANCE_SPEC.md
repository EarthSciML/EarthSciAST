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
| **Conservative-regridding geometry (areas / weights)** | Invariants exact; areas within rel + abs tol | The M4 geometry kernel (`intersect_polygon`, the `polygon_area` FAQ, the weights `W_ij`) is **tolerance-based** — FP polygon clipping cannot be made bit-identical. Gated primarily on the physical invariants (conservation + partition-of-unity), with a combined rel + abs area tolerance and a sliver floor; the integer **candidate overlap-pair index set** stays byte-identical (§5.5). Governed by the **§5.8 geometry tolerance contract**. |

> **Note.** The thresholds above for display/graph/simulation deliberately
> tolerate cosmetic and numerical differences. The determinism contract in
> **§5.5** is the exception in one direction: relational index sets and dense-ID
> arrays must be **byte-identical** across bindings. See §5.5 for the normative
> rules and the adversarial harness that enforces them. The geometry tolerance
> contract in **§5.8** is the exception in the *other* direction: the M4
> conservative-regridding kernel is irreducibly floating-point, so its areas /
> weights are **tolerance-based** by contract — gated on physical invariants —
> while only its integer **candidate overlap-pair set** falls back under the §5.5
> byte-identity rule.

### 5.3 Divergence Analysis

The comparison system categorizes divergences as:

- **Critical**: Different validation results, expression structure changes, **any
  byte-level difference in a relational index set or any difference in a
  dense-ID array** (the §5.5 determinism contract — these are never "minor"), a
  **byte-level difference in the bin-Skolem candidate overlap set** or a
  **conservation / partition-of-unity invariant violation** in the M4 geometry
  kernel (the §5.8 tolerance contract)
- **Major**: Significant display formatting differences, graph topology changes
- **Minor**: Cosmetic differences in formatting, property metadata
- **Acceptable**: Known implementation limitations or language-specific
  constraints, and **sub-`atol` sliver-area disagreement** between geometry
  bindings (the §5.8 snapping / tie-break regime: "present-but-tiny" and "absent"
  both pass)

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
value-invention primitives `distinct`, `skolem`, and `rank`, the arg-witness
reducers `argmin`/`argmax` (§5.5.1 rule 6), together with
value-equality and group-by joins, produce **index sets, dense IDs, and
assignment buffers that
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

6. **Arg-witness reducers (`argmin` / `argmax`).** A build-time reduction over a
   contracted candidate range that emits the **arg** — the witnessing index — not
   the reduced value (`assign[i] = argmin_g dist(point_i, gen_g)`, the
   nearest-generator INDEX). The closed semiring registry (§5.6) reduces to
   *values* and `distinct`/`skolem`/`rank` produce *sets*; neither yields the arg,
   so this is a distinct primitive. The tie-break is **normative: the smallest arg
   (smallest candidate id) wins** on an equal reduced value (`<` selects for
   `argmin`, `>` for `argmax`; on an exact tie the smaller index). The comparison
   is explicit — never enumeration order — so the emitted integer buffer is a pure
   function of the candidate ids and the metric, byte-identical across bindings.
   The reduced value is an ordinary FAQ over the candidate factors; a float value
   participates only in the comparison, never in a key (use a squared metric, not
   `sqrt`, to keep ties bit-exact). An empty candidate set is an error. The buffer
   is a CONST/DISCRETE build-time materialization off the hot path; a continuous
   (state-dependent) arg-witness is rejected by §5.7.6 guard 2, like a continuous
   `distinct`.

7. **Grouped reduction over an arg-witness key (the SCVT centroid step).** A
   group-by aggregate (rule 5) MAY be keyed on an arg-witness assignment buffer
   (rule 6): `num[g] = Σ_{p : assign[p]=g} ρ_p·x_p`, `den[g] = Σ_{p : assign[p]=g}
   ρ_p`, `centroid[g] = num[g]/den[g]` — the per-generator density-weighted
   centroid. The group KEY is the *value-dependent* `assign` buffer (not a loop
   index), so it is a value-equality group-by and MUST follow rule 5 exactly:
   bucket by the canonical integer key, reduce each bucket's floats sequentially in
   canonical value order, and emit `0̄` for an empty group (an unattended generator
   then has `den=0` and a NaN `centroid` — division is IEEE, never an exception, so
   every binding agrees). The whole step is materialized off the hot path through
   the value-invention front-door (the same CONST/DISCRETE point as the `assign`
   buffer it consumes) and dropped from the ODE; `num`/`den`/`centroid` are pure
   functions of the inputs and the rule-5/rule-6 orders, hence byte/tolerance-
   identical across bindings. A grouped/derived buffer reading live ODE `state` is
   rejected by §5.7.6 guard 2 (its inputs MUST be CONST/DISCRETE).

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
golden example in `tests/conformance/determinism/manifest.json`, in two layers:

- **The reference layer** (`--self-test`, always on): asserts the contract
  against an embedded reference implementation of the primitives — byte-identity
  to the committed golden, adversarial-variant collapse, rank base-pin
  round-trip, and negative controls (it must *reject* unsorted output and float
  keys). Wired into `scripts/test-conformance.sh`.
- **The per-binding producer layer** (live — the M2 value-equality joins and the
  M3 relational engine have landed): each binding ships a thin adapter
  (discovered via `$EARTHSCI_DETERMINISM_ADAPTER_<BINDING>` or as
  `earthsci-determinism-adapter-<binding>` on `PATH`) that runs its real
  value-invention primitives over the **canonical input and every adversarial
  variant**. The runner asserts each adapter's serialized index sets are
  byte-identical to the golden — so, transitively, to every other binding — its
  dense IDs identical after base normalization, and that **every variant
  collapses to the golden per binding**, so order-, duplicate-, and
  orientation-independence is proven for each real engine, not just the
  reference. The three evaluators (Julia, Rust, Python) are `bindings_required`,
  so a missing or mismatching producer fails the gate; `test-conformance.sh`
  drives all three. See `tests/conformance/determinism/README.md` for the
  adapter contract.

#### 5.5.5 Const-array gather boundary policy (normative)

A **const-array gather** — `index(factor, e_1, …, e_D)` reading a pre-computed
factor (Fornberg weights, mesh connectivity, a per-cell metric / geometry array)
— may resolve an **out-of-range** index `e_d ∉ 1..N_d` declaratively, exactly as
the state-variable stencil gather honors grid periodicity. This is governed by a
**declared per-factor, per-dimension boundary policy** (one symbol per array
dimension); the policy is supplied alongside the factor data (the evaluator
`const_array_boundaries` input, derivable from the grid's periodic dimensions and
the factor's declared `dims`). The closed set of per-dimension policies and their
**byte-identical** 1-based resolution:

| Policy | Out-of-range `i` (dim size `N`) resolves to | Use |
|---|---|---|
| `periodic` | `mod1(i, N)` = `((i − 1) mod N) + 1` | A periodic axis (e.g. longitude); matches the state-variable periodic fold. |
| `clamp` | `clamp(i, 1, N)` = edge-extend | The correct finite policy for a metric / geometry factor at a non-periodic boundary (e.g. a latitude pole). **NOT** the zero-ghost convention, which is physically wrong for a metric. |
| `error` *(default)* | throw / raise `E_TREEWALK_CONSTARRAY_OOB` | Any factor **without** a declared policy. Genuine out-of-bounds bugs in connectivity / stencil-weight factors stay caught. |

In-range gathers are unaffected. The zero-ghost convention (`u[OOB] → 0`) remains
the state-**variable** gather's boundary default and is **never** applied to a
const-array gather. All evaluating bindings (Julia, Rust, Python) MUST agree
byte-for-byte on the resolved gather; the reference numerics for `M = [10,20,30,40]`
are `clamp(M, 5) = 40`, `periodic(M, 5) = 10`, `periodic(M, 0) = 40`. (Bead
`ess-gj4`; enables the covariant-FV connection-term metric gathers of the
discretization RFC to run unmodified through the evaluator.)

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

### 5.7 Cadence-Partition Pass (normative)

> This is the normative form of RFC `semiring-faq-unified-ir` §6.1. The
> **dependency-partition pass** is the ESS analogue of ModelingToolkit's
> `structural_simplify` / observed-variable elimination, generalized from two
> phases to three. It classifies every node by the **cadence** at which its
> value can change and schedules each class into its own evaluation phase. The
> rules below are the contract; they are exercised by the worked-example
> fixtures in `tests/valid/cadence/` and the harness in
> `tests/conformance/cadence/` (see §5.7.7).

The classification is a **compile-time** property that drives *which code runs
in which phase* — a folded artifact, a per-event handler, or the hot per-step
tree. Two bindings that disagree on a node's class, on the **set of
materialization points**, or on the bytes of a **`CONST`-folded buffer** produce
*different models* (different hot loops, different per-event work), not merely
different formatting. The partition is therefore **normative spec**, and the
§5.2 "minor formatting differences" tolerances explicitly do **not** apply to it.

**Governing principle.** Every node's cadence class is a **pure function of the
data-dependency DAG** — `class(node) = max` over its inputs' classes — and is
**never declared by the author**. The boundary between phases is *derived*, not
written into the file. The one new declaration the pass requires is the leaf
seed (the `discrete` variable kind, §5.7.2); the optional `expect_cadence`
annotation is a checked assertion, not a control input.

#### 5.7.1 The cadence classes

Every value is determined at one of three cadences, forming a total order
`CONST ⊏ DISCRETE ⊏ CONTINUOUS`:

| Class | Changes | Evaluated | Phase | MTK analogue |
|---|---|---|---|---|
| `CONST` | never | once | folded into the artifact | true parameter / literal |
| `DISCRETE` | only at discrete events (piecewise-constant between them) | at setup + on each refresh event, memoized between | per-event handler | callback-updated parameter (`PresetTimeCallback`, `tstops`) |
| `CONTINUOUS` | every step | every RHS call | hot `_Node` tree | integrated state `u` |

Two points fix the semantics:

1. **Named by cadence, not by role.** `CONTINUOUS` means "changes every step,"
   not "the unknown we solve for." Its dominant inhabitant is the integrated
   state `u`, but an explicit continuous-`t` forcing (`sin(2πt)`, an analytic
   diurnal cycle) is **also** `CONTINUOUS` — it is not piecewise-constant
   between events and must recompute every step. Classifying by cadence keeps
   such forcings out of `DISCRETE`, where they would silently go stale.
2. **There is no "grid" class.** With topology first-class (§5.6.4), the mesh is
   not a primitive input — it is `aggregate` nodes (`distinct`, `join`, `rank`)
   over mesh primitive arrays. When those primitives are document literals the
   topology partition is `CONST` and folds into the artifact; when the mesh is
   reloaded at discrete events (AMR, moving meshes) the same nodes are
   `DISCRETE`. "Grid" is a *consequence* of where its leaves sit, not a category.

#### 5.7.2 Seeding the leaves

The `max`-propagation bottoms out at *declared* leaf cadences. Three roles seed
the three classes:

| Leaf | Seed | Source |
|---|---|---|
| `state` variable, the independent variable `t` | `CONTINUOUS` | existing ESM |
| `parameter` variable, numeric literal, index-set name, bound index symbol | `CONST` | existing ESM |
| `discrete` variable | `DISCRETE` | the **one new declaration** (`esm-schema.json`, `ModelVariable.type` enum) |

`DISCRETE` had no existing role to derive from — nothing in the pre-M3 schema
expressed "shape fixed at setup, values refreshed at discrete events." The
`discrete` variable kind (a third role beside `state` and `parameter`) is that
seed: it declares its **fixed shape** and, optionally, a **`refresh` trigger**
(`schedule` / `data_ingest` / `remesh`) that drives its per-event recompute.
Loaded met/BC fields, scheduled emission inventories, and reloadable mesh
topology are all declared `discrete`.

The compile-fold-vs-bind-fold distinction is a **provenance sub-tag**, not a
declared class: a `CONST`/`DISCRETE` leaf whose bytes are inline folds at
**compile**; one loaded from an external resource (NetCDF mesh/met) folds at
**bind**. Same algebra, same propagation.

**Loader-seeded refinement (RFC `pure-io-data-loaders` §4.6).** When a
`discrete` variable's `refresh` is a `data_ingest` trigger, its `source` names a
`DataLoader` in the document's top-level `data_loaders`. The loader's `temporal`
block is what makes its outputs time-varying, and it is the loader — not the
variable's own declaration — that fixes the seed:

- a loader **with** `temporal` keeps the variable `DISCRETE` (its refresh trigger
  is the loader's update times) and folds it at **bind**;
- a loader **without** `temporal` describes non-time-varying data (`temporal` is
  optional; absence ⇒ non-time-varying), so the same variable is refined down to
  `CONST` — loaded once, still folding at **bind**.

Any other refresh trigger (`schedule` / `remesh`) or a `source` that resolves to
no loader keeps the declared `DISCRETE` seed. This is the one context in which a
leaf's seed reads a document field outside its own declaration; it is resolved at
build time, before propagation, so the rest of the pass is unchanged. The
worked-example pair `loader_temporal_seed` (→ `DISCRETE`) and `loader_const_seed`
(→ `CONST`) in `tests/valid/cadence/` are identical models that differ only in the
loader's `temporal` block.

#### 5.7.3 Propagation and the gather rule

Walk the inter-node DAG bottom-up; `class(n) = max` over inputs. The DAG spans
**all** nodes — edges include expression child→parent, a node→an index set it
references (`ranges[*].from`), a `kind:"derived"` set→its `from_faq` node, and a
`join.on` factor→the factor it names. (Node addressing — §5.6.4, the node `id`
and `from_faq` — is a hard prerequisite: the pass cannot run until these are
real edges.)

One rule carries the design. For a **gather** `index(A, e₁…eₖ)`, the index
expressions are classified **independently of the array**:

```
class(index(A, e…)) = max( class(A), class(e₁), …, class(eₖ) )
```

This is what lets a stencil split across phases: in
`index(u, index(nbr, i, k))` the inner neighbour-selection is `CONST` (topology)
while the outer value load is `CONTINUOUS` (it touches `u`). (Operationally this
is just `max` over a node's children, so no special case is needed — the split
is a *consequence* of classing the index sub-expressions as ordinary inputs.)

#### 5.7.4 The frontier cut and materialization points

The boundary is drawn *through* nodes, not around them: wherever a lower-cadence
child feeds a higher-cadence parent, the maximal lower-cadence sub-DAG below
that edge is a **materialization point** — evaluated in its phase, stored in a
buffer, and referenced by the parent. With three classes the cut fires at two
thresholds:

- **`CONST → {DISCRETE, CONTINUOUS}`** — fold once into the artifact (the
  deduplicated edge set, `nbr_idx`, `coeff`, …).
- **`DISCRETE → CONTINUOUS`** — materialize into a buffer the hot path reads as
  a constant, recomputed by the per-event handler when the underlying data
  refreshes (met slices, reloaded BCs, a remeshed topology).

A **bare scalar-constant leaf** that feeds a higher-cadence parent is **not** a
materialization point — it inlines as a literal (the pre-existing constant-fold
`build_evaluator` already performs). A materialization point is a *buffer* (an
array / index set), the maximal lower-cadence **sub-DAG** rooted at the boundary.
The frontier generalizes the existing constant-fold — applied once at the
`CONST` threshold and again at the `DISCRETE` one.

#### 5.7.5 Three execution outputs

Instead of a single compiled tree, the pass emits:

1. **Folded artifact** (`CONST`) — literals plus precomputed index/coefficient
   buffers baked in.
2. **Per-event handler** (`DISCRETE`) — recomputes its buffers on each
   refresh/remesh event; the relational engine (§5.5) runs here, off the hot
   path. **Empty** when nothing is event-driven.
3. **Per-step `_Node` tree** (`CONTINUOUS`) — identical in shape to today's
   `build_evaluator` output for existing rules, with frontier references
   replaced by buffer loads. Performance for existing rules is unchanged.
   **Empty** when nothing is per-step (a pure-topology rule).

#### 5.7.6 The guards (checked, not hoped for)

Each partition is **pure feed-forward**, so the pass needs partial evaluation by
cadence, not equation tearing. This is a *checked* property:

1. **Acyclicity.** The `≤ DISCRETE` subgraph MUST be a DAG; a cycle is an
   implicit/iterative solve, out of scope (use a `call` handler). Reject with a
   diagnostic **naming the cycle**.
2. **No relational engine on the hot path.** A
   `distinct`/`join`/`skolem`/`rank`/`argmin`/`argmax`
   node that classifies `CONTINUOUS` is **rejected** — state-dependent topology
   (or a state-dependent arg-witness assignment) may not run per step in v1.
3. **Optional author assertion.** `expect_cadence: "const"|"discrete"|
   "continuous"` on a node (`esm-schema.json`, the `expect_cadence` property on
   `ExpressionNode`) is a test/diagnostic hook only; the pass errors if the
   **derived class disagrees**. It changes no semantics.

#### 5.7.7 Conformance requirement

The partition is a compile-time classification, so conformance asserts it
**directly**: all bindings MUST agree on (a) **every node's class**, (b) the
**set of materialization points** (and the empty/non-empty status of the hot
tree and per-event handler), and (c) the **byte-identical `CONST`-folded
buffers** (ties to §5.5 — the same canonical-JSON discipline). The §5.2
tolerances do not apply.

Three fixtures under `tests/valid/cadence/`, each carrying an `expect_cadence`
assertion on every meaningful node, fix the contract:

| Fixture | Profile | Exercises |
|---|---|---|
| `mixed_stencil.esm` | all three classes, both thresholds | the gather split `index(u, index(nbr,i,k))`; `CONST` topology fold (`nbr_idx`, `coeff`) + `DISCRETE` per-event materialization (`Kdiff`) + `CONTINUOUS` hot contraction |
| `pure_topology.esm` | all `CONST`, **empty hot tree** | the edge-enumeration FAQ folds entirely into the artifact — nothing per-step (reuses the §5.5 `edge_enumeration` golden) |
| `pure_pointwise.esm` | all `CONTINUOUS`, **empty handler**, no materialization | the analytic continuous-`t` forcing `sin(omega·t)` stays `CONTINUOUS`; `CONST` scalars inline as literals, not buffers |

The golden lives in `tests/conformance/cadence/manifest.json` (per fixture: the
class summary, the materialization-point set, and the `CONST`-fold inputs +
expected byte-serialized buffers). Like the §5.5 determinism contract, the
harness runs in two layers:

- **The reference layer** (`--self-test`, always on):
  `scripts/run-cadence-conformance.py --self-test` asserts the contract against
  an embedded **reference classifier + folder** (the §5.7 rules as code) — class
  agreement (reference == `expect_cadence` == golden), the materialization set
  and hot-tree/handler emptiness, byte-identical `CONST` folds, and negative
  controls (a wrong `expect_cadence`, a `CONTINUOUS` relational node, a
  `from_faq` cycle, a float topology key). Wired into
  `scripts/test-conformance.sh`.
- **The per-binding producer layer** (live — `ess-my4.3.7` Julia, `ess-my4.3.8`
  Rust, `ess-my4.3.9` Python partition passes have landed): each binding ships a
  thin adapter (discovered via `$EARTHSCI_CADENCE_ADAPTER_<BINDING>` or on
  `PATH`); the runner asserts every adapter's class map, materialization set, and
  folded buffers byte-identical to the golden and to each other. The three are
  `bindings_required`, so a missing or mismatching producer fails the gate;
  `test-conformance.sh` drives all three. See
  `tests/conformance/cadence/README.md` for the adapter contract.

Guard 2 (no relational engine on the hot path) is additionally pinned by the
committed fixture `tests/invalid/aggregate/continuous_relational_node.esm` — a
schema-valid document (accepted by Go / TypeScript, marked `resolver_only`) whose
state-dependent `distinct` classifies `CONTINUOUS` and is rejected by the
partition pass in all three evaluators.

### 5.8 Conservative-Regridding Geometry Tolerance Contract (normative)

> This is the normative form of RFC `semiring-faq-unified-ir` §8.1 and
> Appendix B (especially **B.5**). It is the deliberate **inverse** of the
> byte-identity contracts in §5.5–§5.7: the M4 conservative-regridding geometry
> kernel — the `intersect_polygon` leaf, the `polygon_area` FAQ built on it, and
> the regridding weights `W_ij` — is the **one** place where floating-point
> polygon clipping makes bit-for-bit cross-binding identity *unachievable*, so
> its conformance is **tolerance-based**. The rules below are the contract; the
> M4 conformance gate (`ess-my4.4.8`) and the per-binding kernels (`ess-my4.4.3`
> Julia, `ess-my4.4.4` Python, `ess-my4.4.11`/`.12` Rust) implement them.

**Why geometry is the exception.** The relational engine (§5.5) is made
byte-identical by sorting integer tuples; that lever does not exist here.
`intersect_polygon` produces a **floating-point area from polygon clipping**, and
FP clipping is irreducibly implementation-dependent — intersection ordering,
area-summation order, robust-predicate strategy, and snapping all differ between
independent spherical-geometry stacks (Julia → GeometryOps.jl, Python →
spherely/S2, Rust → an S2 FFI binding). Bit-identity across them is **not
pursued** (no shared C++ core, no compute-once-and-serialize): each binding uses
its language's best native stack and cross-binding conformance is tolerance-based
(RFC §B.1).

**Governing principle.** Conservation of the *physics* is the contract, not
agreement on the *geometry*. Conformance has **two exact anchors** and **one
tolerance band**:

1. **Exact (combinatorial).** The **candidate overlap-pair index set** — the
   broad-phase spatial join, expressed as a **bin-Skolem equi-join on integer
   spatial-bin keys** — is **byte-identical** across bindings, governed by the
   §5.5 determinism contract.
2. **Exact (physical invariants).** Global **conservation** and
   **partition-of-unity** are the **primary** gate (§5.8.3).
3. **Tolerance (geometry).** Per-pair overlap **areas** `A_ij` and the **weights**
   `W_ij` built from them satisfy a combined relative + absolute tolerance with a
   **sliver floor** (§5.8.2).

The §5.2 display / graph / simulation tolerances are about *cosmetic and
numerical formatting*; they neither apply to nor substitute for the geometry
tolerance defined here.

#### 5.8.1 What is exact and what is tolerance-based

| Output | Conformance mode | Governed by |
|---|---|---|
| candidate overlap-pair set `{(i, j)}` (bin-Skolem spatial join) | **byte-identical** (integer keys) | §5.5 determinism contract |
| `manifold` flag (`planar` / `spherical` / `geodesic`) | **exact** match — compare same-manifold only | §5.8.4 |
| global conservation `Σ_j A_j·F_tgt[j] = Σ_i A_i·F_src[i]` | invariant gate (tight tol) | §5.8.3 |
| partition-of-unity `Σ_i W_ij = 1` | **exact by construction** | §5.8.3 |
| per-pair overlap area `A_ij`, weight `W_ij` | rel + abs tolerance + sliver floor | §5.8.2 |

This is the §8.1 split made testable: the clip's **combinatorial** structure
(*which* pairs are candidates) is integer and deterministic; only its
**geometric** result (the *area* of each overlap) is floating point.

#### 5.8.2 Area / weight tolerance and the sliver floor

Per overlap area, the conformance test is a **combined relative + absolute
tolerance** against the reference binding:

```
|A_x − A_ref| ≤ atol + rtol·A_ref
```

- `atol ≈ 1e-15·R²` (R = sphere radius / characteristic length) is a real
  **sliver floor**, not a formality. Near-tangent overlaps are the regime where
  two clippers legitimately disagree on whether a tiny intersection even
  *exists*; `atol` absorbs that. **Sub-`atol` areas are treated as
  equal-to-zero** — "present-but-tiny" and "absent" **both pass**. This snapping /
  tie-break regime MUST NOT fail conformance, and it does not affect weights.
- `rtol` is **empirically calibrated** and MUST accommodate the **loosest binding
  pair**. Python and Rust share the **same S2 core** and agree to a much tighter
  `rtol` than either agrees with Julia/GeometryOps; the spec tolerance is set by
  the GeometryOps-vs-S2 pair, never the S2-vs-S2 pair.

Per-pair area equality is **secondary**: it is precisely the unstable sliver
regime, which is why the primary gate is the invariants (§5.8.3), not per-pair
agreement.

#### 5.8.3 The primary gate: physical invariants

The **primary** cross-binding conformance test is the pair of physical
invariants, not per-pair `A_ij` agreement:

1. **Global conservation.** `Σ_j A_j·F_tgt[j] = Σ_i A_i·F_src[i]` for the
   regridded field — the remap neither creates nor destroys mass.
2. **Partition-of-unity.** `Σ_i W_ij = 1` for every target cell `j`. This holds
   **by construction**: the weights are normalized by `dst_areas = Σ_i A_ij` — the
   **row-sum of the *computed* overlap areas**, not the *true* target-cell area
   (`ConservativeRegridding.jl`'s construction). Partition-of-unity is therefore
   exact *regardless of edge-model error*, and every binding that follows the
   construction satisfies it identically.

A subtlety the precedent surfaces: first-order conservation is exact only if
computed cell areas equal true areas, which great-circle-edge approximations
violate; established tools restore exact conservation with a **post-hoc
area / global-mean correction**, and the residual shrinks with resolution. So the
**conservation tolerance is application-set and resolution-dependent, not a fixed
epsilon** — partition-of-unity-by-construction is the part that is exact
everywhere.

#### 5.8.4 Manifold declaration

The geometry interpretation is part of the op's contract: `intersect_polygon`
carries a **`manifold` flag** — `planar`, `spherical`, or `geodesic`
(`esm-schema.json`; additive schema in `ess-my4.4.2`) — matching
`ConservativeRegridding.jl`'s `Manifold`. **Two bindings may be compared only
under the same declared manifold.** The clip must be done on the sphere (a flat
lat-lon plane is wrong at the poles and the antimeridian). Because GeometryOps
(Julia) and S2 (Python, Rust) share the **great-circle-edge** assumption, the
three bindings share the *same geometric model* — their residual differences are
floating-point, not modelling, which is what keeps the §5.8.2 tolerances small. A
lat-lon edge along a parallel is a *small circle*, not a great circle, so coarse
polar cells carry a real edge-model error (RFC §B.4); the contract offers an
**opt-in** densification — `densify_parallel_edges(ring, max_segment_deg)` in the
per-binding kernels, subdividing each parallel edge into short great-circle
segments — where polar accuracy matters. It is **off by default**, so the
great-circle-edge behaviour (and every existing conformance result) is unchanged
unless a producer requests it.

#### 5.8.5 The byte-identical candidate set

Even though areas are tolerance-based, the **candidate overlap-pair set is not**.
The broad phase of the spatial (θ-) join is expressed as a **bin-Skolem
equi-join**: each cell is assigned an **integer** spatial-bin key, and the
candidate pairs are the equi-join of source and target cells sharing a bin. That
key set is a relational index set over **integer** keys, so it falls squarely
under the §5.5 determinism contract — sorted total order, no floats in keys, no
native-hash iteration order — and MUST be **byte-identical** across bindings
(reusing the M3 determinism machinery; the overlap-join idiom is the worked
fixture `tests/valid/geometry/conservative_regrid_overlap_join.esm`, bead
`ess-my4.4.5`, which composes the broad-phase join with the `A_ij → A_j →
apply → normalize` assembly and makes the candidate-vs-surviving boundary
explicit — the `join.on` produces this byte-identical candidate set, a
`filter: A_ij > atol` produces the tolerance-dependent surviving-overlap set).

Two consequences are load-bearing:

- **No FP comparison in the broad phase.** The bin key MUST be integer and
  reproducibly derived (e.g. from the cells' own integer grid indices, or an
  exactly-defined integer quantization), **never** a raw floating-point
  coordinate comparison — otherwise a cell near a bin boundary could be bucketed
  differently per binding and the candidate set would diverge. Floating-point
  coordinates enter **only** the narrow-phase area (§5.8.2).
- **Candidate set ≠ surviving-overlap set.** The byte-identity guarantee is on the
  *candidate* set (broad phase). After clipping, *which* candidates have a
  **nonzero** overlap MAY differ between bindings in the sliver regime — that is
  expected and **passes**, because sub-`atol` areas are equal-to-zero (§5.8.2).

#### 5.8.6 Conformance requirement

The M4 conformance gate (`ess-my4.4.8`) feeds **identical** mesh inputs to every
producing binding under a **declared manifold** and asserts, in priority order:

1. **Candidate set** — byte-identical bin-Skolem candidate overlap-pair index set
   across bindings (§5.8.5; the §5.5 harness machinery applies verbatim,
   including the adversarial **permuted-input-order** variant, which MUST collapse
   to the identical candidate set).
2. **Invariants** — global conservation within the application / resolution
   tolerance, and partition-of-unity `Σ_i W_ij = 1` to a tight epsilon (exact by
   construction, §5.8.3).
3. **Per-pair areas / weights** — within `atol + rtol·A_ref`, with sub-`atol`
   slivers treated as zero (§5.8.2).

Adversarial inputs target the geometry failure modes specifically: **near-tangent
slivers** (must pass via the floor), **antimeridian- and pole-crossing cells**
(must be clipped on the sphere, not the plane), and **permuted input order** (the
candidate set must stay byte-identical). The §5.8 contract is asserted by the
harness **self-test** (against the embedded reference + golden, including the
permuted and negative-control variants) together with the per-binding broad-phase
+ `polygon_area`-FAQ suites and the reference-binding `.esm`-through-evaluator test
(below); the earlier per-binding producer adapters were retired (`ess-3lj.3`). The
golden inputs live under `tests/conformance/geometry/`, the tolerance-mode analogue
of `tests/conformance/determinism/` (§5.5.4). Unlike the determinism and cadence
gates, the assertion is **tolerance + invariant** on areas / weights and
**byte-identity** only on the integer candidate index set.

The conservative regridder is realized as a **single end-to-end-evaluable
document**, `tests/valid/geometry/conservative_regrid_overlap_join.esm` (bead
ess-3lj.3), rather than an imperative per-binding assembly. The document composes
the whole A.8 pipeline — broad-phase bin-Skolem candidate join (the value-invention
front-door, §5.5 / RFC §6.1) → `A_ij` `intersect_polygon` clip + `polygon_area`
FAQ → `A_j` row-sum → apply → normalize — and is driven through the evaluator. The
reference binding (**Julia**) evaluates it end-to-end and asserts the conservation
+ partition-of-unity invariants and the spherical Van Oosterom–Strackee /
analytic-rectangle oracle values in
`packages/EarthSciSerialization.jl/test/geometry_overlap_join_conformance_test.jl`.
The two cross-binding building blocks run in every evaluating binding: the
**broad-phase candidate set** is materialized by the value-invention front-door
(`materialize_value_invention`, Julia/Python/Rust, §5.5) and the **`polygon_area`
FAQ** is the executable area path (`area_faq`'s `polygon_area_via_faq` /
`polygon_area_faq`, Julia/Python/Rust, bead ess-d4g.1). **Go / TypeScript** schema-
and structurally validate the document (no evaluator / polygon clip — §5.8 N/A per
the table above).

The earlier imperative producing-binding assemblies (`conservative_regrid.jl` /
`regrid.rs` / `conservative_regrid.py`, `build_regridder` / `Regridder`, beads
ess-my4.4.6 / .4.7 / .4.12) and their §5.8.6 cross-binding adapters were **retired**
with this consolidation. The harness `scripts/run-geometry-conformance.py` still
guards the §5.8 candidate-set / invariant / area contract against its embedded
reference + static golden via `--self-test`.

### 5.9 Cross-Language PDE-Simulation Conformance (normative)

The byte-identity contracts §5.5–§5.7 govern the **rewrite/IR** half of the
pipeline. This section governs the **simulation** half: the three
PDE-simulation-capable bindings — **Julia (reference), Python, Rust** — must
agree, on a **numeric-tolerance** basis, when they evaluate and integrate shared
**pre-discretized method-of-lines** fixtures (`tests/conformance/pde_simulation/`,
driven by `scripts/run-pde-simulation-conformance.py`; bead ess-fmw).

Go and TypeScript are **out of scope** — they implement only the rewrite half
(no `makearray`/spatial lowering, no simulator).

#### 5.9.1 What is compared

For each fixture, every in-scope binding reports two quantities through a thin
adapter (`$EARTHSCI_PDE_SIM_ADAPTER_<BINDING>`), keyed by bare column-major
element name (`u[1]`, `u[i,j]`):

1. **Discretized RHS** `f(u, t)` at each declared probe state — pure arithmetic
   over the same `makearray` stencil, so it must agree to a **tight** tolerance
   both across bindings (vs the Julia golden) and against an **independent**
   analytic anchor `L u + b` assembled directly from the operator matrix.
2. **Integrated trajectory** to the declared horizon with the binding's
   integrator **pinned in the manifest** — compared (a) across bindings vs the
   Julia golden at a moderate tolerance and (b) vs the exact matrix-exponential /
   manufactured solution `expm(L t)·u0 + φ(t)·b` at a looser tolerance that
   absorbs integrator truncation.

| Band | rtol | atol |
|------|------|------|
| RHS (vs golden and vs `L u + b`) | 1e-9 | 1e-11 |
| Trajectory vs Julia golden (cross-binding) | 1e-6 | 1e-9 |
| Trajectory vs `expm(L t)` (manufactured) | 1e-4 | 1e-6 |

#### 5.9.2 ⛔ Numeric-tolerance, NOT byte-identical

Trajectories are floating-point evaluation; they legitimately differ in the last
bits across language math libraries and integrators. Byte-identity MUST NOT be
asserted on simulation output. The integrator algorithm + step controls are
pinned per binding in `manifest.json` (`integrators`) so the comparison is
apples-to-apples; the tolerances are documented there (`tolerances`) and above.

#### 5.9.3 Coverage

Fixtures exercise 1-D diffusion, 2-D diffusion, and 1-D advection across all five
BC kinds (`dirichlet`, `neumann`, `zero_gradient`, `robin`, `periodic`) with the
BC ghost cells lowered to single-cell `makearray` regions, plus one operator at
two grid sizes (the no-scalarization / shape-generality property the Rust and
Python vectorized evaluators must hold).

#### 5.9.4 Gate

`scripts/run-pde-simulation-conformance.py --self-test` is the always-on
regression guard: it asserts the committed Julia golden reproduces the
independent analytic anchors and that the harness rejects perturbed output (no
live bindings required). The producer mode (run from `test-conformance.sh` for
Julia/Python/Rust) re-runs each binding and gates it against the golden +
analytic anchors, **failing loudly** (non-zero exit) on any divergence beyond
tolerance. This is the capstone that proves the Julia/Python/Rust PDE simulators
agree.

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