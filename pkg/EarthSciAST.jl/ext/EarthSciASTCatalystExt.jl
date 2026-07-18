"""
    EarthSciASTCatalystExt

The Catalyst binding, loaded automatically when `Catalyst` (with
`ModelingToolkit` and `Symbolics`) is in the session. It supplies both
directions of the ESM ⇄ Catalyst reaction-network bridge:

- **ESM → Catalyst**: `Catalyst.ReactionSystem(::EarthSciAST.ReactionSystem)`,
  building real `@species`/`@parameters` symbols (including reservoir
  species) and lowering each reaction's rate expression.
- **Catalyst → ESM**: `EarthSciAST.ReactionSystem(::Catalyst.ReactionSystem)`
  plus the `mtk2esm` migration exporter for reaction systems.

Kept a `weakdep` extension (mirroring `MTKExt` / `SimulateExt`) so the base
package carries no Catalyst dependency; without it loaded, the core stubs in
src/mtk_export.jl throw an `ArgumentError` naming what to load, and the
Catalyst-free path (`derive_odes` on the ESM `ReactionSystem`, plus
`flatten`/`simulate`) remains fully available.
"""
module EarthSciASTCatalystExt

# We refer to the ESM abstract expression type via the `EsmExpr` alias (below)
# rather than importing it unqualified — same pattern as MTKExt. The runtime
# `Core.eval`-built macro calls below (`@species` / `@parameters`) assemble
# Julia `Core.Expr` AST, written explicitly (there is no name clash now that the
# ESM type is `ASTExpr`, not `Expr`).
using EarthSciAST
using EarthSciAST: NumExpr, IntExpr, VarExpr, OpExpr, Reaction,
    ReactionSystem, Species, Parameter,
    get_reactants_dict, get_products_dict,
    GapReport,
    # MTK-independent export helpers shared with the MTK extension
    # (defined next to GapReport in src/mtk_export.jl).
    _strip_time, _resolve_sys_name,
    _reference_notes, _esm_file_metadata, _warn_gaps
# Explicit import so we can add a method to this generic.
import EarthSciAST: mtk2esm
using ModelingToolkit
using Symbolics
using Catalyst

const EsmExpr = EarthSciAST.ASTExpr

# Shared with EarthSciASTMTKExt (each extension compiles its own copy); the
# per-extension policy hooks that keep the two extensions' behavior distinct
# are documented in each file's header.
include("shared/esm_to_symbolic.jl")
include("shared/symbolic_to_esm.jl")
include("shared/eval_var_macro.jl")

# ========================================
# ESM ASTExpr → Symbolics conversion (rate expressions)
# ========================================

# The unary elementwise ops the rate interpreter accepts — deliberately
# NARROWER than the MTK lowering's set (no sinh/asin/…); membership is
# behavior, so it stays explicit.
const _RATE_UNARY_SCALAR_OPS = ("exp", "log", "log10", "sin", "cos", "tan",
                                "sqrt", "abs")

# Lower an ESM rate expression to Symbolics. The extension-independent
# scalar arms live in the shared `_esm_to_symbolic_core`
# (ext/shared/esm_to_symbolic.jl); the hooks below carry this extension's
# policies: NumExpr values pass through untouched (no Int promotion), and
# any op outside the scalar vocabulary is an error.
function _esm_to_symbolic(expr::EsmExpr, var_dict::Dict{String,Any})
    return _esm_to_symbolic_core(expr, a -> _esm_to_symbolic(a, var_dict);
        number_value = identity,
        resolve_var = name -> _resolve_rate_var(name, var_dict),
        unary_ops = _RATE_UNARY_SCALAR_OPS,
        extended_op = (op, _) -> throw(ArgumentError(
            "Unsupported operator in rate expression: $op")))
end

# Unknown-variable policy of the rate interpreter: AUTO-CREATE a fresh real
# symbol and cache it. The MTK lowering throws instead; the divergence is
# live behavior (see ext/shared/esm_to_symbolic.jl).
function _resolve_rate_var(name::String, var_dict::Dict{String,Any})
    if haskey(var_dict, name)
        return var_dict[name]
    else
        sym = Symbolics.variable(Symbol(name); T=Real)
        var_dict[name] = sym
        return sym
    end
end

# ========================================
# ESM ReactionSystem → Catalyst.ReactionSystem
# ========================================

# Create a Catalyst species using @species so it carries the species
# metadata Catalyst.Reaction expects — the plain Symbolics.variable path
# strips it. We invoke @species at runtime via the shared `_eval_var_macro`
# scaffold (ext/shared/eval_var_macro.jl) because the macro insists on
# literal identifiers; the live `t` symbol is passed by value through a
# `let` binding.
function _make_species(name::Symbol, t_sym)
    call = Core.Expr(:call, name, :__esm_t)
    return _eval_var_macro(Catalyst, Symbol("@species"), call;
                           bindings=[:__esm_t => t_sym])
end

_make_catalyst_param(name::Symbol) =
    _eval_var_macro(Catalyst, Symbol("@parameters"), name)

# Reservoir species: declared as a parameter with Catalyst's
# isconstantspecies=true metadata. The @species macro rejects this
# metadata ("can only be used with parameters"), so we must go through
# @parameters. The resulting symbol still participates in reactions as a
# reactant/product but its value is held fixed by the solver.
function _make_constant_species(name::Symbol)
    # Equivalent to `@parameters X [isconstantspecies=true]` at runtime.
    meta = Core.Expr(:vect, Core.Expr(:(=), :isconstantspecies, true))
    return _eval_var_macro(Catalyst, Symbol("@parameters"), name, meta)
end

# Independent variables in Catalyst/MTK need @independent_variables metadata.
_make_catalyst_independent_var(name::Symbol) =
    _eval_var_macro(Catalyst, Symbol("@variables"), name)

"""
    Catalyst.ReactionSystem(rsys::EarthSciAST.ReactionSystem; name=:anonymous, kwargs...)

Build a `Catalyst.ReactionSystem` from an ESM `ReactionSystem`.
"""
function Catalyst.ReactionSystem(rsys::EarthSciAST.ReactionSystem;
                                 name::Union{Symbol,AbstractString}=:anonymous,
                                 kwargs...)
    t = _make_catalyst_independent_var(:t)

    species_dict = Dict{String,Any}()
    species_syms = Any[]
    param_dict = Dict{String,Any}()
    param_syms = Any[]
    for sp in rsys.species
        if sp.constant === true
            # Reservoir species: parameter with isconstantspecies=true metadata.
            sym = _make_constant_species(Symbol(sp.name))
            push!(param_syms, sym)
        else
            sym = _make_species(Symbol(sp.name), t)
            push!(species_syms, sym)
        end
        species_dict[sp.name] = sym
    end

    for p in rsys.parameters
        sym = _make_catalyst_param(Symbol(p.name))
        push!(param_syms, sym)
        param_dict[p.name] = sym
    end

    all_vars = Base.merge(species_dict, param_dict)
    rxns = Any[]
    for esm_rxn in rsys.reactions
        rate = _esm_to_symbolic(esm_rxn.rate, all_vars)

        # A reactant/product naming a species absent from the declared
        # species list is a malformed document — silently dropping it would
        # change the reaction's stoichiometry, so fail loudly instead.
        reactants_syms = Any[]
        reactant_stoich = Real[]
        for (spname, st) in get_reactants_dict(esm_rxn)
            haskey(species_dict, spname) || throw(ArgumentError(
                "reaction reactant '$(spname)' is not declared in the " *
                "reaction system's species list"))
            push!(reactants_syms, species_dict[spname])
            push!(reactant_stoich, st)
        end

        products_syms = Any[]
        product_stoich = Real[]
        for (spname, st) in get_products_dict(esm_rxn)
            haskey(species_dict, spname) || throw(ArgumentError(
                "reaction product '$(spname)' is not declared in the " *
                "reaction system's species list"))
            push!(products_syms, species_dict[spname])
            push!(product_stoich, st)
        end

        if isempty(reactants_syms) && !isempty(products_syms)
            push!(rxns, Catalyst.Reaction(rate, nothing, products_syms,
                                          nothing, product_stoich))
        elseif !isempty(reactants_syms) && isempty(products_syms)
            push!(rxns, Catalyst.Reaction(rate, reactants_syms, nothing,
                                          reactant_stoich, nothing))
        elseif !isempty(reactants_syms) && !isempty(products_syms)
            push!(rxns, Catalyst.Reaction(rate, reactants_syms, products_syms,
                                          reactant_stoich, product_stoich))
        end
    end

    sys_name = name isa Symbol ? name : Symbol(name)
    return Catalyst.ReactionSystem(rxns, t, species_syms, param_syms;
                                   name=sys_name, kwargs...)
end

# ========================================
# Reverse direction: Catalyst → ESM ReactionSystem
# ========================================

"""
    EarthSciAST.ReactionSystem(rs::Catalyst.ReactionSystem)

Convert a `Catalyst.ReactionSystem` back to an ESM `ReactionSystem`.
"""
function EarthSciAST.ReactionSystem(rs::Catalyst.ReactionSystem)
    # Read a symbol's default-value metadata, or `nothing` when absent.
    # No fabrication: an ESM `default` field is omitted rather than invented
    # (same policy as `_lookup_default` in the MTK extension).
    _default_or_nothing(sym) = try
        v = Symbolics.getmetadata(Symbolics.unwrap(sym),
                                  Symbolics.VariableDefaultValue, nothing)
        v isa Number ? Float64(v) : nothing
    catch e
        @debug "ReactionSystem export: default metadata unreadable for $(sym)" exception=(e, catch_backtrace())
        nothing
    end

    species = Species[]
    for sp in Catalyst.species(rs)
        name = _strip_time(string(Catalyst.getname(sp)))
        push!(species, Species(name; default=_default_or_nothing(sp)))
    end

    parameters = Parameter[]
    for p in Catalyst.parameters(rs)
        pname = string(Catalyst.getname(p))
        default = _default_or_nothing(p)
        # Reservoir species travel through Catalyst as parameters with
        # isconstantspecies=true metadata; recover them as ESM species with
        # constant=true rather than as ordinary parameters.
        if Catalyst.isconstant(p)
            push!(species, Species(pname; default=default, constant=true))
        else
            # The ESM `Parameter` struct requires a concrete Float64 default
            # (types.jl), so absence cannot be represented here; 1.0 is the
            # documented placeholder until the core type grows an optional
            # default. (Species above CAN omit theirs, and do.)
            push!(parameters, Parameter(pname, default === nothing ? 1.0 : default))
        end
    end

    reactions = Reaction[]
    for rxn in Catalyst.reactions(rs)
        reactants = Dict{String,Float64}()
        if !isempty(rxn.substrates)
            for (i, s) in enumerate(rxn.substrates)
                name = _strip_time(string(Catalyst.getname(s)))
                stoich = length(rxn.substoich) >= i ? Float64(rxn.substoich[i]) : 1.0
                reactants[name] = stoich
            end
        end
        products = Dict{String,Float64}()
        if !isempty(rxn.products)
            for (i, pr) in enumerate(rxn.products)
                name = _strip_time(string(Catalyst.getname(pr)))
                stoich = length(rxn.prodstoich) >= i ? Float64(rxn.prodstoich[i]) : 1.0
                products[name] = stoich
            end
        end
        rate = _catalyst_rate_to_esm(rxn.rate)
        push!(reactions, Reaction(reactants, products, rate))
    end

    return ReactionSystem(species, reactions; parameters=parameters)
end

# (`_strip_time` is shared from src/mtk_export.jl.)

# Ordered operator table of the Catalyst rate walk, matched by `==` — a
# deliberately smaller coverage than the MTK export walk's table (which is
# also matched by a nameof-tolerant predicate); only the table scan itself
# (`_call_op_to_esm_name`) is shared.
const _RATE_EXPORT_OP_TABLE = ((+, "+"), (*, "*"), (-, "-"), (/, "/"), (^, "^"))

# Reverse walk for rate expressions. The scalar fast-paths, the Const-node
# branch, and the operator-table scan are shared with the MTK export walk
# (ext/shared/symbolic_to_esm.jl); unlike that walk, this one has no
# derivative branch and no `known_vars` disambiguation — species calls are
# recognized by `issym(op)` instead.
function _catalyst_rate_to_esm(expr)
    lit = _number_to_esm_literal(expr)  # Bool arm is defensive here
    lit === nothing || return lit
    raw = Symbolics.unwrap(expr)
    if Symbolics.issym(raw)
        return VarExpr(_strip_time(string(Symbolics.getname(raw))))
    end
    if Symbolics.iscall(raw)
        op = Symbolics.operation(raw)
        args = Symbolics.arguments(raw)
        # Species reference: Catalyst represents a time-dependent species
        # `S` inside a rate as a call `S(t)` whose operation is the species
        # symbol itself. Emit a bare identifier rather than wrapping it in
        # {op: "S", args: ["t"]}, which would serialize as a registered-
        # function call and break downstream consumers (esm-edt).
        if Symbolics.issym(op)
            return VarExpr(_strip_time(string(Symbolics.getname(op))))
        end
        esm_args = [_catalyst_rate_to_esm(a) for a in args]
        esm_op = _call_op_to_esm_name(op, _RATE_EXPORT_OP_TABLE, ==)
        esm_op === nothing || return OpExpr(esm_op, esm_args)
        return OpExpr(string(nameof(op)), esm_args)
    end
    # Const-style symbolic literal (esm-edt): without this branch, numeric
    # Const nodes would fall through to the string fallback below and get
    # serialized as JSON strings.
    const_lit = _symbolic_const_to_esm(raw)
    const_lit === nothing || return const_lit
    return VarExpr(string(expr))
end

# ========================================
# MTK → ESM export for Catalyst.ReactionSystem (gt-dod2)
# ========================================

"""
    mtk2esm(rs::Catalyst.ReactionSystem; metadata=(;)) -> Dict

Walk a Catalyst `ReactionSystem` and emit a schema-valid ESM `Dict` with a
top-level `reaction_systems.<name>` entry. See the plain-MTK `mtk2esm`
method in `EarthSciASTMTKExt` for the general contract.

Fields populated from the reactions:
- `species` (from `Catalyst.species(rs)`)
- `parameters` (from `Catalyst.parameters(rs)`)
- `reactions` (id + substrates/products + rate expression)

Placeholders filled in Phase 2: `description`, `version`, `reference`,
`tests`, `examples`, `metadata.tags`, `metadata.source_ref`.
"""
function mtk2esm(rs::Catalyst.ReactionSystem; metadata=(;))
    gaps = GapReport[]

    sys_name = _resolve_sys_name(rs, metadata, "UnnamedReactionSystem")

    # Build the ESM ReactionSystem via the existing reverse method, which
    # already handles species / parameters / reactions / rate expressions.
    esm_rs = try
        EarthSciAST.ReactionSystem(rs)
    catch e
        push!(gaps, GapReport("unknown",
            "failed to convert Catalyst.ReactionSystem: $(sprint(showerror, e))",
            "reaction_system"))
        # Build an empty ESM reaction system so the output stays schema-valid.
        ReactionSystem(Species[], Reaction[])
    end

    rs_dict = EarthSciAST.serialize_reaction_system(esm_rs)

    # Per-RS reference.notes carries description + source_ref + TODO_GAPs
    # (same convention as the ODE Model branch). Reference is the only
    # schema-sanctioned free-form text slot at the reaction_system level.
    ref_notes_lines = _reference_notes(metadata, gaps)
    if !isempty(ref_notes_lines)
        rs_dict["reference"] = Dict{String,Any}("notes" => join(ref_notes_lines, "\n"))
    end
    rs_dict["tests"] = Any[]
    rs_dict["examples"] = Any[]

    # Top-level EsmFile-shaped dict
    out = Dict{String,Any}(
        "esm" => EarthSciAST.ESM_FORMAT_VERSION,
        "metadata" => _esm_file_metadata(metadata, sys_name),
        "reaction_systems" => Dict{String,Any}(sys_name => rs_dict),
    )

    _warn_gaps(gaps, "ReactionSystem $(sys_name)")

    return out
end

end # module EarthSciASTCatalystExt
