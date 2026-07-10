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
Component-level node representing a model, reaction system, data loader, or operator.
"""
struct ComponentNode
    id::String
    name::String
    type::String  # 'model' | 'reaction_system' | 'data_loader' | 'operator'
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
    kind::String  # 'state' | 'parameter' | 'observed' | 'species'
    units::Union{String, Nothing}
    system::String
end

"""
Edge representing dependency between variables.
"""
struct DependencyEdge
    source::String
    target::String
    relationship::String  # 'additive' | 'rate' | 'stoichiometric' | 'coupling'
    equation_index::Union{Int, Nothing}
    expression::Union{Expr, Nothing}
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
Get nodes that point to this node.
"""
function predecessors(graph::Graph{N, E}, node::N) where {N, E}
    result = N[]
    for edge in graph.edges
        if edge.target == node
            push!(result, edge.source)
        end
    end
    return result
end

"""
Get nodes that this node points to.
"""
function successors(graph::Graph{N, E}, node::N) where {N, E}
    result = N[]
    for edge in graph.edges
        if edge.source == node
            push!(result, edge.target)
        end
    end
    return result
end

"""
    component_graph(file::EsmFile) -> Graph{ComponentNode, CouplingEdge}

Generate component-level graph showing systems and their couplings.

Creates nodes for each model, reaction system, and data loader. Operators are
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

    # Create nodes for data loaders
    if file.data_loaders !== nothing
        for (name, loader) in file.data_loaders
            metadata = Dict{String, Any}(
                "var_count" => 0,
                "eq_count" => 0,
                "species_count" => 0
            )

            node = ComponentNode(
                name,
                name,
                "data_loader",
                nothing,  # DataLoader has no description; scientific role lives in metadata.tags
                loader,
                metadata
            )
            push!(nodes, node)
            node_map[name] = node
        end
    end

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

            if length(from_parts) >= 1 && length(to_parts) >= 1
                from_system = from_parts[1]
                to_system = to_parts[1]
                variable_name = length(from_parts) > 1 ? from_parts[2] : "var"

                from_node = get(node_map, from_system, nothing)
                to_node = get(node_map, to_system, nothing)

                if from_node !== nothing && to_node !== nothing
                    edge = CouplingEdge(
                        edge_id,
                        from_system,
                        to_system,
                        "variable_map",
                        "[$variable_name]",
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
    expression_graph(expr::Expr) -> Graph{VariableNode, DependencyEdge}

Generate expression-level dependency graph showing variable relationships.

Creates nodes for variables and edges for dependencies based on expressions.
Supports different scoping levels from individual expressions to full files.

# Arguments
- Input can be EsmFile, Model, ReactionSystem, Equation, Reaction, or Expr

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
function expression_graph(file::EsmFile)::Graph{VariableNode, DependencyEdge}
    nodes = VariableNode[]
    edges = _GraphEdge{VariableNode, DependencyEdge}[]

    # Create mapping from scoped variable name to node
    node_map = Dict{String, VariableNode}()

    # Merge a component's expression graph, prefixing every node and edge
    # endpoint with "<component_name>." scoping.
    function add_scoped_subgraph!(component_name, subgraph)
        for node in subgraph.nodes
            scoped_name = "$(component_name).$(node.name)"
            scoped_node = VariableNode(
                scoped_name,
                node.kind,
                node.units,
                component_name
            )
            push!(nodes, scoped_node)
            node_map[scoped_name] = scoped_node
        end

        for edge in subgraph.edges
            source_scoped = "$(component_name).$(edge.data.source)"
            target_scoped = "$(component_name).$(edge.data.target)"

            source_node = get(node_map, source_scoped, nothing)
            target_node = get(node_map, target_scoped, nothing)

            if source_node !== nothing && target_node !== nothing
                scoped_edge = DependencyEdge(
                    source_scoped,
                    target_scoped,
                    edge.data.relationship,
                    edge.data.equation_index,
                    edge.data.expression
                )
                push!(edges, (source=source_node, target=target_node, data=scoped_edge))
            end
        end
    end

    if file.models !== nothing
        for (model_name, model) in file.models
            add_scoped_subgraph!(model_name, expression_graph(model))
        end
    end

    if file.reaction_systems !== nothing
        for (rxn_name, rxn_sys) in file.reaction_systems
            add_scoped_subgraph!(rxn_name, expression_graph(rxn_sys))
        end
    end

    # Add cross-system coupling edges
    for coupling in file.coupling
        if coupling isa CouplingVariableMap
            # Parse from and to
            from_parts = split(coupling.from, ".")
            to_parts = split(coupling.to, ".")

            if length(from_parts) >= 2 && length(to_parts) >= 2
                from_node = get(node_map, coupling.from, nothing)
                to_node = get(node_map, coupling.to, nothing)

                if from_node !== nothing && to_node !== nothing
                    coupling_edge = DependencyEdge(
                        coupling.from,
                        coupling.to,
                        "coupling",
                        nothing,
                        nothing  # transform field doesn't exist in EarthSciAST.Expr
                    )
                    push!(edges, (source=from_node, target=to_node, data=coupling_edge))
                end
            end
        end
    end

    return Graph{VariableNode, DependencyEdge}(nodes, edges)
end

function expression_graph(model::Model)::Graph{VariableNode, DependencyEdge}
    nodes = VariableNode[]
    edges = _GraphEdge{VariableNode, DependencyEdge}[]

    # Create mapping from variable name to node
    node_map = Dict{String, VariableNode}()

    # Create nodes for all variables
    for (var_name, var) in model.variables
        kind = if var.type == StateVariable
            "state"
        elseif var.type == ParameterVariable
            "parameter"
        elseif var.type == ObservedVariable
            "observed"
        else
            "unknown"
        end

        node = VariableNode(
            var_name,
            kind,
            var.units,  # ModelVariable has units field
            "model"
        )
        push!(nodes, node)
        node_map[var_name] = node
    end

    # Create edges from equations
    for (eq_idx, equation) in enumerate(model.equations)
        eq_graph = expression_graph(equation)

        # Add edges from this equation's graph
        for edge in eq_graph.edges
            source_node = get(node_map, edge.data.source, nothing)
            target_node = get(node_map, edge.data.target, nothing)

            if source_node !== nothing && target_node !== nothing
                dep_edge = DependencyEdge(
                    edge.data.source,
                    edge.data.target,
                    edge.data.relationship,
                    eq_idx,
                    edge.data.expression
                )
                push!(edges, (source=source_node, target=target_node, data=dep_edge))
            end
        end
    end

    return Graph{VariableNode, DependencyEdge}(nodes, edges)
end

function expression_graph(rxn_sys::ReactionSystem)::Graph{VariableNode, DependencyEdge}
    nodes = VariableNode[]
    edges = _GraphEdge{VariableNode, DependencyEdge}[]

    # Create mapping from name to node
    node_map = Dict{String, VariableNode}()

    # Create nodes for species
    for species in rxn_sys.species
        node = VariableNode(
            species.name,
            "species",
            nothing,  # Species doesn't have units field
            "reaction_system"
        )
        push!(nodes, node)
        node_map[species.name] = node
    end

    # Create nodes for parameters
    for param in rxn_sys.parameters
        node = VariableNode(
            param.name,
            "parameter",
            param.units,  # Parameter has units field
            "reaction_system"
        )
        push!(nodes, node)
        node_map[param.name] = node
    end

    # Create edges from reactions
    for (rxn_idx, reaction) in enumerate(rxn_sys.reactions)
        rxn_graph = expression_graph(reaction)

        # Add edges from this reaction's graph
        for edge in rxn_graph.edges
            source_node = get(node_map, edge.data.source, nothing)
            target_node = get(node_map, edge.data.target, nothing)

            if source_node !== nothing && target_node !== nothing
                dep_edge = DependencyEdge(
                    edge.data.source,
                    edge.data.target,
                    edge.data.relationship,
                    rxn_idx,
                    edge.data.expression
                )
                push!(edges, (source=source_node, target=target_node, data=dep_edge))
            end
        end
    end

    return Graph{VariableNode, DependencyEdge}(nodes, edges)
end

function expression_graph(equation::Equation)::Graph{VariableNode, DependencyEdge}
    nodes = VariableNode[]
    edges = _GraphEdge{VariableNode, DependencyEdge}[]

    # Get LHS variable (target of dependencies)
    lhs_vars = free_variables(equation.lhs)
    rhs_vars = free_variables(equation.rhs)

    # Create nodes for all variables
    node_map = Dict{String, VariableNode}()
    all_vars = union(lhs_vars, rhs_vars)

    for var_name in all_vars
        node = VariableNode(var_name, "unknown", nothing, "equation")
        push!(nodes, node)
        node_map[var_name] = node
    end

    # Create edges: RHS variables -> LHS variables
    for lhs_var in lhs_vars
        for rhs_var in rhs_vars
            if rhs_var != lhs_var  # Don't create self-loops
                source_node = get(node_map, rhs_var, nothing)
                target_node = get(node_map, lhs_var, nothing)

                if source_node !== nothing && target_node !== nothing
                    dep_edge = DependencyEdge(
                        rhs_var,
                        lhs_var,
                        "additive",  # Default relationship
                        nothing,
                        equation.rhs
                    )
                    push!(edges, (source=source_node, target=target_node, data=dep_edge))
                end
            end
        end
    end

    return Graph{VariableNode, DependencyEdge}(nodes, edges)
end

function expression_graph(reaction::Reaction)::Graph{VariableNode, DependencyEdge}
    nodes = VariableNode[]
    edges = _GraphEdge{VariableNode, DependencyEdge}[]

    # Create mapping from name to node
    node_map = Dict{String, VariableNode}()

    # Collect all species and parameters.
    # `.reactants`/`.products` go through the legacy Dict{String,Float64}
    # property shim — intentional here: the dependency graph wants each
    # species once (Dict-key semantics), not the ordered author-entry list
    # (`raw_substrates`/`raw_products`), which may repeat a species.
    all_species = Set{String}()
    for (species, _) in reaction.reactants
        push!(all_species, species)
    end
    for (species, _) in reaction.products
        push!(all_species, species)
    end

    rate_vars = free_variables(reaction.rate)

    # Create nodes
    for species in all_species
        node = VariableNode(species, "species", nothing, "reaction")
        push!(nodes, node)
        node_map[species] = node
    end

    for var in rate_vars
        if !haskey(node_map, var)
            node = VariableNode(var, "parameter", nothing, "reaction")
            push!(nodes, node)
            node_map[var] = node
        end
    end

    # Create stoichiometric edges (reactants and products affect each other)
    for (reactant, _) in reaction.reactants
        for (product, _) in reaction.products
            if reactant != product
                # Reactant affects product (consumption -> production)
                source_node = get(node_map, reactant, nothing)
                target_node = get(node_map, product, nothing)

                if source_node !== nothing && target_node !== nothing
                    dep_edge = DependencyEdge(
                        reactant,
                        product,
                        "stoichiometric",
                        nothing,
                        reaction.rate
                    )
                    push!(edges, (source=source_node, target=target_node, data=dep_edge))
                end
            end
        end
    end

    # Create rate parameter edges (parameters affect all species)
    for param in rate_vars
        for species in all_species
            source_node = get(node_map, param, nothing)
            target_node = get(node_map, species, nothing)

            if source_node !== nothing && target_node !== nothing
                dep_edge = DependencyEdge(
                    param,
                    species,
                    "rate",
                    nothing,
                    reaction.rate
                )
                push!(edges, (source=source_node, target=target_node, data=dep_edge))
            end
        end
    end

    return Graph{VariableNode, DependencyEdge}(nodes, edges)
end

function expression_graph(expr::Expr)::Graph{VariableNode, DependencyEdge}
    nodes = VariableNode[]
    edges = _GraphEdge{VariableNode, DependencyEdge}[]

    # For single expressions, just create nodes for free variables
    # No dependencies since we don't know the target
    vars = free_variables(expr)
    node_map = Dict{String, VariableNode}()

    for var_name in vars
        node = VariableNode(var_name, "unknown", nothing, "expression")
        push!(nodes, node)
        node_map[var_name] = node
    end

    return Graph{VariableNode, DependencyEdge}(nodes, edges)
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
    "data_loader"     => (dot_fillcolor = "lightyellow", mermaid = ("{", "}")),
)
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
    "species"   => (dot_shape = "ellipse", mermaid = ("(", ")")),
    "parameter" => (dot_shape = "box",     mermaid = ("[", "]")),
    "state"     => (dot_shape = "circle",  mermaid = ("((", "))")),
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
labels are quoted, so dotted/scoped names render correctly. Edges carry no
labels (adding them would change the pinned output; see tests/graphs).
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
        push!(lines, "    $(_mermaid_id(edge.data.from)) $arrow $(_mermaid_id(edge.data.to))")
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
        push!(lines, "    $(_mermaid_id(edge.data.source)) $arrow $(_mermaid_id(edge.data.target))")
    end

    return join(lines, "\n")
end

"""
Export graph to JSON adjacency list format.
"""
function to_json(graph::Graph{ComponentNode, CouplingEdge})::String
    adj_list = Dict{String, Vector{String}}()
    for node in graph.nodes
        adj_list[node.id] = String[]
    end
    for edge in graph.edges
        push!(adj_list[edge.data.from], edge.data.to)
    end

    result = Dict(
        "nodes" => [Dict("id" => node.id, "name" => node.name, "type" => node.type) for node in graph.nodes],
        "edges" => [Dict("from" => edge.data.from, "to" => edge.data.to, "type" => edge.data.type, "label" => edge.data.label) for edge in graph.edges],
        "adjacency" => adj_list
    )
    return JSON3.write(result, pretty=true)
end

function to_json(graph::Graph{VariableNode, DependencyEdge})::String
    adj_list = Dict{String, Vector{String}}()
    for node in graph.nodes
        adj_list[node.name] = String[]
    end
    for edge in graph.edges
        push!(adj_list[edge.data.source], edge.data.target)
    end

    result = Dict(
        "nodes" => [Dict("name" => node.name, "kind" => node.kind, "system" => node.system) for node in graph.nodes],
        "edges" => [Dict("source" => edge.data.source, "target" => edge.data.target, "relationship" => edge.data.relationship) for edge in graph.edges],
        "adjacency" => adj_list
    )
    return JSON3.write(result, pretty=true)
end