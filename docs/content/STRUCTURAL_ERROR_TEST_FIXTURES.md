# Structural Error Test Fixtures

This document describes the test fixtures for each structural validation error code defined in the ESM format specification. Each test case demonstrates a specific error condition with clear documentation of the triggering conditions.

## Error Code Coverage

The following structural error codes are covered by test fixtures in `/tests/invalid/`:

### 1. equation_count_mismatch

**Error Code**: `equation_count_mismatch`

**Description**: Occurs when the number of ODE equations does not match the number of state variables in a model.

**Test Fixtures**:
- `equation_count_mismatch.esm` - Two state variables but only one ODE equation
- `equation_count_mismatch_too_many_vars.esm` - Three state variables but only one equation
- `equation_count_mismatch_too_many_equations.esm` - One state variable but two equations

**Triggering Conditions**:
- State variables without corresponding differential equations
- Extra equations that don't correspond to state variables
- Mismatch between `variables` with `type: "state"` and number of ODE equations

### 2. undefined_variable

**Error Code**: `undefined_variable`

**Description**: Occurs when an equation references a variable that is not declared in the model's variables section.

**Test Fixtures**:
- `unknown_variable_ref.esm` - Generic undefined variable reference
- `undefined_variable_in_rhs.esm` - Undefined variable in equation right-hand side
- `undefined_variable_in_nested_expr.esm` - Undefined variable in nested expression

**Triggering Conditions**:
- Variable referenced in equation that doesn't exist in `variables` section
- Typos in variable names
- Missing variable declarations

### 3. undefined_species

**Error Code**: `undefined_species`

**Description**: Occurs when a reaction references a species that is not declared in the reaction system's species section.

**Test Fixtures**:
- `undefined_species.esm` - Generic undefined species in reaction
- `undefined_species_in_substrates.esm` - Undefined species in reaction substrates
- `undefined_species_in_products.esm` - Undefined species in reaction products

**Triggering Conditions**:
- Species referenced in reaction substrates/products not declared in `species` section
- Typos in species names
- Missing species declarations

### 4. undefined_parameter

**Error Code**: `undefined_parameter`

**Description**: Occurs when a rate expression references a parameter that is not declared in the reaction system's parameters section.

**Test Fixtures**:
- `undefined_parameter.esm` - Generic undefined parameter in rate expression
- `undefined_parameter_simple_rate.esm` - Simple rate expression with undefined parameter
- `undefined_parameter_complex_rate.esm` - Complex rate expression with undefined parameter

**Triggering Conditions**:
- Parameter referenced in `rate` field not declared in `parameters` section
- Typos in parameter names
- Missing parameter declarations

### 5. undefined_system

**Error Code**: `undefined_system`

**Description**: Occurs when a coupling entry references a system (model, reaction_system, data_loader, or operator) that doesn't exist.

**Test Fixtures**:
- `undefined_system.esm` - Coupling references nonexistent system

**Triggering Conditions**:
- Coupling `variable_map` or `operator_apply` references system not declared
- System referenced in scoped references that doesn't exist
- Typos in system names

### 6. undefined_operator

**Error Code**: `undefined_operator`

**Description**: Occurs when an operator_apply coupling references an operator that is not declared.

**Test Fixtures**:
- `undefined_operator.esm` - Generic undefined operator reference
- `undefined_operator_in_apply.esm` - Undefined operator in operator_apply coupling

**Triggering Conditions**:
- Operator referenced in `operator_apply` not declared in `operators` section
- Typos in operator names
- Missing operator declarations

### 7. unresolved_scoped_ref

**Error Code**: `unresolved_scoped_ref`

**Description**: Occurs when a scoped reference (e.g., "System.variable") cannot be resolved to an actual variable in the referenced system.

**Test Fixtures**:
- `unresolved_scoped_ref.esm` - Generic unresolved scoped reference
- `unresolved_scoped_ref_missing_system.esm` - Scoped reference to missing system
- `unresolved_scoped_ref_missing_variable.esm` - Scoped reference to missing variable in existing system

**Triggering Conditions**:
- Scoped reference format "System.variable" where System doesn't exist
- Scoped reference where System exists but variable doesn't
- Complex nested scoped references that can't be resolved

### 8. invalid_discrete_param

**Error Code**: `invalid_discrete_param`

**Description**: Occurs when a discrete event references a parameter that is not actually declared as a parameter type.

**Test Fixtures**:
- `invalid_discrete_param.esm` - Discrete event references undefined parameter
- `invalid_discrete_param_not_parameter.esm` - Discrete event references state variable instead of parameter

**Triggering Conditions**:
- Discrete event `discrete_updates` references variable not declared as parameter
- Discrete event tries to update a state variable (should be parameter)
- Parameter referenced doesn't exist at all

### 9. null_reaction

**Error Code**: `null_reaction`

**Description**: Occurs when a reaction has both null substrates and null products (no reactants and no products).

**Test Fixtures**:
- `null_reaction.esm` - Reaction with both substrates and products as null
- `null_reaction_explicit_nulls.esm` - Explicit null values for substrates and products

**Triggering Conditions**:
- Reaction with `"substrates": null` and `"products": null`
- Reaction with empty or missing substrates and products arrays
- Invalid chemical reaction that doesn't consume or produce anything

### 10. missing_observed_expr

**Error Code**: `missing_observed_expr`

**Description**: Occurs when a variable is declared with type "observed" but is missing its required expression field.

**Test Fixtures**:
- `missing_observed_expr.esm` - Single observed variable without expression
- `missing_observed_expr_single.esm` - Another single case variant
- `missing_observed_expr_multiple.esm` - Multiple observed variables without expressions

**Triggering Conditions**:
- Variable with `"type": "observed"` missing `"expression"` field
- Observed variable with null or empty expression
- Required field omitted for observed variable type

### 11. event_var_undeclared

**Error Code**: `event_var_undeclared`

**Description**: Occurs when an event (continuous or discrete) references variables that are not declared in the model.

**Test Fixtures**:
- `event_var_undeclared.esm` - Generic event with undeclared variable
- `event_var_undeclared_condition.esm` - Undefined variable in event condition
- `event_var_undeclared_affects.esm` - Undefined variable in event affects

**Triggering Conditions**:
- Event condition references undeclared variable
- Event affects/discrete_updates references undeclared variable
- Variables in event expressions not found in model variables

## Comprehensive Error Coverage

**Test Fixtures**:
- `multiple_errors_combined.esm` - File with multiple different error types
- `complete_error_coverage.esm` - Comprehensive test covering all error codes

These fixtures demonstrate multiple error conditions in a single file, useful for testing error reporting and ensuring validators can detect multiple issues simultaneously.

## Usage in Test Suites

### Python Tests
Located in `pkg/earthsci-ast-py/tests/test_validate_structural.py`, these tests load fixtures and verify that structural validation correctly identifies the expected error codes.

### Julia Tests
Located in `pkg/EarthSciAST.jl/test/structural_validation_test.jl`, these tests create programmatic examples of each error condition and verify the Julia implementation detects them.

### Rust Tests
Located in `pkg/earthsci-ast-rs/tests/structural_validation.rs`, these tests load the fixture files and verify the Rust implementation correctly identifies each error code.

### Expected Results
The `tests/invalid/expected_errors.json` file documents the exact expected validation results for each fixture, including:
- Error codes
- Error messages
- Error paths/locations
- Additional details for debugging

## Adding New Error Conditions

When adding new structural error codes:

1. Create test fixture file in `tests/invalid/`
2. Add expected results to `expected_errors.json`
3. Update test suites in Python, Julia, and Rust
4. Document the new error code in this file
5. Ensure all three implementations detect the new error consistently

## Testing Guidelines

- Each error code should have at least one clear, minimal test case
- Complex error conditions should have multiple variants showing different triggering scenarios
- Test fixtures should be realistic ESM files that could plausibly occur
- Error conditions should be isolated (one primary error per fixture, except for comprehensive tests)
- Expected error messages should be clear and actionable for users