# Rust API Reference

Complete API reference for the EarthSci Toolkit Rust library.

## Functions

### add_equation

**File:** `pkg/earthsci-ast-rs/src/edit.rs:149`

```rust
pub fn add_equation(model: &Model, equation: Equation) -> EditResult<Model> {
```

Add an equation to a model

# Arguments

* `model` - The model to modify
* `equation` - The equation to add

# Returns

* `EditResult<Model>` - New model with the added equation

---

### add_model

**File:** `pkg/earthsci-ast-rs/src/edit.rs:52`

```rust
pub fn add_model(esm_file: &EsmFile, model_id: &str, model: Model) -> EditResult<EsmFile> {
```

Add a new model to an ESM file

# Arguments

* `esm_file` - The ESM file to modify
* `model_id` - Unique identifier for the new model
* `model` - The model to add

# Returns

* `EditResult<EsmFile>` - New ESM file with the added model

---

### add_reaction

**File:** `pkg/earthsci-ast-rs/src/edit.rs:285`

```rust
pub fn add_reaction(system: &ReactionSystem, reaction: Reaction) -> EditResult<ReactionSystem> {
```

Add a reaction to a reaction system

# Arguments

* `system` - The reaction system to modify
* `reaction` - The reaction to add

# Returns

* `EditResult<ReactionSystem>` - New reaction system with the added reaction

---

### add_reaction_system

**File:** `pkg/earthsci-ast-rs/src/edit.rs:207`

```rust
pub fn add_reaction_system(esm_file: &EsmFile, system_id: &str, system: ReactionSystem) -> EditResult<EsmFile> {
```

Add a reaction system to an ESM file

# Arguments

* `esm_file` - The ESM file to modify
* `system_id` - Unique identifier for the new reaction system
* `system` - The reaction system to add

# Returns

* `EditResult<EsmFile>` - New ESM file with the added reaction system

---

### add_species

**File:** `pkg/earthsci-ast-rs/src/edit.rs:238`

```rust
pub fn add_species(system: &ReactionSystem, species: Species) -> EditResult<ReactionSystem> {
```

Add a species to a reaction system

# Arguments

* `system` - The reaction system to modify
* `species` - The species to add

# Returns

* `EditResult<ReactionSystem>` - New reaction system with the added species

---

### add_variable

**File:** `pkg/earthsci-ast-rs/src/edit.rs:108`

```rust
pub fn add_variable(model: &Model, var_name: &str, variable: ModelVariable) -> EditResult<Model> {
```

Add a variable to a model

# Arguments

* `model` - The model to modify
* `var_name` - Name of the new variable
* `variable` - The variable to add

# Returns

* `EditResult<Model>` - New model with the added variable

---

### add_vectors_simd

**File:** `pkg/earthsci-ast-rs/src/performance.rs:162`

```rust
pub fn add_vectors_simd(a: &[f64], b: &[f64], result: &mut [f64]) -> Result<(), PerformanceError> {
```

SIMD-optimized vector addition

---

### alloc_slice

**File:** `pkg/earthsci-ast-rs/src/performance.rs:264`

```rust
pub fn alloc_slice<T>(&self, len: usize) -> &mut [T]
```

Allocate a slice for storing intermediate results

---

### allocated_bytes

**File:** `pkg/earthsci-ast-rs/src/performance.rs:277`

```rust
pub fn allocated_bytes(&self) -> usize {
```

Get current allocated bytes

---

### base

**File:** `pkg/earthsci-ast-rs/src/units.rs:57`

```rust
pub fn base(dimension: Dimension, power: i32, scale: f64) -> Self {
```

Create a unit with a single dimension

---

### benchmark_parsing

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:246`

```rust
pub fn benchmark_parsing(json_str: &str, iterations: u32) -> Result<f64, JsValue> {
```

---

### check_dimensional_consistency

**File:** `pkg/earthsci-ast-rs/src/units.rs:250`

```rust
pub fn check_dimensional_consistency(lhs_unit: &Unit, rhs_unit: &Unit) -> Result<(), UnitError> {
```

Check dimensional consistency of an equation

# Arguments

* `lhs_unit` - Units of the left-hand side
* `rhs_unit` - Units of the right-hand side

# Returns

* `Result<(), UnitError>` - Ok if consistent, error otherwise

---

### component_exists

**File:** `pkg/earthsci-ast-rs/src/graph.rs:156`

```rust
pub fn component_exists(esm_file: &EsmFile, component_id: &str) -> bool {
```

Check if a component exists in the ESM file

# Arguments

* `esm_file` - The ESM file to check
* `component_id` - The component ID to look for

# Returns

* `true` if the component exists, `false` otherwise

---

### component_graph

**File:** `pkg/earthsci-ast-rs/src/graph.rs:60`

```rust
pub fn component_graph(esm_file: &EsmFile) -> ComponentGraph {
```

Build a component graph from an ESM file

# Arguments

* `esm_file` - The ESM file to analyze

# Returns

* Component graph showing structure and coupling

---

### compute_stoichiometric_matrix

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:212`

```rust
pub fn compute_stoichiometric_matrix(reaction_system_str: &str) -> Result<JsValue, JsValue> {
```

---

### compute_stoichiometric_matrix_parallel

**File:** `pkg/earthsci-ast-rs/src/performance.rs:96`

```rust
pub fn compute_stoichiometric_matrix_parallel(
```

Parallel stoichiometric matrix computation

---

### contains

**File:** `pkg/earthsci-ast-rs/src/expression.rs:47`

```rust
pub fn contains(expr: &Expr, var_name: &str) -> bool {
```

Check if an expression contains a specific variable

# Arguments

* `expr` - The expression to search
* `var_name` - The variable name to look for

# Returns

* `true` if the variable is found, `false` otherwise

---

### convert_units

**File:** `pkg/earthsci-ast-rs/src/units.rs:271`

```rust
pub fn convert_units(value: f64, from_unit: &Unit, to_unit: &Unit) -> Result<f64, UnitError> {
```

Convert between compatible units

# Arguments

* `value` - Value to convert
* `from_unit` - Source unit
* `to_unit` - Target unit

# Returns

* `Result<f64, UnitError>` - Converted value or error

---

### create_compact_expression

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:196`

```rust
pub fn create_compact_expression(expr_str: &str) -> Result<JsValue, JsValue> {
```

---

### derive_odes

**File:** `pkg/earthsci-ast-rs/src/reactions.rs:51`

```rust
pub fn derive_odes(system: &ReactionSystem) -> Result<Model, DeriveError> {
```

Generate ODE model from a reaction system

Converts a reaction system into an ODE model with species as state variables
and reactions contributing to their derivatives using mass action kinetics.

Mass action kinetics: rate law = k * product(substrates^stoichiometry)
Net stoichiometry = products - substrates
d[species]/dt = sum(net_stoichiometry * rate_law)

# Arguments

* `system` - The reaction system to convert

# Returns

* `Result<Model, DeriveError>` - ODE model with species as state variables, or error

# Errors

Returns `DeriveError` for invalid stoichiometry, missing rate laws, or unit conversion issues.

---

### dimensionless

**File:** `pkg/earthsci-ast-rs/src/units.rs:49`

```rust
pub fn dimensionless() -> Self {
```

Create a dimensionless unit

---

### divide

**File:** `pkg/earthsci-ast-rs/src/units.rs:89`

```rust
pub fn divide(&self, other: &Unit) -> Unit {
```

Divide two units

---

### dot_product_simd

**File:** `pkg/earthsci-ast-rs/src/performance.rs:214`

```rust
pub fn dot_product_simd(a: &[f64], b: &[f64]) -> Result<f64, PerformanceError> {
```

SIMD-optimized dot product

---

### errors

**File:** `pkg/earthsci-ast-rs/src/validate.rs:29`

```rust
pub fn errors(&self) -> Vec<StructuralError> {
```

Get all errors as a combined vector (for compatibility with old API)

---

### evaluate

**File:** `pkg/earthsci-ast-rs/src/expression.rs:106`

```rust
pub fn evaluate(expr: &Expr, bindings: &HashMap<String, f64>) -> Result<f64, Vec<String>> {
```

Evaluate an expression with given variable values

# Arguments

* `expr` - The expression to evaluate
* `bindings` - Map from variable names to numeric values

# Returns

* `Ok(f64)` if evaluation succeeds
* `Err(Vec<String>)` with unbound variable names if evaluation fails

---

### evaluate_batch

**File:** `pkg/earthsci-ast-rs/src/performance.rs:79`

```rust
pub fn evaluate_batch(
```

Evaluate multiple expressions in parallel

---

### evaluate_fast

**File:** `pkg/earthsci-ast-rs/src/performance.rs:340`

```rust
pub fn evaluate_fast(&self, variables: &HashMap<String, f64>) -> Result<f64, PerformanceError> {
```

---

### expression_graph

**File:** `pkg/earthsci-ast-rs/src/graph.rs:282`

```rust
pub fn expression_graph<T>(input: &T) -> ExpressionGraph
```

Build an expression graph from various ESM components

# Arguments

* `input` - Can be an ESM file, model, reaction system, equation, reaction, or expression

# Returns

* `ExpressionGraph` - Graph showing variable dependencies

---

### fast_parse

**File:** `pkg/earthsci-ast-rs/src/performance.rs:41`

```rust
pub fn fast_parse(json_bytes: &mut [u8]) -> Result<EsmFile, PerformanceError> {
```

---

### fast_parse

**File:** `pkg/earthsci-ast-rs/src/performance.rs:49`

```rust
pub fn fast_parse(json_str: &str) -> Result<EsmFile, PerformanceError> {
```

---

### free_parameters

**File:** `pkg/earthsci-ast-rs/src/expression.rs:33`

```rust
pub fn free_parameters(expr: &Expr) -> HashSet<String> {
```

Extract all free parameters from an expression

This is currently the same as free_variables since we don't distinguish
parameters from variables at the expression level.

# Arguments

* `expr` - The expression to analyze

# Returns

* Set of parameter names referenced in the expression

---

### free_variables

**File:** `pkg/earthsci-ast-rs/src/expression.rs:15`

```rust
pub fn free_variables(expr: &Expr) -> HashSet<String> {
```

Extract all free variables from an expression

# Arguments

* `expr` - The expression to analyze

# Returns

* Set of variable names referenced in the expression

---

### from_expr

**File:** `pkg/earthsci-ast-rs/src/performance.rs:304`

```rust
pub fn from_expr(expr: &Expr) -> Self {
```

Create a compact expression from a standard expression

---

### get_component_type

**File:** `pkg/earthsci-ast-rs/src/graph.rs:199`

```rust
pub fn get_component_type(esm_file: &EsmFile, component_id: &str) -> Option<ComponentType> {
```

Get the type of a component

# Arguments

* `esm_file` - The ESM file to check
* `component_id` - The component ID to look for

# Returns

* `Some(ComponentType)` if the component exists
* `None` if the component doesn't exist

---

### get_performance_info

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:227`

```rust
pub fn get_performance_info() -> JsValue {
```

---

### has_errors

**File:** `pkg/earthsci-ast-rs/src/validate.rs:24`

```rust
pub fn has_errors(&self) -> bool {
```

Check if there are any errors (schema or structural)

---

### is_compatible

**File:** `pkg/earthsci-ast-rs/src/units.rs:66`

```rust
pub fn is_compatible(&self, other: &Unit) -> bool {
```

Check if two units have compatible dimensions

---

### load

**File:** `pkg/earthsci-ast-rs/src/parse.rs:82`

```rust
pub fn load(json_str: &str) -> Result<EsmFile, EsmError> {
```

Load and parse an ESM file from JSON string

This function performs both JSON parsing and schema validation.
It will throw an error for malformed JSON or schema violations.

# Arguments

* `json_str` - The JSON string to parse

# Returns

* `Ok(EsmFile)` - Successfully parsed and validated ESM file
* `Err(EsmError)` - Parse error or schema validation error

# Examples

```rust
use earthsci_ast::load;

let json = r#"
{
"esm": "0.1.0",
"metadata": {
"name": "test_model"
},
"models": {
"simple": {
"variables": {},
"equations": []
}
}
}
"#;

let esm_file = load(json).expect("Failed to load ESM file");
assert_eq!(esm_file.esm, "0.1.0");
```

---

### load

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:31`

```rust
pub fn load(json_str: &str) -> Result<JsValue, JsValue> {
```

---

### main

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:263`

```rust
pub fn main() {
```

---

### multiply

**File:** `pkg/earthsci-ast-rs/src/units.rs:71`

```rust
pub fn multiply(&self, other: &Unit) -> Unit {
```

Multiply two units

---

### multiply_vectors_simd

**File:** `pkg/earthsci-ast-rs/src/performance.rs:188`

```rust
pub fn multiply_vectors_simd(a: &[f64], b: &[f64], result: &mut [f64]) -> Result<(), PerformanceError> {
```

SIMD-optimized element-wise multiplication

---

### new

**File:** `pkg/earthsci-ast-rs/src/performance.rs:63`

```rust
pub fn new(num_threads: Option<usize>) -> Result<Self, PerformanceError> {
```

Create a new parallel evaluator with specified number of threads

---

### new

**File:** `pkg/earthsci-ast-rs/src/performance.rs:250`

```rust
pub fn new() -> Self {
```

Create a new model allocator with specified capacity

---

### parse_unit

**File:** `pkg/earthsci-ast-rs/src/units.rs:136`

```rust
pub fn parse_unit(unit_str: &str) -> Result<Unit, UnitError> {
```

Parse a unit string into a Unit struct

Supports common unit notations like:
- "m/s" (meters per second)
- "kg*m/s^2" (kilogram meters per second squared)
- "mol/L" (moles per liter)
- "1" or "" (dimensionless)

# Arguments

* `unit_str` - String representation of the unit

# Returns

* `Result<Unit, UnitError>` - Parsed unit or error

---

### power

**File:** `pkg/earthsci-ast-rs/src/units.rs:107`

```rust
pub fn power(&self, exponent: i32) -> Unit {
```

Raise unit to a power

---

### remove_equation

**File:** `pkg/earthsci-ast-rs/src/edit.rs:165`

```rust
pub fn remove_equation(model: &Model, index: usize) -> EditResult<Model> {
```

Remove an equation from a model by index

# Arguments

* `model` - The model to modify
* `index` - Index of the equation to remove

# Returns

* `EditResult<Model>` - New model without the equation

---

### remove_model

**File:** `pkg/earthsci-ast-rs/src/edit.rs:83`

```rust
pub fn remove_model(esm_file: &EsmFile, model_id: &str) -> EditResult<EsmFile> {
```

Remove a model from an ESM file

# Arguments

* `esm_file` - The ESM file to modify
* `model_id` - Identifier of the model to remove

# Returns

* `EditResult<EsmFile>` - New ESM file without the model

---

### remove_reaction

**File:** `pkg/earthsci-ast-rs/src/edit.rs:301`

```rust
pub fn remove_reaction(system: &ReactionSystem, index: usize) -> EditResult<ReactionSystem> {
```

Remove a reaction from a reaction system by index

# Arguments

* `system` - The reaction system to modify
* `index` - Index of the reaction to remove

# Returns

* `EditResult<ReactionSystem>` - New reaction system without the reaction

---

### remove_species

**File:** `pkg/earthsci-ast-rs/src/edit.rs:262`

```rust
pub fn remove_species(system: &ReactionSystem, species_name: &str) -> EditResult<ReactionSystem> {
```

Remove a species from a reaction system

# Arguments

* `system` - The reaction system to modify
* `species_name` - Name of the species to remove

# Returns

* `EditResult<ReactionSystem>` - New reaction system without the species

---

### remove_variable

**File:** `pkg/earthsci-ast-rs/src/edit.rs:129`

```rust
pub fn remove_variable(model: &Model, var_name: &str) -> EditResult<Model> {
```

Remove a variable from a model

# Arguments

* `model` - The model to modify
* `var_name` - Name of the variable to remove

# Returns

* `EditResult<Model>` - New model without the variable

---

### replace_equation

**File:** `pkg/earthsci-ast-rs/src/edit.rs:186`

```rust
pub fn replace_equation(model: &Model, index: usize, equation: Equation) -> EditResult<Model> {
```

Replace an equation in a model

# Arguments

* `model` - The model to modify
* `index` - Index of the equation to replace
* `equation` - The new equation

# Returns

* `EditResult<Model>` - New model with the replaced equation

---

### reset

**File:** `pkg/earthsci-ast-rs/src/performance.rs:272`

```rust
pub fn reset(&mut self) {
```

Reset the allocator for reuse

---

### save

**File:** `pkg/earthsci-ast-rs/src/serialize.rs:46`

```rust
pub fn save(esm_file: &EsmFile) -> Result<String, EsmError> {
```

Serialize an ESM file to JSON string

This function converts an `EsmFile` struct back to a JSON string.
The output will be pretty-printed for human readability.

# Arguments

* `esm_file` - The ESM file to serialize

# Returns

* `Ok(String)` - Successfully serialized JSON string
* `Err(EsmError)` - Serialization error

# Examples

```rust
use earthsci_ast::{EsmFile, Metadata, save};

let esm_file = EsmFile {
esm: "0.1.0".to_string(),
metadata: Metadata {
name: Some("test_model".to_string()),
description: None,
authors: None,
created: None,
modified: None,
version: None,
},
models: None,
reaction_systems: None,
data_loaders: None,
operators: None,
coupling: None,
domain: None,
solver: None,
};

let json = save(&esm_file).expect("Failed to serialize ESM file");
assert!(json.contains("\"esm\": \"0.1.0\""));
```

---

### save

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:46`

```rust
pub fn save(esm_file_js: &JsValue) -> Result<String, JsValue> {
```

---

### save_compact

**File:** `pkg/earthsci-ast-rs/src/serialize.rs:64`

```rust
pub fn save_compact(esm_file: &EsmFile) -> Result<String, EsmError> {
```

Serialize an ESM file to compact JSON string (no pretty printing)

This function is similar to `save` but produces compact JSON without
extra whitespace, suitable for storage or transmission.

# Arguments

* `esm_file` - The ESM file to serialize

# Returns

* `Ok(String)` - Successfully serialized compact JSON string
* `Err(EsmError)` - Serialization error

---

### simplify

**File:** `pkg/earthsci-ast-rs/src/expression.rs:145`

```rust
pub fn simplify(expr: &Expr) -> Expr {
```

Simplify an expression (basic symbolic simplification)

# Arguments

* `expr` - The expression to simplify

# Returns

* Simplified expression

---

### stoichiometric_matrix

**File:** `pkg/earthsci-ast-rs/src/reactions.rs:304`

```rust
pub fn stoichiometric_matrix(system: &ReactionSystem) -> Vec<Vec<f64>> {
```

Generate stoichiometric matrix from a reaction system

Creates a matrix where rows represent species and columns represent reactions.
Matrix[i][j] = stoichiometric coefficient of species i in reaction j.
Negative values indicate reactants, positive values indicate products.

# Arguments

* `system` - The reaction system to analyze

# Returns

* `Vec<Vec<f64>>` - Matrix with species as rows and reactions as columns

---

### substitute

**File:** `pkg/earthsci-ast-rs/src/substitute.rs:16`

```rust
pub fn substitute(expr: &Expr, substitutions: &std::collections::HashMap<String, Expr>) -> Expr {
```

Substitute variables in an expression

# Arguments

* `expr` - The expression to modify
* `substitutions` - Map from variable names to replacement expressions

# Returns

* New expression with substitutions applied

---

### substitute

**File:** `pkg/earthsci-ast-rs/src/expression.rs:70`

```rust
pub fn substitute(expr: &Expr, bindings: &HashMap<String, Expr>) -> Expr {
```

Substitute variables in an expression

Performs recursive replacement of variables with expressions, with support for
scoped reference resolution. Returns a new expression (immutable).

# Arguments

* `expr` - The expression to substitute variables in
* `bindings` - Map from variable names to replacement expressions

# Returns

* New expression with substitutions applied

---

### substitute

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:132`

```rust
pub fn substitute(json_str: &str, bindings_str: &str) -> Result<String, JsValue> {
```

---

### substitute_in_expression

**File:** `pkg/earthsci-ast-rs/src/edit.rs:348`

```rust
pub fn substitute_in_expression(expr: &Expr, substitutions: &HashMap<String, Expr>) -> Expr {
```

Create a copy of an expression with variable substitution

# Arguments

* `expr` - The expression to modify
* `substitutions` - Map of variable names to replacement expressions

# Returns

* `Expr` - New expression with substitutions applied

---

### substitute_in_model

**File:** `pkg/earthsci-ast-rs/src/substitute.rs:51`

```rust
pub fn substitute_in_model(
```

Substitute variables in all expressions within a model

# Arguments

* `model` - The model to modify
* `substitutions` - Map from variable names to replacement expressions

# Returns

* New model with substitutions applied

---

### substitute_in_reaction_system

**File:** `pkg/earthsci-ast-rs/src/substitute.rs:81`

```rust
pub fn substitute_in_reaction_system(
```

Substitute variables in all expressions within a reaction system

# Arguments

* `reaction_system` - The reaction system to modify
* `substitutions` - Map from variable names to replacement expressions

# Returns

* New reaction system with substitutions applied

---

### to_ascii

**File:** `pkg/earthsci-ast-rs/src/display.rs:523`

```rust
pub fn to_ascii(expr: &Expr) -> String {
```

Convert an expression to ASCII representation

---

### to_ascii

**File:** `pkg/earthsci-ast-rs/src/pretty_print.rs:74`

```rust
pub fn to_ascii(expr: &Expr) -> String {
```

Convert an expression to ASCII representation

# Arguments

* `expr` - The expression to format

# Returns

* ASCII string representation

---

### to_dot

**File:** `pkg/earthsci-ast-rs/src/graph.rs:465`

```rust
pub fn to_dot(&self) -> String {
```

Export graph to DOT format for Graphviz

# Returns

* `String` - DOT representation of the graph

---

### to_dot

**File:** `pkg/earthsci-ast-rs/src/graph.rs:543`

```rust
pub fn to_dot(&self) -> String {
```

Export graph to DOT format for Graphviz

# Returns

* `String` - DOT representation of the expression graph

---

### to_json_graph

**File:** `pkg/earthsci-ast-rs/src/graph.rs:532`

```rust
pub fn to_json_graph(&self) -> String {
```

Export graph to JSON format

# Returns

* `String` - JSON representation of the graph

---

### to_json_graph

**File:** `pkg/earthsci-ast-rs/src/graph.rs:604`

```rust
pub fn to_json_graph(&self) -> String {
```

Export graph to JSON format

# Returns

* `String` - JSON representation of the graph

---

### to_latex

**File:** `pkg/earthsci-ast-rs/src/display.rs:361`

```rust
pub fn to_latex(expr: &Expr) -> String {
```

Convert an expression to LaTeX notation

---

### to_latex

**File:** `pkg/earthsci-ast-rs/src/pretty_print.rs:42`

```rust
pub fn to_latex(expr: &Expr) -> String {
```

Convert an expression to LaTeX notation

# Arguments

* `expr` - The expression to format

# Returns

* LaTeX string representation

---

### to_latex

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:103`

```rust
pub fn to_latex(json_str: &str) -> Result<String, JsValue> {
```

---

### to_mermaid

**File:** `pkg/earthsci-ast-rs/src/graph.rs:501`

```rust
pub fn to_mermaid(&self) -> String {
```

Export graph to Mermaid format

# Returns

* `String` - Mermaid representation of the graph

---

### to_mermaid

**File:** `pkg/earthsci-ast-rs/src/graph.rs:577`

```rust
pub fn to_mermaid(&self) -> String {
```

Export graph to Mermaid format

# Returns

* `String` - Mermaid representation of the expression graph

---

### to_unicode

**File:** `pkg/earthsci-ast-rs/src/display.rs:191`

```rust
pub fn to_unicode(&self) -> String {
```

Convert expression to Unicode mathematical notation

---

### to_unicode

**File:** `pkg/earthsci-ast-rs/src/display.rs:356`

```rust
pub fn to_unicode(expr: &Expr) -> String {
```

Convert an expression to Unicode mathematical notation

---

### to_unicode

**File:** `pkg/earthsci-ast-rs/src/pretty_print.rs:14`

```rust
pub fn to_unicode(expr: &Expr) -> String {
```

Convert an expression to Unicode mathematical notation

# Arguments

* `expr` - The expression to format

# Returns

* Unicode string representation

---

### to_unicode

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:74`

```rust
pub fn to_unicode(json_str: &str) -> Result<String, JsValue> {
```

---

### update_model_metadata

**File:** `pkg/earthsci-ast-rs/src/edit.rs:324`

```rust
pub fn update_model_metadata(model: &Model, name: Option<String>, description: Option<String>) -> EditResult<Model> {
```

Update model metadata

# Arguments

* `model` - The model to modify
* `name` - New name (None to keep current)
* `description` - New description (None to keep current)

# Returns

* `EditResult<Model>` - New model with updated metadata

---

### validate

**File:** `pkg/earthsci-ast-rs/src/validate.rs:160`

```rust
pub fn validate(esm_file: &EsmFile) -> ValidationResult {
```

Perform structural validation on an ESM file

This goes beyond schema validation to check:
- All variable references are defined
- Unit consistency in equations
- No circular dependencies
- Mathematical validity of expressions
- Equation-unknown balance
- Reference integrity (scoped ref resolution via subsystem hierarchy)
- Reaction consistency
- Event consistency

# Arguments

* `esm_file` - The ESM file to validate

# Returns

* `ValidationResult` - Detailed validation results with schema_errors, structural_errors, unit_warnings, and is_valid flag

# Examples

```rust
use earthsci_ast::{validate, EsmFile, Metadata};

let esm_file = EsmFile {
esm: "0.1.0".to_string(),
metadata: Metadata {
name: Some("test".to_string()),
description: None,
authors: None,
created: None,
modified: None,
version: None,
},
models: None,
reaction_systems: None,
data_loaders: None,
operators: None,
coupling: None,
domain: None,
solver: None,
};

let result = validate(&esm_file);
assert!(result.is_valid);
```

---

### validate

**File:** `pkg/earthsci-ast-rs/src/wasm.rs:59`

```rust
pub fn validate(json_str: &str) -> Result<JsValue, JsValue> {
```

---

### validate_schema

**File:** `pkg/earthsci-ast-rs/src/parse.rs:109`

```rust
pub fn validate_schema(json_value: &Value) -> Result<(), EsmError> {
```

Validate a JSON value against the ESM schema

This performs schema validation only. The JSON is assumed to be valid.

# Arguments

* `json_value` - The JSON value to validate

# Returns

* `Ok(())` - JSON passes schema validation
* `Err(EsmError::SchemaValidation)` - Schema validation errors

---

### validate_with_schema

**File:** `pkg/earthsci-ast-rs/src/validate.rs:204`

```rust
pub fn validate_with_schema(json_str: &str, esm_file: &EsmFile) -> ValidationResult {
```

Validate an ESM file including schema validation

This function combines schema and structural validation

---

### with_capacity

**File:** `pkg/earthsci-ast-rs/src/performance.rs:257`

```rust
pub fn with_capacity(capacity: usize) -> Self {
```

Create allocator with pre-allocated capacity

---

## Types

### AffectEquation

**File:** `pkg/earthsci-ast-rs/src/types.rs:214`

```rust
pub struct AffectEquation {
```

---

### CompactExpr

**File:** `pkg/earthsci-ast-rs/src/performance.rs:295`

```rust
pub struct CompactExpr {
```

---

### ComponentGraph

**File:** `pkg/earthsci-ast-rs/src/graph.rs:7`

```rust
pub struct ComponentGraph {
```

---

### ComponentNode

**File:** `pkg/earthsci-ast-rs/src/graph.rs:16`

```rust
pub struct ComponentNode {
```

---

### ContinuousEvent

**File:** `pkg/earthsci-ast-rs/src/types.rs:224`

```rust
pub struct ContinuousEvent {
```

---

### CouplingEdge

**File:** `pkg/earthsci-ast-rs/src/graph.rs:40`

```rust
pub struct CouplingEdge {
```

---

### DataLoader

**File:** `pkg/earthsci-ast-rs/src/types.rs:343`

```rust
pub struct DataLoader {
```

---

### DependencyEdge

**File:** `pkg/earthsci-ast-rs/src/graph.rs:264`

```rust
pub struct DependencyEdge {
```

---

### DiscreteEvent

**File:** `pkg/earthsci-ast-rs/src/types.rs:172`

```rust
pub struct DiscreteEvent {
```

---

### Domain

**File:** `pkg/earthsci-ast-rs/src/types.rs:451`

```rust
pub struct Domain {
```

---

### Equation

**File:** `pkg/earthsci-ast-rs/src/types.rs:162`

```rust
pub struct Equation {
```

---

### EsmFile

**File:** `pkg/earthsci-ast-rs/src/types.rs:10`

```rust
pub struct EsmFile {
```

---

### ExpressionGraph

**File:** `pkg/earthsci-ast-rs/src/graph.rs:233`

```rust
pub struct ExpressionGraph {
```

---

### ExpressionNode

**File:** `pkg/earthsci-ast-rs/src/types.rs:90`

```rust
pub struct ExpressionNode {
```

---

### ExpressionNode

**File:** `pkg/earthsci-ast-rs/src/graph.rs:242`

```rust
pub struct ExpressionNode {
```

---

### FunctionalAffect

**File:** `pkg/earthsci-ast-rs/src/types.rs:251`

```rust
pub struct FunctionalAffect {
```

---

### Metadata

**File:** `pkg/earthsci-ast-rs/src/types.rs:48`

```rust
pub struct Metadata {
```

---

### Model

**File:** `pkg/earthsci-ast-rs/src/types.rs:108`

```rust
pub struct Model {
```

---

### ModelAllocator

**File:** `pkg/earthsci-ast-rs/src/performance.rs:243`

```rust
pub struct ModelAllocator {
```

---

### ModelVariable

**File:** `pkg/earthsci-ast-rs/src/types.rs:130`

```rust
pub struct ModelVariable {
```

---

### Operator

**File:** `pkg/earthsci-ast-rs/src/types.rs:359`

```rust
pub struct Operator {
```

---

### ParallelEvaluator

**File:** `pkg/earthsci-ast-rs/src/performance.rs:56`

```rust
pub struct ParallelEvaluator {
```

---

### ParseError

**File:** `pkg/earthsci-ast-rs/src/parse.rs:12`

```rust
pub struct ParseError {
```

---

### Reaction

**File:** `pkg/earthsci-ast-rs/src/types.rs:311`

```rust
pub struct Reaction {
```

---

### ReactionSystem

**File:** `pkg/earthsci-ast-rs/src/types.rs:274`

```rust
pub struct ReactionSystem {
```

---

### SchemaError

**File:** `pkg/earthsci-ast-rs/src/validate.rs:36`

```rust
pub struct SchemaError {
```

---

### SchemaValidationError

**File:** `pkg/earthsci-ast-rs/src/parse.rs:27`

```rust
pub struct SchemaValidationError {
```

---

### Solver

**File:** `pkg/earthsci-ast-rs/src/types.rs:463`

```rust
pub struct Solver {
```

---

### Species

**File:** `pkg/earthsci-ast-rs/src/types.rs:292`

```rust
pub struct Species {
```

---

### StoichiometricEntry

**File:** `pkg/earthsci-ast-rs/src/types.rs:332`

```rust
pub struct StoichiometricEntry {
```

---

### StructuralError

**File:** `pkg/earthsci-ast-rs/src/validate.rs:47`

```rust
pub struct StructuralError {
```

---

### Unit

**File:** `pkg/earthsci-ast-rs/src/units.rs:8`

```rust
pub struct Unit {
```

---

### ValidationResult

**File:** `pkg/earthsci-ast-rs/src/validate.rs:11`

```rust
pub struct ValidationResult {
```

---

### VariableMapping

**File:** `pkg/earthsci-ast-rs/src/types.rs:439`

```rust
pub struct VariableMapping {
```

---

