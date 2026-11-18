# tree_walk/build_discrete_cache.jl — the discrete-cadence cut, its state-freedom check, and the cache
# buffers and fill kernels of a discrete materializer.

# True if `e` contains a gather `index(arr, sub…)` whose SUBSCRIPT references a scalar
# parameter — the signature of a nearest-neighbour COORDINATE regrid
# (`index(F_fuel, floor((tgt_lat[j] − src_y0)/src_dy)…)`, whose subscript reads the
# grid-geometry parameters src_y0/src_dy). The integer const-index folder cannot
# evaluate such a subscript, so it marks the const-tier materialization seed. An affine
# subscript (loop vars + const-array gathers, e.g. a conservative regrid's `W[i,j]` or
# a reshape `(gy−1)·NX+gx`) references no scalar parameter and is NOT flagged.
# The scan visits EVERY expression-bearing field via the shared traversal (not a
# hand-rolled args/expr_body/values subset), so a coordinate gather buried in an
# aggregate `filter` predicate is seen too.
# IDENTITY-MEMOIZED (`foreach_subexpr_once`): a pure existence predicate is
# path-multiplicity-insensitive, and the cadence-split def bodies scanned here
# are DAGs after template lowering / `_sub_preserving` — the per-path walk
# (`foreach_subexpr`) was exponential on a shared doubling chain (ESS-0hh).
function _has_param_indexed_gather(e::ASTExpr, scalar_params::Set{String})
    found = false
    foreach_subexpr_once(e) do n
        found && return nothing
        n isa OpExpr && n.op == "index" && length(n.args) >= 2 || return nothing
        for k in 2:length(n.args)
            if any(r -> r in scalar_params, _referenced_var_names(n.args[k]))
                found = true
                return nothing
            end
        end
        return nothing
    end
    return found
end

# ---- Stage: cadence materialization split (the discrete + const cuts) ----
# From the INLINE-candidate array observeds (`geom_inline_vars` ∪ `array_inline_vars`)
# pull out two classes that must NOT be inlined into the state RHS. A field is
# PARAM-TAINTED iff its def transitively reads a live `param_arrays` buffer;
# STATE-REACHING iff it transitively reads a continuous `state` or `t`.
#
#   • DISCRETE (param-tainted, NOT state-reaching): a per-bracket conservative regrid —
#     materialized ONCE PER REFRESH into a cache buffer (the pre-existing middle phase).
#   • CONST (const-cadence, NOT state-reaching): a NEAREST-NEIGHBOUR COORDINATE regrid
#     (`index(F_fuel, floor((tgt_lat[j] − src_y0)/src_dy)…)`) whose gather SUBSCRIPT is
#     a coordinate/parameter FLOAT the integer const-index folder cannot evaluate. It
#     (and its const dependency chain) materializes BUILD-ONCE into a const array
#     through the setup-time evaluator (see the call site); its readers then fold over
#     that const array per cell. The seed is precise — a def that gathers with a
#     subscript referencing a SCALAR PARAMETER — so a conservative Era5/elevation regrid
#     (affine src gather) and an ordinary contraction (`Σ_i W[i,j]·x`) are NOT flagged.
#
# Everything else (a param-tainted AND state/`t`-reaching field — the time-interpolated
# ERA5 met blend + the Rothermel/EMC/wind physics over it) STAYS inlined: after the
# discrete cut its body is an AFFINE blend of the discrete caches
# (`(1−w_time)·index(t_xy0,x,y) + w_time·index(t_xy1,x,y)`) the symbolic-stencil folder
# handles. `array_inline_candidates` is the const-tier pool (the geometry live-field
# set is param-tainted by construction, never const). A model with no coordinate regrid
# gets an empty const set (byte-identical). Returns `(discrete_vars, const_vars)`.
function _discrete_materialize_split(
        equations::Vector{Equation},
        inline_candidates, array_inline_candidates,
        state_var_names, param_names, scalar_param_names
    )
    empty = Set{String}()
    isempty(inline_candidates) && isempty(array_inline_candidates) &&
        return (empty, copy(empty))
    defs = Dict{String, ASTExpr}()
    for eq in equations
        eq.lhs isa VarExpr && (defs[(eq.lhs::VarExpr).name] = eq.rhs)
    end
    _closure(seed_set) = begin
        reached = Set{String}()
        changed = true
        while changed
            changed = false
            for (n, rhs) in defs
                n in reached && continue
                refs = _referenced_var_names(rhs)
                if any(r -> (r in seed_set) || (r in reached), refs)
                    push!(reached, n); changed = true
                end
            end
        end
        reached
    end
    # PARAM-TAINTED: transitively reads a live forcing buffer name.
    param_tainted = isempty(param_names) ? Set{String}() : _closure(Set{String}(param_names))
    # STATE-REACHING: transitively reads a continuous state (seeded with the states
    # themselves so a direct reader is caught) or `t`.
    state_seed = Set{String}(state_var_names); push!(state_seed, "t")
    state_reaching = _closure(state_seed)
    discrete = Set{String}(
        n for n in inline_candidates
            if (n in param_tainted) && !(n in state_reaching)
    )
    # CONST tier — coordinate-regrid SEED (a parameter-indexed gather), then close over
    # its const-cadence array dependencies so `_materialize_geometry_setup` can resolve
    # each body against the already-materialized upstream. Restricted to const-cadence
    # producers (neither param-tainted nor state/`t`-reaching).
    is_const(n) = !(n in param_tainted) && !(n in state_reaching)
    const_vars = Set{String}(
        n for n in array_inline_candidates
            if is_const(n) && haskey(defs, n) &&
            _has_param_indexed_gather(defs[n], scalar_param_names)
    )
    changed = true
    while changed
        changed = false
        for n in collect(const_vars)
            for r in _referenced_var_names(defs[n])
                (r in array_inline_candidates) && !(r in const_vars) && is_const(r) || continue
                push!(const_vars, r); changed = true
            end
        end
    end
    return (discrete, const_vars)
end

# Dependency order over the discrete-materialize vars (a cache that gathers another
# cache must fill AFTER it). Mirrors `_geom_setup_order`.
function _discrete_fill_order(discrete_vars, discrete_defs)
    return _dependency_order(
        collect(discrete_vars),
        n -> intersect(_referenced_var_names(discrete_defs[n]), discrete_vars);
        on_cycle = done -> throw(
            TreeWalkError(
                "E_TREEWALK_DISCRETE_MATERIALIZE",
                "cyclic dependency among discrete-cadence vars: $(setdiff(discrete_vars, done))"
            )
        )
    )
end

# ---- The discrete-cadence STATE-FREEDOM CHECK (ess-5d1) ----
# `materialize!` evaluates every fill node with `u = zeros(n_states)` and `t = 0.0`,
# and re-runs only on a data-refresh event — so a fill node that READS a continuous
# state or `t` does not merely give a wrong number once, it FREEZES the field at
# `u = 0` for the whole integration, silently. State-freedom is supposed to be
# guaranteed upstream by `_discrete_materialize_split` (a state-reaching def is never
# classified discrete), but that guarantee rests on a name-reachability walker, and a
# walker that misses one expression-bearing field turns the whole class of bug into a
# wrong trajectory with no error. So we do not ASSUME it — we CHECK it, on the thing
# that actually runs: the compiled fill node.
#
# Legal leaves in a fill: `_NK_LITERAL`, `_NK_PARAM` (a scalar param), `_NK_OP` /
# `_NK_CONTRACTION`, and — expected, not exceptional — `_NK_PARAM_GATHER`, which is
# how a fill reads a raw live forcing buffer or an upstream discrete cache.
# `_NK_CACHED` (a CSE prelude slot) cannot occur: fills compile through plain
# `_compile`, never `_cse_compile_scalar`. If one ever appears the prelude that backs
# it is not evaluated by `materialize!`, so the read would be garbage — that is an
# internal invariant break, and it is reported rather than silenced.
function _check_discrete_fill_state_free(node::_Node, name::String)
    k = node.kind
    if k === _NK_STATE || k === _NK_TIME
        _throw_discrete_state_dependent(name, k === _NK_STATE)
    elseif k === _NK_CACHED
        throw(
            TreeWalkError(
                "E_TREEWALK_DISCRETE_MATERIALIZE",
                "internal: the discrete-cadence fill kernel for '$name' contains a CSE " *
                    "cache reference (_NK_CACHED), whose prelude `materialize!` does not " *
                    "evaluate. Fill kernels compile through `_compile`, not the CSE pass — " *
                    "this is a build-pipeline invariant break, not a model error."
            )
        )
    end
    for c in node.children
        _check_discrete_fill_state_free(c, name)
    end
    return nothing
end

function _throw_discrete_state_dependent(name::String, state::Bool)
    what = state ? "a continuous state variable" : "the time variable `t`"
    throw(
        TreeWalkError(
            "E_TREEWALK_DISCRETE_MATERIALIZE",
            "discrete-cadence var '$name' depends on $what. A discrete-cadence cache " *
                "is filled only when the forcing data refreshes (its fill kernel runs " *
                "with u = 0 and t = 0), so it CANNOT depend on a continuous state or on " *
                "`t` — the field would silently freeze at u = 0 instead of tracking the " *
                "solution. Either drop the state/`t` dependency from '$name' (keep the " *
                "state-dependent part in its readers, where it stays on the continuous " *
                "path), or, if the reference reaches '$name' through an expression field " *
                "the cadence classifier does not walk, that classifier is the bug."
        )
    )
end

# ---- Stage: discrete-cadence cache buffers + fill kernels ----
# Allocate a dense cache buffer per discrete var and register it in `pgather`, so
# a reader's `index(var, j…)` gathers the cache via `_NK_PARAM_GATHER` — the SAME
# zero-alloc live-buffer path a raw forcing read uses, NOT an inline
# beta-reduction. Then build each var's fill, in dependency order, and a
# `materialize!` that runs them all into their caches: once here (the initial
# fill) and again per refresh. `mut` is the caller's `DiscreteMaterializer` sink;
# it is populated in place. Mutates `pgather` (adds the caches).
#
# Two routes, chosen by the plan in force:
#
#   * COMPILED (any array tier on — `native` and `xla`): each var is ONE fill
#     equation through the same array cascade the right-hand side takes
#     (`_compile_discrete_fill`), its output slots being the cache itself. The
#     build is independent of the cache's size, and a fill the cascade cannot
#     compile is refused by the cascade, naming it.
#   * PER CELL (`interpreter`, the oracle): every cell is resolved and compiled
#     as `index(<def>, j…)` and walked with `_eval_node` at each refill —
#     the `_seed_faq_init_u0!` pattern, writing a cache buffer instead of a u0
#     slot. Reported `:discrete_percell`, and refused by a strict plan.
#
# A fill may read scalar parameters, so the caches belong to the `p` they were
# filled with. `materialize!(q)` fills them with `q` (with no argument, the `p`
# of the last fill), and the returned `_DiscreteRefill` — which the in-place
# right-hand side calls first on every call — refills them when the call's `p` is
# not that one. That is what makes `remake(prob; p = …)` reach a
# forcing-derived field. The caches also belong to the forcing they were filled
# from: `_DiscreteRefill` refills them when the build's forcing epoch has moved
# since the last fill, so a direct in-place write to a live buffer followed by
# `notify_forcing_refresh!` reaches a forcing-derived field too, as it reaches
# the time tiers. Returns `nothing` when there is nothing to fill.
function _build_discrete_materializer!(
        mut::DiscreteMaterializer,
        discrete_vars, discrete_defs::Dict{String, ASTExpr}, resolved_obs::Dict{String, ASTExpr},
        cs::_CompileScope, p, n_states::Int
    )
    isempty(discrete_vars) && return nothing
    order = _discrete_fill_order(discrete_vars, discrete_defs)
    caches = Dict{String, Array{Float64}}()
    cells_of = Dict{String, Tuple{Vector{String}, Vector{Vector{Int}}}}()
    # 1. Allocate + register EVERY cache first, so a fill body that gathers another
    #    discrete cache resolves to a pgather over it (values filled later, in order).
    for name in order
        rhs = discrete_defs[name]
        (rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op)) ||
            throw(
            TreeWalkError(
                "E_TREEWALK_DISCRETE_MATERIALIZE",
                "discrete-cadence var '$name' must be a faq producer"
            )
        )
        rop = rhs::OpExpr
        idx_names = _output_idx_strings(rop)
        ranges = _ranges_dict(rop)
        rngs = Vector{Int}[collect(_expand_int_range(ranges[n])) for n in idx_names]
        for (d, r) in enumerate(rngs)
            (!isempty(r) && r == collect(1:length(r))) || throw(
                TreeWalkError(
                    "E_TREEWALK_DISCRETE_MATERIALIZE",
                    "discrete-cadence var '$name' dim $d range must be 1..n (got $(r)); " *
                        "the cache gather is 1-based column-major"
                )
            )
        end
        dims = isempty(rngs) ? Int[1] : Int[length(r) for r in rngs]
        cache = zeros(Float64, dims...)
        caches[name] = cache
        cs.pgather[name] = _PGatherArray(vec(cache), collect(size(cache)), true)
        cells_of[name] = (idx_names, rngs)
    end
    uz = zeros(Float64, n_states)
    pp = isnothing(p) ? NamedTuple() : p
    compiled = _array_cascade_on()
    state_names = compiled ? _state_base_names(cs.var_map, cs.array_var_info) : Set{String}()
    # 2. The fills, in dependency order. Scalar observeds are inlined into each
    #    aggregate via `resolved_obs` (the inline reader gets them the same way); an
    #    `index(other_discrete, i)` stays a pgather over that cache (other discrete
    #    vars are excluded from `resolved_obs`).
    fills = Any[]                         # one per var, in dependency order
    for name in order
        rop = discrete_defs[name]::OpExpr
        rop_res = isempty(resolved_obs) ? rop : _sub_preserving(rop, resolved_obs)
        rop_res isa OpExpr ||
            throw(
            TreeWalkError(
                "E_TREEWALK_DISCRETE_MATERIALIZE",
                "discrete-cadence var '$name' resolved to a non-faq expression"
            )
        )
        idx_names, rngs = cells_of[name]
        cvec = vec(caches[name])
        if compiled && !isempty(idx_names)
            # The cadence cut is CHECKED, not assumed (see
            # `_check_discrete_fill_state_free`). Here it is checked on the
            # resolved definition, and the fill compiles against a layout that
            # holds only its own cache, so a state read the name walk missed
            # cannot compile at all rather than read u = 0.
            _check_discrete_def_state_free(rop_res, name, state_names)
            push!(
                fills, _compile_discrete_fill(
                    name, rop, Int[length(r) for r in rngs], cvec, resolved_obs, cs
                )
            )
            continue
        end
        # A rank-0 field, under either plan: one cell, compiled once and walked
        # at each refill as the right-hand side's scalar equations are.
        if isempty(idx_names)
            node = _discrete_cell_node(name, rop_res, (), cs)
            push!(fills, _scalar_discrete_fill(cvec, node, uz))
            _record_rule!(name, :observed, :scalar)
            continue
        end
        # The per-cell route: every cell resolved and compiled, and walked at
        # each refill. A strict plan refuses it once its probe has resolved,
        # compiled and evaluated the first cell, so that a fill no form can
        # evaluate (an undeclared name, an out-of-range const gather) raises the
        # document's own error rather than a refusal.
        dims = Int[length(r) for r in rngs]
        ncells = prod(dims)
        cell_node(idx_tuple) = _discrete_cell_node(name, rop_res, idx_tuple, cs)
        lic = _percell_license(
            name,
            "the discrete-cadence materializer resolves and compiles this " *
                "forcing-derived field once per cell ($ncells cell" *
                (ncells == 1 ? "" : "s") * ") and re-evaluates every cell as a " *
                "tree walk at each data refresh and at each run's start — a " *
                "per-cell evaluation that esm-libraries-spec §2.5.10 puts under " *
                "the same rule as the right-hand side. Build with " *
                "compiler=:interpreter to run it. " * _ONE_CELL_NOTE;
            probe = _ -> _eval_node(
                cell_node(first(Iterators.product(rngs...))),
                uz, pp, 0.0
            )
        )
        lin = LinearIndices(Tuple(dims))
        cell_fills = Tuple{Int, _Node}[
            (lin[idx_tuple...], cell_node(idx_tuple))
                for idx_tuple in Iterators.product(rngs...)
        ]
        push!(fills, _percell_discrete_fill(lic, cvec, cell_fills, uz))
        _record_rule!(name, :observed, :discrete_percell)
    end
    # 3. `materialize!`: every fill into its cache, in dependency order, with the
    #    `p` given (by default the one the caches already hold).
    filled_p = Ref{Any}(pp)
    stamp = Ref{Any}(_pstamp(pp))
    epoch = mut.epoch
    # The build's forcing epoch as the last fill left it.
    filled_epoch = Ref{UInt64}(0)
    function materialize!(q = filled_p[])
        for fill in fills
            fill(q)
        end
        filled_p[] = q
        stamp[] = _pstamp(q)
        # The caches just changed IN PLACE under readers gathering them via
        # `_NK_PARAM_GATHER` — invalidate the memoized time-cadence prelude slots
        # (B3, const_tier.jl): a refresh fires AT its tstop, so the next RHS call
        # is at a `t` the t-tier stamp may already hold.
        _bump_epoch!(epoch)
        filled_epoch[] = _epoch_value(epoch)
        return nothing
    end
    materialize!()          # initial fill — valid caches for u0 seeding + first step
    mut.caches = caches
    mut.materialize! = materialize!
    mut.var_order = order
    refill = _DiscreteRefill{typeof(pp), typeof(materialize!)}(stamp, materialize!, epoch, filled_epoch)
    mut.refresh! = () -> refill(nothing)
    return refill
end

# One cell of a discrete-cadence field, compiled as `index(<def>, j…)` and
# resolved through the SAME `_resolve_index_of_faq` expansion the inline reader
# uses — so a reduction over CONTRACTED indices (the conservative regrid
# Σ_i A_ij·F_src/A_j, whose sum-over-source `i` lives in the aggregate's ranges,
# not the body) is expanded, not silently dropped — and checked state-free.
function _discrete_cell_node(name::String, rop_res::OpExpr, idx_tuple, cs::_CompileScope)
    gather = OpExpr(
        "index", ASTExpr[
            rop_res,
            (IntExpr(Int64(idx_tuple[d])) for d in 1:length(idx_tuple))...,
        ]
    )
    node = _compile_in(cs, _resolve_in(cs, gather))
    _check_discrete_fill_state_free(node, name)
    return node
end

# The fills of one cache. Every node was CHECKED state-free, so the zero `u` /
# `t = 0` passed to `_eval_node` is provably never read; `p` carries the scalar
# params a fill may use. A rank-0 field is one node; a per-cell one walks a
# node per cell, which takes a license.
function _scalar_discrete_fill(cvec::Vector{Float64}, node::_Node, uz::Vector{Float64})
    return function (p)
        @inbounds cvec[1] = _eval_node(node, uz, p, 0.0)
        return nothing
    end
end

struct _PercellDiscreteFill{C}
    license::_PerCellLicense
    cvec::Vector{Float64}
    cell_fills::C
    uz::Vector{Float64}
end
function (f::_PercellDiscreteFill)(p)
    @inbounds for (l, node) in f.cell_fills
        f.cvec[l] = _eval_node(node, f.uz, p, 0.0)
    end
    return nothing
end
_percell_discrete_fill(
    lic::_PerCellLicense, cvec::Vector{Float64}, cell_fills,
    uz::Vector{Float64}
) = _PercellDiscreteFill(lic, cvec, cell_fills, uz)

# The base names of every continuous state `var_map` lays out: its scalars and
# the arrays `array_var_info` names. A `StateLayout` answers the scalars
# directly; a plain map is read key by key, cell keys skipped.
function _state_base_names(var_map::AbstractDict, array_var_info)
    out = Set{String}(String(k) for k in keys(array_var_info))
    if var_map isa StateLayout
        union!(out, _layout_scalar_names(var_map))
    else
        for k in keys(var_map)
            s = String(k)
            endswith(s, "]") || push!(out, s)
        end
    end
    return out
end

# The state-freedom check of the compiled route, on the resolved definition: a
# reference to a continuous state or to `t` anywhere in it, in any expression
# field, raises the same error `_check_discrete_fill_state_free` raises on a
# per-cell node. Loop symbols the definition binds are not references.
function _check_discrete_def_state_free(
        def::ASTExpr, name::String,
        state_names::Set{String}
    )
    bound = Set{String}()
    foreach_subexpr_once(def) do e
        e isa OpExpr || return nothing
        if e.output_idx !== nothing
            for s in e.output_idx
                push!(bound, String(s))
            end
        end
        if e.ranges !== nothing
            for k in keys(e.ranges)
                push!(bound, String(k))
            end
        end
        nothing
    end
    hit = 0          # 1: a state, 2: `t`
    foreach_subexpr_once(def) do e
        (hit == 0 && e isa VarExpr && !(e.name in bound)) || return nothing
        e.name == "t" ? (hit = 2) : (e.name in state_names && (hit = 1))
        nothing
    end
    hit == 0 || _throw_discrete_state_dependent(name, hit == 1)
    return nothing
end

# One discrete var's fill, compiled once: the synthesized
# `faq(D(index(var, i…))) = index(<def>, i…)` equation
# (`_materialized_fill_equation`, the route a materialized array observed's fill
# takes) through `_compile_derivative_equations`, over a layout whose only block
# is the cache itself, so the cascade's output slots ARE the cache's column-major
# cells and its kernels write the cache in place. Returns a `() -> nothing` that
# runs the fill. The cascade labels its report row and its refusals by the
# variable's own name, and the row is filed as an observed.
function _compile_discrete_fill(
        name::String, def::OpExpr, dims::Vector{Int},
        cvec::Vector{Float64}, resolved_obs::Dict{String, ASTExpr}, cs::_CompileScope
    )
    nd = length(dims)
    blk = name => (ones(Int, nd), copy(dims))
    own = _CompileScope(
        Dict{String, Tuple{Vector{Int}, Vector{Int}}}(blk), StateLayout(String[], [blk]),
        cs.const_registry, cs.pgather, cs.param_index
    )
    feqs = _materialized_fill_equations(name, def, dims)
    rec = _build_record()
    n0 = rec === nothing ? 0 : length(rec.rules)
    lv = _with_own_slot_tables() do
        _compile_fill_level(
            (name,), :dynamic, _ -> feqs, _ -> nothing, resolved_obs, own,
            length(cvec); label_by_name = true
        )
    end
    if rec !== nothing
        for k in (n0 + 1):length(rec.rules)
            r = rec.rules[k]
            rec.rules[k] = CompilerRuleRecord(r.rule, :observed, r.tier, r.declines)
        end
    end
    # The kernel emission refuses what it cannot generate, naming the rule open
    # at the time — this one, not the assembled right-hand side.
    label(f) = begin
        rec === nothing || (rec.current = name)
        sec = f()
        rec === nothing || (rec.current = "")
        sec
    end
    levels = (
        _inplace_fill_level(
            lv.scalars, lv.kernels, lv.scans, lv.contractions, lv.recurrences;
            section_label = label
        ),
    )
    return p -> (_fill_obs_levels!(levels, cvec, p, 0.0, Float64); nothing)
end
