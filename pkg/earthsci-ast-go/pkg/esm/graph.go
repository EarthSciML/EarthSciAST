package esm

import (
	"sort"
	"strings"
)

// ========================================
// 1. Graph Data Structures
// ========================================

// GraphEdge represents an edge in a directed graph
type GraphEdge[N any, E any] struct {
	Source N `json:"source"`
	Target N `json:"target"`
	Data   E `json:"data"`
}

// ComponentCounts is a component node's summary metadata (esm-libraries-spec
// §4.8.1). Exactly three counts are defined, and they mean different things for
// the two component types:
//
//   - a MODEL carries VarCount = len(variables), EqCount = len(equations) and
//     SpeciesCount = 0;
//   - a REACTION SYSTEM carries VarCount = 0, EqCount = len(reactions) — the
//     reaction count IS the equation count, there is no fourth field — and
//     SpeciesCount = len(species).
type ComponentCounts struct {
	VarCount     int `json:"var_count"`
	EqCount      int `json:"eq_count"`
	SpeciesCount int `json:"species_count"`
}

// ComponentNode represents a node in the component graph
type ComponentNode struct {
	ID   string `json:"id"`
	Type string `json:"type"` // "model" or "reaction_system"
	Name string `json:"name"`
	// Metadata holds the three summary counts §4.8.1 defines. It replaces the
	// four optional VariableCount/EquationCount/SpeciesCount/ReactionCount
	// pointers: the graph vocabulary has no separate reaction count, a reaction
	// system reporting its reactions through EqCount instead.
	Metadata ComponentCounts `json:"metadata"`
}

// CouplingKind identifies the kind of coupling a component-graph edge represents.
type CouplingKind string

const (
	CouplingKindOperatorCompose CouplingKind = "operator_compose"
	CouplingKindCouple          CouplingKind = "couple"
	CouplingKindVariableMap     CouplingKind = "variable_map"
)

// CouplingEdge represents an edge in the component graph
type CouplingEdge struct {
	Type          CouplingKind `json:"type"` // coupling type
	Label         *string      `json:"label,omitempty"`
	Description   *string      `json:"description,omitempty"`
	Bidirectional bool         `json:"bidirectional"`
	CouplingEntry any          `json:"coupling_entry"`
}

// Graph node kinds (esm-libraries-spec §4.8.2).
//
// This is the GRAPH vocabulary, which is COARSER than the §6.3.1 classifier
// partition the package computes internally: a sampled parameter and a constant
// parameter are both plain "parameter" here. The classifier names themselves
// (see RoleSampled / RoleConstant below) are unchanged; only the graph's node
// label uses these.
const (
	NodeKindState     = "state"
	NodeKindAlgebraic = "algebraic"
	NodeKindParameter = "parameter"
	NodeKindObserved  = "observed"
	NodeKindBrownian  = "brownian"
	NodeKindDiscrete  = "discrete"
	NodeKindSpecies   = "species"
)

// VariableNode represents a node in the expression graph
type VariableNode struct {
	// Name is the node's identity: the SCOPED name within the graph
	// ("Component.variable", "Component.Sub.variable"), or the bare name when
	// the owning system is the synthetic "default" scope — i.e. when a bare
	// Model / ReactionSystem / Equation / Reaction / Expr was graphed directly.
	Name string `json:"name"`
	// Kind is one of the NodeKind* graph kinds above.
	Kind   string  `json:"kind"`
	Units  *string `json:"units,omitempty"`
	System string  `json:"system"`
}

// DependencyEdge represents an edge in the expression graph. Source and Target
// are node keys (VariableNode.Name), i.e. scoped names.
type DependencyEdge struct {
	Source        string     `json:"source"`
	Target        string     `json:"target"`
	Relationship  string     `json:"relationship"` // "additive", "multiplicative", "rate", "stoichiometric"
	EquationIndex *int       `json:"equation_index,omitempty"`
	Expression    Expression `json:"expression,omitempty"`
}

// NonEquationIndex is the EquationIndex sentinel for a dependency that does not
// originate from a positionally-numbered equation or reaction — currently only
// a coupling variable map folded in by ExpressionGraphOptions.MergeCoupled.
const NonEquationIndex = -1

// Dependency-edge relationship labels. These are PROVENANCE categories (which
// structural site produced the edge), not a reading of the operators involved:
// an equation edge is always "additive" even for `w = u * v`, and a definition
// edge always "multiplicative" even for `w = u + v`.
const (
	relationshipEquation      = "additive"
	relationshipDefinition    = "multiplicative"
	relationshipRate          = "rate"
	relationshipStoichiometry = "stoichiometric"
)

// defaultSystem is the synthetic owning system of a graph built from a bare
// Model / ReactionSystem / Equation / Reaction / Expr. Nodes in it keep BARE
// names (the scoping rule below composes nothing onto it).
const defaultSystem = "default"

// ComponentGraph is a specialized graph for system components
type ComponentGraph struct {
	Nodes []ComponentNode                          `json:"nodes"`
	Edges []GraphEdge[ComponentNode, CouplingEdge] `json:"edges"`
}

// ExpressionGraph is a specialized graph for variable dependencies
type ExpressionGraph struct {
	Nodes []VariableNode                            `json:"nodes"`
	Edges []GraphEdge[VariableNode, DependencyEdge] `json:"edges"`
}

// ========================================
// 2. Component Graph Construction
// ========================================

// ComponentGraphFromFile creates a component graph from an ESM file.
//
// Models and reaction systems are visited in sorted key order: ranging over the
// maps directly made the node and edge lists differ run to run, which is not a
// conformance failure (order is not pinned) but does make every rendered or
// diffed export nondeterministic.
func ComponentGraphFromFile(file *ESMFile) *ComponentGraph {
	graph := &ComponentGraph{
		Nodes: make([]ComponentNode, 0),
		Edges: make([]GraphEdge[ComponentNode, CouplingEdge], 0),
	}

	// Create a map to track nodes by ID for edge creation
	nodeMap := make(map[string]ComponentNode)

	// Add nodes for models.
	for _, id := range sortedKeys(file.Models) {
		model := file.Models[id]
		node := ComponentNode{
			ID:   id,
			Type: "model",
			Name: id,
			Metadata: ComponentCounts{
				VarCount:     len(model.Variables),
				EqCount:      len(model.Equations),
				SpeciesCount: 0,
			},
		}
		graph.Nodes = append(graph.Nodes, node)
		nodeMap[id] = node
	}

	// Add nodes for reaction systems. A reaction system has no variables, and
	// its REACTIONS are what EqCount reports.
	for _, id := range sortedKeys(file.ReactionSystems) {
		system := file.ReactionSystems[id]
		node := ComponentNode{
			ID:   id,
			Type: "reaction_system",
			Name: id,
			Metadata: ComponentCounts{
				VarCount:     0,
				EqCount:      len(system.Reactions),
				SpeciesCount: len(system.Species),
			},
		}
		graph.Nodes = append(graph.Nodes, node)
		nodeMap[id] = node
	}

	// A `data_sources` entry is NOT a graph node. From esm 1.0.0 it is a
	// document-scoped ingest registry rather than a component: it exposes no
	// variables, cannot be a coupling endpoint, and therefore has no edges to
	// draw (esm-spec §8, CONFORMANCE_SPEC §3.4). External data reaches a model
	// through a PARAMETER of that model, which is already a node's variable.

	// `operators` block removed in v0.3.0 (closed-function-registry RFC).

	// Add edges for coupling entries
	for _, coupling := range file.Coupling {
		edges := createCouplingEdges(coupling, nodeMap)
		graph.Edges = append(graph.Edges, edges...)
	}

	return graph
}

// createCouplingEdges creates edges for a coupling entry.
//
// A coupling that names no two DECLARED component nodes contributes nothing:
// `event` carries its system references inside condition/affect expressions
// rather than as a data flow, `callback` no longer declares source/target, and
// an endpoint naming a subsystem member or a nonexistent component is skipped
// rather than fabricated.
func createCouplingEdges(coupling any, nodeMap map[string]ComponentNode) []GraphEdge[ComponentNode, CouplingEdge] {
	var edges []GraphEdge[ComponentNode, CouplingEdge]

	switch c := coupling.(type) {
	case OperatorComposeCoupling:
		source, sourceExists := nodeMap[c.Systems[0]]
		target, targetExists := nodeMap[c.Systems[1]]

		if sourceExists && targetExists {
			label := "compose"
			edge := GraphEdge[ComponentNode, CouplingEdge]{
				Source: source,
				Target: target,
				Data: CouplingEdge{
					Type:          CouplingKindOperatorCompose,
					Label:         &label,
					Description:   c.Description,
					Bidirectional: true,
					CouplingEntry: c,
				},
			}
			edges = append(edges, edge)
		}

	case CouplingCouple:
		source, sourceExists := nodeMap[c.Systems[0]]
		target, targetExists := nodeMap[c.Systems[1]]

		if sourceExists && targetExists {
			label := "couple"
			edge := GraphEdge[ComponentNode, CouplingEdge]{
				Source: source,
				Target: target,
				Data: CouplingEdge{
					Type:          CouplingKindCouple,
					Label:         &label,
					Description:   c.Description,
					Bidirectional: true,
					CouplingEntry: c,
				},
			}
			edges = append(edges, edge)
		}

	case VariableMapCoupling:
		// BOTH endpoints must be scoped `Component.path` references. An
		// unscoped one is not a variable of a declared component, so the entry
		// is skipped entirely rather than being read as a bare system name.
		fromSystem, fromVar, fromScoped := splitScopedReference(c.From)
		toSystem, _, toScoped := splitScopedReference(c.To)
		if !fromScoped || !toScoped {
			return edges
		}

		source, sourceExists := nodeMap[fromSystem]
		target, targetExists := nodeMap[toSystem]

		if sourceExists && targetExists {
			// The label is everything after the FIRST dot of the `from`
			// reference — the variable path within its component, not just the
			// last segment.
			varName := fromVar
			edge := GraphEdge[ComponentNode, CouplingEdge]{
				Source: source,
				Target: target,
				Data: CouplingEdge{
					Type:          CouplingKindVariableMap,
					Label:         &varName,
					Description:   c.Description,
					Bidirectional: false,
					CouplingEntry: c,
				},
			}
			edges = append(edges, edge)
		}
	}

	return edges
}

// ========================================
// 3. Expression Graph Construction
// ========================================

// ExpressionGraphOptions tunes ExpressionGraphFromFileWithOptions.
type ExpressionGraphOptions struct {
	// MergeCoupled folds every `variable_map` coupling entry into a
	// cross-system dependency edge (esm-libraries-spec §4.8.2, "coupled
	// file-level graph"), adding either endpoint as a parameter node if the
	// component that owns it did not declare it.
	MergeCoupled bool
}

// exprGraphBuilder is the mutable accumulator threaded through the expression
// graph helpers: the growing node/edge lists plus the dedup map keyed by scoped
// node name.
type exprGraphBuilder struct {
	graph   *ExpressionGraph
	nodeMap map[string]VariableNode
}

func newExprGraphBuilder() *exprGraphBuilder {
	return &exprGraphBuilder{
		graph: &ExpressionGraph{
			Nodes: make([]VariableNode, 0),
			Edges: make([]GraphEdge[VariableNode, DependencyEdge], 0),
		},
		nodeMap: make(map[string]VariableNode),
	}
}

// scopedVariableName composes a variable's node key from its owning system and
// its local name. The synthetic "default" system composes nothing, so a bare
// Model / Equation / Expr target yields bare node names.
func scopedVariableName(system, name string) string {
	if system == defaultSystem {
		return name
	}
	return system + "." + name
}

// childSystemName composes a subsystem's scope from its parent's.
func childSystemName(parent, child string) string {
	if parent == defaultSystem {
		return child
	}
	return parent + "." + child
}

// addNode adds a variable node (deduped by scoped name) and returns its key.
// The FIRST kind wins: a declared variable classified by §6.3.1 keeps that
// classification even if an equation later mentions it as an assignment target.
func (b *exprGraphBuilder) addNode(name, kind string, units *string, system string) string {
	key := scopedVariableName(system, name)
	if _, exists := b.nodeMap[key]; !exists {
		node := VariableNode{Name: key, Kind: kind, Units: units, System: system}
		b.graph.Nodes = append(b.graph.Nodes, node)
		b.nodeMap[key] = node
	}
	return key
}

// addDependency appends a dependency edge between two node keys.
func (b *exprGraphBuilder) addDependency(source, target, relationship string, equationIndex int, expr Expression) {
	// Per-iteration copy: taking &i of a range variable would make every edge
	// point at the last index.
	idx := equationIndex
	b.graph.Edges = append(b.graph.Edges, GraphEdge[VariableNode, DependencyEdge]{
		Source: b.nodeMap[source],
		Target: b.nodeMap[target],
		Data: DependencyEdge{
			Source:        source,
			Target:        target,
			Relationship:  relationship,
			EquationIndex: &idx,
			Expression:    expr,
		},
	})
}

// ExpressionGraphFromFile creates an expression graph from an ESM file.
func ExpressionGraphFromFile(file *ESMFile) *ExpressionGraph {
	return ExpressionGraphFromFileWithOptions(file, ExpressionGraphOptions{})
}

// ExpressionGraphFromFileWithOptions creates an expression graph from an ESM
// file, honouring opts.
//
// Every inline model and reaction system is walked, INCLUDING its inline
// `subsystems` (recursively): a subsystem's variables are part of the document's
// dependency structure, and omitting them silently truncated the graph. Scoped
// names compose with a dot; `{ref}` include stubs are skipped as opaque leaves.
//
// Components are visited in sorted key order so the node and edge lists do not
// vary run to run.
func ExpressionGraphFromFileWithOptions(file *ESMFile, opts ExpressionGraphOptions) *ExpressionGraph {
	b := newExprGraphBuilder()

	for _, systemName := range sortedKeys(file.Models) {
		model := file.Models[systemName]
		b.processModelTree(&model, systemName)
	}

	for _, systemName := range sortedKeys(file.ReactionSystems) {
		system := file.ReactionSystems[systemName]
		b.processReactionSystemTree(&system, systemName)
	}

	if opts.MergeCoupled {
		b.processCoupling(file.Coupling)
	}

	return b.graph
}

// ExpressionGraphFromModel creates an expression graph for a single model,
// including its inline subsystems. Pass "default" as systemName for a bare
// target whose nodes should carry unscoped names.
func ExpressionGraphFromModel(model Model, systemName string) *ExpressionGraph {
	b := newExprGraphBuilder()
	b.processModelTree(&model, systemName)
	return b.graph
}

// ExpressionGraphFromReactionSystem creates an expression graph for a single
// reaction system, including its inline subsystems.
func ExpressionGraphFromReactionSystem(system ReactionSystem, systemName string) *ExpressionGraph {
	b := newExprGraphBuilder()
	b.processReactionSystemTree(&system, systemName)
	return b.graph
}

// ExpressionGraphFromEquation creates an expression graph for a single equation
// (esm-libraries-spec §4.8.2). The equation is numbered 0 and its variables are
// unscoped.
func ExpressionGraphFromEquation(equation Equation) *ExpressionGraph {
	b := newExprGraphBuilder()
	b.processEquation(equation, 0, defaultSystem)
	return b.graph
}

// ExpressionGraphFromReaction creates an expression graph for a single reaction
// (esm-libraries-spec §4.8.2). The reaction is numbered 0 and its species are
// unscoped.
func ExpressionGraphFromReaction(reaction Reaction) *ExpressionGraph {
	b := newExprGraphBuilder()
	b.processReaction(reaction, 0, defaultSystem)
	return b.graph
}

// ExpressionGraphFromExpression creates an expression graph for a bare
// expression (esm-libraries-spec §4.8.2). A synthetic `expr_result` observed
// node stands in for the expression's value, and every free variable feeds it.
func ExpressionGraphFromExpression(expr Expression) *ExpressionGraph {
	b := newExprGraphBuilder()
	b.processExpression(expr, "expr_result", 0, defaultSystem)
	return b.graph
}

// processModelTree adds a model and, recursively, its inline subsystems.
func (b *exprGraphBuilder) processModelTree(model *Model, systemName string) {
	b.processModel(model, systemName)

	for _, childName := range sortedKeys(model.Subsystems) {
		raw := model.Subsystems[childName]
		if isSubsystemRefStub(raw) {
			continue
		}
		child, ok := decodeSubsystemAs[Model](raw)
		if !ok {
			continue
		}
		b.processModelTree(&child, childSystemName(systemName, childName))
	}
}

// processReactionSystemTree adds a reaction system and, recursively, its inline
// subsystems.
func (b *exprGraphBuilder) processReactionSystemTree(system *ReactionSystem, systemName string) {
	b.processReactionSystem(system, systemName)

	for _, childName := range sortedKeys(system.Subsystems) {
		raw := system.Subsystems[childName]
		if isSubsystemRefStub(raw) {
			continue
		}
		child, ok := decodeSubsystemAs[ReactionSystem](raw)
		if !ok {
			continue
		}
		b.processReactionSystemTree(&child, childSystemName(systemName, childName))
	}
}

// processModel adds one model's variables and equations (not its subsystems),
// labelling each node with its DERIVED graph kind rather than its declared type
// — there are only two declared types in esm 1.0.0, and "unknown" tells a reader
// nothing about how the node behaves.
func (b *exprGraphBuilder) processModel(model *Model, systemName string) {
	roles := variableRoles(model)
	for _, varName := range sortedKeys(model.Variables) {
		variable := model.Variables[varName]
		b.addNode(varName, graphKindForRole(roles[varName]), variable.Units, systemName)
	}

	for i, equation := range model.Equations {
		b.processEquation(equation, i, systemName)
	}
}

// processReactionSystem adds one reaction system's species, parameters,
// reactions and constraint equations (not its subsystems). Constraint equations
// are numbered AFTER the reactions, continuing the same index sequence.
func (b *exprGraphBuilder) processReactionSystem(system *ReactionSystem, systemName string) {
	for _, speciesName := range sortedKeys(system.Species) {
		species := system.Species[speciesName]
		b.addNode(speciesName, NodeKindSpecies, species.Units, systemName)
	}

	for _, paramName := range sortedKeys(system.Parameters) {
		param := system.Parameters[paramName]
		b.addNode(paramName, NodeKindParameter, param.Units, systemName)
	}

	for i, reaction := range system.Reactions {
		b.processReaction(reaction, i, systemName)
	}

	for i, equation := range system.ConstraintEquations {
		b.processEquation(equation, i+len(system.Reactions), systemName)
	}
}

// processEquation adds one equation's LHS/RHS dependency edges.
//
// A name the equation references but the component never declared is FABRICATED
// as a node — the assignment target as a state, a free RHS name as a parameter —
// rather than dropping the edge. Dropping it made an equation over undeclared
// names contribute nothing at all, silently.
//
// A self-reference (`D(x) = k*x`) yields a SELF-LOOP; esm-libraries-spec §4.8.2
// lists exactly such edges (NO → NO, O₃ → O₃ self-loss) in its worked example.
func (b *exprGraphBuilder) processEquation(equation Equation, equationIndex int, systemName string) {
	targetName := extractVariableFromLHS(equation.LHS)
	if targetName == "" {
		return // no recognizable defined variable
	}
	lhsVar := b.addNode(targetName, NodeKindState, nil, systemName)

	for _, rhsVar := range extractVariablesFromExpression(equation.RHS) {
		sourceVar := b.addNode(rhsVar, NodeKindParameter, nil, systemName)
		b.addDependency(sourceVar, lhsVar, relationshipEquation, equationIndex, equation.RHS)
	}
}

// processReaction adds one reaction's rate and stoichiometric edges.
//
// Every rate-expression free variable reaches every substrate AND every product
// (a species that is both gets both edges), and every substrate reaches every
// product stoichiometrically.
func (b *exprGraphBuilder) processReaction(reaction Reaction, reactionIndex int, systemName string) {
	rateVars := extractVariablesFromExpression(reaction.Rate)

	// Substrates are consumed (negative stoichiometry).
	for _, substrate := range reaction.Substrates {
		substrateVar := b.addNode(substrate.Species, NodeKindSpecies, nil, systemName)
		for _, rateVar := range rateVars {
			paramVar := b.addNode(rateVar, NodeKindParameter, nil, systemName)
			b.addDependency(paramVar, substrateVar, relationshipRate, reactionIndex, reaction.Rate)
		}
	}

	// Products are produced (positive stoichiometry).
	for _, product := range reaction.Products {
		productVar := b.addNode(product.Species, NodeKindSpecies, nil, systemName)
		for _, rateVar := range rateVars {
			paramVar := b.addNode(rateVar, NodeKindParameter, nil, systemName)
			b.addDependency(paramVar, productVar, relationshipRate, reactionIndex, reaction.Rate)
		}
		for _, substrate := range reaction.Substrates {
			substrateVar := b.addNode(substrate.Species, NodeKindSpecies, nil, systemName)
			b.addDependency(substrateVar, productVar, relationshipStoichiometry, reactionIndex, reaction.Rate)
		}
	}
}

// processExpression adds a bare expression's free-variable → result edges.
func (b *exprGraphBuilder) processExpression(expr Expression, targetVar string, equationIndex int, systemName string) {
	targetKey := b.addNode(targetVar, NodeKindObserved, nil, systemName)
	for _, freeVar := range extractVariablesFromExpression(expr) {
		sourceVar := b.addNode(freeVar, NodeKindParameter, nil, systemName)
		b.addDependency(sourceVar, targetKey, relationshipDefinition, equationIndex, expr)
	}
}

// processCoupling folds `variable_map` entries into cross-system dependency
// edges. Either endpoint is added as a parameter node if it is not already one.
func (b *exprGraphBuilder) processCoupling(coupling []CouplingEntry) {
	for _, entry := range coupling {
		vm, ok := entry.(VariableMapCoupling)
		if !ok {
			continue
		}
		fromSystem, fromVar, fromScoped := splitScopedReference(vm.From)
		toSystem, toVar, toScoped := splitScopedReference(vm.To)
		if !fromScoped || !toScoped {
			continue
		}

		sourceVar := b.addNode(fromVar, NodeKindParameter, nil, fromSystem)
		targetVar := b.addNode(toVar, NodeKindParameter, nil, toSystem)
		b.addDependency(sourceVar, targetVar, relationshipDefinition, NonEquationIndex, vm.From)
	}
}

// ========================================
// 4. Utility Functions
// ========================================

// Derived variable-role labels (esm-spec §6.3.1), the FINER partition the
// classification API computes. The expression graph maps them onto the coarser
// §4.8.2 NodeKind* vocabulary through graphKindForRole.
const (
	RoleODEState  = "ode_state"
	RoleObserved  = "observed"
	RoleAlgebraic = "algebraic"
	RoleBrownian  = "brownian"
	RoleDiscrete  = "discrete"
	RoleSampled   = "sampled"
	RoleConstant  = "constant"
)

// variableRoles maps every declared variable of a model to its derived §6.3.1
// role. It is a thin presentation layer over the seven classification
// functions, kept here so the graph builders share one spelling of the labels.
func variableRoles(model *Model) map[string]string {
	roles := make(map[string]string, len(model.Variables))
	for _, group := range []struct {
		role  string
		names []string
	}{
		{RoleODEState, ODEStates(model)},
		{RoleObserved, ObservedUnknowns(model)},
		{RoleAlgebraic, AlgebraicUnknowns(model)},
		{RoleBrownian, BrownianParameters(model)},
		{RoleDiscrete, DiscreteParameters(model)},
		{RoleSampled, SampledParameters(model)},
		{RoleConstant, ConstantParameters(model)},
	} {
		for _, n := range group.names {
			roles[n] = group.role
		}
	}
	return roles
}

// graphKindForRole projects a §6.3.1 classifier role onto the §4.8.2 graph
// vocabulary. The graph does not distinguish a sampled parameter from a
// constant one — both are "parameter" — and an unclassified name defaults to
// "parameter".
func graphKindForRole(role string) string {
	switch role {
	case RoleODEState:
		return NodeKindState
	case RoleObserved:
		return NodeKindObserved
	case RoleAlgebraic:
		return NodeKindAlgebraic
	case RoleBrownian:
		return NodeKindBrownian
	case RoleDiscrete:
		return NodeKindDiscrete
	default:
		// RoleSampled, RoleConstant, and any name the classifiers did not
		// place.
		return NodeKindParameter
	}
}

// splitScopedReference splits a scoped reference "Component.rest.of.path" into
// its owning component and the variable path WITHIN that component (everything
// after the FIRST dot). It reports false when the reference carries no dot,
// which means it names no component variable and the caller must skip it —
// reading an unscoped name as a bare system name invented couplings that the
// document never declared.
func splitScopedReference(scopedRef string) (system, variable string, ok bool) {
	parts := strings.SplitN(scopedRef, ".", 2)
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}

// extractVariableFromLHS extracts the variable name an equation's LHS assigns
// to: a bare name, the target of a derivative `D(v, t)`, the array element of an
// `index(v, i)`, or — for the array-form equation whose derivative lives in the
// aggregate's contracted body — the target inside `aggregate.expr`. Mirrors TS
// `lhsTargetName` (graph.ts).
func extractVariableFromLHS(lhs Expression) string {
	if s, ok := lhs.(string); ok {
		return s
	}
	node, ok := asExprNode(lhs)
	if !ok {
		return ""
	}
	switch node.Op {
	case OpDerivative, "index":
		if len(node.Args) > 0 {
			return extractVariableFromLHS(node.Args[0])
		}
	case "aggregate":
		if node.Expr != nil {
			return extractVariableFromLHS(node.Expr)
		}
	}
	return ""
}

// extractVariablesFromExpression extracts every variable name an expression
// references, in a deterministic walk order, with duplicates removed.
//
// It used to hand-roll its own recursion over `args` ONLY — and had no
// `*ExprNode` case at all — so a dependency reachable through a sidecar field
// (an aggregate's `expr`/`filter`, an integral's bounds, a `table_lookup`'s
// `axes`, …) contributed NO edge to the dependency graph, silently (audit G11).
// It now shares the one field-preserving walk that backs FreeVariables, so the
// graph sees exactly what the rest of the package sees.
//
// Order is deterministic (mapExprChildren walks maps in sorted-key order), so
// the emitted edge list is stable across runs.
func extractVariablesFromExpression(expr Expression) []string {
	var vars []string
	seen := make(map[string]bool)

	var walk func(Expression)
	walk = func(e Expression) {
		if s, ok := e.(string); ok {
			if !seen[s] {
				seen[s] = true
				vars = append(vars, s)
			}
			return
		}
		node, ok := asExprNode(e)
		if !ok {
			if list, isList := e.([]any); isList {
				for _, el := range list {
					walk(el)
				}
			}
			return
		}
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			walk(child)
			return child, nil
		})
	}
	walk(expr)

	if vars == nil {
		return []string{}
	}
	return vars
}

// ========================================
// 5. Graph Utility Methods
// ========================================

// graphClosure is the adjacency / predecessor / successor lookup for one graph,
// keyed by NODE KEY (ComponentNode.ID, VariableNode.Name).
//
// Adjacency is UNDIRECTED (predecessors ∪ successors); predecessors and
// successors are strictly directed. Every node is pre-registered, so a lookup on
// a known but unconnected node returns an empty list rather than a nil map miss;
// a lookup on an unknown key also returns an empty list.
type graphClosure struct {
	adjacency    map[string]map[string]bool
	predecessors map[string]map[string]bool
	successors   map[string]map[string]bool
}

// edgeKeys is one edge reduced to its two node keys.
type edgeKeys struct{ source, target string }

func buildGraphClosure(nodeKeys []string, edges []edgeKeys) graphClosure {
	c := graphClosure{
		adjacency:    make(map[string]map[string]bool, len(nodeKeys)),
		predecessors: make(map[string]map[string]bool, len(nodeKeys)),
		successors:   make(map[string]map[string]bool, len(nodeKeys)),
	}
	for _, k := range nodeKeys {
		c.adjacency[k] = map[string]bool{}
		c.predecessors[k] = map[string]bool{}
		c.successors[k] = map[string]bool{}
	}
	for _, e := range edges {
		// An edge whose endpoint is not a registered node contributes no
		// adjacency.
		if set, ok := c.adjacency[e.source]; ok {
			set[e.target] = true
		}
		if set, ok := c.adjacency[e.target]; ok {
			set[e.source] = true
		}
		if set, ok := c.predecessors[e.target]; ok {
			set[e.source] = true
		}
		if set, ok := c.successors[e.source]; ok {
			set[e.target] = true
		}
	}
	return c
}

func sortedSetKeys(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func (c graphClosure) adjacent(key string) []string    { return sortedSetKeys(c.adjacency[key]) }
func (c graphClosure) predecessor(key string) []string { return sortedSetKeys(c.predecessors[key]) }
func (c graphClosure) successor(key string) []string   { return sortedSetKeys(c.successors[key]) }

// closure builds the key-based closure for a component graph.
func (g *ComponentGraph) closure() graphClosure {
	keys := make([]string, 0, len(g.Nodes))
	for _, n := range g.Nodes {
		keys = append(keys, n.ID)
	}
	edges := make([]edgeKeys, 0, len(g.Edges))
	for _, e := range g.Edges {
		edges = append(edges, edgeKeys{e.Source.ID, e.Target.ID})
	}
	return buildGraphClosure(keys, edges)
}

// nodesByID indexes a component graph's nodes by ID.
func (g *ComponentGraph) nodesByID() map[string]ComponentNode {
	out := make(map[string]ComponentNode, len(g.Nodes))
	for _, n := range g.Nodes {
		out[n.ID] = n
	}
	return out
}

// closure builds the key-based closure for an expression graph.
func (g *ExpressionGraph) closure() graphClosure {
	keys := make([]string, 0, len(g.Nodes))
	for _, n := range g.Nodes {
		keys = append(keys, n.Name)
	}
	edges := make([]edgeKeys, 0, len(g.Edges))
	for _, e := range g.Edges {
		edges = append(edges, edgeKeys{e.Data.Source, e.Data.Target})
	}
	return buildGraphClosure(keys, edges)
}

// nodesByName indexes an expression graph's nodes by scoped name.
func (g *ExpressionGraph) nodesByName() map[string]VariableNode {
	out := make(map[string]VariableNode, len(g.Nodes))
	for _, n := range g.Nodes {
		out[n.Name] = n
	}
	return out
}

// ComponentAdjacency is one entry returned by ComponentGraph.Adjacency: a
// neighbouring component node and the coupling edge that reaches it.
type ComponentAdjacency struct {
	Neighbor ComponentNode
	Edge     CouplingEdge
}

// Adjacency returns the neighbours of a node in the component graph, together
// with the coupling edge that reaches each (esm-libraries-spec §4.8.3).
// Adjacency is UNDIRECTED: an edge in either direction makes its other endpoint
// a neighbour, regardless of whether the coupling is bidirectional. One entry
// is returned per incident edge.
func (g *ComponentGraph) Adjacency(node ComponentNode) []ComponentAdjacency {
	var result []ComponentAdjacency

	for _, edge := range g.Edges {
		if edge.Source.ID == node.ID {
			result = append(result, ComponentAdjacency{edge.Target, edge.Data})
		}
		if edge.Target.ID == node.ID {
			result = append(result, ComponentAdjacency{edge.Source, edge.Data})
		}
	}

	return result
}

// Predecessors returns the distinct nodes with an edge pointing TO the given
// node, in sorted-ID order. A bidirectional coupling is still one DIRECTED edge:
// its `Bidirectional` flag styles the export, it does not add a reverse
// dependency.
func (g *ComponentGraph) Predecessors(node ComponentNode) []ComponentNode {
	return componentNodesFor(g, g.closure().predecessor(node.ID))
}

// Successors returns the distinct nodes the given node has an edge pointing TO,
// in sorted-ID order.
func (g *ComponentGraph) Successors(node ComponentNode) []ComponentNode {
	return componentNodesFor(g, g.closure().successor(node.ID))
}

func componentNodesFor(g *ComponentGraph, ids []string) []ComponentNode {
	index := g.nodesByID()
	var result []ComponentNode
	for _, id := range ids {
		if n, ok := index[id]; ok {
			result = append(result, n)
		}
	}
	return result
}

// VariableAdjacency is one entry returned by ExpressionGraph.AdjacencyVariable:
// a neighbouring variable node and the dependency edge that reaches it.
type VariableAdjacency struct {
	Neighbor VariableNode
	Edge     DependencyEdge
}

// AdjacencyVariable returns the neighbours of a node in the expression graph,
// together with the dependency edge that reaches each. Adjacency is UNDIRECTED;
// one entry is returned per incident edge.
func (g *ExpressionGraph) AdjacencyVariable(node VariableNode) []VariableAdjacency {
	var result []VariableAdjacency

	for _, edge := range g.Edges {
		if edge.Data.Source == node.Name {
			result = append(result, VariableAdjacency{edge.Target, edge.Data})
		}
		if edge.Data.Target == node.Name {
			result = append(result, VariableAdjacency{edge.Source, edge.Data})
		}
	}

	return result
}

// PredecessorsVariable returns the distinct nodes with a dependency edge
// pointing TO the given variable node, in sorted-name order.
func (g *ExpressionGraph) PredecessorsVariable(node VariableNode) []VariableNode {
	return variableNodesFor(g, g.closure().predecessor(node.Name))
}

// SuccessorsVariable returns the distinct nodes the given variable node has a
// dependency edge pointing TO, in sorted-name order.
func (g *ExpressionGraph) SuccessorsVariable(node VariableNode) []VariableNode {
	return variableNodesFor(g, g.closure().successor(node.Name))
}

func variableNodesFor(g *ExpressionGraph, names []string) []VariableNode {
	index := g.nodesByName()
	var result []VariableNode
	for _, name := range names {
		if n, ok := index[name]; ok {
			result = append(result, n)
		}
	}
	return result
}
