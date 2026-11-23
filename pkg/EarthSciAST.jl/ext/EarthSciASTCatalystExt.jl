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
`flatten`/`esm_problem`) remains fully available.
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

# Lower an ESM rate expression to Symbolics. A rate speaks the same scalar
# vocabulary as the ModelingToolkit lowering, the registry's
# (`_esm_to_symbolic_core`, ext/shared/esm_to_symbolic.jl), comparisons and
# `ifelse` included, so a piecewise rate law lowers on this route as it does
# through `flatten`. The hooks carry this extension's policies: NumExpr values
# pass through untouched (no Int promotion), and any op outside the scalar
# vocabulary is an error.
function _esm_to_symbolic(expr::EsmExpr, var_dict::Dict{String, Any})
    return _esm_to_symbolic_core(
        expr, a -> _esm_to_symbolic(a, var_dict);
        number_value = identity,
        resolve_var = name -> _resolve_rate_var(name, var_dict),
        extended_op = (op, _) -> throw(
            SimulateError(
                "Unsupported operator in rate expression: $op",
                ERROR_CODES.UNSUPPORTED_CONSTRUCT
            )
        )
    )
end

# Unknown-variable policy of the rate interpreter: AUTO-CREATE a fresh real
# symbol and cache it. The MTK lowering throws instead; the divergence is
# live behavior (see ext/shared/esm_to_symbolic.jl).
function _resolve_rate_var(name::String, var_dict::Dict{String, Any})
    if haskey(var_dict, name)
        return var_dict[name]
    else
        sym = Symbolics.variable(Symbol(name); T = Real)
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
    return _eval_var_macro(
        Catalyst, Symbol("@species"), call;
        bindings = [:__esm_t => t_sym]
    )
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

The system is built with `combinatoric_ratelaws = false`: esm-spec §7.4 gives a
reaction the mass-action rate `k · ∏ Sᵢ^nᵢ` with no `1/nᵢ!` factor, which is
what `src/reactions.jl` derives. Species and parameter `default`s are attached
to their symbols. A system carrying `constraint_equations`, events or
`subsystems`, which this constructor has no lowering for, is refused with a
`SimulateError` naming the field (code `unsupported_construct`), as is a
reaction with neither substrates nor products (code `null_reaction`).

A reaction system carries no working precision: its species and parameters
have no `element_type`, and the document's `domain.element_type` is not part
of it. So this constructor cannot refuse a binary32 document. A Float32
document's reaction system is refused with `float32_unsupported` where the
precision is known: `esm_problem` and `ModelingToolkit.System` of the
flattened document.
"""
function Catalyst.ReactionSystem(
        rsys::EarthSciAST.ReactionSystem;
        name::Union{Symbol, AbstractString} = :anonymous,
        kwargs...
    )
    for (field, present) in (
            ("constraint_equations", !isempty(rsys.constraint_equations)),
            ("discrete_events", !isempty(rsys.discrete_events)),
            ("continuous_events", !isempty(rsys.continuous_events)),
            ("subsystems", !isempty(rsys.subsystems)),
        )
        present && throw(
            SimulateError(
                "Catalyst.ReactionSystem: the reaction system declares " *
                    "`$(field)`, which this constructor has no lowering for; " *
                    "flatten the document and build a ModelingToolkit.System " *
                    "(or call esm_problem) instead",
                ERROR_CODES.UNSUPPORTED_CONSTRUCT
            )
        )
    end
    t = _make_catalyst_independent_var(:t)
    _with_default(sym, val) =
        val === nothing ? sym : Symbolics.setdefaultval(sym, Float64(val))

    species_dict = Dict{String, Any}()
    species_syms = Any[]
    param_dict = Dict{String, Any}()
    param_syms = Any[]
    for sp in rsys.species
        if sp.constant === true
            # Reservoir species: parameter with isconstantspecies=true metadata.
            sym = _with_default(_make_constant_species(Symbol(sp.name)), sp.default)
            push!(param_syms, sym)
        else
            sym = _with_default(_make_species(Symbol(sp.name), t), sp.default)
            push!(species_syms, sym)
        end
        species_dict[sp.name] = sym
    end

    for p in rsys.parameters
        sym = _with_default(_make_catalyst_param(Symbol(p.name)), p.default)
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
            haskey(species_dict, spname) || throw(
                SimulateError(
                    "reaction reactant '$(spname)' is not declared in the " *
                        "reaction system's species list",
                    ERROR_CODES.UNDEFINED_SPECIES
                )
            )
            push!(reactants_syms, species_dict[spname])
            push!(reactant_stoich, st)
        end

        products_syms = Any[]
        product_stoich = Real[]
        for (spname, st) in get_products_dict(esm_rxn)
            haskey(species_dict, spname) || throw(
                SimulateError(
                    "reaction product '$(spname)' is not declared in the " *
                        "reaction system's species list",
                    ERROR_CODES.UNDEFINED_SPECIES
                )
            )
            push!(products_syms, species_dict[spname])
            push!(product_stoich, st)
        end

        isempty(reactants_syms) && isempty(products_syms) && throw(
            SimulateError(
                "null_reaction: reaction '$(esm_rxn.id)' has neither " *
                    "substrates nor products",
                ERROR_CODES.NULL_REACTION
            )
        )
        push!(
            rxns, Catalyst.Reaction(
                rate,
                isempty(reactants_syms) ? nothing : reactants_syms,
                isempty(products_syms) ? nothing : products_syms,
                isempty(reactants_syms) ? nothing : reactant_stoich,
                isempty(products_syms) ? nothing : product_stoich
            )
        )
    end

    sys_name = name isa Symbol ? name : Symbol(name)
    return Catalyst.ReactionSystem(
        rxns, t, species_syms, param_syms;
        name = sys_name, combinatoric_ratelaws = false, kwargs...
    )
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
        v = Symbolics.getmetadata(
            Symbolics.unwrap(sym),
            Symbolics.VariableDefaultValue, nothing
        )
        v isa Number ? Float64(v) : nothing
    catch e
        EarthSciAST._is_resource_error(e) && rethrow()
        @debug "ReactionSystem export: default metadata unreadable for $(sym)" exception = (e, catch_backtrace())
        nothing
    end

    species = Species[]
    for sp in Catalyst.species(rs)
        name = _strip_time(string(Catalyst.getname(sp)))
        push!(species, Species(name; default = _default_or_nothing(sp)))
    end

    parameters = Parameter[]
    for p in Catalyst.parameters(rs)
        pname = string(Catalyst.getname(p))
        default = _default_or_nothing(p)
        # Reservoir species travel through Catalyst as parameters with
        # isconstantspecies=true metadata; recover them as ESM species with
        # constant=true rather than as ordinary parameters.
        if Catalyst.isconstant(p)
            push!(species, Species(pname; default = default, constant = true))
        else
            # `Parameter.default` is optional (esm-schema.json's `Parameter`
            # declares no `required` list), so absence travels as absence, as
            # for `Species` just above.
            push!(parameters, Parameter(pname, default))
        end
    end

    reactions = Reaction[]
    for rxn in Catalyst.reactions(rs)
        reactants = Dict{String, Float64}()
        if !isempty(rxn.substrates)
            for (i, s) in enumerate(rxn.substrates)
                name = _strip_time(string(Catalyst.getname(s)))
                stoich = length(rxn.substoich) >= i ? Float64(rxn.substoich[i]) : 1.0
                reactants[name] = stoich
            end
        end
        products = Dict{String, Float64}()
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

    return ReactionSystem(species, reactions; parameters = parameters)
end

# (`_strip_time` is shared from src/mtk_export.jl.)

# A rate expression back to ESM: the shared reverse walk
# (ext/shared/symbolic_to_esm.jl). A species inside a rate is a call `S(t)` whose
# operation is the species symbol; it becomes a bare `VarExpr`, never an
# `OpExpr("S", ["t"])`. A rate has no derivatives.
_catalyst_rate_to_esm(expr) = _symbolic_to_esm(expr; derivatives = false)

# ========================================
# MTK → ESM export for Catalyst.ReactionSystem
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

Left as placeholders for hand migration: `description`, `version`,
`reference`, `tests`, `analyses`, `metadata.tags`, `metadata.source_ref`.
"""
function mtk2esm(rs::Catalyst.ReactionSystem; metadata = (;))
    gaps = GapReport[]

    sys_name = _resolve_sys_name(rs, metadata, "UnnamedReactionSystem")

    # Build the ESM ReactionSystem via the existing reverse method, which
    # already handles species / parameters / reactions / rate expressions.
    esm_rs = try
        EarthSciAST.ReactionSystem(rs)
    catch e
        EarthSciAST._is_resource_error(e) && rethrow()
        push!(
            gaps, GapReport(
                "unknown",
                "failed to convert Catalyst.ReactionSystem: $(sprint(showerror, e))",
                "reaction_system"
            )
        )
        # Build an empty ESM reaction system so the output stays schema-valid.
        ReactionSystem(Species[], Reaction[])
    end

    rs_dict = EarthSciAST.serialize_reaction_system(esm_rs)

    # Per-RS reference.notes carries description + source_ref + TODO_GAPs
    # (same convention as the ODE Model branch). Reference is the only
    # schema-sanctioned free-form text slot at the reaction_system level.
    ref_notes_lines = _reference_notes(metadata, gaps)
    if !isempty(ref_notes_lines)
        rs_dict["reference"] = Dict{String, Any}("notes" => join(ref_notes_lines, "\n"))
    end
    rs_dict["tests"] = Any[]
    rs_dict["analyses"] = Any[]

    # Top-level EsmFile-shaped dict
    out = Dict{String, Any}(
        "esm" => EarthSciAST.SCHEMA_VERSION,
        "metadata" => _esm_file_metadata(metadata, sys_name),
        "reaction_systems" => Dict{String, Any}(sys_name => rs_dict),
    )

    _warn_gaps(gaps, "ReactionSystem $(sys_name)")

    return out
end

end # module EarthSciASTCatalystExt
