# tree_walk/build_initial_state.jl — the initial state: `ic` equations, their start-of-run scope and
# plan, the scalar and field folds, `u0`, the caller's `u0`, faq-valued
# initialization equations, and the re-seed a Problem keeps.

# ---- Stage: split out `ic(var) = <initial value>` equations (esm-spec §11.4) ----
# An `ic`-LHS equation declares an initial condition, not a right-hand side, so
# it is pulled out of the equation stream before the ODE partition and the
# observed-substitution passes (its LHS is not a `D`, so it would otherwise be
# rejected as an unsupported equation form). A target that is an array-shaped
# state is a FIELD `ic` (`field_ics`), folded per cell once its cells are known
# (`_fold_field_ics!`): the target may be a dot-namespaced reference to another
# component's species that coupling has lifted onto the grid
# (`ic(Chemistry.O3) ~ InitialConditions.O3_init`). Any other target is a
# scalar `ic` (`scalar_ics`), folded by `_fold_scalar_ics`. Both are evaluated
# in the start-of-run scope (`_ic_start_scope`). Returns
# `(kept_equations, scalar_ics, field_ics)`; no-op for a model without one.
function _split_ic_equations(equations::Vector{Equation}, model::Model)
    scalar_ics = Tuple{String, ASTExpr}[]
    field_ics = Tuple{String, ASTExpr}[]
    kept = Equation[]
    for eq in equations
        if eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "ic"
            lop = eq.lhs::OpExpr
            (length(lop.args) == 1 && lop.args[1] isa VarExpr) ||
                throw(
                TreeWalkError(
                    "E_TREEWALK_UNSUPPORTED_EQUATION",
                    "ic(...) LHS must name a single state variable; got " *
                        "$(first(string(eq.lhs), 200))"
                )
            )
            vn = (lop.args[1]::VarExpr).name
            tvar = get(model.variables, vn, nothing)
            if tvar !== nothing && _is_array_shape(tvar.shape)
                push!(field_ics, (vn, eq.rhs))
            else
                push!(scalar_ics, (vn, eq.rhs))
            end
        else
            push!(kept, eq)
        end
    end
    return kept, scalar_ics, field_ics
end

# ---- The start-of-run scope of an `ic` right-hand side (esm-spec §11.4.2) ----
# Every `ic` right-hand side is evaluated ONCE, at `t0 = tspan[1]`, the start of
# the run. It may read every parameter (scalar or shaped), the independent
# variable `t` bound to `t0`, each data-fed parameter at the value its provider
# gives at `t0`, the caller's const arrays, and every observed over those,
# evaluated at `t0`. It may not read a state — an ODE state or an algebraic
# unknown — directly or through any chain of observeds: there is no value for
# one before the initial state exists, so that is refused with
# `ic_reads_state` rather than evaluated with a placeholder.
#
# `scalars` holds the scalar names, `arrays` the array ones (each a dense array
# a reference reads the way it reads a loaded field). An observed an `ic`
# reads is evaluated once, as a whole field, by the build-time field evaluator
# (`evaluate_cellwise`, which takes the compiler's per-cell license like every
# other construction-time field), and added to the scope; a reader then reads
# its value, never a copy of its body per cell.
#
# `t` reaches every build-time evaluator the same way: each right-hand side in
# the scope is read with `t` renamed to `_IC_T0_NAME`, a scalar bound to `t0`
# (`_ic_bind_start_time`). The construction-time evaluators bind the time slot
# to `0.0`, so leaving `t` as the time read there would evaluate the `ic` at
# `t = 0` whatever the run's start.
#
# `reads_start` is true when the initial state depends on `t0` (a right-hand
# side in the cone reads `t` or a data-fed parameter): `remake` with a new
# `tspan` then has to evaluate the `ic` right-hand sides again.
const _IC_T0_NAME = "__esm_ic_t0"

# `_IcStart`: build_records.jl.

_ic_bind_start_time(e::ASTExpr) =
    _sub_preserving(e, Dict{String, ASTExpr}("t" => VarExpr(_IC_T0_NAME)))

# The array scope a field `ic` reads: the build's own (`const_arrays`, which
# wins, as it does for every build-time array read) with the start-of-run
# additions (the data-fed parameters at `t0` and the observeds an `ic` reads).
_ic_field_arrays(const_arrays::AbstractDict, s::_IcStart) =
    _ic_field_arrays(const_arrays, s.arrays)
function _ic_field_arrays(const_arrays::AbstractDict, additions::AbstractDict)
    isempty(additions) && return const_arrays
    out = Dict{String, Any}(String(k) => v for (k, v) in const_arrays)
    for (k, v) in additions
        haskey(out, k) || (out[k] = v)
    end
    return out
end

function _ic_reads_state_error(target, chain::Vector{String}, state::String)
    reads = isempty(chain) ? "reads '$(state)', a state" :
        "reads '" * join(chain, "', which reads '") * "', which reads '$(state)', a state"
    return TreeWalkError(
        ERROR_CODES.IC_READS_STATE,
        "ic($(target)) $(reads). An `ic` right-hand side is evaluated at the start of " *
            "the run, before any state has a value, so it may read parameters, `t`, " *
            "data-fed parameters and observeds over those, but not a state " *
            "(esm-spec §11.4.2)"
    )
end

# `_IcPlan`: build_records.jl.

function _ic_plan(
        model::Model, scalar_ics::Vector{Tuple{String, ASTExpr}}, field_ics::Vector{Tuple{String, ASTExpr}};
        param_scope::AbstractDict, base_arrays::AbstractDict,
        param_arrays::AbstractDict, index_sets::AbstractDict,
        derived_extents::AbstractDict, factor_scope::AbstractDict, vi_vars::Set{String}
    )
    params = Dict{String, Float64}(String(k) => Float64(v) for (k, v) in param_scope)
    bound_fields = Tuple{String, ASTExpr}[(n, _ic_bind_start_time(r)) for (n, r) in field_ics]
    empty_plan() = _IcPlan(
        collect(Tuple{String, ASTExpr}, scalar_ics), bound_fields, params,
        Dict{String, Any}(), Dict{String, Any}(), Set{String}(),
        Tuple{String, ASTExpr, Union{Nothing, Vector{Int}}}[], Set{String}(),
        false
    )
    (isempty(scalar_ics) && isempty(field_ics)) && return empty_plan()
    scalar_param(n) = (
        v = get(model.variables, n, nothing);
        v !== nothing && v.type == ParameterVariable && !_is_array_shape(v.shape)
    )
    # Data-fed parameters: the live buffer holds the `sample_time` record; the
    # value at `t0`, where it differs, is the evaluation's `data`.
    live = Set{String}(String(k) for k in keys(param_arrays))

    # The observeds the `ic` right-hand sides read, transitively, checked for a
    # state read, in dependency order.
    states = Set{String}(solver_unknowns(model))
    setdiff!(states, vi_vars)
    rhss = Tuple{String, ASTExpr}[(n, r) for (n, r) in scalar_ics]
    append!(rhss, field_ics)
    observed = Set{String}(observed_unknowns(model))
    obs_defs = nothing    # built on first need
    function defs()
        obs_defs === nothing || return obs_defs
        eqs = Equation[
            eq for eq in _normalize_indexed_observed_lhs(model.equations, model; vi_vars = vi_vars)
                if eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in observed
        ]
        eqs = _resolve_index_set_ranges(eqs, index_sets, derived_extents, factor_scope)
        d = Dict{String, ASTExpr}()
        for eq in eqs
            n = (eq.lhs::VarExpr).name
            haskey(d, n) || (d[n] = eq.rhs)
        end
        obs_defs = d
        return d
    end
    order = String[]
    done = Set{String}()
    onpath = Set{String}()
    reads_start = false
    known(n) = n == _IC_T0_NAME || haskey(base_arrays, n) || n in live || haskey(params, n)
    function visit(target, n::String, chain::Vector{String})
        (n in done || n in onpath) && return nothing
        push!(onpath, n)
        for m in sort!(collect(_referenced_var_names(defs()[n])))
            m == n && continue
            m == "t" && (reads_start = true)
            m in live && (reads_start = true)
            m in states && throw(_ic_reads_state_error(target, chain, m))
            (!known(m) && haskey(defs(), m)) && visit(target, m, String[chain; m])
        end
        delete!(onpath, n)
        push!(done, n)
        push!(order, n)
        return nothing
    end
    for (target, rhs) in rhss
        for m in sort!(collect(_referenced_var_names(rhs)))
            m == "t" && (reads_start = true)
            m in live && (reads_start = true)
            m in states && throw(_ic_reads_state_error(target, String[], m))
            # A name the scope already holds (a const array, a parameter) is
            # read as it is; only an observed is evaluated.
            known(m) && continue
            m in observed || continue
            haskey(defs(), m) && visit(target, m, String[m])
        end
    end

    steps = Tuple{String, ASTExpr, Union{Nothing, Vector{Int}}}[]
    reads = Set{String}()
    for (_, r) in rhss
        union!(reads, _referenced_var_names(r))
    end
    for n in order
        def = defs()[n]
        union!(reads, _referenced_var_names(def))
        v = model.variables[n]
        exts = nothing
        if _is_array_shape(v.shape)
            exts = _declared_shape_extents(v.shape, index_sets, derived_extents)
            exts === nothing && throw(
                TreeWalkError(
                    "E_TREEWALK_UNSUPPORTED_EQUATION",
                    "observed '$(n)', read by an `ic` right-hand side: its declared shape " *
                        "$(v.shape) does not resolve to extents"
                )
            )
        end
        push!(steps, (n, _ic_bind_start_time(def), exts))
    end
    arrays = Dict{String, Any}(k => base_arrays[k] for k in reads if haskey(base_arrays, k))
    fed = Dict{String, Any}()
    for (rawk, a) in param_arrays
        k = String(rawk)
        k in reads && (fed[k] = a)
    end
    unknowns = Set{String}()
    for (_, r) in scalar_ics, m in _referenced_var_names(r)
        v = get(model.variables, m, nothing)
        v !== nothing && v.type == UnknownVariable && push!(unknowns, m)
    end
    return _IcPlan(
        collect(Tuple{String, ASTExpr}, scalar_ics), bound_fields, params, arrays, fed,
        Set{String}(k for k in keys(fed) if scalar_param(k)), steps, unknowns,
        reads_start
    )
end

# The `ic` right-hand sides of `plan` evaluated at the start `t0`, with the
# data-fed values `data` there: `(scope, scalar ic values, field ics)`.
function _ic_evaluate(plan::_IcPlan, t0::Float64, data::AbstractDict)
    scalars = copy(plan.params)
    scalars[_IC_T0_NAME] = t0
    arrays = Dict{String, Any}()
    for (k, a) in plan.live
        at0 = get(data, k, a)
        if k in plan.scalar_live
            at0 isa AbstractArray && length(at0) == 1 && (scalars[k] = Float64(first(at0)))
        else
            haskey(plan.arrays, k) || (arrays[k] = at0)
        end
    end
    for (n, def, exts) in plan.order
        in_scope = _ic_field_arrays(plan.arrays, arrays)
        if exts !== nothing
            # Column-major, so the values reshape onto the field's own array.
            cells = vec(Vector{Int}[collect(Int, Tuple(I)) for I in CartesianIndices(Tuple(exts))])
            vals = evaluate_cellwise(
                def, cells; const_arrays = in_scope, params = scalars, t = t0
            )
            arrays[n] = reshape(vals, exts...)
        else
            scalars[n] = _ic_eval_scalar(def, scalars, in_scope, t0)
        end
    end
    s = _IcStart(t0, scalars, arrays, plan.reads_start)
    e = _fold_scalar_ics(plan.scalar_ics, plan.unknowns, s, plan.arrays)
    return s, e, plan.field_ics
end

# One scalar value in the start-of-run scope: the scalar evaluator when the
# expression reads no array of the scope, else the build-time field evaluator
# over the single cell of a rank-0 field.
function _ic_eval_scalar(e::ASTExpr, scalars, arrays, t0)
    reads_array = any(n -> !haskey(scalars, n) && haskey(arrays, n), _referenced_var_names(e))
    reads_array || return Float64(
        evaluate_expr(e, scalars)
    )
    return only(
        evaluate_cellwise(
            e, [Int[]]; const_arrays = arrays, params = scalars, t = t0
        )
    )
end

# ---- Stage: fold the scalar `ic` equations ----
# Each scalar `ic` right-hand side evaluated in the start-of-run scope (see
# `_ic_start_scope`, which has already refused a state read).
function _fold_scalar_ics(
        scalar_ics::Vector{Tuple{String, ASTExpr}}, unknowns::AbstractSet{String}, s::_IcStart, base_arrays::AbstractDict
    )
    eq_ics = Dict{String, Float64}()
    isempty(scalar_ics) && return eq_ics
    arrays = _ic_field_arrays(base_arrays, s)
    for (vn, rhs) in scalar_ics
        eq_ics[vn] = try
            _ic_eval_scalar(_ic_bind_start_time(rhs), s.scalars, arrays, s.t0)
        catch err
            # Running out of memory or stack is not a statement about this RHS,
            # and a `TreeWalkError` saying it is would be swallowed as an
            # ordinary decline further up (`_is_resource_error`).
            _is_resource_error(err) && rethrow()
            err isa UnboundVariableError && err.variable_name in unknowns &&
                throw(
                TreeWalkError(
                    "E_TREEWALK_UNSUPPORTED_EQUATION",
                    "ic($(vn)): the right-hand side reads the unknown " *
                        "'$(err.variable_name)', which has no value at the start of the " *
                        "run (esm-spec §11.4.2)"
                )
            )
            throw(
                TreeWalkError(
                    "E_TREEWALK_UNSUPPORTED_EQUATION",
                    "ic($(vn)) RHS must const-fold to a scalar for the " *
                        "tree-walk path ($(sprint(showerror, err)))"
                )
            )
        end
    end
    return eq_ics
end

# ---- Stage: enumerate declared-shape cells for equation-less array states ----
# A declared array STATE may carry only an `ic` and NO per-cell / whole-array
# `D` equation (a constant field held at its initial value, e.g. an ocean
# current pinned to 0). Such a state appears in no equation LHS and no per-cell
# ic key, so `_discover_array_cells` finds no cells for it — yet it needs one
# u0 slot per cell. Enumerate its cells from the declared shape's index-set
# extents (interval size / categorical cardinality / derived-set extent), the
# same registry the range machinery resolves. No-op for a state whose cells the
# equations already pin. Mutates `array_cells` in place.
function _enumerate_declared_array_cells!(
        array_cells, model::Model,
        index_sets::AbstractDict,
        derived_extents::AbstractDict, vi_vars::Set{String}
    )
    state_here = Set{String}(solver_unknowns(model))
    for (n, v) in model.variables
        (n in state_here && _is_array_shape(v.shape) && !(n in vi_vars)) || continue
        (haskey(array_cells, n) && !isempty(array_cells[n])) && continue
        exts = _declared_shape_extents(v.shape, index_sets, derived_extents)
        exts === nothing && continue
        cs = _DiscoveredCells()
        if all(>(0), exts)
            _cellset_push_box!(cs, ones(Int, length(exts)), exts, n)
        end
        array_cells[n] = cs
    end
    return nothing
end

# Per-dimension extents of a DECLARED shape, resolved against the document's
# index-set registry (interval `size` / categorical `members`) with the
# geometry- and value-invention-derived extents as the fallback. `nothing` when
# any axis does not resolve — the caller then leaves that variable alone.
function _declared_shape_extents(
        shape, index_sets::AbstractDict,
        derived_extents::AbstractDict
    )
    shape === nothing && return nothing
    exts = Int[]
    for s in shape
        ss = String(s)
        e = if haskey(index_sets, ss)
            is = index_sets[ss]
            if is.kind == "interval"
                is.size
            elseif is.kind == "categorical"
                _maybe(length, is.members)
            else
                get(derived_extents, ss, nothing)
            end
        else
            get(derived_extents, ss, nothing)
        end
        e === nothing && return nothing
        push!(exts, Int(e))
    end
    return exts
end

# ---- Stage: fold scoped-reference / array `ic` equations (spec §11.4.1) ----
# Now that each array state's cells are known, expand every deferred field-ic
# into per-element initial values, handed to `set(slot, value)` for each cell of
# the target (in lexicographic cell order). The RHS may be a LOADED FIELD (a
# `const_arrays` entry supplying the initial field over the lifted grid), a
# broadcast constant, or a coordinate expression. Folding here means the
# array-cell u0 seeding (and callers that don't override) pick these up exactly
# like a model-local `ic`. A target that resolves to no array cells, or an RHS
# the seed path cannot evaluate, is a hard error — a missing/unsupported scoped
# ic is never silently dropped.
function _fold_field_ics!(
        set, field_ics::Vector{Tuple{String, ASTExpr}}, array_cells, layout::StateLayout,
        param_scope::AbstractDict,
        const_arrays::AbstractDict
    )
    for (target, rhs) in field_ics
        cells = get(array_cells, target, nothing)
        (cells === nothing || isempty(cells)) && throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_EQUATION",
                "ic($(target)): scoped-reference target resolves to no array cells; the " *
                    "target must name a lifted/array state variable of the flattened system"
            )
        )
        blk = _layout_block(layout, target)
        put = (idxs, val) -> (blk === nothing || set(_block_slot(blk, idxs), val); nothing)
        # A coordinate expression is filled through the right-hand-side cascade
        # and emitted code, once (`_field_ic_fill`, setup_fill.jl); failing
        # that, a bare coordinate aggregate is compiled once and evaluated per
        # cell; failing both, the per-cell resolve+compile below. With the
        # construction-time compile-once forms off (`compiler = :interpreter`)
        # only the per-cell path runs.
        filled = _field_ic_fill(rhs, cells, param_scope, const_arrays)
        if filled !== nothing
            sf, buf = filled
            _record_rule!("ic($(target))", :equation, :setup_codegen)
            _foreach_cell_lex(idxs -> put(idxs, _setup_fill_at(sf, buf, idxs)), cells)
            continue
        end
        fast = _setup_compile_once_enabled() ?
            _try_field_ic_fastpath(rhs, param_scope, const_arrays) :
            nothing
        if fast !== nothing
            _record_rule!("ic($(target))", :equation, :setup_compiled)
            _foreach_cell_lex(idxs -> put(idxs, fast(idxs)), cells)
            continue
        end
        # The first two forms `_resolve_field_ic` serves do not depend on the
        # cell, so they are answered once for the whole field, under every
        # compiler: a LOADED FIELD is read straight out of its array, a
        # BROADCAST CONSTANT is evaluated once and filled. Only what neither
        # covers goes per cell, handed this verdict so no cell re-runs the
        # failed constant attempt.
        uniform = _field_ic_uniform(
            target, rhs, cells.rank, const_arrays; params = param_scope
        )
        hit = uniform[1]
        if hit !== nothing
            tier, val = hit
            _record_rule!("ic($(target))", :equation, tier)
            _foreach_cell_lex(idxs -> put(idxs, val(idxs)), cells)
            continue
        end
        # The per-cell seed needs a license. A strict compiler's refusal comes
        # after its probe has shown the coordinate-expression step SERVES the
        # first cell: a document no step can seed raises its own diagnostic,
        # which "your compiler cannot run this" would misname.
        seed_cell(access, idxs) =
            _resolve_field_ic(
            access, target, rhs, copy(idxs), const_arrays; params = param_scope, uniform = uniform
        )
        lic = _percell_evaluation_license(
            "ic($(target))",
            "the coordinate-expression initial-state seed", nothing;
            probe = pr -> seed_cell(pr, _first_cell_lex(cells))
        )
        _record_rule!("ic($(target))", :equation, :setup_percell)
        _foreach_cell_lex(idxs -> put(idxs, seed_cell(lic, idxs)), cells)
    end
    return nothing
end

# ---- Stage: initial-condition vector ----
# Seed u0 per state slot: an explicit `initial_conditions` entry wins, then an
# `ic`-equation value (scalar or per-cell field), then the variable's declared
# scalar default (an array cell falls back to its parent variable's default).
# `fold_fields!(set)` hands the field-`ic` values to `set(slot, value)`.
function _build_u0(
        model::Model, layout::StateLayout,
        initial_conditions::AbstractDict,
        eq_ics::Dict{String, Float64}, fold_fields!;
        unvalued::Union{Nothing, Vector{Int}} = nothing
    )
    _check_ic_keys(layout, initial_conditions)
    u0 = Vector{Float64}(undef, length(layout))
    # Slots with a starting value; the rest hold a 0.0 placeholder, reported
    # through `unvalued` (esm-spec §11.4).
    valued = trues(length(u0))
    scalar_names = _layout_scalar_names(layout)
    for (i, name) in enumerate(scalar_names)
        if haskey(initial_conditions, name)
            u0[i] = Float64(initial_conditions[name])
        elseif haskey(eq_ics, name)
            u0[i] = eq_ics[name]   # ic(var) = <value> equation
        else
            d = model.variables[name].default
            u0[i] = d === nothing ? 0.0 : Float64(d)
            d === nothing && (valued[i] = false)
        end
    end
    # Array cells: the parent variable's declared default first (a scalar
    # broadcasts to every cell, and INLINE ARRAY DATA (esm-spec §6.3) supplies
    # each cell's own value at its multi-index), then the field-`ic` values,
    # then the explicit initial conditions, so the later wins. A block whose
    # default cannot be written to every cell up front (inline data that does
    # not cover the block, or a value that does not convert) is resolved cell
    # by cell at the end, for the cells nothing else set, so a cell an `ic` or
    # an initial condition sets never reads the default.
    deferred = _ArrayBlock[]
    for b in _layout_blocks(layout)
        rng = (b.base):(b.base + b.len - 1)
        if !haskey(model.variables, b.name) || any(<(0), b.lo)
            push!(deferred, b)
            continue
        end
        d = model.variables[b.name].default
        if d === nothing
            fill!(view(u0, rng), 0.0)
            valued[rng] .= false
        elseif is_inline_array(d)
            inside = eltype(d) <: Real && ndims(d) == length(b.lo) &&
                all(dd -> b.lo[dd] >= 1 && b.hi[dd] <= size(d, dd), eachindex(b.lo))
            if inside
                k = b.base
                for I in CartesianIndices(_block_ranges(b))
                    u0[k] = Float64(d[I])
                    k += 1
                end
            else
                push!(deferred, b)
            end
        elseif d isa Real
            fill!(view(u0, rng), Float64(d))
        else
            push!(deferred, b)
        end
    end
    n_scalar = length(scalar_names)
    covered = isempty(deferred) ? nothing : falses(length(u0))
    mark = s -> (valued[s] = true; covered === nothing || (covered[s] = true); nothing)
    _overlay_array_ics!((s, v) -> (u0[s] = v; mark(s); nothing), layout, initial_conditions, fold_fields!)
    for b in deferred
        idxs = Vector{Int}(undef, length(b.lo))
        for s in (b.base):(b.base + b.len - 1)
            covered[s] && continue
            cell = _block_cell!(idxs, b, s)
            u0[s] = _cell_default(model, b.name, cell)
            valued[s] = any(<(0), cell) || !haskey(model.variables, b.name) ||
                model.variables[b.name].default !== nothing
        end
    end
    if unvalued !== nothing
        # Only an ODE state needs a starting value; an algebraic unknown the
        # build solves for takes it from its definition.
        ode = Set{String}(ode_states(model))
        for s in findall(!, valued)
            name = s <= n_scalar ? scalar_names[s] : _layout_block_name(layout, s)
            name in ode && push!(unvalued, s)
        end
    end
    return u0
end

# The array part of the initial-state precedence, over whatever the cells hold:
# the field-`ic` values (`fold_fields!(set)` hands each to `set(slot, value)`),
# then the caller's explicit array cells over them, each written through
# `set!(slot, value)`. Construction (`_build_u0`) and a re-seed at another start
# (`_IcReseed`) both apply it.
function _overlay_array_ics!(set!, layout::StateLayout, initial_conditions::AbstractDict, fold_fields!)
    fold_fields!((s, v) -> (s == 0 || set!(s, v); nothing))
    n_scalar = length(_layout_scalar_names(layout))
    _apply_ics_by_slot!(
        (s, v) -> (s > n_scalar && set!(s, Float64(v)); nothing), layout, initial_conditions
    )
    return nothing
end

# Every explicit `initial_conditions` key must name a state element of the
# layout (a scalar state, one array cell, or a whole array variable with a
# scalar value, which sets every cell); a key that names none is refused, as
# `esm_problem` refuses it for `u0`, never dropped. Whole-array inline data is
# checked where it is expanded (`_expand_inline_array_ics`).
_check_ic_keys(layout::StateLayout, ics::_InlineICs) = _check_ic_keys(layout, ics.explicit)
function _check_ic_keys(layout::StateLayout, ics::AbstractDict)
    for key in keys(ics)
        named = key isa AbstractString && (
            get(layout, key, 0) != 0 ||
                (ics[key] isa Real && _layout_block(layout, String(key)) !== nothing)
        )
        named && continue
        throw(
            TreeWalkError(
                "E_TREEWALK_UNKNOWN_STATE",
                "initial_conditions names unknown state element '$(key)'"
            )
        )
    end
    return nothing
end

# The array variable whose block holds state slot `s` (a slot past the scalars).
function _layout_block_name(layout::StateLayout, s::Int)
    i = _block_index_of_slot(layout, s)
    return i == 0 ? "" : layout.blocks[i].name
end

# One array cell's default value: its parent variable's declared default, or 0
# for a cell at a negative index (a ghost cell outside the declared grid) and
# for a block that names no variable.
function _cell_default(model::Model, name::String, idxs::Vector{Int})
    (any(<(0), idxs) || !haskey(model.variables, name)) && return 0.0
    d = model.variables[name].default
    d === nothing && return 0.0
    if is_inline_array(d)
        checkbounds(Bool, d, idxs...) || throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_SHAPE",
                "default[$(name)]: inline array data has shape $(size(d)), which " *
                    "does not cover cell $(Tuple(idxs)) (esm-spec §6.6.2)"
            )
        )
        return Float64(d[idxs...])
    end
    return Float64(d)
end

# ---- Stage: faq-valued initialization_equations → u0 ----
# When discretize() materializes an IC equation as a faq (coord-subst
# x→index(coord_x,i)), the aggregate is filled through the right-hand-side
# cascade and emitted code, once (`_init_equation_fill`, setup_fill.jl). A body
# the fill declines — one that reads a state, say — is compiled ONCE with the
# output indices kept symbolic — the same symbolic resolve the whole-array
# contraction tier uses, so a const or state read at an output index becomes a
# runtime gather — and then evaluated at each cell by setting the index
# counters. Only a body that will not resolve symbolically takes the per-cell
# substitute → resolve → compile, which a strict compiler refuses. The coord_<dim> const_array must be provided
# by the caller. Explicit initial_conditions values take precedence (already
# seeded in u0).
# Write the caller's u0 override `cu` (`esm_problem`'s `u0`, `BuildOptions`
# `caller_u0`) into `u0` before the initialization equations run, and return the
# slots it names (they keep the caller's value): an initialization equation
# reads the state the caller set (the Rust and Python front doors seed the same
# way). Nothing to do, and an empty set, without a caller u0 or without an
# initialization equation.
function _apply_caller_u0!(u0::Vector{Float64}, var_map, init_equations, cu)
    isempty(init_equations) && return Set{Int}()
    cu === nothing && return Set{Int}()
    if cu isa AbstractVector
        length(cu) == length(u0) || return Set{Int}()
        u0 .= cu
        return Set{Int}(eachindex(u0))
    end
    cu isa AbstractDict || return Set{Int}()
    # The slots the override names: those it writes over either of two
    # backgrounds (a NaN it writes shows against the zero one).
    a = fill(NaN, length(u0)); _apply_initial_conditions!(a, var_map, cu)
    b = zeros(length(u0));     _apply_initial_conditions!(b, var_map, cu)
    slots = Set{Int}(i for i in eachindex(u0) if !isnan(a[i]) || !iszero(b[i]))
    for i in slots
        u0[i] = b[i]
    end
    return slots
end

# Each `faq`-valued initialization equation (esm-spec §6.2) evaluated into the
# cells of `u0` it sets, against the state-only scope `cs`. A cell an explicit
# initial condition or the caller's `u0` names (`skip_slots`) keeps its value.
# Returns the slots the equations set: each now has a starting value
# (esm-spec §11.4).
function _seed_faq_init_u0!(
        u0::Vector{Float64}, init_equations::Vector{Equation},
        initial_conditions::AbstractDict, cs::_CompileScope, p::Union{Nothing, NamedTuple};
        skip_slots::Set{Int} = Set{Int}(), t0::Float64 = 0.0
    )
    seeded = Set{Int}()
    var_map = cs.var_map
    pp = isnothing(p) ? NamedTuple() : p
    for eq in init_equations
        eq.lhs isa VarExpr || continue
        var_name = (eq.lhs::VarExpr).name
        if !(
                eq.rhs isa OpExpr && _is_faq_op((eq.rhs::OpExpr).op) &&
                    !isempty(_output_idx_strings(eq.rhs::OpExpr))
            )
            # A scalar target (a seed of the initialization system,
            # build_ic_system.jl): its right-hand side compiled once and
            # evaluated once, at the start of the run.
            haskey(initial_conditions, var_name) && continue
            slot = get(var_map, var_name, 0)
            (slot == 0 || slot in skip_slots) && continue
            _record_rule!("init($(var_name))", :equation, :setup_compiled)
            u0[slot] = _eval_node(_compile_in(cs, _resolve_in(cs, eq.rhs)), u0, pp, t0)
            push!(seeded, slot)
            continue
        end
        rhs_op = eq.rhs::OpExpr
        idx_names = _output_idx_strings(rhs_op)
        ranges_dict = _ranges_dict(rhs_op)
        body = rhs_op.expr_body
        body === nothing && continue
        # An array-valued observed: a numeric evaluator refuses ⊕ = `or` there
        # (CONFORMANCE_SPEC §5.6.1).
        isempty(idx_names) ||
            _is_numeric_reducer(first(_aggregate_oplus_identity(rhs_op.semiring, rhs_op.reduce))) ||
            _throw_array_bool_and_or("or")
        # A POINTWISE filter (no contracted index): a cell whose predicate is
        # false is the semiring's 0̄ (esm-schema `filter`). It goes on the body as
        # the `ifelse` guard the array-equation path builds for it
        # (`_compile_faq_equation!`), so the compiled fill and every per-cell
        # form below compute it.
        if rhs_op.filter !== nothing && isempty(_contracted_index_names(ranges_dict, idx_names))
            _, zb = _aggregate_oplus_identity(rhs_op.semiring, rhs_op.reduce)
            body = OpExpr("ifelse", ASTExpr[rhs_op.filter, body, NumExpr(zb)])
            rhs_op = reconstruct(rhs_op; expr_body = body, filter = nothing)
        end
        range_iters = [collect(_expand_int_range(ranges_dict[n])) for n in idx_names]
        todo = Tuple{Any, Int}[]
        may_override = _ics_may_name_cells(initial_conditions)
        # A whole-variable key sets every cell, so the explicit value wins there too.
        haskey(initial_conditions, var_name) && continue
        cell = Vector{Int}(undef, length(idx_names))
        for idx_tuple in Iterators.product(range_iters...)
            for d in eachindex(cell)
                cell[d] = idx_tuple[d]
            end
            slot = _vm_slot(var_map, var_name, cell)
            slot == 0 && continue
            # explicit override wins
            may_override && haskey(initial_conditions, _cell_key(var_name, cell)) && continue
            slot in skip_slots && continue
            push!(todo, (idx_tuple, slot))
        end
        isempty(todo) && continue
        union!(seeded, (slot for (_, slot) in todo))
        rule = "init($(var_name))"
        # The compiled fill (setup_fill.jl): the aggregate filled through the
        # right-hand-side cascade and emitted code, once, over its own ranges.
        filled = _init_equation_fill(
            rhs_op, [_expand_int_range(ranges_dict[n]) for n in idx_names], cs, p;
            u0 = u0, target = var_name
        )
        if filled !== nothing
            sf, buf = filled
            _record_rule!(rule, :equation, :setup_codegen)
            for (idx_tuple, slot) in todo
                u0[slot] = _setup_fill_at(sf, buf, idx_tuple)
            end
            continue
        end
        # What is left walks a tree at every cell: the body compiled once and
        # walked per cell, or resolved and compiled per cell. Both are the
        # interpreter's, so both take a license. A strict compiler's refusal
        # follows a probe of the first cell: a body no form can evaluate — an
        # undeclared name, an out-of-range const gather — is the document's
        # error, not a compiler's refusal.
        percell(::_PerCellAccess, idx_tuple) = begin
            idx_exprs = Dict{String, ASTExpr}(
                idx_names[d] => IntExpr(Int64(idx_tuple[d]))
                    for d in 1:length(idx_names)
            )
            sub_body = _sub_preserving(body, idx_exprs)
            _eval_node(_compile_in(cs, _resolve_in(cs, sub_body)), u0, pp, t0)
        end
        lic = _percell_license(
            rule,
            "no compiled fill serves this faq-valued initialization equation " *
                "(a fill reads another state only as a unit-origin array or a " *
                "scalar, never its own target, and takes no join gate, filter or " *
                "contraction), and the forms left walk a tree at each of its " *
                "$(length(todo)) cell" * (length(todo) == 1 ? "" : "s") * ": one " *
                "compiled once, or one resolved and compiled per cell. That is a " *
                "tree walk per cell at construction time, which esm-libraries-spec " *
                "§2.5.10 puts under the same rule as the right-hand side. Build " *
                "with compiler=:interpreter to run it. " * _ONE_CELL_NOTE;
            probe = pr -> percell(pr, first(todo)[1])
        )
        # With the construction-time compile-once forms off the seed is the
        # per-cell reference, as the field-`ic` fast path is.
        once = _setup_compile_once_enabled() ?
            _compile_init_once(body, idx_names, cs) :
            nothing
        if once !== nothing
            _record_rule!(rule, :equation, :setup_compiled)
            _walk_init_once!(lic, u0, todo, once..., pp, t0)
            continue
        end
        _record_rule!(rule, :equation, :setup_percell)
        for (idx_tuple, slot) in todo
            u0[slot] = percell(lic, idx_tuple)
        end
    end
    return seeded
end

# The compile-once form of an initialization equation: its body compiled once
# against the output-index counters `refs`, walked at every cell of `todo`.
function _walk_init_once!(::_PerCellLicense, u0, todo, refs, node::_Node, pp, t0::Float64 = 0.0)
    for (idx_tuple, slot) in todo
        for d in eachindex(refs)
            refs[d][] = idx_tuple[d]
        end
        u0[slot] = _eval_node(node, u0, pp, t0)
    end
    return nothing
end

# `(refs, node)` — the output-index counters, in `idx_names` order, and the body
# compiled once against them — or `nothing` when the body does not resolve or
# compile with its indices symbolic.
function _compile_init_once(body::ASTExpr, idx_names::Vector{String}, cs::_CompileScope)
    isempty(idx_names) && return nothing
    got = _resolve_array_contraction_term(body, idx_names, String[], _resolve_ctx(cs))
    got isa _Decline && return nothing
    refs, _, resolved = got
    node = try
        _compile_in(cs, resolved)
    catch err
        # Only a document-level refusal is a decline (see resolve_loops.jl).
        err isa EarthSciASTError || rethrow()
        return nothing
    end
    return (refs, node)
end

# The build's initial state at another start of the run (`remake` with a new
# `tspan`, esm-spec §11.4.2): the `ic` right-hand sides evaluated there
# (`_IcPlan`), written over the state construction seeded, in the precedence
# `_build_u0` applies (a scalar `ic` where no explicit value names the slot, then
# `_overlay_array_ics!`). Holds what that needs and no more of the build.
struct _IcReseed{L, I}
    plan::_IcPlan
    # The seeded state at construction; a slot no `ic` sets keeps its value.
    u0::Vector{Float64}
    layout::L
    # Each scalar `ic` target the caller's initial conditions leave to it,
    # with its slot.
    scalar_slots::Vector{Tuple{String, Int}}
    initial_conditions::I
    # The cells, and the build's arrays, the array `ic` right-hand sides read.
    cells::Dict{String, Any}
    const_arrays::Dict{String, Any}
end

function _IcReseed(plan::_IcPlan, u0, layout, initial_conditions, array_cells, const_arrays)
    scalar_slots = Tuple{String, Int}[]
    for (i, name) in enumerate(_layout_scalar_names(layout))
        haskey(initial_conditions, name) && continue
        any(t -> first(t) == name, plan.scalar_ics) && push!(scalar_slots, (name, i))
    end
    cells = Dict{String, Any}()
    reads = Set{String}()
    for (target, rhs) in plan.field_ics
        haskey(array_cells, target) && (cells[target] = array_cells[target])
        union!(reads, _referenced_var_names(rhs))
    end
    arrays = Dict{String, Any}(
        String(k) => v for (k, v) in const_arrays if String(k) in reads
    )
    return _IcReseed(
        plan, copy(u0), layout, scalar_slots, initial_conditions, cells, arrays
    )
end

function (r::_IcReseed)(t0::Float64, data::AbstractDict)
    s, eqi, fics = _ic_evaluate(r.plan, t0, data)
    u0 = copy(r.u0)
    for (name, slot) in r.scalar_slots
        u0[slot] = eqi[name]
    end
    arrays = _ic_field_arrays(r.const_arrays, s)
    _overlay_array_ics!(
        (slot, v) -> (u0[slot] = v; nothing), r.layout, r.initial_conditions,
        set -> _fold_field_ics!(set, fics, r.cells, r.layout, s.scalars, arrays)
    )
    return u0
end
