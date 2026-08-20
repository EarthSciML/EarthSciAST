# ESM Format Conformance Test Suite

This directory contains the language-independent test suite for ESM format implementations. All libraries must pass these tests to ensure consistent behavior across languages.

## Directory Structure

```
tests/
├── valid/                    # Valid ESM files for round-trip testing
│   ├── minimal_chemistry.esm # Baseline test - all libraries must parse this
│   ├── full_coupled.esm      # TODO: Complete file with all sections
│   └── events_all_types.esm  # TODO: All event variants
├── events/                   # Event system test fixtures
│   ├── comprehensive_events.esm # Basic event system functionality
│   ├── event_system_edge_cases.esm # Advanced edge cases: ordering, boundaries, scoping, chains
│   └── event_timing_synchronization.esm # Timing precision, race conditions, synchronization
├── invalid/                  # Invalid ESM files for validation testing
│   ├── expected_errors.json  # Expected validation errors for each invalid file
│   ├── event_expected_errors.json # Expected validation errors for event system edge cases
│   ├── missing_esm_version.esm
│   ├── unknown_variable_ref.esm
│   ├── equation_count_mismatch.esm
│   ├── undefined_species.esm
│   ├── undefined_parameter.esm
│   ├── null_reaction.esm
│   ├── unknown_without_equation.esm
│   ├── unresolved_scoped_ref.esm
│   ├── event_var_undeclared.esm
│   └── event_error_conditions.esm # Invalid event configurations for error testing
├── display/                  # Expected pretty-printing outputs
│   ├── expr_precedence.json  # Expression → Unicode/LaTeX/ASCII
│   ├── chemical_subscripts.json # Basic chemical species formatting test cases
│   ├── chemical_subscripts_comprehensive.json # Comprehensive chemical species formatting (all elements, complex formulas, edge cases)
│   ├── chemical_subscripts_edge_cases.json # Additional edge cases and negative test cases
│   └── model_summary.json
├── substitution/             # Expression substitution tests
│   └── simple_var_replace.json
├── graphs/                   # Graph generation tests
│   ├── system_graph.json    # Component-level graphs
│   ├── expression_graph.json # TODO: Variable-level graphs
│   └── expected_dot/         # TODO: Expected DOT format outputs
└── simulation/               # TODO: Reference trajectories
    ├── box_model_ozone.esm
    └── expected/
```

## Test Categories

### Core Functionality
- **Parse/Serialize**: All valid files must round-trip identically
- **Schema Validation**: All invalid files must produce expected schema errors
- **Structural Validation**: Invalid files must produce expected structural error codes

### Display Formats
- **Unicode**: Chemical subscripts, mathematical notation, operator precedence
- **LaTeX**: Proper mathematical typesetting
- **ASCII**: Fallback plain-text representation
- **Model Summary**: Structured overview of entire ESM files

### Expression Engine
- **Substitution**: Variable replacement in expressions
- **Evaluation**: Numerical evaluation with variable bindings
- **Pretty-printing**: Consistent formatting across languages

### Graph Generation
- **System Graph**: Component-level coupling visualization
- **Expression Graph**: Variable dependency analysis
- **Export Formats**: DOT, Mermaid, JSON adjacency lists

### Data Loaders and Operators (ESM Spec Sections 8-9)
- **Valid Fixtures**: Comprehensive test cases covering data loader kinds (`grid`, `points`, `static`) and operator configurations
- **Schema Validation**: Tests for missing required fields (`kind`, `source`, `variables`, `operator_id`, `needed_vars`)
- **Source & Temporal Validation**: Tests for missing `url_template`, malformed ISO 8601 durations, and invalid `records_per_file` values
- **Spatial Validation**: Tests for missing `crs`/`grid_type`, invalid `grid_type` enum values, and invalid staggering values
- **Variable Validation**: Tests for missing `file_variable` and `units` in the loader's `variables` map

## Error Codes Tested

Based on libraries specification Section 3.4:

- `equation_count_mismatch`: State variables vs ODE equations
- `undefined_variable`: Equation references undeclared variable
- `undefined_species`: Reaction references undeclared species
- `undefined_parameter`: Rate expression references undeclared parameter
- `undefined_system`: Coupling references nonexistent system
- `unresolved_scoped_ref`: Invalid scoped reference path
- `null_reaction`: Reaction with both null substrates and products
- `equation_count_mismatch`: unknowns and equations do not balance (esm-spec §4.9.4) — including an unknown with no defining equation, which 0.x reported as the now-removed `missing_observed_expr`
- `event_var_undeclared`: Event affects undeclared variable

## Conformance Requirements

1. **Baseline Test**: All libraries must parse `minimal_chemistry.esm`
2. **Round-Trip**: `load(save(load(file))) == load(file)` for all valid files
3. **Validation Consistency**: Same error codes for same invalid files across languages
4. **Display Consistency**: Identical Unicode/LaTeX output for same expressions
5. **Graph Consistency**: Same nodes/edges for system and expression graphs

## Usage

Each language library should implement tests that:

1. Load all files in `valid/` and verify they parse successfully
2. Load all files in `invalid/` and verify they produce the expected errors from `expected_errors.json`
3. Test pretty-printing by comparing outputs to `display/` fixtures
4. Test substitution using `substitution/` fixtures
5. Test graph generation using `graphs/` fixtures

## Status

**Created**: February 2026
**Coverage**:
- ✅ Baseline directory structure
- ✅ Schema validation errors (3 cases)
- ✅ Structural validation errors (7 cases + 9 event system error cases)
- ✅ Display format fixtures (18 expression cases, 18 basic + 150+ comprehensive chemical subscript cases)
- ✅ Substitution fixtures (8 cases)
- ✅ System graph fixtures (1 case)
- ✅ Event system fixtures (3 comprehensive files: basic functionality, edge cases, timing/synchronization)
- ✅ Data loader and operator fixtures (2 comprehensive valid files + 13 invalid error cases)
- ❌ Full coupled system fixtures (TODO)
- ❌ Expression graph fixtures (TODO)
- ❌ Simulation reference trajectories (TODO)