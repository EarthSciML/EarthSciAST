# Typescript API Reference

Complete API reference for the ESM Format Typescript library.

## Functions

### addContinuousEvent

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:387`

**Signature:**
```typescript
export function addContinuousEvent(
```

**Description:**
Add a continuous event to a model
@param model Model to add event to
@param event Continuous event to add
@returns New model with event added
/

---

### addCoupling

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:464`

**Signature:**
```typescript
export function addCoupling(
```

**Description:**
Add a coupling entry to an ESM file
@param file ESM file to add coupling to
@param entry Coupling entry to add
@returns New ESM file with coupling added
/

---

### addDiscreteEvent

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:404`

**Signature:**
```typescript
export function addDiscreteEvent(
```

**Description:**
Add a discrete event to a model
@param model Model to add event to
@param event Discrete event to add
@returns New model with event added
/

---

### addEquation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:193`

**Signature:**
```typescript
export function addEquation(
```

**Description:**
Add a new equation to a model
@param model Model to add equation to
@param equation Equation to add
@returns New model with equation added
/

---

### addReaction

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:262`

**Signature:**
```typescript
export function addReaction(
```

**Description:**
Add a new reaction to a reaction system
@param system ReactionSystem to add reaction to
@param reaction Reaction to add
@returns New reaction system with reaction added
/

---

### addSpecies

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:306`

**Signature:**
```typescript
export function addSpecies(
```

**Description:**
Add a new species to a reaction system
@param system ReactionSystem to add species to
@param name Species name
@param species Species definition
@returns New reaction system with species added
/

---

### addVariable

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:61`

**Signature:**
```typescript
export function addVariable(
```

**Description:**
Add a new variable to a model
@param model Model to add variable to
@param name Variable name
@param variable Variable definition
@returns New model with variable added
/

---

### analyzeComplexity

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/complexity.ts:17`

**Signature:**
```typescript
export function analyzeComplexity(expr: Expr): ComplexityMetrics {
```

**Description:**
Analyze the complexity of an expression
@param expr Expression to analyze
@returns Complexity metrics
/

---

### buildDependencyGraph

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/dependency-graph.ts:19`

**Signature:**
```typescript
export function buildDependencyGraph(
```

**Description:**
Build a dependency graph from an ESM file, model, or expression
@param target The target to analyze
@param options Analysis options
@returns Dependency graph with nodes and edges
/

---

### canMigrate

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/migration.ts:22`

**Signature:**
```typescript
export function canMigrate(sourceVersion: string, targetVersion: string): boolean {
```

**Description:**
Check if migration is possible from the source version to target version.
/

---

### checkDimensions

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/units.ts:210`

**Signature:**
```typescript
export function checkDimensions(expr: Expression, unitBindings: Map<string, DimensionalRep>): UnitResult {
```

**Description:**
Check dimensional consistency of an expression

Follows rules from ESM spec Section 3.3.1:
- Addition/subtraction: operands must have same dimensions
- Multiplication: dimensions add
- Division: dimensions subtract
- D(x,t): dimension of x divided by dimension of t
- Functions require dimensionless arguments; result is dimensionless

@param expr Expression to check
@param unitBindings Map of variable names to their dimensional representations
@returns Unit result with dimensions and any warnings
/

---

### classifyComplexity

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/complexity.ts:219`

**Signature:**
```typescript
export function classifyComplexity(expr: Expr): 'trivial' | 'simple' | 'moderate' | 'complex' | 'very_complex' {
```

**Description:**
Classify expression complexity level
@param expr Expression to classify
@returns Complexity level
/

---

### compareAnalysis

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/index.ts:261`

**Signature:**
```typescript
export function compareAnalysis(results1: any, results2: any) {
```

**Description:**
Compare analysis results between different expressions or models
/

---

### compareComplexity

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/complexity.ts:187`

**Signature:**
```typescript
export function compareComplexity(expr1: Expr, expr2: Expr): number {
```

**Description:**
Compare complexity of two expressions
@param expr1 First expression
@param expr2 Second expression
@returns Comparison result (-1: expr1 simpler, 0: equal, 1: expr1 more complex)
/

---

### componentExists

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:349`

**Signature:**
```typescript
export function componentExists(esmFile: EsmFile, componentId: string): boolean {
```

**Description:**
Utility to check if a component exists in the ESM file
/

---

### componentGraph

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:290`

**Signature:**
```typescript
export function componentGraph(file: EsmFile): Graph<ComponentNode, CouplingEdge> {
```

**Description:**
Extract the system graph from an ESM file as specified in task.
Returns a directed graph where nodes are model components and edges are coupling rules.
Implements the Graph interface with adjacency methods.
/

---

### component_graph

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:104`

**Signature:**
```typescript
export function component_graph(esmFile: EsmFile): ComponentGraph {
```

**Description:**
Extract the system graph from an ESM file.
Returns a directed graph where nodes are model components and edges are coupling rules.
/

**Available in other languages:**
- [Julia](julia.md#component_graph)
- [Julia](julia.md#component_graph)

---

### compose

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:506`

**Signature:**
```typescript
export function compose(
```

**Description:**
Compose two systems using a coupling entry
@param file ESM file
@param a First system name
@param b Second system name
@returns New ESM file with composition coupling added
/

**Available in other languages:**
- [Julia](julia.md#compose)
- [Julia](julia.md#compose)

---

### contains

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/expression.ts:65`

**Signature:**
```typescript
export function contains(expr: Expr, varName: string): boolean {
```

**Description:**
Check if an expression contains a specific variable
@param expr Expression to search
@param varName Variable name to look for
@returns True if the variable appears in the expression
/

**Available in other languages:**
- [Julia](julia.md#contains)
- [Julia](julia.md#contains)

---

### createAstStore

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/ast-store.ts:129`

**Signature:**
```typescript
export function createAstStore(config: AstStoreConfig = {}): AstStore {
```

**Description:**
Create a centralized AST store for ESM file management

@param config - Configuration options
@returns AST store interface with reactive state and path-based updates
/

---

### createDebouncedValidation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/validation.ts:327`

**Signature:**
```typescript
export function createDebouncedValidation(
```

**Description:**
Debounced validation hook for use in components that trigger validation

@param validationFn - Function that performs validation
@param debounceMs - Debounce delay in milliseconds
@returns Debounced validation function
/

---

### createDemoServer

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/demo/demo-pages.ts:333`

**Signature:**
```typescript
export function createDemoServer() {
```

---

### createUndoHistory

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/history.ts:70`

**Signature:**
```typescript
export function createUndoHistory(
```

**Description:**
Create undo/redo history management for an ESM file

@param file - Reactive signal containing the current ESM file
@param setFile - Function to update the ESM file
@param config - Optional configuration
@returns History management interface with undo/redo functions
/

---

### createUndoKeyboardHandler

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/history.ts:281`

**Signature:**
```typescript
export function createUndoKeyboardHandler(
```

**Description:**
Default keyboard shortcut handler for undo/redo
Can be used independently of createUndoHistory if needed
/

---

### createValidationContext

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/validation.ts:306`

**Signature:**
```typescript
export function createValidationContext(
```

**Description:**
Create a simplified validation context for components that only need basic validation state

@param file - Reactive signal containing the current ESM file
@param config - Optional configuration
@returns Simplified validation interface
/

---

### createValidationSignals

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/validation.ts:93`

**Signature:**
```typescript
export function createValidationSignals(
```

**Description:**
Create reactive validation signals for an ESM file

@param file - Reactive signal containing the current ESM file
@param config - Optional configuration for validation behavior
@returns Validation signals interface with reactive validation state
/

---

### deriveODEs

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/reactions.ts:28`

**Signature:**
```typescript
export function deriveODEs(system: ReactionSystem): Model {
```

**Description:**
Derive ODEs from a reaction system using mass action kinetics

Generates an ODE model from reaction stoichiometry and rate laws. For each reaction
with rate k, substrates {Si} with stoichiometries {ni}, products {Pj} with
stoichiometries {mj}:
- rate law: v = k * prod(Si^ni)
- ODE contribution: dX/dt += net_stoich_X * v

Handles:
- Source reactions (null substrates): rate is the direct production term
- Sink reactions (null products): rate is the direct loss term
- Constraint equations are appended as additional equations

@param system ReactionSystem to derive ODEs from
@returns Model with species as state variables, derived ODEs plus constraints
/

---

### detectStabilityIssues

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/complexity.ts:324`

**Signature:**
```typescript
export function detectStabilityIssues(expr: Expr): Array<{
```

**Description:**
Detect numerical stability issues in expressions
@param expr Expression to analyze
@returns Array of potential stability issues
/

---

### differentiate

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/differentiation.ts:19`

**Signature:**
```typescript
export function differentiate(expr: Expr, variable: string): DerivativeResult {
```

**Description:**
Compute the symbolic derivative of an expression with respect to a variable
@param expr Expression to differentiate
@param variable Variable with respect to which to differentiate
@returns Derivative result with simplified form
/

**Available in other languages:**
- [Python](python.md#differentiate)

---

### downloadExport

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/ModelExportUtils.ts:631`

**Signature:**
```typescript
export function downloadExport(content: string, filename: string, mimeType: string = 'text/plain'): void {
```

**Description:**
Download exported model as file
/

---

### estimateParallelPotential

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/complexity.ts:282`

**Signature:**
```typescript
export function estimateParallelPotential(expr: Expr): number {
```

**Description:**
Estimate parallel execution potential
@param expr Expression to analyze
@returns Parallelization score (0-1, higher means more parallelizable)
/

---

### estimateSavings

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts:288`

**Signature:**
```typescript
export function estimateSavings(commonSubexpressions: CommonSubexpression[]): number {
```

**Description:**
Estimate the cost savings from factoring out common subexpressions
@param commonSubexpressions Array of common subexpressions
@returns Total estimated cost savings
/

---

### evaluate

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/expression.ts:85`

**Signature:**
```typescript
export function evaluate(expr: Expr, bindings: Map<string, number>): number {
```

**Description:**
Evaluate an expression numerically with variable bindings
@param expr Expression to evaluate
@param bindings Map of variable names to their numeric values
@returns Numeric result
@throws Error if variables are unbound or evaluation fails
/

**Available in other languages:**
- [Julia](julia.md#evaluate)
- [Julia](julia.md#evaluate)

---

### exportModel

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/ModelExportUtils.ts:33`

**Signature:**
```typescript
export function exportModel(model: Model, format: ExportFormat, options: ExportOptions = {}): string {
```

**Description:**
Export model to various formats
/

---

### exportResults

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/index.ts:246`

**Signature:**
```typescript
export function exportResults(results: any, format: 'json' | 'yaml' | 'markdown' | 'html') {
```

**Description:**
Export analysis results to various formats
/

---

### expressionGraph

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:377`

**Signature:**
```typescript
export function expressionGraph(
```

**Description:**
Extract variable-level dependency graph from an ESM file, model, reaction system, equation, reaction, or expression.
Creates a directed graph where nodes are variables/parameters/species and edges represent dependencies.

@param target The target to analyze (EsmFile, Model, ReactionSystem, Equation, Reaction, or Expr)
@param options Optional settings for graph generation
@returns Graph with VariableNode nodes and DependencyEdge edges
/

---

### extract

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:589`

**Signature:**
```typescript
export function extract(
```

**Description:**
Extract a specific component from an ESM file into a new file
@param file ESM file to extract from
@param componentName Name of the component to extract
@returns New ESM file containing only the specified component
@throws EntityNotFoundError if component not found
/

**Available in other languages:**
- [Julia](julia.md#extract)
- [Julia](julia.md#extract)

---

### findCommonSubexpressions

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts:18`

**Signature:**
```typescript
export function findCommonSubexpressions(expr: Expr, minComplexity: number = 5): CommonSubexpression[] {
```

**Description:**
Find common subexpressions in a single expression
@param expr Expression to analyze
@param minComplexity Minimum complexity threshold for considering subexpressions
@returns Array of common subexpressions found
/

---

### findCommonSubexpressionsAcrossExpressions

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts:87`

**Signature:**
```typescript
export function findCommonSubexpressionsAcrossExpressions(
```

**Description:**
Find common subexpressions across multiple expressions
@param expressions Array of expressions to analyze
@param minComplexity Minimum complexity threshold
@returns Array of common subexpressions found across expressions
/

---

### findCommonSubexpressionsInEsmFile

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts:211`

**Signature:**
```typescript
export function findCommonSubexpressionsInEsmFile(esmFile: EsmFile, minComplexity: number = 5): CommonSubexpression[] {
```

**Description:**
Find common subexpressions across an entire ESM file
@param esmFile ESM file to analyze
@param minComplexity Minimum complexity threshold
@returns Array of common subexpressions found across the file
/

---

### findCommonSubexpressionsInModel

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts:159`

**Signature:**
```typescript
export function findCommonSubexpressionsInModel(model: Model, minComplexity: number = 5): CommonSubexpression[] {
```

**Description:**
Find common subexpressions in a model
@param model Model to analyze
@param minComplexity Minimum complexity threshold
@returns Array of common subexpressions found in the model
/

---

### findCriticalPoints

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/differentiation.ts:544`

**Signature:**
```typescript
export function findCriticalPoints(expr: Expr, variable: string): {
```

**Description:**
Find critical points (where derivative equals zero)
This is a symbolic analysis - actual solving would require numerical methods
@param expr Expression to analyze
@param variable Variable to find critical points for
@returns Information about potential critical points
/

---

### findDeadVariables

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/dependency-graph.ts:463`

**Signature:**
```typescript
export function findDeadVariables(graph: DependencyGraph): DependencyNode[] {
```

**Description:**
Find dead variables (those that are defined but never used)
/

---

### findDependencyChains

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/dependency-graph.ts:480`

**Signature:**
```typescript
export function findDependencyChains(graph: DependencyGraph, startNode: string, maxDepth: number = 10): string[][] {
```

**Description:**
Find variable dependency chains (paths from parameters to state variables)
/

---

### findExpensiveSubexpressions

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/complexity.ts:242`

**Signature:**
```typescript
export function findExpensiveSubexpressions(expr: Expr, limit: number = 5): Array<{
```

**Description:**
Find the most expensive sub-expressions in an expression
@param expr Expression to analyze
@param limit Maximum number of results to return
@returns Array of expensive sub-expressions with their costs
/

---

### flatten

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/flatten.ts:70`

**Signature:**
```typescript
export function flatten(file: EsmFile): FlattenedSystem {
```

**Description:**
Flatten a multi-system ESM file into a single unified system.

The algorithm:
1. Iterates over all models and reaction_systems in the file
2. Namespaces all variables with their system name prefix (dot notation)
3. Processes coupling entries to produce variable mappings and connector equations
4. Returns a unified flattened system

@param file - The ESM file to flatten
@returns A FlattenedSystem with all variables namespaced and equations unified
/

**Available in other languages:**
- [Julia](julia.md#flatten)
- [Julia](julia.md#flatten)
- [Julia](julia.md#flatten)
- [Julia](julia.md#flatten)

---

### formatResults

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/index.ts:238`

**Signature:**
```typescript
export function formatResults(results: any): string {
```

**Description:**
Format analysis results for display
/

---

### formatUserFriendly

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/error-handling.ts:195`

**Signature:**
```typescript
export function formatUserFriendly(error: ESMError): string {
```

---

### freeParameters

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/expression.ts:45`

**Signature:**
```typescript
export function freeParameters(expr: Expr, model: Model): Set<string> {
```

**Description:**
Extract free parameters from an expression within a model context
@param expr Expression to analyze
@param model Model context to determine parameter vs state variables
@returns Set of parameter names referenced in the expression
/

---

### freeVariables

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/expression.ts:20`

**Signature:**
```typescript
export function freeVariables(expr: Expr): Set<string> {
```

**Description:**
Extract all variable references from an expression
@param expr Expression to analyze
@returns Set of variable names referenced in the expression
/

---

### generateFactoredVariableNames

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts:298`

**Signature:**
```typescript
export function generateFactoredVariableNames(
```

**Description:**
Generate variable names for factored subexpressions
@param commonSubexpressions Array of common subexpressions
@param prefix Prefix for generated variable names
@returns Map of expressions to generated variable names
/

---

### getAvailableFormats

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/ModelExportUtils.ts:609`

**Signature:**
```typescript
export function getAvailableFormats(): ExportFormat[] {
```

**Description:**
Get available export formats
/

---

### getComponentType

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:361`

**Signature:**
```typescript
export function getComponentType(esmFile: EsmFile, componentId: string): ComponentNode['type'] | null {
```

**Description:**
Get the type of a component by its ID
/

---

### getFileExtension

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/ModelExportUtils.ts:616`

**Signature:**
```typescript
export function getFileExtension(format: ExportFormat): string {
```

**Description:**
Get file extension for export format
/

---

### getProfiler

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/error-handling.ts:486`

**Signature:**
```typescript
export function getProfiler(): PerformanceProfiler {
```

---

### getSupportedMigrationTargets

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/migration.ts:30`

**Signature:**
```typescript
export function getSupportedMigrationTargets(sourceVersion: string): string[] {
```

**Description:**
Get the list of schema versions that a given source version can migrate to.
/

---

### gradient

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/differentiation.ts:52`

**Signature:**
```typescript
export function gradient(expr: Expr, variables?: string[]): DerivativeResult[] {
```

**Description:**
Compute the gradient (all first partial derivatives)
@param expr Expression to differentiate
@param variables Array of variables (if not provided, will extract from expression)
@returns Gradient as array of derivatives
/

---

### groupSubexpressionsByType

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts:320`

**Signature:**
```typescript
export function groupSubexpressionsByType(
```

**Description:**
Group common subexpressions by their structure type
@param commonSubexpressions Array of common subexpressions
@returns Grouped subexpressions by operation type
/

---

### higherOrderDerivative

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/differentiation.ts:494`

**Signature:**
```typescript
export function higherOrderDerivative(expr: Expr, variable: string, order: number = 1): DerivativeResult {
```

**Description:**
Compute higher-order derivatives
@param expr Expression to differentiate
@param variable Variable with respect to which to differentiate
@param order Order of derivative (default: 1)
@returns Higher-order derivative result
/

---

### isDifferentiable

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/differentiation.ts:527`

**Signature:**
```typescript
export function isDifferentiable(expr: Expr, variable: string): boolean {
```

**Description:**
Check if an expression is differentiable with respect to a variable
@param expr Expression to check
@param variable Variable to check differentiability with respect to
@returns True if differentiable, false otherwise
/

---

### load

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/parse.ts:1767`

**Signature:**
```typescript
export function load(input: string | object): EsmFile {
```

**Description:**
Load an ESM file from a JSON string or pre-parsed object

@param input - JSON string or pre-parsed JavaScript object
@returns Typed EsmFile object
@throws {ParseError} When JSON parsing fails or version is incompatible
@throws {SchemaValidationError} When schema validation fails
/

**Available in other languages:**
- [Julia](julia.md#load)
- [Julia](julia.md#load)
- [Julia](julia.md#load)
- [Python](python.md#load)

---

### mapVariable

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:527`

**Signature:**
```typescript
export function mapVariable(
```

**Description:**
Map a variable from one system to another with optional transformation
@param file ESM file
@param from Source variable reference
@param to Target variable reference
@param transform Optional transformation type
@returns New ESM file with variable mapping coupling added
/

---

### merge

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:553`

**Signature:**
```typescript
export function merge(
```

**Description:**
Merge two ESM files
@param fileA First ESM file
@param fileB Second ESM file
@returns New ESM file with merged content
/

**Available in other languages:**
- [Julia](julia.md#merge)
- [Julia](julia.md#merge)

---

### migrate

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/migration.ts:40`

**Signature:**
```typescript
export function migrate(file: EsmFile, targetVersion: string): EsmFile {
```

**Description:**
Migrate an ESM file from its current schema version to the target version.
/

**Available in other languages:**
- [Python](python.md#migrate)

---

### parseUnit

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/units.ts:65`

**Signature:**
```typescript
export function parseUnit(unitStr: string): DimensionalRep {
```

**Description:**
Parse a unit string into canonical dimensional representation

Handles common patterns:
- "mol/mol" → {dimensionless: true} (cancels out)
- "cm^3/molec/s" → {cm: 3, molec: -1, s: -1}
- "K" → {K: 1}
- "m/s" → {m: 1, s: -1}
- "1/s" → {s: -1}
- "degrees" → {dimensionless: true}

@param unitStr Unit string to parse
@returns Dimensional representation
/

---

### partialDerivatives

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/differentiation.ts:36`

**Signature:**
```typescript
export function partialDerivatives(expr: Expr, variables: string[]): Map<string, DerivativeResult> {
```

**Description:**
Compute partial derivatives with respect to multiple variables
@param expr Expression to differentiate
@param variables Array of variables to differentiate with respect to
@returns Map of variable names to their derivative results
/

---

### productMatrix

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/reactions.ts:314`

**Signature:**
```typescript
export function productMatrix(system: ReactionSystem): number[][] {
```

**Description:**
Compute product stoichiometric matrix from a reaction system

Returns the product stoichiometric matrix (species × reactions) where:
- Rows are species (in declaration order)
- Columns are reactions (in array order)
- Entry [i][j] = product stoichiometry for species i in reaction j
- Null products contribute 0

@param system ReactionSystem to compute matrix from
@returns Product stoichiometric matrix
/

---

### profileOperation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/error-handling.ts:491`

**Signature:**
```typescript
export function profileOperation(operationName: string) {
```

---

### registerWebComponents

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/web-components.ts:565`

**Signature:**
```typescript
export function registerWebComponents() {
```

---

### registerWebComponents

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/web-components.ts:420`

**Signature:**
```typescript
export function registerWebComponents() {
```

**Description:**
Register all ESM editor web components
/

---

### removeCoupling

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:482`

**Signature:**
```typescript
export function removeCoupling(
```

**Description:**
Remove a coupling entry from an ESM file by index
@param file ESM file to remove coupling from
@param index Index of coupling entry to remove
@returns New ESM file with coupling removed
@throws EntityNotFoundError if index is out of bounds
/

---

### removeEquation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:211`

**Signature:**
```typescript
export function removeEquation(
```

**Description:**
Remove an equation from a model
@param model Model to remove equation from
@param indexOrLhs Either the numeric index or the LHS expression of the equation
@returns New model with equation removed
@throws EntityNotFoundError if equation not found
/

---

### removeEvent

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:422`

**Signature:**
```typescript
export function removeEvent(
```

**Description:**
Remove an event from a model by name
@param model Model to remove event from
@param name Event name to remove
@returns New model with event removed
@throws EntityNotFoundError if event not found
/

---

### removeReaction

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:279`

**Signature:**
```typescript
export function removeReaction(
```

**Description:**
Remove a reaction from a reaction system
@param system ReactionSystem to remove reaction from
@param id Reaction ID to remove
@returns New reaction system with reaction removed
@throws EntityNotFoundError if reaction not found
/

---

### removeSpecies

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:328`

**Signature:**
```typescript
export function removeSpecies(
```

**Description:**
Remove a species from a reaction system, with reference checking
@param system ReactionSystem to remove species from
@param name Species name to remove
@returns New reaction system with species removed
@throws VariableInUseError if species is still referenced in reactions
@throws EntityNotFoundError if species doesn't exist
/

---

### removeVariable

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:83`

**Signature:**
```typescript
export function removeVariable(
```

**Description:**
Remove a variable from a model, with reference checking
@param model Model to remove variable from
@param name Variable name to remove
@returns New model with variable removed
@throws VariableInUseError if variable is still referenced
@throws EntityNotFoundError if variable doesn't exist
/

---

### renameVariable

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:155`

**Signature:**
```typescript
export function renameVariable(
```

**Description:**
Rename a variable throughout a model
@param model Model to rename variable in
@param oldName Current variable name
@param newName New variable name
@returns New model with variable renamed
@throws EntityNotFoundError if variable doesn't exist
/

---

### save

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/serialize.ts:15`

**Signature:**
```typescript
export function save(file: EsmFile): string {
```

**Description:**
Serialize an EsmFile object to a formatted JSON string

@param file - The EsmFile object to serialize
@returns Formatted JSON string representation
/

**Available in other languages:**
- [Julia](julia.md#save)
- [Julia](julia.md#save)
- [Julia](julia.md#save)

---

### setupErrorLogging

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/error-handling.ts:628`

**Signature:**
```typescript
export function setupErrorLogging(config: ErrorLoggerConfig = { logLevel: 'info', logToConsole: true }) {
```

---

### simplify

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/expression.ts:210`

**Signature:**
```typescript
export function simplify(expr: Expr): Expr {
```

**Description:**
Simplify an expression using basic algebraic rules
@param expr Expression to simplify
@returns Simplified expression
/

**Available in other languages:**
- [Julia](julia.md#simplify)
- [Julia](julia.md#simplify)

---

### stoichiometricMatrix

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/reactions.ts:225`

**Signature:**
```typescript
export function stoichiometricMatrix(system: ReactionSystem): {
```

**Description:**
Compute stoichiometric matrix from a reaction system

Returns the net stoichiometric matrix (species × reactions) where:
- Rows are species (in declaration order)
- Columns are reactions (in array order)
- Entry [i][j] = (stoichiometry as product) - (stoichiometry as substrate) for species i in reaction j
- Null substrates contribute 0 to substrate stoichiometry
- Null products contribute 0 to product stoichiometry

@param system ReactionSystem to compute matrix from
@returns Object containing matrix, species list, and reactions list
/

---

### substitute

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/substitute.ts:27`

**Signature:**
```typescript
export function substitute(
```

**Description:**
Recursively substitute variable references in an expression with bound expressions.
Handles scoped references (Model.Subsystem.var) by splitting on '.' and matching
path through system hierarchy per format spec Section 4.3.

@param expr - Expression to substitute into
@param bindings - Variable name to expression mappings
@param context - Optional context for resolving scoped references
@returns New expression with substitutions applied (immutable)
/

**Available in other languages:**
- [Julia](julia.md#substitute)
- [Julia](julia.md#substitute)

---

### substituteInEquations

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/edit.ts:245`

**Signature:**
```typescript
export function substituteInEquations(
```

**Description:**
Apply substitutions to all equations in a model
@param model Model to apply substitutions to
@param bindings Variable name to expression mappings
@returns New model with substitutions applied
/

---

### substituteInModel

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/substitute.ts:148`

**Signature:**
```typescript
export function substituteInModel(
```

**Description:**
Apply substitution across all equations in a model.
Returns a new model with substitutions applied (immutable).

@param model - Model to substitute into
@param bindings - Variable name to expression mappings
@param context - Optional context for resolving scoped references
@returns New model with substitutions applied
/

---

### substituteInReactionSystem

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/substitute.ts:200`

**Signature:**
```typescript
export function substituteInReactionSystem(
```

**Description:**
Apply substitution across all rate expressions in a reaction system.
Returns a new reaction system with substitutions applied (immutable).

@param system - ReactionSystem to substitute into
@param bindings - Variable name to expression mappings
@param context - Optional context for resolving scoped references
@returns New reaction system with substitutions applied
/

---

### substrateMatrix

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/reactions.ts:280`

**Signature:**
```typescript
export function substrateMatrix(system: ReactionSystem): number[][] {
```

**Description:**
Compute substrate stoichiometric matrix from a reaction system

Returns the substrate stoichiometric matrix (species × reactions) where:
- Rows are species (in declaration order)
- Columns are reactions (in array order)
- Entry [i][j] = substrate stoichiometry for species i in reaction j
- Null substrates contribute 0

@param system ReactionSystem to compute matrix from
@returns Substrate stoichiometric matrix
/

---

### toAscii

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/pretty-print.ts:577`

**Signature:**
```typescript
export function toAscii(expr: Expr | Equation | Model | ReactionSystem | EsmFile): string {
```

**Description:**
Format an expression as plain ASCII text
/

---

### toLatex

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/pretty-print.ts:536`

**Signature:**
```typescript
export function toLatex(expr: Expr | Equation | Model | ReactionSystem | EsmFile): string {
```

**Description:**
Format an expression as LaTeX mathematical notation
/

---

### toMathML

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/pretty-print.ts:617`

**Signature:**
```typescript
export function toMathML(expr: Expr | Equation | Model | ReactionSystem | EsmFile): string {
```

**Description:**
Format an expression as MathML markup for web/academic publishing
/

---

### toUnicode

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/pretty-print.ts:496`

**Signature:**
```typescript
export function toUnicode(expr: Expr | Equation | Model | ReactionSystem | EsmFile): string {
```

**Description:**
Format an expression as Unicode mathematical notation
/

---

### validate

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/validate.ts:856`

**Signature:**
```typescript
export function validate(data: string | object): ValidationResult {
```

**Description:**
Validate ESM data and return structured validation result.

@param data - ESM data as JSON string or object
@returns ValidationResult with validation status and errors
/

**Available in other languages:**
- [Julia](julia.md#validate)
- [Julia](julia.md#validate)

---

### validateSchema

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/parse.ts:1468`

**Signature:**
```typescript
export function validateSchema(data: unknown): SchemaError[] {
```

**Description:**
Validate data against the ESM schema
/

---

### validateUnits

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/units.ts:408`

**Signature:**
```typescript
export function validateUnits(file: EsmFile): UnitWarning[] {
```

**Description:**
Validate dimensional consistency of all equations in an ESM file
@param file ESM file to validate
@returns Array of unit warnings
/

---

## Types

### AffectEquation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:412`

**Definition:**
```typescript
export interface AffectEquation {
```

**Description:**
An affect equation in an event: lhs is the target variable (string), rhs is an expression.
/

**Available in other languages:**
- [Julia](julia.md#affectequation)
- [Python](python.md#affectequation)

---

### Assertion

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:559`

**Definition:**
```typescript
export interface Assertion {
```

**Description:**
A single scalar check at a (variable, time) point.
/

---

### AstStore

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/ast-store.ts:39`

**Definition:**
```typescript
export interface AstStore {
```

**Description:**
AST Store interface providing centralized ESM file management
/

---

### AstStoreConfig

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/ast-store.ts:27`

**Definition:**
```typescript
export interface AstStoreConfig {
```

**Description:**
Configuration for the AST store
/

---

### BoundaryCondition

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1195`

**Definition:**
```typescript
export interface BoundaryCondition {
```

**Description:**
Boundary condition for one or more dimensions.
/

**Available in other languages:**
- [Python](python.md#boundarycondition)

---

### Change

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/index.ts:73`

**Definition:**
```typescript
export interface Change {
```

---

### Command

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/index.ts:56`

**Definition:**
```typescript
export interface Command {
```

---

### CommandResult

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/index.ts:67`

**Definition:**
```typescript
export interface CommandResult {
```

---

### CommonSubexpression

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:70`

**Definition:**
```typescript
export interface CommonSubexpression {
```

---

### ComplexityMetrics

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:52`

**Definition:**
```typescript
export interface ComplexityMetrics {
```

---

### ComponentGraph

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:53`

**Definition:**
```typescript
export interface ComponentGraph {
```

---

### ComponentNode

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:12`

**Definition:**
```typescript
export interface ComponentNode {
```

**Available in other languages:**
- [Julia](julia.md#componentnode)
- [Python](python.md#componentnode)

---

### ConnectorEquation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1042`

**Definition:**
```typescript
export interface ConnectorEquation {
```

**Description:**
A single equation in a ConnectorSystem linking two coupled systems.
/

**Available in other languages:**
- [Python](python.md#connectorequation)

---

### ContinuousEvent

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:452`

**Definition:**
```typescript
export interface ContinuousEvent {
```

**Description:**
Fires when a condition expression crosses zero (root-finding). Maps to MTK SymbolicContinuousCallback.
/

**Available in other languages:**
- [Julia](julia.md#continuousevent)
- [Python](python.md#continuousevent)

---

### CoordinateTransform

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1187`

**Definition:**
```typescript
export interface CoordinateTransform {
```

**Available in other languages:**
- [Python](python.md#coordinatetransform)

---

### CouplingCallback

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1105`

**Definition:**
```typescript
export interface CouplingCallback {
```

**Description:**
Register a callback for simulation events.
/

**Available in other languages:**
- [Julia](julia.md#couplingcallback)

---

### CouplingCouple

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1016`

**Definition:**
```typescript
export interface CouplingCouple {
```

**Description:**
Bi-directional coupling via explicit ConnectorSystem equations.
/

**Available in other languages:**
- [Julia](julia.md#couplingcouple)
- [Python](python.md#couplingcouple)

---

### CouplingEdge

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:35`

**Definition:**
```typescript
export interface CouplingEdge {
```

**Available in other languages:**
- [Julia](julia.md#couplingedge)
- [Python](python.md#couplingedge)
- [Python](python.md#couplingedge)

---

### CouplingOperatorApply

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1094`

**Definition:**
```typescript
export interface CouplingOperatorApply {
```

**Description:**
Register an Operator to run during simulation.
/

**Available in other languages:**
- [Julia](julia.md#couplingoperatorapply)

---

### CouplingOperatorCompose

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:988`

**Definition:**
```typescript
export interface CouplingOperatorCompose {
```

**Description:**
Match LHS time derivatives and add RHS terms together.
/

**Available in other languages:**
- [Julia](julia.md#couplingoperatorcompose)

---

### CouplingVariableMap

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1063`

**Definition:**
```typescript
export interface CouplingVariableMap {
```

**Description:**
Replace a parameter in one system with a variable from another.
/

**Available in other languages:**
- [Julia](julia.md#couplingvariablemap)

---

### DataLoader

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:826`

**Definition:**
```typescript
export interface DataLoader {
```

**Description:**
A generic, runtime-agnostic description of an external data source. Carries enough structural information to locate files, map timestamps to files, describe spatial/variable semantics, and regrid — rather than pointing at a runtime handler. Authentication and algorithm-specific tuning are runtime-only and not part of the schema.
/

**Available in other languages:**
- [Julia](julia.md#dataloader)
- [Python](python.md#dataloader)

---

### DataLoaderRegridding

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:950`

**Definition:**
```typescript
export interface DataLoaderRegridding {
```

**Description:**
Structural regridding configuration. Algorithm-specific tuning parameters are runtime-side and not in the schema.
/

---

### DataLoaderSource

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:853`

**Definition:**
```typescript
export interface DataLoaderSource {
```

**Description:**
File discovery configuration. Describes how to locate data files at runtime via URL templates with date/variable substitutions.
/

---

### DataLoaderSpatial

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:895`

**Definition:**
```typescript
export interface DataLoaderSpatial {
```

**Description:**
Spatial grid description for a data source.
/

---

### DataLoaderStaggering

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:925`

**Definition:**
```typescript
export interface DataLoaderStaggering {
```

**Description:**
Per-dimension grid staggering (centered or edge-aligned).
/

---

### DataLoaderTemporal

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:866`

**Definition:**
```typescript
export interface DataLoaderTemporal {
```

**Description:**
Temporal coverage and record layout for a data source.
/

---

### DataLoaderVariable

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:931`

**Definition:**
```typescript
export interface DataLoaderVariable {
```

**Description:**
A variable exposed by a data loader, mapped from a source-file variable.
/

---

### DemoPageConfig

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/demo/demo-pages.ts:8`

**Definition:**
```typescript
export interface DemoPageConfig {
```

---

### DependencyEdge

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:87`

**Definition:**
```typescript
export interface DependencyEdge {
```

**Available in other languages:**
- [Julia](julia.md#dependencyedge)
- [Python](python.md#dependencyedge)

---

### DependencyGraph

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:42`

**Definition:**
```typescript
export interface DependencyGraph extends Graph<DependencyNode, DependencyRelation> {
```

---

### DependencyNode

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:12`

**Definition:**
```typescript
export interface DependencyNode {
```

---

### DependencyRelation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:28`

**Definition:**
```typescript
export interface DependencyRelation {
```

---

### DerivativeResult

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:126`

**Definition:**
```typescript
export interface DerivativeResult {
```

---

### DimensionalRep

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/units.ts:14`

**Definition:**
```typescript
export interface DimensionalRep {
```

**Description:**
Canonical dimensional representation
Maps base dimensions to their powers
/

---

### Domain

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1146`

**Definition:**
```typescript
export interface Domain {
```

**Description:**
Spatiotemporal domain specification (DomainInfo).
/

**Available in other languages:**
- [Julia](julia.md#domain)
- [Python](python.md#domain)

---

### DragState

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/index.ts:41`

**Definition:**
```typescript
export interface DragState {
```

---

### ESMError

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/error-handling.ts:101`

**Definition:**
```typescript
export interface ESMError {
```

**Available in other languages:**
- [Julia](julia.md#esmerror)
- [Python](python.md#esmerror)

---

### ESMFormat2

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:208`

**Definition:**
```typescript
export interface ESMFormat2 {
```

---

### EditorState

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/index.ts:24`

**Definition:**
```typescript
export interface EditorState {
```

---

### Equation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:404`

**Definition:**
```typescript
export interface Equation {
```

**Description:**
An equation: lhs = rhs (or lhs ~ rhs in MTK notation).
/

**Available in other languages:**
- [Julia](julia.md#equation)
- [Python](python.md#equation)
- [Python](python.md#equation)

---

### ErrorContext

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/error-handling.ts:80`

**Definition:**
```typescript
export interface ErrorContext {
```

**Available in other languages:**
- [Julia](julia.md#errorcontext)
- [Python](python.md#errorcontext)

---

### ErrorLoggerConfig

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/error-handling.ts:621`

**Definition:**
```typescript
export interface ErrorLoggerConfig {
```

---

### EsmCouplingGraphProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/web-components.ts:84`

**Definition:**
```typescript
export interface EsmCouplingGraphProps {
```

**Description:**
Web component wrapper for CouplingGraph

Usage:
<esm-coupling-graph
esm-file='{"components": [...], "coupling": [...]}'
width="800"
height="600"
interactive="true">
</esm-coupling-graph>
/

---

### EsmCouplingGraphProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/web-components.ts:143`

**Definition:**
```typescript
export interface EsmCouplingGraphProps {
```

**Description:**
Web component wrapper for CouplingGraph

Usage:
<esm-coupling-graph
esm-file='{"components": [...], "coupling": [...]}'
width="800"
height="600"
interactive="true"
allow-editing="true">
</esm-coupling-graph>
/

---

### EsmExpressionEditorProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/web-components.ts:55`

**Definition:**
```typescript
export interface EsmExpressionEditorProps {
```

**Description:**
Web component wrapper for EquationEditor (expression editing)

Usage:
<esm-expression-editor
expression='{"op": "+", "args": [1, 2]}'
allow-editing="true"
show-palette="true">
</esm-expression-editor>
/

---

### EsmExpressionNodeProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/web-components.ts:36`

**Definition:**
```typescript
export interface EsmExpressionNodeProps {
```

**Description:**
Web component wrapper for ExpressionNode

Usage:
<esm-expression-node
expression='{"op": "+", "args": [1, 2]}'
path='["root"]'
allow-editing="true">
</esm-expression-node>
/

---

### EsmFileEditorProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/web-components.ts:97`

**Definition:**
```typescript
export interface EsmFileEditorProps {
```

**Description:**
Web component wrapper for complete ESM file editing

Usage:
<esm-file-editor
esm-file='{"components": {...}, "coupling": [...]}'
allow-editing="true"
enable-undo="true">
</esm-file-editor>
/

---

### EsmFileSummaryProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/web-components.ts:135`

**Definition:**
```typescript
export interface EsmFileSummaryProps {
```

**Description:**
Web component wrapper for FileSummary

Usage:
<esm-file-summary
esm-file='{"components": [...], "coupling": [...]}'
show-details="true"
show-export-options="true">
</esm-file-summary>
/

---

### EsmModelEditorProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/web-components.ts:59`

**Definition:**
```typescript
export interface EsmModelEditorProps {
```

**Description:**
Web component wrapper for ModelEditor

Usage:
<esm-model-editor
model='{"variables": {...}, "equations": [...]}'
allow-editing="true">
</esm-model-editor>
/

---

### EsmModelEditorProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/web-components.ts:76`

**Definition:**
```typescript
export interface EsmModelEditorProps {
```

**Description:**
Web component wrapper for ModelEditor

Usage:
<esm-model-editor
model='{"variables": {...}, "equations": [...]}'
allow-editing="true"
show-validation="true">
</esm-model-editor>
/

---

### EsmReactionEditorProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/web-components.ts:120`

**Definition:**
```typescript
export interface EsmReactionEditorProps {
```

**Description:**
Web component wrapper for ReactionEditor

Usage:
<esm-reaction-editor
reaction-system='{"species": {...}, "reactions": [...]}'
allow-editing="true"
show-validation="true">
</esm-reaction-editor>
/

---

### EsmSimulationControlsProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/web-components.ts:157`

**Definition:**
```typescript
export interface EsmSimulationControlsProps {
```

**Description:**
Web component wrapper for SimulationControls

Usage:
<esm-simulation-controls
esm-file='{"components": [...], "coupling": [...]}'
is-running="false"
progress="50"
available-backends='["julia", "python"]'>
</esm-simulation-controls>
/

---

### EsmValidationPanelProps

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/web-components.ts:108`

**Definition:**
```typescript
export interface EsmValidationPanelProps {
```

**Description:**
Web component wrapper for ValidationPanel

Usage:
<esm-validation-panel
model='{"variables": {...}, "equations": [...]}'
validation-errors='[{"message": "Error", "path": "..."}]'
show-details="true">
</esm-validation-panel>
/

---

### Example

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:590`

**Definition:**
```typescript
export interface Example {
```

**Description:**
An inline illustrative example of how to run the enclosing component. Defines the run configuration and one or more plots derived from the result.
/

---

### ExportOptions

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/ModelExportUtils.ts:19`

**Definition:**
```typescript
export interface ExportOptions {
```

**Description:**
Export options for different formats
/

---

### ExpressionLocation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:82`

**Definition:**
```typescript
export interface ExpressionLocation {
```

---

### ExpressionNode

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:346`

**Definition:**
```typescript
export interface ExpressionNode {
```

**Description:**
An operation in the expression AST.
/

---

### ExpressionPattern

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:92`

**Definition:**
```typescript
export interface ExpressionPattern {
```

---

### FixSuggestion

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/error-handling.ts:92`

**Definition:**
```typescript
export interface FixSuggestion {
```

**Available in other languages:**
- [Julia](julia.md#fixsuggestion)
- [Python](python.md#fixsuggestion)

---

### FlattenMetadata

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/flatten.ts:35`

**Definition:**
```typescript
export interface FlattenMetadata {
```

**Description:**
Metadata describing the origin of the flattened system.
/

**Available in other languages:**
- [Julia](julia.md#flattenmetadata)
- [Python](python.md#flattenmetadata)

---

### FlattenedEquation

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/flatten.ts:23`

**Definition:**
```typescript
export interface FlattenedEquation {
```

**Description:**
A single equation in the flattened system, with dot-namespaced variable names.
/

**Available in other languages:**
- [Python](python.md#flattenedequation)

---

### FlattenedSystem

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/flatten.ts:45`

**Definition:**
```typescript
export interface FlattenedSystem {
```

**Description:**
A fully flattened representation of a coupled ESM system.
/

**Available in other languages:**
- [Julia](julia.md#flattenedsystem)
- [Python](python.md#flattenedsystem)

---

### FunctionalAffect

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:425`

**Definition:**
```typescript
export interface FunctionalAffect {
```

**Description:**
Registered functional affect handler (alternative to symbolic affects).
/

**Available in other languages:**
- [Julia](julia.md#functionalaffect)
- [Python](python.md#functionalaffect)

---

### FunctionalAffect1

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1119`

**Definition:**
```typescript
export interface FunctionalAffect1 {
```

**Description:**
Registered functional affect handler (alternative to symbolic affects).
/

---

### Graph

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:61`

**Definition:**
```typescript
export interface Graph<N, E> {
```

**Available in other languages:**
- [Julia](julia.md#graph)
- [Python](python.md#graph)

---

### GraphExportOptions

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:162`

**Definition:**
```typescript
export interface GraphExportOptions {
```

---

### HistoryEntry

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/history.ts:26`

**Definition:**
```typescript
export interface HistoryEntry {
```

**Description:**
History entry representing a state snapshot
/

---

### HoverState

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/index.ts:79`

**Definition:**
```typescript
export interface HoverState {
```

---

### Interface

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1228`

**Definition:**
```typescript
export interface Interface {
```

**Description:**
Geometric connection between two domains of potentially different dimensionality.
/

**Available in other languages:**
- [Julia](julia.md#interface)

---

### InterfaceConstraint

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1268`

**Definition:**
```typescript
export interface InterfaceConstraint {
```

**Description:**
Constraint on a non-shared dimension at the interface.
/

---

### LayoutAlgorithm

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:141`

**Definition:**
```typescript
export interface LayoutAlgorithm {
```

---

### LayoutResult

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:149`

**Definition:**
```typescript
export interface LayoutResult<N> {
```

---

### MatchResult

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:102`

**Definition:**
```typescript
export interface MatchResult {
```

---

### Metadata

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:258`

**Definition:**
```typescript
export interface Metadata {
```

**Description:**
Authorship, provenance, and description.
/

**Available in other languages:**
- [Julia](julia.md#metadata)
- [Python](python.md#metadata)

---

### Model

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:289`

**Definition:**
```typescript
export interface Model {
```

**Description:**
An ODE system — a fully specified set of time-dependent equations.
/

**Available in other languages:**
- [Julia](julia.md#model)
- [Python](python.md#model)

---

### ModelVariable

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:330`

**Definition:**
```typescript
export interface ModelVariable {
```

**Description:**
A variable in an ODE model.
/

**Available in other languages:**
- [Julia](julia.md#modelvariable)
- [Python](python.md#modelvariable)

---

### Operator

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:963`

**Definition:**
```typescript
export interface Operator {
```

**Description:**
A registered runtime operator (e.g., dry deposition, wet scavenging).
/

**Available in other languages:**
- [Julia](julia.md#operator)
- [Python](python.md#operator)

---

### Optimization

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/analysis/types.ts:112`

**Definition:**
```typescript
export interface Optimization {
```

---

### Parameter

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:775`

**Definition:**
```typescript
export interface Parameter {
```

**Description:**
A parameter in a reaction system.
/

**Available in other languages:**
- [Julia](julia.md#parameter)
- [Python](python.md#parameter)

---

### ParameterSweep

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:634`

**Definition:**
```typescript
export interface ParameterSweep {
```

**Description:**
Optional parameter sweep. When present, the example represents a family of runs (one per Cartesian combination) rather than a single trajectory.
/

---

### Plot

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:659`

**Definition:**
```typescript
export interface Plot {
```

**Description:**
A plot specification associated with an example. Only structural information is recorded — axes, series selection, and value reductions. Styling (colors, fonts, legends, themes) is the viewer's concern.
/

---

### PlotAxis

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:677`

**Definition:**
```typescript
export interface PlotAxis {
```

**Description:**
Axis specification: any state variable, observed variable, parameter name, or swept parameter may be used.
/

---

### PlotSeries

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:707`

**Definition:**
```typescript
export interface PlotSeries {
```

**Description:**
A single named series for multi-series line or scatter plots.
/

---

### PlotValue

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:690`

**Definition:**
```typescript
export interface PlotValue {
```

**Description:**
Required for heatmap; defines the color channel. Ignored for line/scatter.
/

---

### Reaction

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:783`

**Definition:**
```typescript
export interface Reaction {
```

**Description:**
A single reaction in a reaction system.
/

**Available in other languages:**
- [Julia](julia.md#reaction)
- [Python](python.md#reaction)

---

### ReactionSystem

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:714`

**Definition:**
```typescript
export interface ReactionSystem {
```

**Description:**
A reaction network — declarative representation of chemical or biological reactions.
/

**Available in other languages:**
- [Julia](julia.md#reactionsystem)
- [Python](python.md#reactionsystem)

---

### Reference

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:280`

**Definition:**
```typescript
export interface Reference {
```

**Description:**
Academic citation or data source reference.
/

**Available in other languages:**
- [Julia](julia.md#reference)
- [Python](python.md#reference)

---

### SchemaError

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/parse.ts:15`

**Definition:**
```typescript
export interface SchemaError {
```

**Description:**
Schema validation error with JSON Pointer path
/

**Available in other languages:**
- [Julia](julia.md#schemaerror)

---

### SpatialDimension

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:1181`

**Definition:**
```typescript
export interface SpatialDimension {
```

**Description:**
Specification of a single spatial dimension.
/

**Available in other languages:**
- [Python](python.md#spatialdimension)

---

### Species

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:767`

**Definition:**
```typescript
export interface Species {
```

**Description:**
A reactive species in a reaction system.
/

**Available in other languages:**
- [Julia](julia.md#species)
- [Python](python.md#species)

---

### StoichiometryEntry

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:806`

**Definition:**
```typescript
export interface StoichiometryEntry {
```

**Description:**
A species with its stoichiometric coefficient in a reaction.
/

**Available in other languages:**
- [Julia](julia.md#stoichiometryentry)

---

### StructuralError

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/validate.ts:51`

**Definition:**
```typescript
export interface StructuralError {
```

**Description:**
Structural error type matching the format specification
/

**Available in other languages:**
- [Julia](julia.md#structuralerror)

---

### SubstitutionContext

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/substitute.ts:13`

**Definition:**
```typescript
export interface SubstitutionContext {
```

**Description:**
Context for resolving scoped references during substitution
/

---

### SubsystemRef

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:484`

**Definition:**
```typescript
export interface SubsystemRef {
```

**Description:**
A reference to an external ESM file containing a model or reaction system definition. The ref field can be a relative or absolute local file path, or an HTTP/HTTPS URL. Relative paths are resolved relative to the directory of the referencing file.
/

---

### SweepRange

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:647`

**Definition:**
```typescript
export interface SweepRange {
```

**Description:**
Generated range; mutually exclusive with values.
/

---

### Test

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:506`

**Definition:**
```typescript
export interface Test {
```

**Description:**
An inline validation test for the enclosing model or reaction system. Defines the run configuration (initial conditions, parameter overrides, time span) and the scalar assertions that must hold.
/

---

### TimeSpan

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:539`

**Definition:**
```typescript
export interface TimeSpan {
```

**Description:**
Simulation time interval expressed in the component's time units.
/

---

### Tolerance

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:493`

**Definition:**
```typescript
export interface Tolerance {
```

**Description:**
Model-level default numerical tolerance for tests, used when a test or assertion does not provide its own.
/

---

### Tolerance1

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:546`

**Definition:**
```typescript
export interface Tolerance1 {
```

**Description:**
Test-level default tolerance applied to all assertions in this test that do not override it.
/

---

### Tolerance2

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:577`

**Definition:**
```typescript
export interface Tolerance2 {
```

**Description:**
Per-assertion tolerance override. If present, this takes precedence over the test-level and model-level defaults.
/

---

### Tolerance3

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/generated.ts:813`

**Definition:**
```typescript
export interface Tolerance3 {
```

**Description:**
System-level default numerical tolerance for tests, used when a test or assertion does not provide its own.
/

---

### TooltipData

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/index.ts:86`

**Definition:**
```typescript
export interface TooltipData {
```

---

### UndoHistory

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/history.ts:38`

**Definition:**
```typescript
export interface UndoHistory {
```

**Description:**
Undo/redo history management interface
/

---

### UndoHistoryConfig

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/history.ts:14`

**Definition:**
```typescript
export interface UndoHistoryConfig {
```

**Description:**
Configuration for undo history behavior
/

---

### UndoRedoState

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/index.ts:48`

**Definition:**
```typescript
export interface UndoRedoState {
```

---

### UnitResult

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/units.ts:37`

**Definition:**
```typescript
export interface UnitResult {
```

**Description:**
Result of dimensional analysis
/

---

### UnitWarning

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/units.ts:45`

**Definition:**
```typescript
export interface UnitWarning {
```

**Description:**
Unit validation warning
/

**Available in other languages:**
- [Python](python.md#unitwarning)

---

### ValidationConfig

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/validation.ts:16`

**Definition:**
```typescript
export interface ValidationConfig {
```

**Description:**
Configuration for validation behavior
/

---

### ValidationError

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/validate.ts:31`

**Definition:**
```typescript
export interface ValidationError {
```

**Description:**
Validation error with structured details
/

**Available in other languages:**
- [Python](python.md#validationerror)
- [Python](python.md#validationerror)

---

### ValidationError

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/interactive-editor/index.ts:32`

**Definition:**
```typescript
export interface ValidationError {
```

**Available in other languages:**
- [Python](python.md#validationerror)
- [Python](python.md#validationerror)

---

### ValidationErrorWithMetadata

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/validation.ts:28`

**Definition:**
```typescript
export interface ValidationErrorWithMetadata extends ValidationError {
```

**Description:**
Extended validation error with UI-specific metadata
/

---

### ValidationResult

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/validate.ts:41`

**Definition:**
```typescript
export interface ValidationResult {
```

**Description:**
Structured validation result
/

**Available in other languages:**
- [Julia](julia.md#validationresult)
- [Python](python.md#validationresult)

---

### ValidationSignals

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-editor/src/primitives/validation.ts:40`

**Definition:**
```typescript
export interface ValidationSignals {
```

**Description:**
Validation signals interface providing reactive validation state
/

---

### VariableNode

**File:** `/home/ctessum/esmlgt/EarthSciAST/polecats/pipboy/EarthSciAST/pkg/earthsci-ast-ts/src/graph.ts:75`

**Definition:**
```typescript
export interface VariableNode {
```

**Available in other languages:**
- [Julia](julia.md#variablenode)
- [Python](python.md#variablenode)

---

