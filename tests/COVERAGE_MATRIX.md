# ESM Format Test Coverage Matrix

This document maps ESM format specifications to test fixtures to ensure complete validation coverage.

## ESM Format Specification Coverage

| Section | Specification | Test Fixture Status | Location |
|---------|---------------|-------------------|----------|
| 1. Overview | Format version, MIME type | ✅ Created | `valid/minimal_chemistry.esm` |
| 2. Top-Level Structure | All 8 required fields | ✅ Created | `valid/minimal_chemistry.esm` |
| 3. Metadata | Authors, license, created, etc. | ❌ Missing | **GAP**: Need `metadata_complete.esm` |
| 4. Expression AST | All operators, numbers, strings | ✅ Partial | `display/expr_precedence.json` (18 cases) |
| 4.2 Built-in Operators | All 30+ operators | ✅ Created | `display/all_operators.json` (35+ cases) |
| 4.3 Scoped References | Hierarchical dot notation | ✅ Created | `scoping/hierarchical_scoped_references.esm` |
| 5. Events | Continuous and discrete | ✅ Created | `events/continuous_events.esm`, `events/discrete_events.esm` |
| 5.2 Continuous Events | Root-finding, affect_neg | ✅ Created | `events/continuous_events.esm` (bouncing_ball) |
| 5.3 Discrete Events | All trigger types | ✅ Created | `events/discrete_events.esm` (periodic/preset) |
| 5.6 Cross-System Events | Multi-system events | ✅ Created | `events/cross_system_events.esm` |
| 6. Models (ODE Systems) | Variables, equations, events | ✅ Created | `valid/minimal_chemistry.esm` |
| 7. Reaction Systems | Species, reactions, mass action | ✅ Created | `valid/minimal_chemistry.esm` |
| 8. Data Loaders | By reference, provides vars | ✅ Created | `valid/minimal_chemistry.esm` |
| 9. Operators | By reference, needed_vars | ❌ Missing | **GAP**: Need operator fixtures |
| 10. Coupling | All 6 coupling types | ✅ Created | `coupling/` (couple, operator_apply, callback) |
| 11. Domain | Temporal, spatial, BCs, ICs | ❌ Partial | Basic spatial in minimal_chemistry.esm |
| 12. Solver | All 3 solver strategies | ❌ Partial | Only strang_threads in minimal_chemistry.esm |
| 13. Complete Example | MinimalChemAdvection | ✅ Created | `valid/minimal_chemistry.esm` |

**Coverage: 11/15 Complete, 4/15 Partial, 0/15 Missing**

## Libraries Specification Coverage

### Capability Tiers

| Tier | Capability | TypeScript | Python | Rust | Julia | Go | Test Coverage |
|------|------------|------------|--------|------|-------|----|----- ---|
| **Core** | Parse/serialize | Required | Required | Required | Required | Required | ✅ Round-trip tests |
| **Core** | Schema validation | Required | Required | Required | Required | Required | ✅ Invalid file tests |
| **Core** | Pretty-print | Required | Required | Required | Required | Required | ✅ Display format tests |
| **Core** | Substitute | Required | Required | Required | Required | Required | ✅ Substitution tests |
| **Analysis** | Unit checking | Required | Required | Required | Required | Optional | ❌ Missing unit test fixtures |
| **Analysis** | Derive ODEs | Required | Required | Required | Required | Optional | ✅ Created `expected_trajectories/ode_derivation_examples.json` |
| **Analysis** | Stoich matrix | Required | Required | Required | Required | Optional | ✅ Created (included in ODE examples) |
| **Analysis** | System graphs | Required | Required | Required | Required | Required | ✅ Partial (1 case) |
| **Analysis** | Expression graphs | Required | Required | Required | Required | Required | ✅ `conformance/graph/cases.json` (generated; driven by all five bindings) |
| **Interactive** | Click-to-edit | SolidJS | — | — | — | — | ❌ Missing interaction fixtures |
| **Interactive** | Structural editing | SolidJS | — | — | — | — | ❌ Missing |
| **Interactive** | Coupling graph | SolidJS | — | — | — | — | ❌ Missing |
| **Simulation** | ODE solving | — | Required | — | Required | — | ❌ Missing simulation fixtures |
| **Simulation** | Event handling | — | Required | — | Required | — | ❌ Missing |
| **Full** | MTK conversion | — | — | — | Required | — | ❌ Missing |
| **Full** | Coupled systems | — | — | — | Required | — | ❌ Missing |

### Validation Error Code Coverage

Based on libraries spec Section 3.4:

| Error Code | Test Fixture | Status |
|------------|-------------|--------|
| `equation_count_mismatch` | `invalid/equation_count_mismatch.esm` | ✅ Created |
| `undefined_variable` | `invalid/unknown_variable_ref.esm` | ✅ Created |
| `undefined_species` | `invalid/undefined_species.esm` | ✅ Created |
| `undefined_parameter` | `invalid/undefined_parameter.esm` | ✅ Created |
| `undefined_system` | `invalid/unresolved_scoped_ref.esm` | ✅ Created |
| `undefined_operator` | N/A | ❌ Missing |
| `unresolved_scoped_ref` | `invalid/unresolved_scoped_ref.esm` | ✅ Created |
| `invalid_discrete_param` | N/A | ❌ Missing |
| `null_reaction` | `invalid/null_reaction.esm` | ✅ Created |
| `equation_count_mismatch` (unknown with no defining equation) | `invalid/unknown_without_equation.esm` | ✅ Created |
| `event_var_undeclared` | `invalid/event_var_undeclared.esm` | ✅ Created |

**Error Code Coverage: 7/11 Created, 4/11 Missing**

## Critical Gaps Analysis

### High Priority Missing (Blocks Phase 1)

1. **Operator Coverage** (Section 4.2): Missing test fixtures for:
   - `div`, `laplacian` (spatial operators)
   - `and`, `or`, `not` (logical operators)
   - `atan2`, `min`, `max`, `floor`, `ceil` (functions)

2. **Coupling Types** (Section 10): Only 2/6 coupling types tested:
   - ❌ `couple` with connector equations
   - ❌ `operator_apply`
   - ❌ `callback`
   - ❌ `event` (cross-system)

3. **Event System** (Section 5): No event test fixtures created
   - ❌ Continuous events with affect_neg
   - ❌ Discrete events (periodic, preset_times)
   - ❌ Event ordering and synchronization

4. **Scoped References** (Section 4.3): No hierarchical resolution tests
   - ❌ Multi-level nesting (A.B.C.variable)
   - ❌ Subsystem variable resolution
   - ❌ Scoped reference error cases

### Medium Priority Missing (Blocks Phase 2)

1. **Graph Generation**: Only 1 system graph test case
   - ❌ Expression graphs (variable-level dependencies)
   - ❌ Complex coupling scenarios
   - ❌ DOT/Mermaid export format validation

2. **Mathematical Correctness**: No verification fixtures
   - ❌ Mass conservation in reactions
   - ❌ ODE derivation correctness
   - ❌ Stoichiometric matrix rank analysis

3. **Unit & Dimensional Analysis**: No unit test fixtures
   - ❌ Unit propagation through expressions
   - ❌ Conversion factor validation
   - ❌ Dimensional inconsistency detection

### Low Priority Missing (Phase 3+)

1. **Performance & Scalability**: No stress test fixtures
   - ❌ Large reaction networks (100+ species)
   - ❌ Deep coupling chains
   - ❌ Memory and parse time benchmarks

2. **Security & Robustness**: No malicious input fixtures
   - ❌ JSON bombing attacks
   - ❌ Circular reference detection
   - ❌ Malformed input handling

## Recommendations

### Immediate Actions (Fix Phase 1 Blockers)

1. **Create Complete Operator Test Suite**
   ```
   tests/display/all_operators.json  # All 30+ operators with examples
   ```

2. **Create Coupling Test Suite**
   ```
   tests/coupling/couple_examples.esm        # Connector equations
   tests/coupling/operator_apply_examples.esm  # Runtime operators
   tests/coupling/callback_examples.esm        # Simulation callbacks
   ```

3. **Create Event Test Suite**
   ```
   tests/events/continuous_events.esm  # Root-finding, affect_neg
   tests/events/discrete_events.esm    # All trigger types
   tests/events/cross_system_events.esm # Multi-system events
   ```

4. **Create Scoped Reference Test Suite**
   ```
   tests/scoping/nested_subsystems.esm     # A.B.C.variable resolution
   tests/scoping/scoped_coupling.esm       # Cross-system references
   tests/invalid/scoped_ref_errors.esm     # Invalid reference patterns
   ```

### Progress Tracking

**Current Status**: 13/39 test fixture categories completed (33%)

**Phase 1 Requirements**: Core + Analysis tiers = 22 fixture categories needed
**Currently Available**: 13 categories
**Still Needed**: 9 categories for Phase 1 completion

**Critical Path**:
1. Complete operator test suite (1 week)
2. Complete coupling test suite (1 week)
3. Complete event test suite (1 week)
4. Complete scoped reference test suite (3 days)

**Estimated Time to Phase 1 Test Coverage**: 3.5 weeks