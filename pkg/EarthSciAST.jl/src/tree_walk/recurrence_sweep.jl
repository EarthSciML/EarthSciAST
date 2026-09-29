# ============================================================
# Causal self-reference (recurrence) — the ordered sweep
# ============================================================
#
# esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19. An array observed `V` whose defining
# `faq` reads `index(V, …)` at a strictly earlier position along one output axis
# is not a set of independent cells: it is materialized by ONE ordered sweep, the
# recurrence axis outermost and ascending, the other output axes inside it in
# `output_idx` order (the last fastest), each cell PUBLISHED into the observed's
# buffer before the next is evaluated. Nothing here reorders, merges, fuses or
# threads cells (§5.19.2): the sweep is a loop over the cells in that order and
# nothing else.
#
# WHERE IT RUNS. A recurrence observed is always a materialized observed — a
# buffer block above the state in the extended value vector (build.jl,
# "FACTORED array observeds") — under every compiler, and its fill is a sweep
# instead of the fill equation the other materialized observeds compile. Every
# route that fills an observed buffer builds its sweep through
# `_compile_recurrence_sweep` and runs it through `_run_recurrence_sweeps!`: the
# per-call fill levels of the right-hand side (`_fill_obs_levels!`) and the
# observed program behind `observed_field`, the inline-test runner and the output
# sinks, with or without a state (observed_program.jl). That is the one
# implementation §5.19.3b asks for.
#
# THE BODY. The cell's value is the `faq` restricted to that cell (§4.3.1.1 point
# 2): its term resolved and compiled ONCE with every index symbolic — the output
# indices and the contracted ones as loop counters, exactly the term the
# whole-array contraction tier builds (`_resolve_array_contraction_term`) — and
# its reduction the same `_ACFold` that tier folds with: one accumulator seeded
# from the Float64 0̄, the contracted tuples in `Iterators.product` order (the
# first contracted index fastest), a filter as the term's `ifelse(filter, term,
# 0̄)` guard. A self-read in the term is a `_NK_RECUR_GATHER` (compile.jl): it
# reads the observed's own buffer, and only a cell the sweep has already
# published — any other position is `E_TREEWALK_RECUR_UNAVAILABLE`, never the
# zero ghost a state gather reads out of range (§5.19.4).
#
# TWO FORMS OF ONE PROGRAM. `interpreter` walks that body per cell with
# `_eval_node` (`_walk_recurrence!`). `native` emits the sweep as one generated
# function (`_try_codegen_recurrence`): the same loop, the body through the
# scalar-spine emitter `_cg_emit` (array_contraction.jl), whose every arm is the
# walker's arm written as an expression. The two therefore agree bit for bit, and
# the emitted build is independent of the number of cells: every extent, base
# and stride is run-time geometry (`_cg_geo!`), so two sizes of one document emit
# one function. A strict `native` whose emitter declines refuses the rule by name.
#
# PRECISION. The carried value is a cell of the variable, so it is stored at the
# variable's `element_type` at every cell (§5.19.3a). This binding evaluates only
# in binary64, so a recurrence whose variable declares another precision is
# refused rather than folded in binary64 (`_check_recurrence_precision`).

# One recurrence of one fill route: the compiled body and fold, the sweep
# geometry, and — under `native` — the generated function that runs it.
# Concretely parameterized so a level holds its sweeps in a tuple and every call
# is statically dispatched (`_fill_obs_levels!` explains why).
struct _RecurrenceSweep{F,TB}
    name::String
    gen::F                              # generated sweep, or `nothing` (walked)
    tabs::TB                            # its by-type tab containers
    body::_Node                         # the cell's term (no fold)
    fold::Union{Nothing,_ACFold}        # the cell's reduction, if it contracts
    out_refs::Vector{Base.RefValue{Int}}  # output-index counters, `output_idx` order
    cur::Base.RefValue{Int}             # sweep position of the cell being evaluated
    order::Vector{Int}                  # output axes, outermost first
    dims::Vector{Int}                   # the frame's extents (each axis is 1…dims[d])
    base::Int                           # slot of cell (1, …, 1) in the extended vector
    strides::Vector{Int}                # column-major strides of the buffer block
    ncells::Int
end

# The sweep order: the recurrence axis, then the others in `output_idx` order.
_recurrence_order(axis::Int, rank::Int) = vcat(axis, [d for d in 1:rank if d != axis])

# Weight of each axis in the sweep position (0-based), the last of `order` fastest.
function _recurrence_sweep_weights(order::Vector{Int}, dims::Vector{Int})
    w = zeros(Int, length(dims))
    acc = 1
    for j in length(order):-1:1
        w[order[j]] = acc
        acc *= dims[order[j]]
    end
    return w
end

# ---- Recognition at build ---------------------------------------------------

# The recurrence CANDIDATES among `defs`: array-shaped names whose own definition
# reads `index(name, …)` (CONFORMANCE_SPEC §5.19.5 — candidacy, not the
# well-foundedness verdict, which `_recurrence_axis` decides).
function _recurrence_names(defs::AbstractDict, array_shaped)
    out = Set{String}()
    for (name, def) in defs
        name in array_shaped || continue
        recurrence_self_reference_kind(name, def) === :indexed && push!(out, String(name))
    end
    return out
end

# Every self-read `index(name, …)` in `e` (its subscripts), in any
# expression-bearing field.
function _collect_self_read_args!(out::Vector{Vector{ASTExpr}}, e::ASTExpr, name::String)
    foreach_subexpr_once(e) do x
        (x isa OpExpr && x.op == "index" && !isempty(x.args) &&
         x.args[1] isa VarExpr && (x.args[1]::VarExpr).name == name) || return nothing
        push!(out, ASTExpr[x.args[2:end]...])
        return nothing
    end
    return out
end

# The recurrence axis of `name`'s definition `def` (a `faq` whose output indices
# are `idx_names`), decided the way the validator decides it (recurrence.jl) but
# against the RESOLVED ranges the build holds, which prove at least as much. A
# document that skipped `validate()` still cannot reach the sweep with a
# self-read that is not well founded: it is refused here with the validator's
# code.
function _recurrence_axis(name::String, def::OpExpr, idx_names::Vector{String})
    env = Dict{String,Tuple{Int,Int}}()
    ranges = _ranges_dict(def)
    for (sym, spec) in ranges
        (spec isa AbstractVector && _is_const_int_range(spec)) || continue
        r = _expand_int_range(spec)
        isempty(r) || (env[String(sym)] = (minimum(r), maximum(r)))
    end
    reads = Vector{ASTExpr}[]
    body = def.expr_body
    body === nothing || _collect_self_read_args!(reads, body, name)
    def.filter === nothing || _collect_self_read_args!(reads, def.filter, name)
    bad(msg) = throw(TreeWalkError(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
        "'$name': $msg (esm-spec §4.3.1.1)"))
    isempty(reads) && throw(TreeWalkError(ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
        "'$name' reads itself outside the body of its defining `faq`; a causal " *
        "self-read must sit in the body a cell evaluates (esm-spec §4.3.1.1)"))
    axis = 0
    for args in reads
        length(args) == length(idx_names) ||
            bad("a causal self-read supplies $(length(args)) indices but the frame " *
                "has $(length(idx_names)) axes")
        lagged = 0
        for (d, arg) in enumerate(args)
            aff = _recurrence_affine_in_sym(arg, idx_names[d], env)
            aff === nothing &&
                bad("index $(d-1) of a causal self-read is not affine in its frame " *
                    "symbol '$(idx_names[d])'")
            coef, konst = aff
            coef == 1 ||
                bad("index $(d-1) of a causal self-read carries its frame symbol with " *
                    "coefficient $coef, not 1")
            if konst !== nothing
                lag_lo, lag_hi = -konst[2], -konst[1]
                (lag_lo == 0 && lag_hi == 0) && continue
                lag_hi <= 0 &&
                    bad("a causal self-read names the cell being written, or a later " *
                        "one, on axis '$(idx_names[d])'")
            end
            lagged == 0 || bad("a causal self-read is offset on more than one axis")
            lagged = d
        end
        lagged == 0 && bad("a causal self-read is at the same cell on every axis")
        axis == 0 && (axis = lagged)
        axis == lagged ||
            bad("the causal self-reads disagree on the recurrence axis " *
                "('$(idx_names[axis])' and '$(idx_names[lagged])')")
    end
    return axis
end

# §5.19.3a: the carried value is stored at the variable's `element_type` at every
# cell. This binding evaluates in binary64 only (it has no binary32 arithmetic),
# so any other declared precision is refused by name — folding it in binary64
# would return a BETTER answer than the reference, the failure that section pins.
function _check_recurrence_precision(name::String, var)
    et = var === nothing ? nothing : var.element_type
    (et === nothing || et == "Float64") && return nothing
    throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_RECURRENCE",
        "'$name' is a recurrence (esm-spec §4.3.1.1) whose variable declares " *
        "element_type $(et). CONFORMANCE_SPEC §5.19.3a requires the carried value " *
        "to be rounded to that precision at every cell, with the body's arithmetic " *
        "in it (esm-spec §11.3.1); this binding evaluates in binary64 only, and " *
        "folding in binary64 would return a more precise answer than the document " *
        "defines. Refusing rather than returning it"))
end

# Replace every self-read `index(name, …)` in `e` by the `__recur_read` marker
# that `_compile` lowers to `_NK_RECUR_GATHER`, with the subscripts as its args.
function _mark_self_reads(e::ASTExpr, name::String, ref::_RecurGatherRef,
                          memo::IdDict{OpExpr,ASTExpr}=IdDict{OpExpr,ASTExpr}())
    e isa OpExpr || return e
    got = get(memo, e, nothing)
    got === nothing || return got
    r = if e.op == "index" && !isempty(e.args) && e.args[1] isa VarExpr &&
           (e.args[1]::VarExpr).name == name
        OpExpr("__recur_read",
               ASTExpr[_mark_self_reads(a, name, ref, memo) for a in e.args[2:end]];
               value=ref)
    else
        map_children(c -> _mark_self_reads(c, name, ref, memo), e)
    end
    memo[e] = r
    return r
end

# ---- Build: one recurrence → its sweep ---------------------------------------
#
# `name` is the materialized observed, `def` its definition, `dims` its frame
# (already checked to be the dense `1…dims[d]` box its buffer block holds), and
# the rest the resolve/compile context the fill route compiles against, with
# `var_map`/`array_var_info` the EXTENDED layout that carries the buffer block.
function _compile_recurrence_sweep(name::String, def::ASTExpr, dims::Vector{Int},
        var, resolved_obs::Dict{String,ASTExpr}, array_var_info,
        var_map::AbstractDict{String,Int}, const_registry::AbstractDict,
        pgather::AbstractDict, param_sym_set, reg_funcs)
    _check_recurrence_precision(name, var)
    (def isa OpExpr && _is_faq_op((def::OpExpr).op) &&
     (def::OpExpr).expr_body !== nothing) ||
        throw(TreeWalkError(ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "'$name' reads itself but its definition is not a `faq` over its axes; " *
            "a recurrence is one `faq` with the base case as an `ifelse` guard in " *
            "the body (esm-spec §4.3.1.1)"))
    dop = def::OpExpr
    idx_names = _output_idx_strings(dop)
    rank = length(idx_names)
    rank == length(dims) ||
        throw(TreeWalkError(ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "'$name': its defining `faq` has $rank output indices but the variable " *
            "has $(length(dims)) axes"))
    axis = _recurrence_axis(name, dop, idx_names)
    order = _recurrence_order(axis, rank)
    blk = _layout_block(var_map, name)
    blk === nothing && throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_RECURRENCE",
        "'$name' has no buffer block in this build's layout"))
    rg = _RecurGather(name, copy(dims), _recurrence_sweep_weights(order, dims),
                      blk.base, copy(blk.strides), Ref(0))

    # The cell body: the `faq`'s term, its filter as the term's guard, the
    # observeds this build inlines substituted, every self-read marked.
    ranges = _ranges_dict(dop)
    oplus, zerobar = _aggregate_oplus_identity(dop.semiring, dop.reduce)
    contract_names = _contracted_index_names(ranges, idx_names)
    term = dop.expr_body::ASTExpr
    dop.filter === nothing ||
        (term = OpExpr("ifelse", ASTExpr[dop.filter, term, NumExpr(zerobar)]))
    isempty(resolved_obs) || (term = _sub_preserving(term, resolved_obs))
    term = _mark_self_reads(term, name, _RecurGatherRef(rg))
    got = _resolve_array_contraction_term(term, idx_names, contract_names,
                                          array_var_info, var_map, const_registry, pgather)
    got === nothing && throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_RECURRENCE",
        "the body of recurrence '$name' does not resolve with its indices kept " *
        "symbolic (a read this build can only resolve at a concrete cell, such as a " *
        "live forcing buffer gathered at a loop index), so it has no sweep"))
    out_refs, contract_refs, resolved = got
    body = _compile(resolved, var_map, param_sym_set, reg_funcs)
    fold = nothing
    if !isempty(contract_names)
        contract_ranges = Vector{Any}[collect(ranges[n]) for n in contract_names]
        contract_const = Union{Vector{Int},Nothing}[
            _is_const_int_range(r) ? collect(_expand_int_range(r)) : nothing
            for r in contract_ranges]
        fold = if dop.join_gates !== nothing || any(c -> c === nothing, contract_const)
            # Per-cell admitted tuples, indexed by the cell's position in
            # `Iterators.product` order over the output ranges — dimension 1
            # fastest, which for a dense `1…dims` frame is the buffer offset.
            _array_contraction_table(contract_refs, idx_names,
                [collect(1:dims[d]) for d in 1:rank], contract_names,
                contract_ranges, contract_const, dop.join_gates, oplus, zerobar,
                const_registry)
        else
            _ACFold(contract_refs, Symbol(oplus), zerobar,
                    StepRange{Int,Int}[(r = _expand_int_range(c);
                                        first(r):step(r):last(r))
                                       for c in contract_ranges])
        end
    end
    ncells = prod(dims)
    walked = _RecurrenceSweep(name, nothing, (), body, fold, out_refs, rg.cur,
                              order, copy(dims), blk.base, copy(blk.strides), ncells)
    if _codegen_disabled()
        _compiler_is_strict() && _refuse_rule(name,
            "an ordered recurrence sweep (esm-spec §4.3.1.1) under this compiler has " *
            "only its walked form, which evaluates the body as a tree per cell")
        _note_recurrence!(:recurrence_walk)
        return walked
    end
    gen = _try_codegen_recurrence(walked)
    if gen isa Symbol
        _compiler_is_strict() && _refuse_rule(name,
            "the emitter for its ordered recurrence sweep (esm-spec §4.3.1.1) " *
            "declined ($(gen)), and the walked form evaluates the body as a tree per " *
            "cell. Build with compiler=:interpreter to run it")
        _note_recurrence!(:recurrence_walk)
        return walked
    end
    _note_recurrence!(:recurrence_sweep)
    return gen
end

# The cascade tally and the compiler report row for one recurrence: `native`'s
# emitted sweep is its own tier; the walked form is the interpreter's.
function _note_recurrence!(k::Symbol)
    lock(_CASCADE_TALLY_LOCK) do
        _CASCADE_TALLY[k] = get(_CASCADE_TALLY, k, 0) + 1
    end
    rec = _build_record()
    rec === nothing || (rec.tally[k] = get(rec.tally, k, 0) + 1)
    return nothing
end
_recurrence_tier(sw::_RecurrenceSweep) = sw.gen === nothing ? :interpreter : :recurrence_sweep

# ---- Run ---------------------------------------------------------------------

@inline _run_recurrence_sweeps!(::Tuple{}, ue, p, t, ::Type{T}) where {T} = nothing
@inline function _run_recurrence_sweeps!(sws::Tuple, ue, p, t, ::Type{T}) where {T}
    _run_recurrence_sweep!(sws[1], ue, p, t, T)
    return _run_recurrence_sweeps!(Base.tail(sws), ue, p, t, T)
end

@inline function _run_recurrence_sweep!(sw::_RecurrenceSweep{Nothing}, ue, p, t,
                                        ::Type{T}) where {T}
    _walk_recurrence!(sw, ue, p, t, T)
    return nothing
end
@inline function _run_recurrence_sweep!(sw::_RecurrenceSweep, ue, p, t,
                                        ::Type{T}) where {T}
    sw.gen(ue, p, t, sw.tabs)
    return nothing
end

# The walked form: the cells in sweep order, each evaluated and published before
# the next. Position `c` decodes into the output indices with the last axis of
# `order` fastest.
function _walk_recurrence!(sw::_RecurrenceSweep, ue, p, t, ::Type{T}) where {T}
    refs = sw.out_refs
    order = sw.order
    dims = sw.dims
    strides = sw.strides
    @inbounds for c in 0:(sw.ncells - 1)
        r = c
        for j in length(order):-1:1
            ax = order[j]
            refs[ax][] = 1 + r % dims[ax]
            r = div(r, dims[ax])
        end
        sw.cur[] = c
        off = 0
        for d in eachindex(refs)
            off += (refs[d][] - 1) * strides[d]
        end
        fold = sw.fold
        v = fold === nothing ? _eval_node(sw.body, ue, p, t, T) :
            _recur_fold(fold, off + 1, sw.body, ue, p, t, T)
        ue[sw.base + off] = v
    end
    return nothing
end

@inline _recur_oplus(op::Symbol, a, b) =
    op === :+ ? a + b : op === :* ? a * b : op === :max ? max(a, b) :
    op === :min ? min(a, b) : op === :or ? _or_combine(a, b) :
    throw(TreeWalkError("E_TREEWALK_ARRAYOP_UNKNOWN_REDUCE",
                        "no fold for the reduction '$op' in a recurrence body"))

# The cell's reduction, as `_cg_fold` (array_contraction.jl) emits it: one
# accumulator seeded from the Float64 0̄, the TABLE form's entries for the cell at
# product position `pc`, or the STATIC form's nested loops with the first
# contracted index innermost.
function _recur_fold(fold::_ACFold, pc::Int, body::_Node, ue, p, t, ::Type{T}) where {T}
    acc = fold.zerobar
    op = fold.op
    if _acfold_is_table(fold)
        @inbounds for e in fold.seg[pc]:(fold.seg[pc + 1] - 1)
            for r in eachindex(fold.refs)
                fold.refs[r][] = fold.cols[r][e]
            end
            acc = _recur_oplus(op, acc, _eval_node(body, ue, p, t, T))
        end
        return acc
    end
    return _recur_fold_static(fold, length(fold.refs), acc, body, ue, p, t, T)
end

function _recur_fold_static(fold::_ACFold, d::Int, acc, body::_Node, ue, p, t,
                            ::Type{T}) where {T}
    ref = fold.refs[d]
    @inbounds for k in fold.ranges[d]
        ref[] = k
        acc = d == 1 ? _recur_oplus(fold.op, acc, _eval_node(body, ue, p, t, T)) :
              _recur_fold_static(fold, d - 1, acc, body, ue, p, t, T)
    end
    return acc
end

# ---- native: the sweep as one generated function -----------------------------
#
# The walked form's loop written as code. `c` is the sweep position; the output
# indices decode from it exactly as `_walk_recurrence!` decodes them, and a
# self-read compares its own position against `c` (`_cg_recur_gather`). Returns a
# `_RecurrenceSweep` carrying the function, or the emitter's decline reason.
function _try_codegen_recurrence(sw::_RecurrenceSweep)
    ctx = _CGCtx(_codegen_node_budget())
    kc = _CGScalarCtx()
    cv = _cg_name(ctx, "c")
    kc.loops[sw.cur] = cv
    rank = length(sw.dims)
    isyms = Symbol[_cg_name(ctx, "oi") for _ in 1:rank]
    for d in 1:rank
        kc.loops[sw.out_refs[d]] = isyms[d]
    end
    rv = _cg_name(ctx, "r")
    seek = Any[:(local $rv = $cv)]
    for j in rank:-1:1
        ax = sw.order[j]
        len = _cg_geo!(ctx, sw.dims[ax], (sw.dims, ax))
        push!(seek, :(local $(isyms[ax]) = 1 + $rv % $len))
        push!(seek, :($rv = div($rv, $len)))
    end
    offv = _cg_name(ctx, "off")
    off = Any[0]
    for d in 1:rank
        st = _cg_geo!(ctx, sw.strides[d], (sw.strides, d), true)
        push!(off, :(($(isyms[d]) - 1) * $st))
    end
    push!(seek, :(local $offv = $(_cg_foldl(:+, off))))
    kvs = Symbol[]
    if sw.fold !== nothing
        for r in sw.fold.refs
            kv = _cg_name(ctx, "kk")
            kc.loops[r] = kv
            push!(kvs, kv)
        end
    end
    pcv = _cg_name(ctx, "pc")
    cell = try
        term = _cg_emit(ctx, kc, sw.body)
        sw.fold === nothing ? term : _cg_fold(ctx, sw.fold, pcv, kvs, term)
    catch err
        err isa _CodegenDecline || rethrow()
        return err.reason
    end
    base = _cg_geo!(ctx, sw.base, (sw, :base))
    ncells = _cg_geo!(ctx, sw.ncells, (sw, :ncells))
    ln = LineNumberNode(0, Symbol("ess-recurrence-sweep"))
    loop = quote
        $(ctx.geosink...)
        for $cv in 0:($ncells - 1)
            $(seek...)
            local $pcv = $offv + 1
            u[$base + $offv] = $cell
        end
    end
    ngrp = length(ctx.tab_types)
    grpstmts = Any[:(local $(_cg_grp_sym(g)) = tabs[$g]) for g in 1:ngrp]
    ex = Expr(:function, Expr(:tuple, :u, :p, :t, :tabs),
        Expr(:block, grpstmts...,
             :(local _cgT = _rhs_value_type(u, p, t)),
             ctx.helpers...,
             Expr(:macrocall, Symbol("@inbounds"), ln, loop),
             :(return nothing)))
    f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
        @__MODULE__, @__MODULE__, ex)
    tabpack = ntuple(g -> Vector{ctx.tab_types[g]}(ctx.tab_objs[g]), ngrp)
    return _RecurrenceSweep(sw.name, f, tabpack, sw.body, sw.fold, sw.out_refs, sw.cur,
                            sw.order, sw.dims, sw.base, sw.strides, sw.ncells)
end

# `_NK_RECUR_GATHER` (mirrors `_eval_recur_gather`): each subscript evaluated and
# range-checked in dimension order, the later ones not evaluated once one is out
# of the frame; then the read is served only from a cell whose sweep position is
# before the current one, `c`.
function _cg_recur_gather(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    rg = nd.payload::_RecurGather
    cv = get(kc.loops, rg.cur, nothing)
    cv === nothing && throw(_CodegenDecline(:recur_cursor_out_of_scope))
    rgv = _cg_name(ctx, "rga")
    base = _cg_geo!(ctx, rg.base, (rg, :base))
    inner = _cg_recur_gather_dim(ctx, kc, nd, rg, rgv, cv, 1, Any[0], Any[base], Symbol[])
    return Expr(:let, Expr(:block, :($rgv = $(_cg_tab!(ctx, rg)))), Expr(:block, inner))
end

function _cg_recur_gather_dim(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node, rg::_RecurGather,
                              rgv::Symbol, cv::Symbol, d::Int, ord::Vector{Any},
                              slot::Vector{Any}, subs::Vector{Symbol})
    children = nd.children
    if d > length(children)
        return :($(_cg_foldl(:+, ord)) < $cv ? u[$(_cg_foldl(:+, slot))] :
                 _recur_unavailable_at($rgv, $cv, Int[$(subs...)]))
    end
    sd = _cg_name(ctx, "rgs")
    dim = _cg_geo!(ctx, rg.dims[d], (rg.dims, d))
    w = _cg_geo!(ctx, rg.sweep_w[d], (rg.sweep_w, d), true)
    st = _cg_geo!(ctx, rg.strides[d], (rg.strides, d), true)
    nsubs = vcat(subs, sd)
    nxt = _cg_recur_gather_dim(ctx, kc, nd, rg, rgv, cv, d + 1,
                               push!(copy(ord), :(($sd - 1) * $w)),
                               push!(copy(slot), :(($sd - 1) * $st)), nsubs)
    return Expr(:let,
        Expr(:block, :($sd = round(Int, $(_cg_emit(ctx, kc, children[d]))))),
        Expr(:block, :((1 <= $sd <= $dim) ? $nxt :
                       _recur_unavailable_at($rgv, $cv, Int[$(nsubs...)]))))
end
