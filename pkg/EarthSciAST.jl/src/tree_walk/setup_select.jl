# tree_walk/setup_select.jl — which array observeds are build-time constants
# materialized at setup, and in what order: the setup reductions' predicates and
# the selection over the definition graph.

# A join-gated array `faq` whose body is itself a reduction over a nested
# `faq` (`A_ij[i,j] = overlap_area_planar(src, i, 4, tgt, j, 4)` expanded from
# lib/geometry.esm: per candidate pair, a sum over edges of min/max folds over
# the other ring's half-planes) is, over const inputs, a build-once setup
# array: it takes the compiled setup sweep (`_materialize_geom_array`) and its readers gather
# a const array per cell instead of an `index(faq, …)` of a gated reduction the
# right-hand-side tiers cannot fold. The body must speak only the setup
# language (`_GEO_EVAL_OPS`). Without a join the same holds for a body whose
# reductions nest two deep (the templates' sum over edges of min/max folds
# over the other ring's half-planes): unrolled into a right-hand-side kernel
# that body is tens of thousands of nodes per cell, while the setup sweep
# loops over it. A gated faq whose body has no nested reduction (a right-hand
# side's `Σ_i W[i,j]·F[i]`), or an ungated one whose reductions nest only one
# deep, is not matched.
function _is_setup_join_reduction(e)
    (e isa OpExpr && _is_faq_op(e.op) && e.expr_body isa OpExpr) || return false
    (e.output_idx !== nothing && !isempty(e.output_idx)) || return false
    _body_needs_general_eval(e) && return false
    gated = e.join !== nothing || e.join_gates !== nothing
    # Ungated, the rule is about a body unrolled per cell; a template call's
    # body is compiled once, so its own nesting does not count there.
    depth = _faq_nesting(e.expr_body::OpExpr, IdDict{OpExpr, Int}(); calls = gated)
    # Ungated, a dense range the setup sweep has no loop for (not starting at
    # 1) leaves the faq to the right-hand-side tiers. Gated, no tier takes it,
    # so it stays a setup var and the sweep refuses it by name.
    gated || _setup_ranges_ok(e, nothing, IdDict{OpExpr, Nothing}()) || return false
    return gated ? depth >= 1 : depth >= 2
end
# How deep `faq` reductions nest inside `e` (0: none).
function _faq_nesting(e::OpExpr, memo::IdDict{OpExpr, Int}; calls::Bool = true)
    got = get(memo, e, nothing)
    got === nothing || return got
    d = 0
    for a in _operands(e)
        a isa OpExpr && (d = max(d, _faq_nesting(a, memo; calls = calls)))
    end
    e.expr_body isa OpExpr && (d = max(d, _faq_nesting(e.expr_body::OpExpr, memo; calls = calls)))
    # A template call nests what its body nests (call.jl).
    calls && _tpl_is_call(e) && (d = max(d, _call_body_measure(_faq_nesting, e, :faq_nesting)))
    _is_faq_op(e.op) && (d += 1)
    return memo[e] = d
end
_model_has_setup_join_reduction(equations) =
    _anyof(eq -> eq.lhs isa VarExpr && _is_setup_join_reduction(eq.rhs), equations)

# An ungated array `faq` whose body holds a nested reduction over build
# constants (a `rank_of_set` lookup's count, an `argmin` template's min and
# index search, any reduction the observed's cells cannot change) is, over
# inputs that read no state, no time and no scalar parameter, a build-once
# table: the setup sweep fills it once and its readers gather it (an indicator sum in it is a
# binary search, `_geo_count_node`). Every range of it and of its nested
# reductions must be one the sweep loops over: a dense `[1, n]` range or an
# interval or derived index set (`_setup_range_ok`; without the registry, any
# index set). Under a plan without the
# construction-time compiled forms (the interpreter) it stays an observed.
function _is_setup_const_reduction(e, index_sets, scalar_params)
    (e isa OpExpr && _is_faq_op(e.op) && e.expr_body isa OpExpr) || return false
    (e.join === nothing && e.join_gates === nothing) || return false
    (e.output_idx !== nothing && !isempty(e.output_idx)) || return false
    _setup_compile_once_enabled() || return false
    _body_needs_general_eval(e) && return false
    _faq_nesting(e.expr_body::OpExpr, IdDict{OpExpr, Int}()) >= 1 || return false
    _anyof(n -> n in scalar_params, _referenced_var_names(e)) && return false
    return _setup_ranges_ok(e, index_sets, IdDict{OpExpr, Nothing}())
end
function _setup_ranges_ok(e::OpExpr, index_sets, seen::IdDict{OpExpr, Nothing})
    haskey(seen, e) && return true
    seen[e] = nothing
    if _is_faq_op(e.op) && e.ranges !== nothing
        _allof(r -> _setup_range_ok(r, index_sets), collect(values(e.ranges))) || return false
    end
    _allof(a -> !(a isa OpExpr) || _setup_ranges_ok(a, index_sets, seen), _operands(e)) || return false
    # A template call loops over its body's ranges (call.jl).
    if _tpl_is_call(e)
        b = _call_inst_body(e)
        b isa OpExpr && !_setup_ranges_ok(b, index_sets, seen) && return false
    end
    for c in (e.expr_body, e.filter)
        c isa OpExpr && !_setup_ranges_ok(c, index_sets, seen) && return false
    end
    return true
end
function _setup_range_ok(r, index_sets)
    r isa AbstractVector && return length(r) == 2 && r[1] isa Integer && r[1] == 1 && r[2] isa Integer
    (r isa IndexSetRef && isempty(r.of)) || return false
    index_sets === nothing && return true
    s = get(index_sets, r.from, nothing)
    return s isa IndexSet && (s.kind == "interval" || (s.kind == "derived" && s.from_faq !== nothing))
end

function _model_has_setup_const_reduction(
        model::Model, g::_DefGraph, index_sets, state_var_names::Set{String}
    )
    sp = Set{String}(
        n for (n, v) in model.variables if v.type == ParameterVariable && !_is_array_shape(v.shape)
    )
    dynamic = _dynamic_names(g, state_var_names)
    return _anyof(
        n -> !(n in dynamic) && _is_setup_const_reduction(g.defs[n], index_sets, sp),
        collect(keys(g.defs))
    )
end

# The defined names that read a state or `t`, directly or through other
# definitions: never a build-once table.
function _dynamic_names(g::_DefGraph, state_var_names::Set{String})
    seeds = copy(state_var_names)
    push!(seeds, "t")
    return _readers_of(g, seeds)
end

# Build-once ARRAY observeds to materialize at setup: the gated / nested
# reductions (`_is_setup_join_reduction`, `_is_setup_const_reduction`) over
# inputs that read no state, plus the closure of array observeds that depend on
# them WITHOUT touching a state variable. Returns the set, the name → RHS map and
# the live-tainted names.
function _geometry_setup_vars(
        model::Model, g::_DefGraph, state_var_names::Set{String},
        live_params::Set{String}; index_sets = nothing
    )
    scalar_params = Set{String}(
        n for (n, v) in model.variables
            if v.type == ParameterVariable && !_is_array_shape(v.shape)
    )
    defs = g.defs
    refs_of(n) = g.reads[n]
    observed_here = Set{String}(observed_unknowns(model))
    is_arr_obs(n) = haskey(model.variables, n) && n in observed_here &&
        _is_array_shape(model.variables[n].shape)
    # Live taint: a var whose defining expression (transitively)
    # reads a `param_arrays` buffer is a LIVE-FIELD observed — its value changes
    # each refresh, so it CANNOT be a build-once setup const. `F_tgt = A_ij ⊗
    # F_src / A_j` mixes setup-const weights (A_ij/A_j) with a live field (F_src):
    # the weights materialize at setup, but F_tgt itself must stay a runtime
    # observed (inlined into its readers below), never pulled into setup where
    # F_src is unbound.
    tainted = _readers_of(g, live_params)
    dynamic = _dynamic_names(g, state_var_names)
    setup = Set{String}()
    for (n, _) in defs
        (is_arr_obs(n) && !(n in tainted) && haskey(defs, n)) || continue
        # A recurrence (esm-spec §4.3.1.1) reads its own earlier cells, so it is
        # materialized by its ordered sweep, never by a setup-time evaluation.
        n in refs_of(n) && continue
        # The pure-AST overlap area, or a rank table, over inputs that read no state.
        _is_setup_join_reduction(defs[n]) &&
            !_anyof(f -> f in state_var_names, refs_of(n)) &&
            push!(setup, n)
        _is_setup_const_reduction(defs[n], index_sets, scalar_params) && !(n in dynamic) &&
            push!(setup, n)
    end
    mvars = Set{String}(keys(model.variables))
    # An array observed is build-once-SETUP-materializable only if it does NOT read a
    # COMPUTED SCALAR OBSERVED — a scalar-shaped observed carrying a defining equation
    # (in `defs`). The setup-time evaluator resolves const arrays, parameters,
    # const-op / loader-field / bin-buffer observeds (all seeded into the setup env)
    # and other setup arrays, but it cannot evaluate an arbitrary scalar-observed
    # equation. So an observed that mixes a build-once spatial field with such a
    # scalar — the Rothermel slope factor `phi_s = phi_s_coeff · tan_phi²` reads the
    # computed scalar `phi_s_coeff` — must stay in the ODE RHS, where it GATHERS the
    # build-once const array (`index(TerrainRegrid.dzdx, …)`, registered by the
    # geometry setup) per cell and reads the scalar through the normal
    # observed-substitution path. A reference to an ARRAY observed (e.g. the
    # value-invention bin buffers `src_bin`/`tgt_bin` a broad-phase `join` gates on,
    # pulled into setup by the backward pass below) does NOT block, so pure-geometry
    # regrid chains are unaffected — byte-identical.
    _is_scalar_computed_obs(f) =
        haskey(model.variables, f) && f in observed_here &&
        !_is_array_shape(model.variables[f].shape) && haskey(defs, f)
    # The exclusion is TRANSITIVE. An array observed that reads a computed scalar
    # observed is setup-ineligible (above); so is one that GATHERS an ineligible
    # array observed — `R0 = f(index(IR,…))` cannot materialize at setup when `IR`
    # (which reads the scalar Rothermel constant `eta_s`) is itself rejected, since
    # `IR` is never in the setup env. A DIRECT-refs-only check lets `R0` slip in (its
    # own refs carry no scalar observed) and materialize with a dangling `IR` gather.
    # Propagate the block through the array-observed graph so the whole tainted cone
    # (IR, R0, R, …) stays together in the ODE-RHS array-inline path — never a split.
    # A no-op (byte-identical) for a pure-geometry regrid: nothing there reads a
    # computed scalar observed, so the block set is empty and setup is unchanged.
    blocked = Set{String}()
    _saturate!() do   # SCALAR-OBSERVED BLOCK pass: transitive setup-ineligibility
        changed = false
        for (n, rhs) in defs
            (is_arr_obs(n) && !(n in blocked)) || continue
            refs = intersect(refs_of(n), mvars)
            if _anyof(_is_scalar_computed_obs, refs) || _anyof(f -> f in blocked, refs)
                push!(blocked, n); changed = true
            end
        end
        changed
    end
    _saturate!() do   # SETUP-FORWARD pass: state-free dependents of setup vars
        changed = false
        for (n, rhs) in defs
            (
                is_arr_obs(n) && !(n in setup) &&
                    !(n in tainted) && !(n in blocked) && !(n in refs_of(n))
            ) || continue
            refs = intersect(refs_of(n), mvars)
            if any(f -> f in setup, refs) &&
                    !any(f -> f in state_var_names, refs)
                push!(setup, n); changed = true
            end
        end
        changed
    end
    # Backward pass: also materialize state-free array observeds REFERENCED BY a
    # setup var — the bin buffers a broad-phase `join` gates on (src_bin/tgt_bin),
    # which a setup aggregate reads but which are not themselves geometry-derived.
    # A `const`-op operand (an in-file `src_poly` / `tgt_poly` ring stack an
    # overlap-area template gathers per cell) is NOT pulled in here: it is build-time literal data
    # seeded into the setup env directly (and registered as a const_array for the
    # ODE), so it needs no `_materialize_geom_array` pass. A BARE-ALIAS observed
    # (`src_poly := mesh.src_poly`, a `VarExpr` def — the MPAS keyed-factor
    # re-exposure, esm-spec §4.6) is likewise NOT pulled in: it resolves to
    # build-time literal data under a second name, is registered as a const array by
    # the bare-alias pass, and is seeded into the setup env directly. Pulling it in
    # would hand `_materialize_geom_array` a bare `VarExpr` (no `output_idx` field)
    # and crash — a setup var reads the alias's value from `env`, it is not itself a
    # materialised aggregate.
    _saturate!() do   # SETUP-BACKWARD pass: state-free array observeds READ BY setup vars
        changed = false
        for n in collect(setup)
            for r in intersect(refs_of(n), mvars)
                (
                    is_arr_obs(r) && !(r in setup) &&
                        !(r in tainted) && !(r in blocked) && haskey(defs, r) &&
                        !(r in refs_of(r)) &&
                        !_is_const_op(defs[r]) && !(defs[r] isa VarExpr)
                ) || continue
                rrefs = intersect(refs_of(r), mvars)
                any(f -> f in state_var_names, rrefs) && continue
                push!(setup, r); changed = true
            end
        end
        changed
    end
    return setup, copy(defs), tainted
end

# Dependency order over the setup vars (A_ij before its row sums).
function _geom_setup_order(setup, defs)
    deps = Dict{String, Set{String}}(n => intersect(_referenced_var_names(defs[n]), setup) for n in setup)
    return _dependency_order(
        setup, n -> deps[n];
        on_cycle = _ -> throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "cyclic setup-time geometry dependency"
            )
        )
    )
end
