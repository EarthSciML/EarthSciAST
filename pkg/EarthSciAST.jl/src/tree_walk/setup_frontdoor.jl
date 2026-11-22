# tree_walk/setup_frontdoor.jl — the two front-door derivations that run before
# the build: binning coordinates and overlap-gate envelope factors.

# ---- Build-time binning-COORDINATE derivation (RFC §8.6.1 broad phase) ----
# A broad-phase binning coordinate may be declared INLINE as an aggregate over the
# in-file cell geometry — a `reduce` projection (a bbox-min corner
# `src_lon[i] = min_v src_poly[i, v, 1]`) OR a plain affine MAP over a grid spec
# (the cartesian `lon[c] = x0 + ((c-1) mod GX)*dx + dx/2`) — instead of being
# supplied as a `const` vector. Such an observed reads only build-time data (scalar
# parameters and other build-time-constant arrays; never a state variable or a live
# loader field), so its value is a build-time constant: it is evaluated ONCE here
# and fed into the value-invention `const_arrays` so a bin column
# `floor(index(src_lon,i)/dx)` resolves at setup, and to the typed build as a
# derived const array (excluded from the ODE like any `const`-op array observed).
# This keeps the fixture PURE — the coordinate is derived from geometry, not
# hand-supplied — and admits a TEMPLATE-CONSTRUCTED coordinate whose inputs (the
# cell rings) are themselves an aggregate over a grid spec. Determinism is
# preserved: the STATE-DEPENDENCE guard (`state_names`) and the requirement that
# every referenced factor fold to a build-time constant (a scalar param, a const
# array, or another statically-determinable aggregate) still REJECT a genuinely
# runtime coordinate — only §9.6.3-static build-time data becomes an index target.

# The `reduce` spellings that mark a 1-D aggregate observed as a build-time
# coordinate-PROJECTION seed in `_derive_binning_coords` below (RFC §8.6.1).
# The seed test there is deliberately the light check — reduce kind + declared
# 1-D shape (or a value-invention index target); the heavier per-reference
# state-freedom / build-time-constant checks run in the closure-materialization
# pass, which is what actually gates evaluation.
const _REDUCE_PROJECTION_KINDS = ("min", "max", "sum", "prod")

# The loop-bound symbols of an aggregate (its `ranges` keys + `output_idx`) — index
# names, not data references.
function _agg_bound_syms(e::OpExpr)
    bound = Set{String}()
    e.ranges !== nothing && for k in keys(e.ranges)
        push!(bound, String(k))
    end
    e.output_idx !== nothing && for k in e.output_idx
        push!(bound, String(k))
    end
    return bound
end

# Materializable NON-const-op aggregate array observeds: name → expression. A
# build-time coordinate derivation can fold only these (a faq over
# build-time data); a `const`-op / kwarg-supplied array observed is already seeded
# into `env` and is not a materialization candidate.
function _agg_array_obs_defs(model, env)
    d = Dict{String, OpExpr}()
    for (n, e) in observed_definitions(model)
        _is_array_shape(model.variables[n].shape) || continue
        haskey(env, n) && continue
        (e isa OpExpr && _is_faq_op(e.op)) || continue
        d[n] = e
    end
    return d
end

# Evaluate the inline binning-COORDINATE observeds into dense `Vector{Float64}`s,
# reusing the reduce-aware setup-time array materializer (`_materialize_geom_array`).
# The COORDINATE SEEDS are the 1-D array observeds that are a `reduce`-projection
# (the original const-geometry derivation) OR a value-invention key INDEX TARGET
# (`vi_index_targets` — this admits a TEMPLATE-CONSTRUCTED, aggregate-valued
# coordinate like the cartesian cell-centre map, or a reduce over constructed rings,
# as a bin-key index target). ONLY the seeds and their build-time-constant array
# dependencies are materialised — a model without a broad-phase coordinate is
# untouched (byte-identical), and no unrelated array observed is force-evaluated.
# Determinism is preserved: a coordinate whose closure reaches a live STATE variable
# (or any name absent from the build-time env) is NOT build-time-constant, so it is
# never materialised and never becomes an index target. Returns name → values.
function _derive_binning_coords(
        model, index_sets, const_arrays_kw, param_overrides,
        vi_index_targets = Set{String}()
    )
    out = Dict{String, Vector{Float64}}()
    # The shared setup env (see `_build_setup_env` for the precedence proof that
    # this equals the assembly formerly inlined here): in-file `const`-op ring
    # stacks the projection gathers per cell via `index(src_poly, i)`, the
    # kwarg const arrays, and the scalar params/overrides.
    env = _build_setup_env(model, const_arrays_kw; param_overrides = param_overrides)
    # The LIVE names a build-time derivation may never read: the ODE states plus
    # the algebraic unknowns (esm-spec §6.3.1). An observed is not live by
    # declaration — whether it resolves is decided by whether its own factors
    # are in `env`, which is the test the loop below already makes.
    state_names = Set{String}(solver_unknowns(model))
    var_shapes = _declared_var_shapes(model)

    cand = _agg_array_obs_defs(model, env)   # materializable aggregate array observeds
    # Coordinate SEEDS: 1-D materializable coordinate buffers to derive.
    seeds = String[]
    for (n, e) in cand
        length(get(var_shapes, n, String[])) == 1 || continue
        (
            n in vi_index_targets ||
                (e.reduce !== nothing && e.reduce in _REDUCE_PROJECTION_KINDS)
        ) || continue
        push!(seeds, n)
    end
    isempty(seeds) && return out             # byte-identical for a coordinate-free model

    # Transitive array-observed dependency closure of the seeds (reachability over
    # `cand`; a `const`-op / kwarg dep is already in `env`).
    want = Set{String}()
    stack = copy(seeds)
    while !isempty(stack)
        n = pop!(stack)
        (haskey(cand, n) && !(n in want)) || continue
        push!(want, n)
        for r in _referenced_var_names(cand[n])
            (haskey(cand, r) && !(r in want)) && push!(stack, r)
        end
    end

    # Materialise the reachable build-time-constant closure in dependency order. A
    # member referencing a live STATE variable — or any name absent from the
    # build-time env / not yet accepted — is skipped; its dependents then fail to
    # materialise and are simply not returned (the coordinate falls back to the
    # existing error). The fixpoint yields a valid topological order.
    derived_extents = Dict{String, Int}()
    accepted = Set{String}()
    _saturate!() do   # CLOSURE-MATERIALIZATION pass: accept once every dep resolves
        changed = false
        for n in want
            n in accepted && continue
            e = cand[n]; bound = _agg_bound_syms(e); ok = true
            for r in _referenced_var_names(e)
                r in bound && continue
                r in state_names && (ok = false; break)      # never a live state
                (haskey(env, r) || r in accepted) && continue
                ok = false; break                            # unresolved dep — retry / drop
            end
            ok || continue
            # A coordinate whose body reaches an op OUTSIDE the setup-time geometry
            # vocabulary (`_GEO_EVAL_OPS`) — a Lambert-conformal PROJECTION (`X[e] =
            # lambert_conformal_forward_x(lon[e],lat[e])`, trig, `^`, an
            # `apply_expression_template` expansion) — cannot be compiled by
            # `_materialize_geom_array` (whose `_geo_compile` speaks only that
            # vocabulary). Route it to the GENERAL build-time cell pipeline
            # (`_eval_cellwise`, the full scalar op set the right-hand side
            # uses), exactly as a promoted-physics MAP is materialised in
            # `_materialize_geometry_setup`. Because this runs BEFORE
            # `materialize_value_invention` (the seeds feed `const_arrays`), a
            # projected coordinate becomes visible to value-invention's `_vi_eval`
            # (which has no trig): the CALLER supplies only raw `lon`/`lat`, never
            # pre-projected `X`/`Y`. The geometry-vocabulary reduce-projection path
            # is unchanged (`_body_needs_general_eval` is false there).
            _open_rule!(n, :setup_array)
            env[n] = if _body_needs_general_eval(e)
                _materialize_setup_general_map(
                    e, env, index_sets, derived_extents
                )
            else
                _materialize_geom_array(e, env, index_sets, derived_extents, var_shapes)
            end
            push!(accepted, n); changed = true
        end
        changed
    end

    # Return the 1-D coordinate seeds that materialised to a build-time constant.
    for n in seeds
        haskey(env, n) || continue
        (env[n] isa AbstractArray && ndims(env[n]) == 1) || continue
        out[n] = vec(Array{Float64}(env[n]))
    end
    return out
end

# ---- Build-time OVERLAP-gate ENVELOPE-FACTOR derivation (§5.5.6) -----------
# An `join.overlap` gate names CONST-ARRAY envelope factors: its broad phase is
# computed ONCE at build time, so every factor it names must be build-time data
# by the time `_resolve_join_gates_for` runs. That is automatic for a plain
# parameter (`src_W[c]`) or a derived coordinate (`X[r]`, above) — but NOT for a
# factor living on a value-invented DERIVED axis.
#
# The projection-pushdown rewrite emits exactly such a factor: it re-points a
# binning aggregate onto the compact `pd_support__*` axis and gates it on the
# generated `pd_cell__*` gathers, `cell_F[c] = index(F, index(member_factor, c))`.
# Those cannot exist before value invention has sized the derived axis and fed
# the member factor back (Hook 1), so they are derived HERE, one hook later.
#
# Deliberately NARROW. A name is materialised only when it (a) is named by an
# overlap gate, (b) is not already const-array data, (c) is a 1-D array OBSERVED
# defined by an aggregate, and (d) reads nothing but build-time-constant names
# (never a live state) — exactly the determinism guard `_derive_binning_coords`
# applies. Anything else is left alone and the existing missing-factor error
# still surfaces. Evaluation goes through the GENERAL build-time cell pipeline
# (`_eval_cellwise` via `_materialize_setup_general_map`), which is the one that
# speaks indirect gathers (`index(F, index(M, c))`).
#
# `vi_extents` is the value-invention extent map, keyed by PRODUCER id; the
# setup materializer resolves a range by its index-set NAME, so derived sets are
# re-keyed through `from_faq` here. Returns name → dense values (empty, hence
# byte-identical, for a document with no overlap gate).

# Every `src_env` / `tgt_env` factor name of every OVERLAP join clause reachable
# from `model`'s variable expressions and equations.
function _overlap_env_factor_names(model)
    names = Set{String}()
    seen = IdDict{OpExpr, Nothing}()
    function visit(e)
        e isa OpExpr || return
        haskey(seen, e) && return
        seen[e] = nothing
        if e.join !== nothing
            for clause in e.join
                clause isa _OverlapJoinSpec || continue
                for f in clause.src_env
                    push!(names, String(f))
                end
                for f in clause.tgt_env
                    push!(names, String(f))
                end
            end
        end
        for a in _operands(e)
            visit(a)
        end
        visit(e.expr_body); visit(e.filter); visit(e.lower); visit(e.upper)
        return e.values === nothing || for v in e.values
            visit(v)
        end
    end
    for eqs in (model.equations, model.initialization_equations)
        eqs === nothing && continue
        for eq in eqs
            visit(eq.lhs); visit(eq.rhs)
        end
    end
    return names
end

function _derive_overlap_env_factors(
        model, index_sets, const_arrays_kw, param_overrides,
        vi_extents
    )
    out = Dict{String, Vector{Float64}}()
    want = _overlap_env_factor_names(model)
    isempty(want) && return out                  # byte-identical: no overlap gate
    env = _build_setup_env(model, const_arrays_kw; param_overrides = param_overrides)
    todo = sort!(String[n for n in want if !haskey(env, n)])
    isempty(todo) && return out                  # every factor is already const data
    # Derived-set extents keyed by SET NAME (value invention keys them by producer id).
    derived_extents = Dict{String, Int}()
    for (sname, iset) in index_sets
        (iset isa IndexSet && iset.kind == "derived" && iset.from_faq !== nothing) || continue
        e = get(vi_extents, String(iset.from_faq), nothing)
        e === nothing || (derived_extents[String(sname)] = Int(e))
    end
    var_shapes = _declared_var_shapes(model)
    state_names = Set{String}(solver_unknowns(model))
    obs_defs = observed_definitions(model)
    # One SATURATING pass so a factor that gathers through another derived factor
    # resolves regardless of name order (the same fixpoint `_derive_binning_coords`
    # uses; monotone over a finite set, so it terminates).
    _saturate!() do
        changed = false
        for n in todo
            haskey(out, n) && continue
            e = get(obs_defs, n, nothing)
            e === nothing && continue
            length(get(var_shapes, n, String[])) == 1 || continue
            (e isa OpExpr && _is_faq_op(e.op)) || continue
            bound = _agg_bound_syms(e); ok = true
            for r in _referenced_var_names(e)
                r in bound && continue
                r in state_names && (ok = false; break)     # never a live state
                haskey(env, r) && continue
                ok = false; break                            # unresolved dep — retry / drop
            end
            ok || continue
            _open_rule!(n, :setup_array)
            arr = _materialize_setup_general_map(
                e, env, index_sets, derived_extents
            )
            env[n] = arr
            out[n] = vec(Array{Float64}(arr))
            changed = true
        end
        changed
    end
    return out
end
