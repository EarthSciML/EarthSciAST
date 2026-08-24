"""
Graph analysis functionality for ESM format.

This module implements component-level and expression-level graph generation
as specified in the ESM Libraries Spec Section 4.8.
"""

# Graph data structures

"""
Element type of a `Graph{N,E}` edge list: a `(source, target, data)` named
tuple. Alias so edge-vector construction sites don't each spell out the
NamedTuple type.
"""
const _GraphEdge{N, E} = NamedTuple{(:source, :target, :data), Tuple{N, N, E}}

"""
Generic graph structure with nodes and edges.
"""
struct Graph{N, E}
    nodes::Vector{N}
    edges::Vector{_GraphEdge{N, E}}
end

"""
Component-level node representing a model, reaction system, data source, or operator.
"""
struct ComponentNode
    id::String
    name::String
    type::String  # 'model' | 'reaction_system' (§4.8.1: a data source is not a node)
    description::Union{String, Nothing}
    reference::Any
    metadata::Dict{String, Any}
end

"""
Edge representing coupling between components.
"""
struct CouplingEdge
    id::String
    from::String
    to::String
    type::String
    label::String
    description::Union{String, Nothing}
    coupling::CouplingEntry
end

"""
Variable-level node for expression graphs.
"""
struct VariableNode
    name::String
    # DERIVED (esm-spec §6.3.1), never the declared type: 'state' | 'algebraic' |
    # 'observed' | 'parameter' | 'brownian' | 'discrete' | 'species'.
    kind::String
    units::Union{String, Nothing}
    system::String
end

"""
Edge representing dependency between variables.
"""
struct DependencyEdge
    source::String
    target::String
    relationship::String  # 'additive' | 'multiplicative' | 'rate' | 'stoichiometric'
    equation_index::Union{Int, Nothing}
    expression::Union{ASTExpr, Nothing}
end

# Graph analysis methods

"""
Get all adjacent nodes (both predecessors and successors).
"""
function adjacency(graph::Graph{N, E}, node::N) where {N, E}
    result = Tuple{N, E}[]
    for edge in graph.edges
        if edge.source == node
            push!(result, (edge.target, edge.data))
        elseif edge.target == node
            push!(result, (edge.source, edge.data))
        end
    end
    return result
end

"""
Get nodes that point to this node, each ONCE.

Deduplicated: two parallel edges between the same pair (a pair of
`variable_map` couplings between the same two components, or two equations of
one model that read the same variable) name one predecessor, not two. This
returns a NODE SET, unlike [`adjacency`](@ref), which pairs each neighbour with
the edge that reaches it and so legitimately repeats a neighbour per edge.
"""
function predecessors(graph::Graph{N, E}, node::N) where {N, E}
    result = N[]
    for edge in graph.edges
        if edge.target == node && !(edge.source in result)
            push!(result, edge.source)
        end
    end
    return result
end

"""
Get nodes that this node points to, each ONCE. See [`predecessors`](@ref) for
why this deduplicates and [`adjacency`](@ref) for why that one does not.
"""
function successors(graph::Graph{N, E}, node::N) where {N, E}
    result = N[]
    for edge in graph.edges
        if edge.source == node && !(edge.target in result)
            push!(result, edge.target)
        end
    end
    return result
end

"""
The neighbour SET of `node` — every node an edge joins it to, in either
direction, each once.

`adjacency` pairs each neighbour with the edge that reaches it, so it repeats a
neighbour once per parallel edge; this is the plain node set that
esm-libraries-spec §4.8.3's adjacency map and the other bindings' `adjacency`
return.
"""
function _adjacent_nodes(graph::Graph{N, E}, node::N) where {N, E}
    result = N[]
    for (neighbor, _) in adjacency(graph, node)
        neighbor in result || push!(result, neighbor)
    end
    return result
end

"""
    component_graph(file::EsmFile) -> Graph{ComponentNode, CouplingEdge}

Generate component-level graph showing systems and their couplings.

Creates nodes for each model, reaction system, and data source. Operators are
NOT given nodes: a `CouplingOperatorApply` entry only registers an operator
(the operator lives in the file's `operators` section), so it contributes no
node or edge here. Creates edges based on the remaining coupling entries with
appropriate types and labels.

# Arguments
- `file::EsmFile`: Input ESM file

# Returns
- `Graph{ComponentNode, CouplingEdge}`: Component graph with coupling relationships

# Example
```julia
graph = component_graph(file)
# Access nodes and edges
for node in graph.nodes
    println("Component: \$(node.name) (\$(node.type))")
end
for edge in graph.edges
    println("Coupling: \$(edge.from) --[\$(edge.label)]--> \$(edge.to)")
end
```
"""
function component_graph(file::EsmFile)::Graph{ComponentNode, CouplingEdge}
    nodes = ComponentNode[]
    edges = _GraphEdge{ComponentNode, CouplingEdge}[]

    # Create mapping from component name to node
    node_map = Dict{String, ComponentNode}()

    # Create nodes for models
    if file.models !== nothing
        for (name, model) in file.models
            metadata = Dict{String, Any}(
                "var_count" => length(model.variables),
                "eq_count" => length(model.equations),
                "species_count" => 0
            )

            node = ComponentNode(
                name,
                name,
                "model",
                nothing,  # Model doesn't have description field
                model,
                metadata
            )
            push!(nodes, node)
            node_map[name] = node
        end
    end

    # Create nodes for reaction systems
    if file.reaction_systems !== nothing
        for (name, rxn_sys) in file.reaction_systems
            # A reaction system's PARAMETERS are its `var_count`. The schema
            # forbids a `variables` field here and `species_count` below already
            # carries the species, so `parameters` is the only thing left for
            # esm-libraries-spec §4.8.1's "variable count" to mean — and it is
            # the exact analogue of a model's `variables`, which likewise counts
            # unknowns and parameters together. This used to be 0, which
            # asserted that a reaction system declares no variables at all.
            metadata = Dict{String, Any}(
                "var_count" => length(rxn_sys.parameters),
                "eq_count" => length(rxn_sys.reactions),
                "species_count" => length(rxn_sys.species)
            )

            node = ComponentNode(
                name,
                name,
                "reaction_system",
                nothing,  # ReactionSystem doesn't have description field
                rxn_sys,
                metadata
            )
            push!(nodes, node)
            node_map[name] = node
        end
    end

    # `data_sources` contributes NO node. esm-libraries-spec §4.8.1 is
    # explicit: "A `data_sources` entry is not a component and is NOT a node:
    # from 1.0.0 external data is a parameter of the consuming model, so it is
    # an attribute of an existing node rather than a node of its own". A model
    # reaches a source through a parameter whose `update` names it (esm-spec
    # §8.5), and that parameter is already a variable of an existing node.
    # This module used to draw a leaf `data_source` node; TypeScript, Go and
    # Python never did.

    # Shared edge builder for the two two-system coupling forms
    # (operator_compose / couple). Although the coupling SEMANTICS are
    # bidirectional, the graph gets a single DIRECTED edge from the first
    # listed system to the second (renderers draw one arrow; no reverse edge
    # is added). Entries with fewer than two systems, or naming unknown
    # systems, contribute no edge.
    function push_two_system_edge!(coupling, edge_id, type, label, description)
        length(coupling.systems) >= 2 || return
        system_a = coupling.systems[1]
        system_b = coupling.systems[2]
        from_node = get(node_map, system_a, nothing)
        to_node = get(node_map, system_b, nothing)
        (from_node === nothing || to_node === nothing) && return

        edge = CouplingEdge(edge_id, system_a, system_b, type, label,
                            description, coupling)
        push!(edges, (source=from_node, target=to_node, data=edge))
        return
    end

    # Create edges from coupling entries
    for (i, coupling) in enumerate(file.coupling)
        edge_id = "coupling_$i"

        # Handle different coupling types
        if coupling isa CouplingOperatorCompose
            push_two_system_edge!(coupling, edge_id, "operator_compose",
                                  "compose", "System composition coupling")

        elseif coupling isa CouplingCouple
            push_two_system_edge!(coupling, edge_id, "couple",
                                  "couple", "Bidirectional coupling")

        elseif coupling isa CouplingVariableMap
            # Directed edge for variable mapping
            # Parse from "system.variable" format
            from_parts = split(coupling.from, ".")
            to_parts = split(coupling.to, ".")

            # Both endpoints must be SCOPED `Component.variable` references: a
            # bare name identifies no component. The label is the mapped
            # variable — everything after the first dot, so a subsystem-scoped
            # endpoint keeps its path (§4.8.1: "labeled with the mapped
            # variable"). This used to emit `[<second segment>]`, which for
            # `EmissionSources.Transportation.traffic_density` printed the
            # SUBSYSTEM name rather than the variable.
            if length(from_parts) >= 2 && length(to_parts) >= 2
                from_system = from_parts[1]
                to_system = to_parts[1]
                variable_name = join(from_parts[2:end], ".")

                from_node = get(node_map, from_system, nothing)
                to_node = get(node_map, to_system, nothing)

                if from_node !== nothing && to_node !== nothing
                    edge = CouplingEdge(
                        edge_id,
                        from_system,
                        to_system,
                        "variable_map",
                        variable_name,
                        "Variable mapping: $(coupling.from) -> $(coupling.to)",
                        coupling
                    )
                    push!(edges, (source=from_node, target=to_node, data=edge))
                end
            end

        elseif coupling isa CouplingOperatorApply
            # CouplingOperatorApply just registers an operator, no edges needed
            # The operator itself should be in the operators section, not as a system node
            @debug "Operator application registered: $(coupling.operator)"
        end
    end

    return Graph{ComponentNode, CouplingEdge}(nodes, edges)
end

"""
    expression_graph(file::EsmFile) -> Graph{VariableNode, DependencyEdge}
    expression_graph(model::Model) -> Graph{VariableNode, DependencyEdge}
    expression_graph(system::ReactionSystem) -> Graph{VariableNode, DependencyEdge}
    expression_graph(equation::Equation) -> Graph{VariableNode, DependencyEdge}
    expression_graph(reaction::Reaction) -> Graph{VariableNode, DependencyEdge}
    expression_graph(expr::ASTExpr) -> Graph{VariableNode, DependencyEdge}

Generate expression-level dependency graph showing variable relationships.

Creates nodes for variables and edges for dependencies based on expressions.
Supports different scoping levels from individual expressions to full files.

# Arguments
- Input can be EsmFile, Model, ReactionSystem, Equation, Reaction, or ASTExpr

# Returns
- `Graph{VariableNode, DependencyEdge}`: Variable dependency graph

# Examples
```julia
# File-level analysis
graph = expression_graph(file)

# Model-level analysis
graph = expression_graph(model)

# Single equation analysis
graph = expression_graph(equation)
```
"""
# ── expression_graph ────────────────────────────────────────────────────────
#
# The variable-level dependency graph (esm-libraries-spec §4.8.2). One builder
# accumulates nodes and edges for every granularity; the six public methods are
# thin dispatchers over it, so a Model reached through an EsmFile and a Model
# passed on its own share one definition of what a node and an edge are.

"""
`system` for a standalone `Model` / `ReactionSystem` / `Equation` / `Reaction` /
expression target. Node names are NOT scoped under it, so a standalone target
yields bare names while a whole-file target yields `Component.variable`.
"""
const _DEFAULT_SYSTEM = "default"

"""
`equation_index` for a dependency no positionally-numbered equation or reaction
produced: a coupling variable map, or the synthetic `expr_result` edges of a
bare-expression target. Spelled -1 rather than `nothing` so "no positional
equation" is a positive statement rather than "not tracked".
"""
const _NON_EQUATION_INDEX = -1

"""Name of the synthetic node standing for a bare expression's VALUE, so the
§4.8.2 expression overload has a target to draw its dependency edges to."""
const _EXPR_RESULT = "expr_result"

"""
Mutable accumulator threaded through the `expression_graph` helpers: the growing
node and edge lists plus the dedup map, keyed by SCOPED name.
"""
struct _ExprGraphBuilder
    nodes::Vector{VariableNode}
    edges::Vector{_GraphEdge{VariableNode, DependencyEdge}}
    node_map::Dict{String, VariableNode}
end
_ExprGraphBuilder() = _ExprGraphBuilder(
    VariableNode[],
    _GraphEdge{VariableNode, DependencyEdge}[],
    Dict{String, VariableNode}(),
)

"""Add a node (deduped by scoped name) and return that scoped name."""
function _add_node!(b::_ExprGraphBuilder, name::AbstractString, kind::AbstractString,
                    units::Union{String,Nothing}, system::AbstractString)
    scoped = system == _DEFAULT_SYSTEM ? String(name) : "$(system).$(name)"
    if !haskey(b.node_map, scoped)
        node = VariableNode(scoped, String(kind), units, String(system))
        push!(b.nodes, node)
        b.node_map[scoped] = node
    end
    return scoped
end

"""Append a dependency edge between two already-added scoped names."""
function _add_dependency!(b::_ExprGraphBuilder, source::AbstractString, target::AbstractString,
                          relationship::AbstractString, equation_index::Int,
                          expression::Union{ASTExpr,Nothing})
    source_node = b.node_map[source]
    target_node = b.node_map[target]
    edge = DependencyEdge(String(source), String(target), String(relationship),
                          equation_index, expression)
    push!(b.edges, (source=source_node, target=target_node, data=edge))
    return nothing
end

_graph(b::_ExprGraphBuilder) = Graph{VariableNode, DependencyEdge}(b.nodes, b.edges)

"""
The single variable an equation's LHS defines: a bare name, or the name under
the derivative / element-index / aggregate-output wrappers (`D(x)`,
`index(v, i)`, `aggregate(…, expr: D(index(v, i)))`). `nothing` when the LHS
addresses no single variable (an implicit constraint such as `H*H*SO4 ~ Ksp`).

Reuses classification's `_lhs_unwrap` so the graph and §6.3.1 agree on what an
equation assigns to. Note this is NOT `free_variables(lhs)`: that returns every
name the LHS mentions, including an `index`'s subscript, which would fabricate
an index variable as a graph node and draw an edge to it.
"""
function _lhs_target_name(lhs::ASTExpr)::Union{String,Nothing}
    head = _lhs_unwrap(lhs)
    head isa VarExpr && return head.name
    if head isa OpExpr && (head.op == "D") && !isempty(head.args)
        base = _lhs_unwrap(head.args[1])
        base isa VarExpr && return base.name
    end
    return nothing
end

"""
Every variable of `model` mapped to its DERIVED graph kind (esm-spec §6.3.1).

The kind is derived, never read off `var.type`: the format declares only
`unknown` and `parameter`, so `var.type` would label every unknown `"unknown"` —
a value that appears in no §4.8.2 vocabulary and tells a reader nothing about
how the node behaves. This module used to do exactly that.

Computed once per model rather than per reference, since each classifier walks
the equation list.
"""
function _variable_kinds(model::Model)::Dict{String,String}
    kinds = Dict{String,String}()
    for n in ode_states(model);          kinds[n] = "state";     end
    for n in observed_unknowns(model);   kinds[n] = "observed";  end
    for n in algebraic_unknowns(model);  kinds[n] = "algebraic"; end
    for n in brownian_parameters(model); kinds[n] = "brownian";  end
    for n in discrete_parameters(model); kinds[n] = "discrete";  end
    for n in sampled_parameters(model);  kinds[n] = "parameter"; end
    for n in constant_parameters(model); kinds[n] = "parameter"; end
    return kinds
end

"""Add one equation's LHS/RHS dependency edges under `system`."""
function _process_equation!(b::_ExprGraphBuilder, equation::Equation,
                            equation_index::Int, system::AbstractString)
    target_name = _lhs_target_name(equation.lhs)
    target_name === nothing && return nothing  # no single defined variable
    lhs_key = _add_node!(b, target_name, "state", nothing, system)

    # Every RHS free variable feeds the LHS. A SELF-reference is kept: §4.8.2's
    # worked example lists `NO → NO` / `O₃ → O₃` self-loss edges explicitly.
    for rhs_var in sort!(collect(free_variables(equation.rhs)))
        source_key = _add_node!(b, rhs_var, "parameter", nothing, system)
        _add_dependency!(b, source_key, lhs_key, "additive", equation_index, equation.rhs)
    end
    return nothing
end

"""Add one reaction's rate (parameter → species) and stoichiometric edges."""
function _process_reaction!(b::_ExprGraphBuilder, reaction::Reaction,
                            reaction_index::Int, system::AbstractString)
    rate_vars = sort!(collect(free_variables(reaction.rate)))
    substrates = reaction.substrates === nothing ? StoichiometryEntry[] : reaction.substrates
    products   = reaction.products   === nothing ? StoichiometryEntry[] : reaction.products

    # Substrates are consumed; the rate drives that consumption.
    for substrate in substrates
        substrate_key = _add_node!(b, substrate.species, "species", nothing, system)
        for rate_var in rate_vars
            param_key = _add_node!(b, rate_var, "parameter", nothing, system)
            _add_dependency!(b, param_key, substrate_key, "rate", reaction_index, reaction.rate)
        end
    end

    # Products are produced by the rate, and by each substrate's stoichiometry.
    for product in products
        product_key = _add_node!(b, product.species, "species", nothing, system)
        for rate_var in rate_vars
            param_key = _add_node!(b, rate_var, "parameter", nothing, system)
            _add_dependency!(b, param_key, product_key, "rate", reaction_index, reaction.rate)
        end
        for substrate in substrates
            substrate_key = _add_node!(b, substrate.species, "species", nothing, system)
            _add_dependency!(b, substrate_key, product_key, "stoichiometric",
                             reaction_index, reaction.rate)
        end
    end
    return nothing
end

"""Add a model's declared variables and its equations' edges."""
function _process_model!(b::_ExprGraphBuilder, model::Model, system::AbstractString)
    kinds = _variable_kinds(model)
    for var_name in sort!(collect(keys(model.variables)))
        var = model.variables[var_name]
        _add_node!(b, var_name, get(kinds, var_name, "parameter"), var.units, system)
    end
    for (i, equation) in enumerate(model.equations)
        # 0-BASED, matching every other binding. This module used to emit the
        # Julia 1-based `enumerate` index, leaking a language convention into a
        # cross-binding wire field.
        _process_equation!(b, equation, i - 1, system)
    end
    return nothing
end

"""Add a reaction system's species, parameters, and its reactions' edges."""
function _process_reaction_system!(b::_ExprGraphBuilder, rxn_sys::ReactionSystem,
                                   system::AbstractString)
    # Species carry their DECLARED units; this module used to drop them.
    for species in rxn_sys.species
        _add_node!(b, species.name, "species", species.units, system)
    end
    for parameter in rxn_sys.parameters
        _add_node!(b, parameter.name, "parameter", parameter.units, system)
    end
    for (i, reaction) in enumerate(rxn_sys.reactions)
        _process_reaction!(b, reaction, i - 1, system)
    end
    return nothing
end

"""
Process one component and, recursively, its inline `subsystems`.

An unresolved `SubsystemRef` is skipped: it is a reference stub, not a
component, and its variables live in the file it names. Scoped names compose
with a dot, so a `Meteorology` model's `Temperature` subsystem contributes
`Meteorology.Temperature.surface_temp`. This module used to visit only the
top-level components, so a document like `tests/valid/scoped_refs_coupling.esm`
produced 4 nodes where the oracle produces 37.
"""
function _process_component_tree!(b::_ExprGraphBuilder, component::Model,
                                  system::AbstractString)
    _process_model!(b, component, system)
    for child_name in sort!(collect(keys(component.subsystems)))
        child = component.subsystems[child_name]
        child isa Model || continue  # SubsystemRef: unresolved stub
        child_scoped = system == _DEFAULT_SYSTEM ? child_name : "$(system).$(child_name)"
        _process_component_tree!(b, child, child_scoped)
    end
    return nothing
end

function _process_component_tree!(b::_ExprGraphBuilder, component::ReactionSystem,
                                  system::AbstractString)
    _process_reaction_system!(b, component, system)
    for child_name in sort!(collect(keys(component.subsystems)))
        child_scoped = system == _DEFAULT_SYSTEM ? child_name : "$(system).$(child_name)"
        _process_component_tree!(b, component.subsystems[child_name], child_scoped)
    end
    return nothing
end

"""Fold `variable_map` coupling entries into cross-system dependency edges."""
function _process_coupling!(b::_ExprGraphBuilder, coupling)
    for entry in coupling
        entry isa CouplingVariableMap || continue
        from_parts = split(entry.from, ".")
        to_parts = split(entry.to, ".")
        (length(from_parts) >= 2 && length(to_parts) >= 2) || continue
        source_key = _add_node!(b, join(from_parts[2:end], "."), "parameter",
                                nothing, from_parts[1])
        target_key = _add_node!(b, join(to_parts[2:end], "."), "parameter",
                                nothing, to_parts[1])
        _add_dependency!(b, source_key, target_key, "multiplicative",
                         _NON_EQUATION_INDEX, nothing)
    end
    return nothing
end

function expression_graph(file::EsmFile; merge_coupled::Bool=false)::Graph{VariableNode, DependencyEdge}
    # Expand at the boundary (RFC out-of-line-expression-templates §7.7): a
    # surviving `apply_expression_template` node hides its BODY's free component
    # variables from `free_variables` (bindings are traversed; the body lives in
    # the registry), so dependency edges would be incomplete. No-op without refs.
    file.component_templates === nothing || (file = _expand_refs!(deepcopy(file)))

    b = _ExprGraphBuilder()
    if file.models !== nothing
        for name in sort!(collect(keys(file.models)))
            _process_component_tree!(b, file.models[name], name)
        end
    end
    if file.reaction_systems !== nothing
        for name in sort!(collect(keys(file.reaction_systems)))
            _process_component_tree!(b, file.reaction_systems[name], name)
        end
    end
    # OFF by default, matching TypeScript's `mergeCoupled` and Python's
    # `merge_coupled`. This module used to add these edges unconditionally, and
    # under the relationship `"coupling"` — a value in no §4.8.2 vocabulary.
    merge_coupled && _process_coupling!(b, file.coupling)
    return _graph(b)
end

function expression_graph(model::Model)::Graph{VariableNode, DependencyEdge}
    b = _ExprGraphBuilder()
    _process_component_tree!(b, model, _DEFAULT_SYSTEM)
    return _graph(b)
end

function expression_graph(rxn_sys::ReactionSystem)::Graph{VariableNode, DependencyEdge}
    b = _ExprGraphBuilder()
    _process_component_tree!(b, rxn_sys, _DEFAULT_SYSTEM)
    return _graph(b)
end

function expression_graph(equation::Equation)::Graph{VariableNode, DependencyEdge}
    b = _ExprGraphBuilder()
    _process_equation!(b, equation, 0, _DEFAULT_SYSTEM)
    return _graph(b)
end

function expression_graph(reaction::Reaction)::Graph{VariableNode, DependencyEdge}
    b = _ExprGraphBuilder()
    _process_reaction!(b, reaction, 0, _DEFAULT_SYSTEM)
    return _graph(b)
end

function expression_graph(expr::ASTExpr)::Graph{VariableNode, DependencyEdge}
    # §4.8.2 requires this overload to produce EDGES, not just nodes: "every
    # variable in the expression becomes a node, and the tree structure is
    # flattened into dependency edges". The expression's VALUE has no name in
    # the document, so it gets a synthetic target every free variable feeds.
    # This module used to return nodes only.
    b = _ExprGraphBuilder()
    result_key = _add_node!(b, _EXPR_RESULT, "observed", nothing, _DEFAULT_SYSTEM)
    for var_name in sort!(collect(free_variables(expr)))
        source_key = _add_node!(b, var_name, "parameter", nothing, _DEFAULT_SYSTEM)
        # `_NON_EQUATION_INDEX`: a bare expression has no positional equation to
        # index, which is exactly what the sentinel is for. (The Equation and
        # Reaction overloads DO number their single target 0.)
        _add_dependency!(b, source_key, result_key, "multiplicative",
                         _NON_EQUATION_INDEX, expr)
    end
    return _graph(b)
end

# Chemical subscript rendering utilities

"""
    render_chemical_formula(formula::String) -> String

Convert chemical formula to format with subscripts for visualization.

Thin wrapper over display.jl's element-aware
[`format_chemical_subscripts`](@ref) (`:unicode` form), so graph exports render
species exactly like the display formatters: digits become subscripts only when
they follow a recognized chemical element symbol.

# Examples
```julia
render_chemical_formula("CO2") # "CO₂"
render_chemical_formula("H2SO4") # "H₂SO₄"
render_chemical_formula("CH3OH") # "CH₃OH"
```
"""
render_chemical_formula(formula::String)::String =
    format_chemical_subscripts(formula, :unicode)

"""
    format_node_label(name::String) -> String

Format node label with chemical subscript rendering if applicable.
Detects chemical formulas and applies subscript formatting.
"""
function format_node_label(name::String)::String
    # Check if this looks like a chemical formula (has letters followed by digits)
    if occursin(r"[A-Za-z]+\d+", name)
        return render_chemical_formula(name)
    end
    return name
end

# Export formats

# Mermaid node ids must be plain identifiers: dotted names like `model.x`
# are invalid/ambiguous in Mermaid syntax. Deterministically map every
# non-[A-Za-z0-9_] character to `_`.
_mermaid_id(name::AbstractString)::String = replace(String(name), r"[^A-Za-z0-9_]" => "_")

# Mermaid labels are emitted inside double quotes; escape embedded quotes
# using the Mermaid entity form.
_mermaid_label(label::AbstractString)::String = replace(String(label), "\"" => "#quot;")

# DOT ids/labels are emitted inside double quotes; escape backslashes and
# embedded quotes so arbitrary names cannot break the quoting.
_dot_escape(s::AbstractString)::String =
    replace(String(s), "\\" => "\\\\", "\"" => "\\\"")

# ── Export styling tables ────────────────────────────────────────────────
# One row per node/edge category holding BOTH the DOT and the Mermaid styling,
# so `to_dot` and `to_mermaid` consume the same source of truth and cannot
# drift. Unknown categories fall back to the paired _DEFAULT row.

# ComponentNode.type → styling. `mermaid` is the (open, close) shape delimiters.
const _COMPONENT_NODE_STYLE = Dict{String,@NamedTuple{dot_fillcolor::String, mermaid::Tuple{String,String}}}(
    "model"           => (dot_fillcolor = "lightgreen",  mermaid = ("[", "]")),
    "reaction_system" => (dot_fillcolor = "lightcoral",  mermaid = ("(", ")")),
)  # no "data_source" row: §4.8.1 says a data source is not a node.
const _COMPONENT_NODE_DEFAULT_STYLE =
    (dot_fillcolor = "lightgray", mermaid = ("((", "))"))

# CouplingEdge.type → styling. No row for "operator_apply": component_graph
# never emits such edges (CouplingOperatorApply only registers an operator),
# so it styles like any unknown type.
const _COUPLING_EDGE_STYLE = Dict{String,@NamedTuple{dot_color::String, mermaid_arrow::String}}(
    "operator_compose" => (dot_color = "blue",  mermaid_arrow = "-->"),
    "couple"           => (dot_color = "blue",  mermaid_arrow = "-->"),
    "variable_map"     => (dot_color = "green", mermaid_arrow = "-.->"),
)
const _COUPLING_EDGE_DEFAULT_STYLE = (dot_color = "black", mermaid_arrow = "-->")

# VariableNode.kind → styling ("state" has a DOT shape but the default
# Mermaid delimiters).
const _VARIABLE_NODE_STYLE = Dict{String,@NamedTuple{dot_shape::String, mermaid::Tuple{String,String}}}(
    "species"   => (dot_shape = "ellipse",       mermaid = ("(", ")")),
    "parameter" => (dot_shape = "box",           mermaid = ("[", "]")),
    "state"     => (dot_shape = "circle",        mermaid = ("((", "))")),
    # The remaining §6.3.1 derived kinds. Before the kind became derived this
    # table only ever saw the two DECLARED types, so an observed, algebraic,
    # brownian or discrete node fell through to the default diamond.
    "algebraic" => (dot_shape = "circle",        mermaid = ("((", "))")),
    "observed"  => (dot_shape = "diamond",       mermaid = ("{", "}")),
    "brownian"  => (dot_shape = "doubleoctagon", mermaid = ("{{", "}}")),
    "discrete"  => (dot_shape = "hexagon",       mermaid = ("[/", "/]")),
)
const _VARIABLE_NODE_DEFAULT_STYLE = (dot_shape = "diamond", mermaid = ("((", "))"))

# DependencyEdge.relationship → styling.
const _DEPENDENCY_EDGE_STYLE = Dict{String,@NamedTuple{dot_style::String, mermaid_arrow::String}}(
    "rate"           => (dot_style = "dotted", mermaid_arrow = "-..->"),
    "stoichiometric" => (dot_style = "dashed", mermaid_arrow = "-..->"),
)
const _DEPENDENCY_EDGE_DEFAULT_STYLE = (dot_style = "solid", mermaid_arrow = "-->")

_component_node_style(type::String) =
    get(_COMPONENT_NODE_STYLE, type, _COMPONENT_NODE_DEFAULT_STYLE)
_coupling_edge_style(type::String) =
    get(_COUPLING_EDGE_STYLE, type, _COUPLING_EDGE_DEFAULT_STYLE)
_variable_node_style(kind::String) =
    get(_VARIABLE_NODE_STYLE, kind, _VARIABLE_NODE_DEFAULT_STYLE)
_dependency_edge_style(relationship::String) =
    get(_DEPENDENCY_EDGE_STYLE, relationship, _DEPENDENCY_EDGE_DEFAULT_STYLE)

"""
Export graph to DOT format for Graphviz rendering.
"""
function to_dot(graph::Graph{ComponentNode, CouplingEdge})::String
    lines = ["digraph ComponentGraph {"]

    # Add nodes with colors based on type
    for node in graph.nodes
        color = _component_node_style(node.type).dot_fillcolor
        label = format_node_label(node.name)
        push!(lines, "  \"$(_dot_escape(node.id))\" [label=\"$(_dot_escape(label))\", fillcolor=$color, style=filled];")
    end

    # Add edges with colors based on coupling type
    for edge in graph.edges
        edge_color = _coupling_edge_style(edge.data.type).dot_color
        push!(lines, "  \"$(_dot_escape(edge.data.from))\" -> \"$(_dot_escape(edge.data.to))\" [label=\"$(_dot_escape(edge.data.label))\", color=$edge_color];")
    end

    push!(lines, "}")
    return join(lines, "\n")
end

function to_dot(graph::Graph{VariableNode, DependencyEdge})::String
    lines = ["digraph ExpressionGraph {"]

    # Add nodes with shapes based on variable kind
    for node in graph.nodes
        shape = _variable_node_style(node.kind).dot_shape
        label = format_node_label(node.name)
        push!(lines, "  \"$(_dot_escape(node.name))\" [label=\"$(_dot_escape(label))\", shape=$shape];")
    end

    # Add edges with styles based on relationship
    for edge in graph.edges
        style = _dependency_edge_style(edge.data.relationship).dot_style
        push!(lines, "  \"$(_dot_escape(edge.data.source))\" -> \"$(_dot_escape(edge.data.target))\" [label=\"$(_dot_escape(edge.data.relationship))\", style=$style];")
    end

    push!(lines, "}")
    return join(lines, "\n")
end

"""
Export graph to Mermaid format for markdown embedding.

Node ids are sanitized to plain identifiers (`model.x` → `model_x`) and
labels are quoted, so dotted/scoped names render correctly. Edges carry a
quoted label — the coupling label (component graph) or dependency
relationship (expression graph) — matching the DOT emitter and Mermaid's
`A -->|"label"| B` labeled-edge syntax.
"""
function to_mermaid(graph::Graph{ComponentNode, CouplingEdge})::String
    lines = ["graph TD"]

    # Add nodes
    for node in graph.nodes
        shape_open, shape_close = _component_node_style(node.type).mermaid
        label = format_node_label(node.name)
        push!(lines, "    $(_mermaid_id(node.id))$shape_open\"$(_mermaid_label(label))\"$shape_close")
    end

    # Add edges
    for edge in graph.edges
        arrow = _coupling_edge_style(edge.data.type).mermaid_arrow
        push!(lines, "    $(_mermaid_id(edge.data.from)) $arrow|\"$(_mermaid_label(edge.data.label))\"| $(_mermaid_id(edge.data.to))")
    end

    return join(lines, "\n")
end

function to_mermaid(graph::Graph{VariableNode, DependencyEdge})::String
    lines = ["graph TD"]

    # Add nodes
    for node in graph.nodes
        shape_open, shape_close = _variable_node_style(node.kind).mermaid
        label = format_node_label(node.name)
        push!(lines, "    $(_mermaid_id(node.name))$shape_open\"$(_mermaid_label(label))\"$shape_close")
    end

    # Add edges
    for edge in graph.edges
        arrow = _dependency_edge_style(edge.data.relationship).mermaid_arrow
        push!(lines, "    $(_mermaid_id(edge.data.source)) $arrow|\"$(_mermaid_label(edge.data.relationship))\"| $(_mermaid_id(edge.data.target))")
    end

    return join(lines, "\n")
end

"""
Export graph to the JSON adjacency list of esm-libraries-spec §4.8.3.

Three top-level keys:

* `nodes` — each node's own fields, prefixed with the `id` that keys it (a
  component node's `id`, a variable node's `name`);
* `edges` — `{"source", "target", "data"}`, endpoints by node key with the edge
  payload under `data`;
* `adjacency` — every node key mapped to its UNDIRECTED neighbours, matching
  [`adjacency`](@ref). (This used to map to SUCCESSORS, so a graph's JSON export
  disagreed with its own `adjacency` method.)

Pinned by `tests/conformance/graph/cases.json` at the level of the top-level
keys, the node ids, the edge endpoints and the adjacency map; the per-node and
per-edge payloads are this binding's own and are not.
"""
function to_json(graph::Graph{ComponentNode, CouplingEdge})::String
    adj_list = Dict{String, Vector{String}}()
    for node in graph.nodes
        adj_list[node.id] = sort!(String[n.id for n in _adjacent_nodes(graph, node)])
    end

    result = Dict(
        "nodes" => [Dict("id" => node.id, "name" => node.name, "type" => node.type,
                         "metadata" => node.metadata) for node in graph.nodes],
        "edges" => [Dict("source" => edge.source.id, "target" => edge.target.id,
                         "data" => Dict("id" => edge.data.id,
                                        "from" => edge.data.from,
                                        "to" => edge.data.to,
                                        "type" => edge.data.type,
                                        "label" => edge.data.label))
                    for edge in graph.edges],
        "adjacency" => adj_list
    )
    return JSON3.write(result, pretty=true)
end

function to_json(graph::Graph{VariableNode, DependencyEdge})::String
    adj_list = Dict{String, Vector{String}}()
    for node in graph.nodes
        adj_list[node.name] = sort!(String[n.name for n in _adjacent_nodes(graph, node)])
    end

    result = Dict(
        "nodes" => [Dict("id" => node.name, "name" => node.name, "kind" => node.kind,
                         "units" => node.units, "system" => node.system)
                    for node in graph.nodes],
        "edges" => [Dict("source" => edge.data.source, "target" => edge.data.target,
                         "data" => Dict("source" => edge.data.source,
                                        "target" => edge.data.target,
                                        "relationship" => edge.data.relationship,
                                        "equation_index" => edge.data.equation_index))
                    for edge in graph.edges],
        "adjacency" => adj_list
    )
    return JSON3.write(result, pretty=true)
end
