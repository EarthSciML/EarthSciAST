# Expression AST Round-Trip Test Fixtures

This directory contains comprehensive test fixtures for expression Abstract Syntax Tree (AST) round-trip fidelity testing, as specified in ESM Libraries Specification Section 7.3.

## Test Files

### Core Round-Trip Tests

1. **`ast_round_trip_fixtures.json`** - Comprehensive AST structure tests
   - Basic literals (numbers, variables)
   - Number precision edge cases
   - Variable names with special characters and Unicode
   - Complex nested arithmetic expressions
   - Expression tree depth limits
   - All operator types (arithmetic, transcendental, comparison, logical, derivatives)
   - Invalid expressions that should trigger parsing errors
   - Mixed type edge cases

2. **`round_trip_fidelity.json`** - Perfect round-trip preservation tests
   - Tests that verify `load(save(load(expr))) === load(expr)` property
   - Precision preservation for extreme numbers
   - Unicode and special character preservation
   - Structural preservation for complex nested expressions
   - Field ordering and optional field preservation

3. **`parsing_error_fixtures.json`** - Error case validation tests
   - Schema validation errors (missing fields, invalid types)
   - Structural validation errors (invalid arity, unknown operators)
   - Invalid argument content (null values, wrong types)
   - Complex nested error scenarios
   - Boundary condition tests (depth/size limits)
   - JSON parsing edge cases

### Existing Tests (from previous work)

4. **`round_trip_evaluation.json`** - Expression evaluation tests
   - Basic numeric literals, variables, and operations
   - Binary arithmetic operations
   - Complex mathematical expressions

5. **`evaluation_edge_cases.json`** - Edge case evaluation tests
   - Unbound variable errors
   - Division by zero cases
   - Mathematical function domain errors

## Test Structure

Each test file follows a consistent structure:

```json
[
  {
    "name": "Test Category Name",
    "description": "Description of what this category tests",
    "tests": [
      {
        "description": "Individual test description",
        "input": /* test input expression */,
        "expected_type": "ExpectedExprType",
        "serialized": /* expected serialized form */,
        "expected_error": "ErrorType", // for error tests
        // ... other test-specific fields
      }
    ]
  }
]
```

## Round-Trip Testing Requirements

These test fixtures are designed to validate that all ESM library implementations satisfy the round-trip fidelity requirement:

**`load(save(load(expression))) === load(expression)`**

Key aspects tested:

1. **Number Normalization**: Integers should normalize to floating-point representation
2. **String Preservation**: Variable names must preserve exactly, including Unicode
3. **Structure Preservation**: Complex nested expressions must maintain exact structure
4. **Field Preservation**: Optional fields (like `wrt`, `dim`) must be preserved
5. **Error Handling**: Invalid expressions must fail consistently across implementations

## Usage for Library Implementations

Library implementers should:

1. Run all valid test cases through their `load() → save() → load()` pipeline
2. Verify that the second load result exactly matches the first load result
3. Confirm that error cases produce the expected error types and messages
4. Test precision preservation for edge cases like very small/large numbers
5. Validate Unicode handling for complex variable names

## Test Coverage

These fixtures provide comprehensive coverage for:

- ✅ All basic expression types (numbers, strings, operators)
- ✅ All standard operators (arithmetic, logical, comparison, transcendental)
- ✅ Special operators (D, grad, Pre, ifelse)
- ✅ Complex nesting and wide expressions
- ✅ Unicode variable names and chemical formulas
- ✅ Precision edge cases (very small/large numbers)
- ✅ Invalid expressions and error conditions
- ✅ JSON schema validation errors
- ✅ Structural validation errors

## Conformance Testing

For cross-language conformance testing, implementations should produce identical results for all round-trip tests. Any differences indicate a bug or inconsistency that needs to be resolved.

The fixtures support the Phase 1 and Phase 2 requirements from the ESM Libraries Specification and provide a solid foundation for ensuring consistent expression handling across Julia, TypeScript, Python, Rust, and Go implementations.