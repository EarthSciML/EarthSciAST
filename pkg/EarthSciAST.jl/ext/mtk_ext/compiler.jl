# ============================================================================
# `compiler = :mtk` — the ModelingToolkit compiler behind `esm_problem`
# (API_SPEC §5.8, esm-libraries-spec §2.5.2 and §2.5.10)
# ============================================================================
#
# WHERE THIS COMPILER SITS. `interpreter` is a deliberately simple oracle whose
# only job is checking the other compilers. `native` is the universally fast
# option with no heavy external dependency, which is why it is the default.
# `sympy` and `mtk` are SPECIALTY compilers: they work only for SOME documents.
# `xla` is the other kind of specialty — it needs a heavy external dependency to
# exist at all.
#
# `:mtk`'s specialty is the one thing no other compiler in any binding runs:
# EVENTS and IMPLICIT EQUATIONS, the three constructs CONFORMANCE_SPEC §5.39
# has every other evaluator refuse with `unsupported_construct`. A continuous
# event becomes a root-found callback, a discrete event a periodic / preset /
# condition callback, and an implicit equation an algebraic constraint that
# `mtkcompile` either solves away into an observed or leaves as a residual for
# a mass-matrix DAE solver.
#
# What it gives up for that is everything the run document can carry BESIDES
# equations. There is no provider seam, no live forcing buffer, no const-array
# channel and no projection-pushdown rewrite on this path: a loaded field never
# reaches the ModelingToolkit system, so a document fed by data is REFUSED BY
# NAME (`compiler_refused_rule`) rather than built without it. That is the
# §2.5.10 contract — a compiler either runs the whole document or names what it
# refused — and it is why this one is called a specialty.
#
# THE SHAPE OF THE BUILD. `esm_problem(file; compiler = :mtk)` runs
#
#     load → flatten → lower_table_lookups → ModelingToolkit.System
#          → mtkcompile → ODEProblem
#
# and wraps the result in the SAME `EsmProblem` every other compiler returns,
# so `solve`, `remake`, `callbacks`, `observed_field`, `compiler_report` and
# name-indexed solution access are the ordinary ones. The compiled system's
# `ODEProblem` — with its events, its mass matrix and its observed equations —
# is what `solve` integrates: it rides on the problem's right-hand side through
# the `_compiler_backend` seam (src/simulate.jl), because rebuilding one out of
# the right-hand side alone would drop all three.
#
# NOTE the deliberate difference from `esm_problem`'s own `_prepare_run_doc`:
# that path calls `_refuse_flat_events`, which is exactly the §5.39 refusal this
# compiler exists to lift, and it applies the tree-walk shape transforms
# (`algebraic_states_to_observeds`, `promote_downstream_shapes`) whose job
# `mtkcompile` does here. So the coercion below is its own, and the only ESM
# document rewrite it keeps is `lower_table_lookups` (esm-spec §9.5.3, the
# first transform inside any build).

const _MTK_SII = ModelingToolkit.SciMLBase.SymbolicIndexingInterface

# ---------------------------------------------------------------------------
# The compiled right-hand side
# ---------------------------------------------------------------------------

"""
    MTKCompiler

The `:mtk` build's right-hand side, and the carrier of everything the compiled
ModelingToolkit system owns that a bare `f!(du, u, p, t)` cannot express.

`<: Function` so it fits `EsmProblem.f!`; calling it evaluates the compiled
system's own `ODEFunction`, which is what makes `prob.f!(du, u, p, t)` mean the
same thing here as under `:native`. `EarthSciAST._compiler_backend` hands the
whole object back to the solve extension and to `observed_field`, which is how
the events, the mass matrix and the observed equations reach a run.

* `system` — the `mtkcompile`d `ModelingToolkit.System`.
* `prototype` — the `ODEProblem` built from it, with this document's parameter
  values already baked in and its events and mass matrix on it.
* `handles` — flattened ESM name → the symbolic object the COMPILED system
  carries for it (every unknown, observed and parameter it kept).
* `unknown_names` — the ESM name of each of the compiled system's unknowns, in
  state-vector order; `EsmProblem.var_map` is its inverse.
* `observed_names` — the ESM names the compiled system answers as OBSERVED.

**Solution indexing under this compiler is ModelingToolkit's own.** A solution
`solve` returns carries the COMPILED SYSTEM as its index provider, so it is read
with that system's symbols (`sol[sym]` for a `sym` out of `handles`, or the
sanitized `Symbol("Chem_A")`) — not with the flattened ESM spelling every other
compiler's `SymbolCache` answers. The ESM spelling reaches a caller through
`prob.var_map` (name → state-vector slot, which is what indexes `sol.u[i]`) and
through `observed_field`. Swapping the index provider for a translating one was
tried and does not work: ModelingToolkit's own initialization reads
`prob.f.sys` back as a `System` and fails on anything else.
"""
struct MTKCompiler{S,P} <: Function
    system::S
    prototype::P
    handles::Dict{String,Any}
    unknown_names::Vector{String}
    observed_names::Vector{String}
end

(f::MTKCompiler)(du, u, p, t) = f.prototype.f(du, u, p, t)
(f::MTKCompiler)(u, p, t) = f.prototype.f(u, p, t)

Base.show(io::IO, f::MTKCompiler) =
    print(io, "MTKCompiler(", length(f.unknown_names), " unknowns, ",
          length(f.observed_names), " observed)")

EarthSciAST._compiler_backend(f::MTKCompiler) = f

# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------
#
# `_refuse_rule` raises `compiler_refused_rule` for the compiler in force, in
# the one shape esm-libraries-spec §2.5.10 fixes and the compiler-agreement tier
# reads back: `compiler=:mtk refuses '<rule>': <reason>`. Every refusal here
# names a rule and says what to build with instead. None of them is a fallback:
# nothing in this file quietly builds a different program.

_mtk_refuse(rule, reason) = EarthSciAST._refuse_rule(rule, reason)

const _MTK_TRY_INSTEAD =
    "Build it with compiler=:native (the universally fast default), or with " *
    "compiler=:interpreter to check that build; `:mtk` is a specialty " *
    "compiler that runs only some documents"

# The keyword surface `esm_problem` accepts and this compiler cannot honour.
# Checked BEFORE the load, because the answer does not depend on the document
# and making the caller wait through a load to hear it is a worse diagnostic.
function _mtk_refuse_unsupported_inputs(; providers, const_arrays, param_arrays,
                                        pushdown_rewrite)
    if providers !== nothing && !isempty(providers)
        k = String(first(sort!([String(x) for x in keys(providers)])))
        _mtk_refuse(k,
            "it is a DATA-FED parameter — `providers` supplies its field through " *
            "the loader seam, and this compiler has none: a ModelingToolkit " *
            "`System` carries symbols and equations, so a loaded field would have " *
            "to be frozen into the system as a constant (a const provider) or " *
            "rewritten in a live buffer at a refresh cadence (a discrete one), " *
            "and neither has a lowering here. $_MTK_TRY_INSTEAD")
    end
    for (label, reg) in (("const_arrays", const_arrays), ("param_arrays", param_arrays))
        isempty(reg) && continue
        k = String(first(sort!([String(x) for x in keys(reg)])))
        _mtk_refuse(k,
            "it is supplied as $label data, and this compiler has no array-data " *
            "channel: the ModelingToolkit lowering resolves every name against " *
            "the flattened document's own variables, so an array handed in at " *
            "the call would never be read. $_MTK_TRY_INSTEAD")
    end
    pushdown_rewrite && _mtk_refuse("(the document)",
        "`pushdown_rewrite = true` asks for the projection-pushdown desugar, " *
        "whose whole purpose is to gate a PROVIDER's fetch to an invented index " *
        "set — and this compiler has no provider seam to gate. $_MTK_TRY_INSTEAD")
    return nothing
end

# Document-level constructs the ODE lowering cannot express. Each one is found
# by looking for it, never by catching a failure: a refusal that is really a
# swallowed bug would make this compiler look like it covers less than it does
# while hiding that something is broken.
function _mtk_refuse_unsupported_document(flat::FlattenedSystem)
    # A CONTINUOUS SPATIAL DIMENSION. `ModelingToolkit.System` is the ODE
    # constructor; a document with spatial independent variables is a PDE, which
    # needs `ModelingToolkit.PDESystem` plus a discretizer (MethodOfLines) that
    # this compiler does not run. A DISCRETIZED spatial document — one whose
    # stencil is already `arrayop` over an index set — has no spatial IV and
    # goes straight through. The predicate is `_has_spatial_ivs`, the one
    # `ModelingToolkit.System(flat)` enforces; the list is only for the message.
    if _has_spatial_ivs(flat)
        ivs = [String(iv) for iv in flat.independent_variables if iv != :t]
        _mtk_refuse(_mtk_first_rule_label(flat),
            "the document declares the continuous spatial independent variable" *
            (length(ivs) == 1 ? " " : "s ") * join(ivs, ", ") * ", so it is a PDE. " *
            "This compiler builds the ODE `ModelingToolkit.System`; a continuous " *
            "spatial dimension needs `ModelingToolkit.PDESystem` and a " *
            "discretization, which it does not run. Discretize the document (an " *
            "`arrayop` stencil over an index set), or hand the flattened system to " *
            "`ModelingToolkit.PDESystem` yourself. $_MTK_TRY_INSTEAD")
    end

    for eq in flat.equations
        # A GEOMETRY LEAF. `polygon_intersection_area` / `intersect_polygon` are
        # evaluated against loaded geometry at BUILD by the native setup pass;
        # they are not symbolic functions and have no ModelingToolkit lowering.
        geo = _mtk_find_op(eq.rhs, ("polygon_intersection_area", "intersect_polygon"))
        geo === nothing || _mtk_refuse(_mtk_equation_label(eq),
            "its right-hand side carries the geometry operator `$geo`, which is " *
            "resolved against loaded polygons at build time and has no symbolic " *
            "form a ModelingToolkit system can hold. $_MTK_TRY_INSTEAD")
        # `D(<expression>)`. esm-spec calls an equation whose LHS is a time
        # derivative of an EXPRESSION implicit, not a derivative (it credits no
        # state), and `mtkcompile` rejects it outright: "Differential(t)(a + b)
        # is present in the system but a + b is not an unknown". Named here so
        # the refusal says which equation and why, instead of surfacing MTK's
        # message about a symbol the document never wrote.
        lhs = eq.lhs
        if lhs isa OpExpr && lhs.op == "D" && length(lhs.args) == 1 &&
           !(lhs.args[1] isa VarExpr) &&
           !(lhs.args[1] isa OpExpr && (lhs.args[1]::OpExpr).op == "index")
            _mtk_refuse(_mtk_equation_label(eq),
                "its left-hand side is the time derivative of an EXPRESSION, not " *
                "of an unknown, so it credits no state. ModelingToolkit has no " *
                "unknown to differentiate and rejects the system; rewrite it as a " *
                "residual on the unknowns (an implicit equation, which this " *
                "compiler does run) or introduce the sum as its own unknown")
        end
    end
    return nothing
end

# The first argument's op name if any node in the tree is one of `ops`.
function _mtk_find_op(expr, ops)::Union{String,Nothing}
    expr isa OpExpr || return nothing
    expr.op in ops && return expr.op
    for a in expr.args
        hit = _mtk_find_op(a, ops)
        hit === nothing || return hit
    end
    if expr.expr_body !== nothing
        hit = _mtk_find_op(expr.expr_body, ops)
        hit === nothing || return hit
    end
    if expr.values !== nothing
        for v in expr.values
            hit = _mtk_find_op(v, ops)
            hit === nothing || return hit
        end
    end
    return nothing
end

# A rule label for one equation: the name it DEFINES, component-qualified the
# way the document spells it, which is the identity `CompilerRuleRecord.rule`
# carries under every other compiler.
function _mtk_equation_label(eq::Equation)
    lhs = eq.lhs
    if lhs isa VarExpr
        return lhs.name
    elseif lhs isa OpExpr
        op = lhs::OpExpr
        if op.op in ("D", "ic") && length(op.args) >= 1
            inner = op.args[1]
            inner isa VarExpr && return string(op.op, "(", inner.name, ")")
            inner isa OpExpr && (inner::OpExpr).op == "index" &&
                !isempty((inner::OpExpr).args) &&
                (inner::OpExpr).args[1] isa VarExpr &&
                return string(op.op, "(", ((inner::OpExpr).args[1]::VarExpr).name, ")")
        elseif op.op == "faq" && op.expr_body !== nothing
            return _mtk_equation_label(Equation(op.expr_body, eq.rhs))
        elseif op.op == "index" && !isempty(op.args) && op.args[1] isa VarExpr
            return (op.args[1]::VarExpr).name
        end
        return string(op.op, "(…)")
    end
    return "(unnamed equation)"
end

_mtk_first_rule_label(flat::FlattenedSystem) =
    isempty(flat.equations) ?
        (isempty(flat.state_variables) ? "(the document)" :
         String(first(keys(flat.state_variables)))) :
        _mtk_equation_label(flat.equations[1])

# ---------------------------------------------------------------------------
# Names: the flattened ESM spelling ⇄ the compiled system's symbols
# ---------------------------------------------------------------------------
#
# `_build_var_dict` sanitizes `Chem.A` to the Julia identifier `Chem_A`, because
# the `@variables` macro it goes through builds Julia AST and a dot is not an
# identifier character. Everything this compiler hands back to a caller — the
# problem's `var_map`, `compiler_report`, `observed_field`, a refusal's rule —
# is in the DOCUMENT'S spelling, so the two have to be mapped back, and the map
# is by NAME rather than by symbol identity: the symbols this file can see are
# the ones the compiled system kept, which carry metadata the ones originally
# built for the document do not.
#
# Two flattened names that sanitize to the SAME identifier (`a.b` and `a_b`)
# would make the map ambiguous, so that is a refusal rather than a coin flip.
function _mtk_name_reversal(flat::FlattenedSystem)
    rev = Dict{Symbol,String}()
    for reg in (flat.state_variables, flat.observed_variables, flat.parameters)
        for name in keys(reg)
            s = String(name)
            key = Symbol(replace(s, '.' => '_'))
            prior = get(rev, key, nothing)
            (prior === nothing || prior == s) || _mtk_refuse(s,
                "it and '$prior' both sanitize to the ModelingToolkit symbol " *
                "`$key` — a dot is not a Julia identifier character, so the " *
                "lowering replaces it with an underscore and the two names " *
                "collide. Rename one of them. $_MTK_TRY_INSTEAD")
            rev[key] = s
        end
    end
    return rev
end

# One compiled symbol's flattened ESM name, or `nothing` for a symbol the
# document did not declare (nothing this file builds produces one, but a
# ModelingToolkit pass may introduce its own and it must not be reported under
# a document name it does not have).
function _mtk_esm_name(sym, rev::Dict{Symbol,String})
    u = Symbolics.unwrap(sym)
    if SymUtils.iscall(u) && SymUtils.operation(u) === getindex
        args = SymUtils.arguments(u)
        base = _mtk_esm_name(args[1], rev)
        base === nothing && return nothing
        idx = Int[Int(Symbolics.value(a)) for a in args[2:end]]
        return EarthSciAST._cell_key(base, idx)
    end
    return get(rev, Symbol(ModelingToolkit.getname(u)), nothing)
end

# The ESM names of a compiled system's unknowns, in state-vector order, and the
# `var_map` that inverts them.
function _mtk_unknown_names(system, rev::Dict{Symbol,String})
    names = String[]
    var_map = Dict{String,Int}()
    for (i, u) in enumerate(ModelingToolkit.unknowns(system))
        nm = _mtk_esm_name(u, rev)
        nm === nothing && (nm = string(u))
        push!(names, nm)
        var_map[nm] = i
    end
    return names, var_map
end

# ---------------------------------------------------------------------------
# Initial conditions that are really GUESSES
# ---------------------------------------------------------------------------
#
# An ESM `ic(v) ~ value` rides into the ModelingToolkit system as `v`'s initial
# condition, which is right for a state the compiled system still integrates.
# For a state `mtkcompile` SOLVED AWAY — the whole point of an implicit equation
# — it is not: `2*s - 4 = 0` determines `s = 2`, and an initial condition of 1
# next to it is an over-determined initialization the solver reports as
# `ReturnCode.InitialFailure` rather than a value. In DAE terms the document's
# `ic` on an algebraically determined variable IS a guess: the number to start
# the consistent-initialization solve from, not a constraint on its answer.
#
# So: every initial condition whose variable is not an unknown of the COMPILED
# system moves to `guesses`, where the initialization uses it and the residual
# decides the value. A state the system still integrates keeps its initial
# condition untouched, which is every ordinary document.
function _mtk_ics_to_guesses!(system)
    ics = getfield(system, :initial_conditions)
    (ics isa AbstractDict && !isempty(ics)) || return String[]
    kept = Set{Any}(Symbolics.unwrap(u) for u in ModelingToolkit.unknowns(system))
    guesses = getfield(system, :guesses)
    moved = Any[]
    for (var, val) in collect(pairs(ics))
        Symbolics.unwrap(var) in kept && continue
        push!(moved, (var, val))
    end
    isempty(moved) && return String[]
    for (var, val) in moved
        delete!(ics, var)
        guesses isa AbstractDict && (guesses[var] = val)
    end
    return String[string(var) for (var, _) in moved]
end

# ---------------------------------------------------------------------------
# Parameter overrides
# ---------------------------------------------------------------------------
#
# `esm_problem`'s `p` binds parameters at BUILD under every compiler; here they
# are baked into the `ODEProblem`'s parameter object, which is also why this
# compiler classifies every parameter `:structural` (see `_mtk_param_classes`).
# Keys may be spelled locally (`k`) or namespaced (`Chem.k`), exactly as the
# native path spells them — the resolution is the SAME helper, so the two
# compilers cannot drift on which key names which parameter.
function _mtk_resolve_overrides(flat::FlattenedSystem, overrides::AbstractDict)
    isempty(overrides) && return Dict{String,Any}()
    names = Set{String}(String(k) for k in keys(flat.parameters))
    namespaces = EarthSciAST._override_namespaces(names)
    normalized, unknown, ambiguous, collisions =
        EarthSciAST._canonicalize_override_keys(Any, names, namespaces, overrides)
    isempty(collisions) || throw(SimulateError(
        EarthSciAST._override_collision_message(
            "esm_problem(...; compiler = :mtk, p)", "parameter",
            first(sort!(collect(collisions), by = first))...)))
    isempty(unknown) || throw(SimulateError(
        "esm_problem(...; compiler = :mtk, p): no parameter named " *
        join(("'" * k * "'" for k in sort(unknown)), ", ") *
        " in the flattened document (keys may be local or namespaced). Known: " *
        EarthSciAST._elide_names(sort(collect(names)))))
    isempty(ambiguous) || throw(SimulateError(
        "esm_problem(...; compiler = :mtk, p): ambiguous parameter key(s) " *
        join(("'" * k * "' (matches " * join(sort(v), ", ") * ")"
              for (k, v) in sort(collect(ambiguous), by = first)), "; ") *
        "; spell the namespaced name."))
    out = Dict{String,Any}()
    for (name, value) in normalized
        # An ARRAY-shaped parameter is a single scalar symbol in this lowering
        # (`_build_var_dict` builds every parameter with `@parameters`), so
        # inline array data has nowhere to land. Named rather than dropped.
        value isa AbstractArray && _mtk_refuse(name,
            "its override is INLINE ARRAY DATA (esm-spec §6.6.2), and this " *
            "compiler carries every parameter as one scalar ModelingToolkit " *
            "symbol, so the column has nowhere to land. $_MTK_TRY_INSTEAD")
        out[name] = value
    end
    return out
end

# Every declared parameter is `:structural` under this compiler, and the class
# is the truth about the build rather than a way of saying no: the value is read
# at BUILD, where `mtkcompile`'s alias elimination can see it, and it is baked
# into the compiled `ODEProblem`'s parameter object. `remake(prob; p = …)` swaps
# `EsmProblem.p`, which under `:mtk` is ModelingToolkit's own opaque parameter
# carrier and not a slot vector this package can address — so a changed
# parameter here is an explicit rebuild, which is exactly what `:structural`
# means and what its refusal tells the caller to do.
_mtk_param_classes(flat::FlattenedSystem) =
    Dict{String,Symbol}(String(k) => :structural for k in keys(flat.parameters))

# `param_map` is this package's "name => slot of `p`" reader, and ModelingToolkit's
# parameter object has no such slots. An empty map (rather than a `MethodError`
# several frames into `remake`) lets `remake_parameters` reach the class refusal
# above, which is the message a caller can act on.
EarthSciAST.param_map(::ModelingToolkit.MTKParameters) = Dict{String,Int}()

# ---------------------------------------------------------------------------
# The build
# ---------------------------------------------------------------------------

# The run system. Deliberately NOT `EarthSciAST._prepare_run_doc`: that path
# calls `_refuse_flat_events`, which is the §5.39 refusal this compiler exists
# to lift, and it runs the tree-walk shape transforms whose job `mtkcompile`
# does here. `lower_table_lookups` is kept — esm-spec §9.5.3 puts it at the
# first point inside ANY build, and a `table_lookup` that reached the symbolic
# lowering un-lowered would have no arm there.
function _mtk_run_system(input; metaparameters, base_path, renames_out)
    if input isa AbstractString
        isfile(input) ||
            throw(SimulateError("esm_problem: no such file '$input'"))
        input = EarthSciAST.load_path(input; metaparameters = metaparameters)
    end
    input isa AbstractDict && (input = EarthSciAST.load_document(
        input; base_path = base_path, metaparameters = metaparameters))
    coordinates = nothing
    solver_block = nothing
    if input isa EarthSciAST.EsmFile
        coordinates = input.coordinates
        solver_block = input.solver
        input = flatten(input)
    end
    input isa FlattenedSystem || throw(SimulateError(
        "esm_problem: unsupported input of type $(typeof(input)); pass a path, " *
        "EsmFile, FlattenedSystem, or native ESM Dict"))
    flat = EarthSciAST.lower_table_lookups(input)
    merge!(renames_out, flat.metadata.merged_variable_renames)
    # The run DOCUMENT is metadata only: output naming / CF coordinates, the
    # §2.2 `solver` block, the equation count `show` prints, and the component
    # set `observed_field`'s bare-name rule reads. The SYSTEM is what is built.
    doc = EarthSciAST.flattened_to_esm(flat)
    coordinates === nothing || isempty(coordinates) ||
        (doc["coordinates"] = coordinates)
    if solver_block !== nothing
        block = EarthSciAST.serialize_solver(solver_block)
        isempty(block) || (doc["solver"] = block)
    end
    return flat, doc
end

# The per-rule record (API_SPEC §5.8). Under `:native` a tier names which arm of
# the cascade took a rule; there is no cascade here, so a tier names WHAT
# `mtkcompile` DID WITH IT — which is the system-level decision a caller of this
# compiler wants back, above all the one `:native` and `:interpreter` can never
# report: an algebraic variable ELIMINATED into an observed equation.
#
#   :mtk_differential   an unknown of the compiled system with a `D(v) ~ …`
#   :mtk_algebraic      an unknown of the compiled system left in a residual —
#                       a mass-matrix DAE row, which is what an implicit
#                       equation becomes when tearing cannot solve it away
#   :mtk_eliminated     solved away by structural simplification; its value is
#                       an observed equation of the compiled system
#   :mtk_observed       an ESM observed the compiled system answers as observed
#   :mtk_continuous_event / :mtk_discrete_event   lowered to a callback
function _mtk_report(flat::FlattenedSystem, system, rev::Dict{Symbol,String})
    rules = EarthSciAST.CompilerRuleRecord[]
    tally = Dict{Symbol,Int}()
    bump!(k) = (tally[k] = get(tally, k, 0) + 1)

    kept = Dict{String,Bool}()          # ESM name => is it a compiled unknown
    for u in ModelingToolkit.unknowns(system)
        nm = _mtk_esm_name(u, rev)
        nm === nothing || (kept[nm] = true)
    end
    differential = Set{String}()
    for eq in ModelingToolkit.equations(system)
        lhs = Symbolics.unwrap(eq.lhs)
        SymUtils.iscall(lhs) || continue
        SymUtils.operation(lhs) isa Symbolics.Differential || continue
        nm = _mtk_esm_name(SymUtils.arguments(lhs)[1], rev)
        nm === nothing || push!(differential, nm)
    end
    observed_names = String[]
    for oe in ModelingToolkit.observed(system)
        nm = _mtk_esm_name(oe.lhs, rev)
        nm === nothing || push!(observed_names, nm)
    end
    observed_set = Set{String}(observed_names)

    # One record per DECLARED name, at the granularity the document writes:
    # a scalar name once, an array name once per cell (its cells can land
    # differently — a Dirichlet boundary cell is eliminated where an interior
    # one is integrated).
    _cells(name) = begin
        hits = [k for k in keys(kept) if _mtk_cell_of(k) == name]
        append!(hits, [k for k in observed_set if _mtk_cell_of(k) == name])
        sort!(unique!(hits))
    end
    for name in keys(flat.state_variables)
        targets = haskey(kept, name) || name in observed_set ? [name] : _cells(name)
        isempty(targets) && (targets = [name])
        for nm in targets
            tier = get(kept, nm, false) ?
                   (nm in differential ? :mtk_differential : :mtk_algebraic) :
                   (nm in observed_set ? :mtk_eliminated : :mtk_dropped)
            bump!(tier)
            push!(rules, EarthSciAST.CompilerRuleRecord(nm, :equation, tier,
                                                        Pair{Symbol,Symbol}[]))
        end
    end
    for name in keys(flat.observed_variables)
        haskey(flat.state_variables, name) && continue
        targets = name in observed_set ? [name] : _cells(name)
        isempty(targets) && (targets = [name])
        for nm in targets
            tier = nm in observed_set ? :mtk_observed :
                   get(kept, nm, false) ? :mtk_differential : :mtk_dropped
            bump!(tier)
            push!(rules, EarthSciAST.CompilerRuleRecord(nm, :observed, tier,
                                                        Pair{Symbol,Symbol}[]))
        end
    end
    for (i, ev) in enumerate(flat.continuous_events)
        bump!(:mtk_continuous_event)
        push!(rules, EarthSciAST.CompilerRuleRecord(
            _mtk_event_label("continuous_events", ev, i), :event,
            :mtk_continuous_event, Pair{Symbol,Symbol}[]))
    end
    for (i, ev) in enumerate(flat.discrete_events)
        bump!(:mtk_discrete_event)
        push!(rules, EarthSciAST.CompilerRuleRecord(
            _mtk_event_label("discrete_events", ev, i), :event,
            :mtk_discrete_event, Pair{Symbol,Symbol}[]))
    end
    tally[:mtk_unknowns] = length(ModelingToolkit.unknowns(system))
    tally[:mtk_observed_equations] = length(ModelingToolkit.observed(system))
    tally[:mtk_equations] = length(ModelingToolkit.equations(system))
    return EarthSciAST.CompilerReport(:mtk, rules, tally)
end

# `"M.u[3]"` → `"M.u"`; a scalar name is its own stem.
function _mtk_cell_of(key::AbstractString)
    parsed = EarthSciAST._parse_cell_key(String(key))
    return parsed === nothing ? String(key) : parsed[1]
end

function _mtk_event_label(kind::AbstractString, ev, i::Int)
    nm = hasproperty(ev, :name) ? getproperty(ev, :name) : nothing
    return string(kind, "[", nm === nothing || isempty(String(nm)) ?
                  string(i) : String(nm), "]")
end

"""
    EarthSciAST._mtk_problem(input, span; kwargs...) -> EsmProblem

`esm_problem(input, tspan; compiler = :mtk, …)`. See the file header for what
this compiler is for and what it refuses.
"""
function EarthSciAST._mtk_problem(input, span::Tuple{Float64,Float64};
                                  p::AbstractDict,
                                  u0,
                                  providers,
                                  model_name,
                                  metaparameters::AbstractDict,
                                  base_path::AbstractString,
                                  sample_time::Float64,
                                  const_arrays::AbstractDict,
                                  param_arrays::AbstractDict,
                                  inspect,
                                  materialize_out,
                                  pushdown_rewrite::Bool,
                                  seed_ic!,
                                  sinks,
                                  snapshot,
                                  pre_write,
                                  checkpoint_predicates,
                                  checkpoint_sinks,
                                  terminate_on_checkpoint::Bool)
    # Every refusal below goes through `_refuse_rule`, which names the compiler
    # in force — so the whole build runs under the `:mtk` plan.
    return EarthSciAST._with_compiler_plan(EarthSciAST._plan_for(:mtk)) do
        _mtk_problem_impl(input, span; p, u0, providers, model_name,
                          metaparameters, base_path, sample_time, const_arrays,
                          param_arrays, inspect, materialize_out,
                          pushdown_rewrite, seed_ic!, sinks, snapshot,
                          pre_write, checkpoint_predicates, checkpoint_sinks,
                          terminate_on_checkpoint)
    end
end

function _mtk_problem_impl(input, span::Tuple{Float64,Float64};
                           p, u0, providers, model_name, metaparameters,
                           base_path, sample_time, const_arrays, param_arrays,
                           inspect, materialize_out, pushdown_rewrite, seed_ic!,
                           sinks, snapshot, pre_write, checkpoint_predicates,
                           checkpoint_sinks, terminate_on_checkpoint)
    _mtk_refuse_unsupported_inputs(; providers = providers,
                                   const_arrays = const_arrays,
                                   param_arrays = param_arrays,
                                   pushdown_rewrite = pushdown_rewrite)

    merged_renames = EarthSciAST.OrderedDict{String,String}()
    flat, doc = _mtk_run_system(input; metaparameters = metaparameters,
                                base_path = base_path,
                                renames_out = merged_renames)
    _mtk_refuse_unsupported_document(flat)

    overrides = EarthSciAST._resolve_merged_renames(
        merged_renames,
        Dict{String,Any}(String(k) => EarthSciAST._coerce_inline_value(v)
                         for (k, v) in p))
    u0 = u0 === nothing || isempty(merged_renames) ? u0 :
         (u0 isa AbstractDict ?
          EarthSciAST._resolve_merged_renames(merged_renames, u0) : u0)

    rev = _mtk_name_reversal(flat)
    resolved = _mtk_resolve_overrides(flat, overrides)

    # ESM → ModelingToolkit, then the structural compile. `mtkcompile` is what
    # the installed ModelingToolkit spells this; older versions called it
    # `structural_simplify`, and both names are tried so the compiler tracks the
    # package rather than one release of it.
    # `model_name` names the SYSTEM here. `flatten` has already merged the
    # document into ONE system by the time this compiler sees it, so there is no
    # model left to select; the keyword survives as the compiled system's name,
    # which is what ModelingToolkit's own printing shows.
    name = model_name === nothing ? :esm : Symbol(String(model_name))
    system = ModelingToolkit.System(flat; name = name)
    system = _mtk_compile(system)

    # An `ic` on a variable the compile solved away is a GUESS, not a
    # constraint (see `_mtk_ics_to_guesses!`).
    _mtk_ics_to_guesses!(system)

    # The parameter overrides bind here: `op` is ModelingToolkit's merged
    # initial-value / parameter map, so a value named in `p` is what the
    # compiled problem — and every `ic` expression that reads it — sees.
    op = Dict{Any,Any}()
    handles = _mtk_handles(system, rev)
    for (pname, value) in resolved
        sym = get(handles, pname, nothing)
        sym === nothing && _mtk_refuse(pname,
            "it is a declared parameter of the document, but the compiled " *
            "ModelingToolkit system no longer carries it — structural " *
            "simplification folded it away, so an override could not reach the " *
            "right-hand side. $_MTK_TRY_INSTEAD")
        op[sym] = value
    end
    prototype = ModelingToolkit.SciMLBase.ODEProblem(system, op, span)

    unknown_names, var_map = _mtk_unknown_names(system, rev)
    observed_names = String[]
    for oe in ModelingToolkit.observed(system)
        nm = _mtk_esm_name(oe.lhs, rev)
        nm === nothing || push!(observed_names, nm)
    end

    f! = MTKCompiler(system, prototype, handles, unknown_names, observed_names)

    u0_built = prototype.u0 === nothing ? Float64[] :
               Vector{Float64}(prototype.u0)
    u0_run = EarthSciAST._seed_u0(u0_built, var_map, u0, seed_ic!)

    insp = inspect === nothing ? EarthSciAST.BuildInspection() : inspect
    report = _mtk_report(flat, system, rev)
    insp.compiler_report = report
    merge!(insp.params, Dict{String,Float64}(
        k => Float64(v) for (k, v) in resolved if v isa Real))
    param_classes = _mtk_param_classes(flat)
    merge!(insp.param_classes, param_classes)

    # The problem's own callbacks (§2.5.4). There are no PROVIDER refresh
    # callbacks on this path — a data-fed document is refused above — so the set
    # is the streaming-output one: an output-sink callback and a checkpoint
    # callback, each a solve-time callback that DiffEq composes with the
    # compiled system's own event callbacks rather than replacing them.
    cbs = Any[]
    tstops = Float64[]
    sink_vec = collect(Any, sinks)
    save_everystep = true
    if !isempty(sink_vec)
        out_cb, out_tstops = EarthSciAST.build_output_callback(;
            sinks = sink_vec, snapshot = snapshot, pre_write = pre_write)
        tstops = EarthSciAST._union_tstops(tstops, out_tstops)
        push!(cbs, out_cb)
        save_everystep = false
    end
    ck_vec = checkpoint_sinks === nothing ? sink_vec :
             collect(Any, checkpoint_sinks)
    if !isempty(collect(Any, checkpoint_predicates))
        push!(cbs, EarthSciAST.build_checkpoint_callback(;
            sinks = ck_vec, predicates = checkpoint_predicates,
            snapshot = snapshot, pre_write = pre_write,
            terminate_on_fire = terminate_on_checkpoint))
        save_everystep = false
    end

    dm = materialize_out === nothing ? EarthSciAST.DiscreteMaterializer() :
         materialize_out
    return EarthSciAST.EsmProblem(
        f!, u0_run, span, prototype.p, var_map, Dict{String,Any}(),
        Dict{String,Any}(), dm, EarthSciAST._doc_equation_count(doc),
        Ref(sample_time), Ref(false), EarthSciAST.derive_output_meta(doc), doc,
        Ref{Any}(nothing), param_classes, insp,
        EarthSciAST._compose_callbacks(cbs), tstops, save_everystep,
        sink_vec, EarthSciAST._distinct_sinks(sink_vec, ck_vec),
        Ref{Any}(nothing), merged_renames)
end

# The structural compile, under whichever name the installed ModelingToolkit
# gives it. `mtkcompile` is the current one; `structural_simplify` was it
# through v9 and is still what a good deal of downstream code says.
function _mtk_compile(system)
    if isdefined(ModelingToolkit, :mtkcompile)
        return getfield(ModelingToolkit, :mtkcompile)(system)
    elseif isdefined(ModelingToolkit, :structural_simplify)
        return getfield(ModelingToolkit, :structural_simplify)(system)
    end
    throw(SimulateError(
        "compiler=:mtk needs a structural compile, and the loaded " *
        "ModelingToolkit ($(pkgversion(ModelingToolkit))) exports neither " *
        "`mtkcompile` nor `structural_simplify`",
        EarthSciAST.ERROR_CODES.COMPILER_UNAVAILABLE))
end

# Flattened ESM name → the symbol the COMPILED system carries for it, for every
# unknown, observed and parameter it kept.
function _mtk_handles(system, rev::Dict{Symbol,String})
    handles = Dict{String,Any}()
    for u in ModelingToolkit.unknowns(system)
        nm = _mtk_esm_name(u, rev)
        nm === nothing || (handles[nm] = u)
    end
    for oe in ModelingToolkit.observed(system)
        nm = _mtk_esm_name(oe.lhs, rev)
        nm === nothing || (handles[nm] = oe.lhs)
    end
    for pr in ModelingToolkit.parameters(system)
        nm = _mtk_esm_name(pr, rev)
        nm === nothing || (handles[nm] = pr)
    end
    return handles
end

# ---------------------------------------------------------------------------
# The run: the compiled system's own ODEProblem
# ---------------------------------------------------------------------------
#
# What `solve(prob, alg; …)` integrates. The prototype is remade rather than
# rebuilt so the events, the mass matrix, the observed function and the
# initialization data the compile produced ride into every run; `u0` and
# `tspan` are the only two things a run varies, and `u0` is the problem's
# SEEDED vector (the document's initial conditions, then the caller's), in the
# compiled system's own unknown order because `var_map` was built from it.
function EarthSciAST._backend_ode_problem(b::MTKCompiler, prob, tspan)
    b.prototype.u0 === nothing &&
        return ModelingToolkit.SciMLBase.remake(b.prototype; tspan = tspan)
    return ModelingToolkit.SciMLBase.remake(b.prototype;
                                            u0 = copy(prob.u0), tspan = tspan)
end

# ---------------------------------------------------------------------------
# `observed_field` out of the compiled system's observed equations
# ---------------------------------------------------------------------------
#
# The §5.8 resolution rule, unchanged: an EXACT flattened name, or a BARE name
# on a document with exactly one component. What differs is where the value
# comes from — this package's build-time observed graph knows nothing about a
# ModelingToolkit build, so the answer is the compiled system's own observed
# equation, evaluated through its generated observed function.
#
# STATE-FREE only, which is the same contract `:native` answers under: an
# observed whose value depends on an unknown is not a build-time field, and
# reporting its value at the seeded state would be a number the name does not
# mean. The check is symbolic (the equation's variables against the compiled
# unknowns), so it does not depend on what u0 happens to hold.
function EarthSciAST._backend_observed_field(b::MTKCompiler, prob,
                                             name::AbstractString)
    want = get(prob.merged_renames, String(name), String(name))
    target = _mtk_resolve_field_name(b, prob, want, String(name))
    cells = target isa AbstractVector ? target : [target]
    # The state set and the observed definitions are properties of the SYSTEM,
    # so they are built once for the whole read rather than once per cell — a
    # shaped field is thousands of cells on a real document.
    unknown_set = Set{Any}(Symbolics.unwrap(u)
                           for u in ModelingToolkit.unknowns(b.system))
    defs = Dict{Any,Any}()
    for oe in ModelingToolkit.observed(b.system)
        defs[Symbolics.unwrap(oe.lhs)] = oe.rhs
    end
    syms = Any[]
    for nm in cells
        sym = get(b.handles, nm, nothing)
        sym === nothing && throw(SimulateError(
            "observed_field: '$name' resolved to '$nm', which the compiled " *
            "ModelingToolkit system does not carry"))
        dep = _mtk_state_dependency(sym, unknown_set, defs)
        dep === nothing || throw(SimulateError(
            "observed_field: '$name' is not a BUILD-TIME field — the compiled " *
            "system's observed equation for it depends on the state '$dep', so " *
            "its value is a function of the trajectory. Read it off a solution " *
            "instead"))
        push!(syms, sym)
    end
    # ONE generated observed function for the whole field, never one per cell.
    # esm-libraries-spec §2.5.10 puts every evaluation a compiler performs for
    # the problem under the same rule as the right-hand side, and a build that
    # GENERATED A FUNCTION per output cell is the thing that rule exists to
    # refuse; SymbolicIndexingInterface takes a vector of symbols and returns
    # one function that answers the whole row.
    vals = _MTK_SII.observed(b.system, syms)(prob.u0, prob.p, prob.tspan[1])
    return Float64[Float64(v) for v in vals]
end

# The name(s) to read: one for a scalar observed, the row-major cell list for a
# shaped one. Raises the same `SimulateError` the native reader raises for a
# name that is not a build-time-evaluable observed of this document.
function _mtk_resolve_field_name(b::MTKCompiler, prob, want::String,
                                 spelled::String)
    isobs(nm) = nm in b.observed_names
    # CELLS FIRST. An array-valued observed is answered as BOTH the whole array
    # (its defining equation's left-hand side is the `Symbolics.Arr`) and its
    # scalarized elements, so the bare stem is in `observed_names` too — and
    # reading THAT gives one value of array type where the caller asked for the
    # field. The cells are the field; the stem only names it.
    cells = _mtk_field_cells(b, want)
    isempty(cells) || return cells
    isobs(want) && return want

    if !occursin('.', want)
        # BARE name (§5.8): only on a single-component document, and the
        # candidates are named when it is refused.
        comps = Set{String}()
        for nm in b.observed_names
            stem = _mtk_cell_of(nm)
            push!(comps, occursin('.', stem) ?
                  String(rsplit(stem, '.'; limit = 2)[1]) : "")
        end
        cands = sort!(unique!(String[_mtk_cell_of(nm) for nm in b.observed_names
                                     if occursin('.', _mtk_cell_of(nm)) &&
                                        String(rsplit(_mtk_cell_of(nm), '.';
                                                      limit = 2)[2]) == want]))
        if length(comps) == 1 && !isempty(cands)
            qualified = first(cands)
            cells = _mtk_field_cells(b, qualified)
            isempty(cells) || return cells
            isobs(qualified) && return qualified
        elseif length(comps) > 1 && !isempty(cands)
            throw(SimulateError(
                "observed_field: '$spelled' is a bare name and this problem has " *
                "$(length(comps)) components ($(join(sort!(collect(comps)), ", "))); " *
                "qualify it as one of: $(join(cands, ", "))"))
        end
    end
    throw(SimulateError(
        "observed_field: '$spelled' is not a build-time-evaluable observed of " *
        "the prepared document. compiler=:mtk answers out of the compiled " *
        "ModelingToolkit system's OBSERVED equations; this name is not one of " *
        "them (a state the system integrates is read off the solution, not here)"))
end

# `"M.f"` → its cells in ROW-MAJOR order, which is the flattening
# `observed_field` returns at every rank and the order the Python `np.ndindex`
# and the Rust enumeration agree on.
function _mtk_field_cells(b::MTKCompiler, stem::String)
    hits = Tuple{Vector{Int},String}[]
    for nm in b.observed_names
        parsed = EarthSciAST._parse_cell_key(nm)
        parsed === nothing && continue
        parsed[1] == stem || continue
        push!(hits, (parsed[2], nm))
    end
    sort!(hits; by = first)          # row-major: last index varies fastest
    return String[nm for (_, nm) in hits]
end

# STATE DEPENDENCE, symbolically: the name of an unknown the observed equation
# for `sym` reaches, or `nothing` when it reaches none. Walks
# observed-into-observed, so a chain that ends at a state is caught at any
# depth; the visited set makes a cyclic registry terminate rather than recur
# (`mtkcompile` does not produce one, but this must not be the thing that hangs
# if it ever did). Symbolic rather than numeric, so the answer does not depend
# on what `u0` happens to hold.
function _mtk_state_dependency(sym, unknown_set::Set{Any}, defs::Dict{Any,Any})
    seen = Set{Any}()
    stack = Any[Symbolics.unwrap(sym)]
    while !isempty(stack)
        cur = pop!(stack)
        cur in seen && continue
        push!(seen, cur)
        rhs = get(defs, cur, nothing)
        rhs === nothing && continue
        for v in Symbolics.get_variables(rhs)
            uv = Symbolics.unwrap(v)
            uv in unknown_set && return string(uv)
            # An ARRAY unknown is scalarized: its element is the unknown, and a
            # read of the whole array names the base, so test both.
            if SymUtils.iscall(uv) && SymUtils.operation(uv) === getindex
                any(x -> isequal(x, uv), unknown_set) && return string(uv)
            end
            uv in seen || push!(stack, uv)
        end
    end
    return nothing
end
