module EarthSciASTCatalystExt

using EarthSciAST
# Note: we deliberately do NOT import `Expr` from EarthSciAST into
# this extension's namespace — that would shadow Core.Expr and break the
# runtime `Core.eval`-built macro calls below (`@species` / `@parameters`),
# whose quoted ASTs are assembled from plain `Expr` nodes. Use the `EsmExpr`
# alias for the ESM expression type instead (same pattern as MTKExt).
using EarthSciAST: NumExpr, IntExpr, VarExpr, OpExpr, Reaction,
    ReactionSystem, Species, Parameter, Equation, ContinuousEvent,
    DiscreteEvent, AffectEquation, FunctionalAffect, ConditionTrigger,
    PeriodicTrigger, PresetTimesTrigger,
    GapReport,
    # MTK-independent export helpers shared with the MTK extension
    # (defined next to GapReport in src/mtk_export.jl).
    _strip_time, _meta_string, _meta_vec_string, _gap_to_note,
    _reference_notes, _esm_file_metadata, _warn_gaps
# Explicit import so we can add a method to this generic.
import EarthSciAST: mtk2esm, mtk2esm_gaps
using ModelingToolkit
using Symbolics
using Catalyst

const EsmExpr = EarthSciAST.Expr

# ========================================
# ESM Expr → Symbolics conversion (local copy for rate expressions)
# ========================================

function _esm_to_symbolic(expr::EsmExpr, var_dict::Dict{String,Any})
    if expr isa IntExpr
        return expr.value
    elseif expr isa NumExpr
        return expr.value
    elseif expr isa VarExpr
        if haskey(var_dict, expr.name)
            return var_dict[expr.name]
        else
            sym = Symbolics.variable(Symbol(expr.name); T=Real)
            var_dict[expr.name] = sym
            return sym
        end
    elseif expr isa OpExpr
        op = expr.op
        if op == "+"
            args = [_esm_to_symbolic(a, var_dict) for a in expr.args]
            return length(args) == 1 ? args[1] : sum(args)
        elseif op == "-"
            args = [_esm_to_symbolic(a, var_dict) for a in expr.args]
            return length(args) == 1 ? -args[1] : args[1] - args[2]
        elseif op == "*"
            args = [_esm_to_symbolic(a, var_dict) for a in expr.args]
            return length(args) == 1 ? args[1] : prod(args)
        elseif op == "/"
            l = _esm_to_symbolic(expr.args[1], var_dict)
            r = _esm_to_symbolic(expr.args[2], var_dict)
            return l / r
        elseif op == "^"
            l = _esm_to_symbolic(expr.args[1], var_dict)
            r = _esm_to_symbolic(expr.args[2], var_dict)
            return l^r
        elseif op in ("exp", "log", "log10", "sin", "cos", "tan", "sqrt", "abs")
            arg = _esm_to_symbolic(expr.args[1], var_dict)
            fn = getfield(Base, Symbol(op))
            return fn(arg)
        elseif op in ("max", "min")
            # Same arity rule the MTK extension enforces: the spec defines
            # min/max as n-ary with n >= 2 (esm-spec §4.2).
            length(expr.args) < 2 && throw(ArgumentError(
                "$op requires at least 2 arguments (esm-spec §4.2)"))
            args = [_esm_to_symbolic(a, var_dict) for a in expr.args]
            fn = getfield(Base, Symbol(op))
            return reduce(fn, args)
        else
            throw(ArgumentError("Unsupported operator in rate expression: $op"))
        end
    end
    error("Unknown expression type: $(typeof(expr))")
end

# ========================================
# ESM ReactionSystem → Catalyst.ReactionSystem
# ========================================

# Create a Catalyst species using @species so it carries the species
# metadata Catalyst.Reaction expects — the plain Symbolics.variable path
# strips it. We invoke @species at runtime via Core.eval because the macro
# insists on literal identifiers. Julia ASTs are built with the qualified
# `Core.Expr` — bare `Expr` is ambiguous here (Base.Expr vs the package's
# exported ESM `Expr`); the ESM expression type is only ever referenced via
# the `EsmExpr` alias.
function _make_species(name::Symbol, t_sym)
    binding = Core.Expr(:(=), :__esm_t, t_sym)
    call = Core.Expr(:call, name, :__esm_t)
    block = Core.Expr(:block, binding, :(Catalyst.@species $(call)))
    let_expr = Core.Expr(:let, Core.Expr(:block), block)
    vars = Core.eval(Catalyst, let_expr)
    return vars[1]
end

function _make_cparam(name::Symbol)
    vars = Core.eval(Catalyst, :(@parameters $(name)))
    return vars[1]
end

# Reservoir species: declared as a parameter with Catalyst's
# isconstantspecies=true metadata. The @species macro rejects this
# metadata ("can only be used with parameters"), so we must go through
# @parameters. The resulting symbol still participates in reactions as a
# reactant/product but its value is held fixed by the solver.
function _make_constant_species(name::Symbol)
    # Equivalent to `@parameters X [isconstantspecies=true]` at runtime.
    meta = Core.Expr(:vect, Core.Expr(:(=), :isconstantspecies, true))
    decl = Core.Expr(:macrocall, Symbol("@parameters"), LineNumberNode(0), name, meta)
    vars = Core.eval(Catalyst, decl)
    return vars[1]
end

function _make_civ(name::Symbol)
    # Independent variables in Catalyst/MTK need @independent_variables metadata.
    vars = Core.eval(Catalyst, :(@variables $(name)))
    return vars[1]
end

"""
    Catalyst.ReactionSystem(rsys::EarthSciAST.ReactionSystem; name=:anonymous, kwargs...)

Build a `Catalyst.ReactionSystem` from an ESM `ReactionSystem`.
"""
function Catalyst.ReactionSystem(rsys::EarthSciAST.ReactionSystem;
                                 name::Union{Symbol,AbstractString}=:anonymous,
                                 kwargs...)
    t = _make_civ(:t)

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
        sym = _make_cparam(Symbol(p.name))
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
        for (spname, st) in esm_rxn.reactants
            haskey(species_dict, spname) || throw(ArgumentError(
                "reaction reactant '$(spname)' is not declared in the " *
                "reaction system's species list"))
            push!(reactants_syms, species_dict[spname])
            push!(reactant_stoich, st)
        end

        products_syms = Any[]
        product_stoich = Real[]
        for (spname, st) in esm_rxn.products
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

function _catalyst_rate_to_esm(expr)
    if expr isa Bool
        return IntExpr(Int64(expr))  # defensive
    elseif expr isa Integer
        return IntExpr(Int64(expr))
    elseif expr isa AbstractFloat
        return NumExpr(Float64(expr))
    elseif expr isa Real
        return NumExpr(Float64(expr))
    end
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
        if op == (+); return OpExpr("+", esm_args)
        elseif op == (*); return OpExpr("*", esm_args)
        elseif op == (-); return OpExpr("-", esm_args)
        elseif op == (/); return OpExpr("/", esm_args)
        elseif op == (^); return OpExpr("^", esm_args)
        else
            return OpExpr(string(nameof(op)), esm_args)
        end
    end
    # Const-style symbolic literal: numeric values (including those
    # introduced by MTK Constants substitution) appear in the symbolic
    # tree as BasicSymbolic Const nodes for which `issym`/`iscall` are
    # both false. Without this branch they fall through to the string
    # fallback below and get serialized as JSON strings (esm-edt).
    val = Symbolics.value(raw)
    if val isa Bool
        return IntExpr(Int64(val))
    elseif val isa Integer
        return IntExpr(Int64(val))
    elseif val isa Real
        return NumExpr(Float64(val))
    end
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

    # Resolve system name: caller-supplied `metadata.name` wins; else
    # `nameof(rs)` if non-anonymous; else a literal placeholder.
    sys_name = let name_kw = _meta_string(metadata, :name, "")
        if !isempty(name_kw)
            name_kw
        else
            try
                sn = String(nameof(rs))
                sn == "" ? "UnnamedReactionSystem" : sn
            catch e
                @debug "mtk2esm: nameof(rs) unavailable" exception=(e, catch_backtrace())
                "UnnamedReactionSystem"
            end
        end
    end

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
