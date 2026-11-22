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
# buffer block above the state in the extended value vector (build_classify.jl,
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
# whole-array contraction tier builds (`_compile_cell_program`) — and
# its reduction the same `_ACFold` that tier folds with: one accumulator seeded
# from the Float64 0̄, the contracted tuples in `Iterators.product` order (the
# first contracted index fastest), a filter as the term's `ifelse(filter, term,
# 0̄)` guard. A self-read in the term is a `_NK_RECUR_GATHER` (node.jl): it
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
# geometry, and how it runs — `gen`, the generated function (`native`), or the
# `_PerCellLicense` the walked form needs (`interpreter`; compiler.jl), so a
# strict plan cannot build a sweep that walks. `nothing` marks the draft the
# emitter reads, which has no run method. Concretely parameterized so a level
# holds its sweeps in a tuple and every call is statically dispatched
# (`_fill_obs_levels!` explains why).
struct _RecurrenceSweep{F, TB}
    name::String
    gen::F                              # generated sweep, license (walked), or draft
    tabs::TB                            # its by-type tab containers
    body::_Node                         # the cell's term (no fold)
    fold::Union{Nothing, _ACFold}        # the cell's reduction, if it contracts
    out_refs::Vector{Base.RefValue{Int}}  # output-index counters, `output_idx` order
    cur::Base.RefValue{Int}             # sweep position of the cell being evaluated
    order::Vector{Int}                  # output axes, outermost first
    lo::Vector{Int}                     # the box's first cell (each axis is lo[d]…lo[d]+dims[d]-1)
    dims::Vector{Int}                   # the box's extents
    base::Int                           # slot of cell lo in the extended vector
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
        recurrence_self_reference_kind(name, def; templates = _build_templates()) === :indexed && push!(out, String(name))
    end
    return out
end

# Every self-read `index(name, …)` in `e` (its subscripts), in any
# expression-bearing field.
function _collect_self_read_args!(out::Vector{Vector{ASTExpr}}, e::ASTExpr, name::String)
    foreach_subexpr_once(e) do x
        (
            x isa OpExpr && x.op == "index" && !isempty(x.args) &&
                x.args[1] isa VarExpr && (x.args[1]::VarExpr).name == name
        ) || return nothing
        push!(out, ASTExpr[x.args[2:end]...])
        return nothing
    end
    return out
end

# The recurrence axis of `name`'s definition `def` (a `faq` whose output indices
# are `idx_names`): its self-reads decided by the validator's own rules
# (`_recurrence_reads_verdict`, recurrence.jl), against the RESOLVED ranges the
# build holds, which prove at least as much. A document that skipped
# `validate()` still cannot reach the sweep with a self-read that is not well
# founded: it is refused here with the validator's code.
#
# Returns `(axis, max_lag, lag_proven)` (see `_RecurrenceAxis`). The lag bound
# and whether every read was proved strictly earlier are reported, never used
# to evaluate: an unproven read is ruled out at run time by the fail-closed
# self-read.
function _recurrence_axis(name::String, def::OpExpr, idx_names::Vector{String})
    env = Dict{String, Tuple{Int, Int}}()
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
    isempty(reads) && throw(
        TreeWalkError(
            ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "'$name' reads itself outside the body of its defining `faq`; a causal " *
                "self-read must sit in the body a cell evaluates (esm-spec §4.3.1.1)"
        )
    )
    noenv = Dict{String, Tuple{Int, Int}}()
    v = _recurrence_reads_verdict(
        (_RecurrenceSelfRead(args, noenv, false, name) for args in reads), name, idx_names, env;
        member_sym = RECURRENCE_MEMBER_SYM
    )
    v isa _RecurrenceProblem && throw(_recurrence_build_error(v, name))
    return v.axis, v.max_lag, v.lag_proven
end

# The build's error for problem `p` in the definition of `name`, with the
# validator's code (`_recurrence_problem_code`) and, outside the two short
# forms below, the validator's message.
function _recurrence_build_error(p::_RecurrenceProblem, name::AbstractString)
    k = p.kind
    idx_names = p.idx_names
    code = _recurrence_problem_code(p)
    k === :lag && return TreeWalkError(code, _lag_defect_message(p.lag::_LagDefect, name))
    k === :same_cell && return TreeWalkError(
        code, "'$name': a causal self-read is at the same cell on every axis (esm-spec §4.3.1.1)"
    )
    k === :axes_disagree && return TreeWalkError(
        code,
        "'$name': the causal self-reads disagree on the recurrence axis " *
            "('$(idx_names[p.axis])' and '$(idx_names[p.axis2])') (esm-spec §4.3.1.1)"
    )
    return TreeWalkError(code, first(_recurrence_problem_message(p, name)))
end

# What `BuildInspection.recurrences` reports for the recurrence `name`, read off
# its compiled sweep `sw` and its definition `def`. Called only once the sweep
# has compiled, so `_recurrence_axis` has already accepted `def` and cannot
# throw here: filling the inspection never decides which error a build raises.
# The extents are the sweep's own box, the cells it publishes.
function _recurrence_info(name::String, def::OpExpr, sw::_RecurrenceSweep)
    axis, max_lag, lag_proven = _recurrence_axis(name, def, _output_idx_strings(def))
    return RecurrenceInfo(
        name, _output_idx_strings(def)[axis], max_lag, lag_proven,
        sw.dims[axis], sw.ncells
    )
end

# §5.19.3a: the carried value is stored at the variable's `element_type` at every
# cell. This binding evaluates in binary64 only (it has no binary32 arithmetic),
# so any other declared precision is refused by name — folding it in binary64
# would return a BETTER answer than the reference, the failure that section pins.
function _check_recurrence_precision(name::String, var)
    et = var === nothing ? nothing : var.element_type
    (et === nothing || et == "Float64") && return nothing
    throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_RECURRENCE",
            "'$name' is a recurrence (esm-spec §4.3.1.1) whose variable declares " *
                "element_type $(et). CONFORMANCE_SPEC §5.19.3a requires the carried value " *
                "to be rounded to that precision at every cell, with the body's arithmetic " *
                "in it (esm-spec §11.3.1); this binding evaluates in binary64 only, and " *
                "folding in binary64 would return a more precise answer than the document " *
                "defines. Refusing rather than returning it"
        )
    )
end

# Replace every self-read `index(name, …)` in `e` by the `__recur_read` marker
# that `_compile` lowers to `_NK_RECUR_GATHER`, with the subscripts as its args.
function _mark_self_reads(
        e::ASTExpr, name::String, ref::_Lowered,
        memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}()
    )
    e isa OpExpr || return e
    got = get(memo, e, nothing)
    got === nothing || return got
    r = if e.op == "index" && !isempty(e.args) && e.args[1] isa VarExpr &&
            (e.args[1]::VarExpr).name == name
        OpExpr(
            "__recur_read",
            ASTExpr[_mark_self_reads(a, name, ref, memo) for a in e.args[2:end]];
            value = ref
        )
    else
        map_children(c -> _mark_self_reads(c, name, ref, memo), e)
    end
    memo[e] = r
    return r
end

# ---- Build: one recurrence → its sweep ---------------------------------------
#
# `name` is the materialized observed, `def` its definition, `dims` its frame
# (each axis `1…dims[d]`), and `cs` the scope the fill route compiles against,
# whose layout is the EXTENDED one that carries the buffer block.
#
# The block is the whole frame except in a range-restricted program
# (src/range/), where it may cover only the cells the program needs.
# The sweep runs over the block: every self-read has lag 0 off the recurrence
# axis, so off that axis a cell of the block reads only cells of the block, and
# a block starting at position 1 of the recurrence axis (the whole axis, or a
# prefix of it) holds every earlier cell a self-read can name. A restriction
# that would drop earlier positions of the recurrence axis is refused by the
# restriction's own analysis, once (`_refuse_cut_recurrences` for a decomposed
# axis; a lane program refuses the self-read that leaves its lane). Should a
# block ever start later anyway, nothing reads a value it does not hold: the
# first position's self-read lands outside the box and faults
# (`E_TREEWALK_RECUR_UNAVAILABLE`, `_eval_recur_gather`).
function _compile_recurrence_sweep(
        name::String, def::ASTExpr, dims::Vector{Int},
        var, resolved_obs::Dict{String, ASTExpr}, cs::_CompileScope
    )
    var_map = cs.var_map
    _check_recurrence_precision(name, var)
    (
        def isa OpExpr && _is_faq_op((def::OpExpr).op) &&
            (def::OpExpr).expr_body !== nothing
    ) ||
        throw(
        TreeWalkError(
            ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "'$name' reads itself but its definition is not a `faq` over its axes; " *
                "a recurrence is one `faq` with the base case as an `ifelse` guard in " *
                "the body (esm-spec §4.3.1.1)"
        )
    )
    dop = def::OpExpr
    idx_names = _output_idx_strings(dop)
    rank = length(idx_names)
    rank == length(dims) ||
        throw(
        TreeWalkError(
            ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "'$name': its defining `faq` has $rank output indices but the variable " *
                "has $(length(dims)) axes"
        )
    )
    axis, _, _ = _recurrence_axis(name, dop, idx_names)
    order = _recurrence_order(axis, rank)
    blk = _layout_block(var_map, name)
    blk === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_RECURRENCE",
            "'$name' has no buffer block in this build's layout"
        )
    )
    lo = copy(blk.lo)
    ext = Int[blk.hi[d] - blk.lo[d] + 1 for d in eachindex(lo)]
    rg = _RecurGather(
        name, lo, ext, _recurrence_sweep_weights(order, ext),
        blk.base, copy(blk.strides), Ref(0)
    )

    # The cell program: the `faq`'s term, its filter as the term's guard, the
    # observeds this build inlines substituted, every self-read marked, and its
    # fold; the table form indexes each cell by its position in
    # `Iterators.product` order over the block's output ranges — dimension 1
    # fastest, which for the dense block is the buffer offset.
    ranges = _ranges_dict(dop)
    oplus, zerobar = _aggregate_oplus_identity(dop.semiring, dop.reduce)
    contract_names = _contracted_index_names(ranges, idx_names)
    contract_ranges = Vector{Any}[_as_type(Vector{Any}, collect(ranges[n])) for n in contract_names]
    contract_const = Union{Vector{Int}, Nothing}[
        _is_const_int_range(r) ? collect(_expand_int_range(r)) : nothing
            for r in contract_ranges
    ]
    prog = _compile_cell_program(
        dop.expr_body::ASTExpr, idx_names, [collect(lo[d]:blk.hi[d]) for d in 1:rank],
        contract_names, contract_ranges, contract_const, dop.join_gates, dop.filter,
        oplus, zerobar,
        (; resolved_obs, cs);
        prepare = t -> _mark_self_reads(t, name, _Lowered(_NK_RECUR_GATHER, rg))
    )
    prog isa _Decline && throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_RECURRENCE",
            "the body of recurrence '$name' does not resolve with its indices kept " *
                "symbolic (a read this build can only resolve at a concrete cell, such as a " *
                "live forcing buffer gathered at a loop index), so it has no sweep: " *
                prog.detail
        )
    )
    body, fold, out_refs = prog.body, prog.fold, prog.out_refs
    ncells = prod(ext)
    draft = _RecurrenceSweep(
        name, nothing, (), body, fold, out_refs, rg.cur,
        order, lo, ext, blk.base, copy(blk.strides), ncells
    )
    if _codegen_disabled()
        return _walked_recurrence(
            draft, _percell_license(
                name,
                "an ordered recurrence sweep (esm-spec §4.3.1.1) under this compiler has " *
                    "only its walked form, which evaluates the body as a tree per cell"
            )
        )
    end
    gen = _try_codegen_recurrence(draft)
    if gen isa _Decline
        return _walked_recurrence(
            draft, _percell_license(
                name,
                "the emitter for its ordered recurrence sweep (esm-spec §4.3.1.1) " *
                    "declined ($(sprint(showerror, gen))), and the walked form evaluates the body as a tree per " *
                    "cell. Build with compiler=:interpreter to run it"
            )
        )
    end
    _tally_cascade!(:recurrence_sweep)
    return gen
end

# The walked form of a drafted sweep: the interpreter's, so it carries a license.
function _walked_recurrence(d::_RecurrenceSweep{Nothing}, lic::_PerCellLicense)
    _tally_cascade!(:recurrence_walk)
    return _RecurrenceSweep(
        d.name, lic, (), d.body, d.fold, d.out_refs, d.cur,
        d.order, d.lo, d.dims, d.base, d.strides, d.ncells
    )
end

# The compiler report row for one recurrence: `native`'s emitted sweep is its
# own tier; the walked form is the interpreter's.
_recurrence_tier(sw::_RecurrenceSweep) =
    sw.gen isa _PerCellLicense ? :interpreter : :recurrence_sweep

# ---- Run ---------------------------------------------------------------------

@inline _run_recurrence_sweeps!(::Tuple{}, ue, p, t, ::Type{T}) where {T} = nothing
@inline function _run_recurrence_sweeps!(sws::Tuple, ue, p, t, ::Type{T}) where {T}
    _run_recurrence_sweep!(sws[1], ue, p, t, T)
    return _run_recurrence_sweeps!(Base.tail(sws), ue, p, t, T)
end

@inline function _run_recurrence_sweep!(
        sw::_RecurrenceSweep{_PerCellLicense}, ue, p, t,
        ::Type{T}
    ) where {T}
    _walk_recurrence!(sw, ue, p, t, T)
    return nothing
end
@inline function _run_recurrence_sweep!(
        sw::_RecurrenceSweep, ue, p, t,
        ::Type{T}
    ) where {T}
    sw.gen(ue, p, t, sw.tabs)
    return nothing
end

# The walked form: the cells in sweep order, each evaluated and published before
# the next. Position `c` decodes into the output indices with the last axis of
# `order` fastest.
function _walk_recurrence!(
        sw::_RecurrenceSweep{_PerCellLicense}, ue, p, t,
        ::Type{T}
    ) where {T}
    refs = sw.out_refs
    order = sw.order
    lo = sw.lo
    dims = sw.dims
    strides = sw.strides
    @inbounds for c in 0:(sw.ncells - 1)
        r = c
        for j in length(order):-1:1
            ax = order[j]
            refs[ax][] = lo[ax] + r % dims[ax]
            r = div(r, dims[ax])
        end
        sw.cur[] = c
        off = 0
        for d in eachindex(refs)
            off += (refs[d][] - lo[d]) * strides[d]
        end
        fold = sw.fold
        v = fold === nothing ? _eval_node(sw.body, ue, p, t, T) :
            _recur_fold(fold, off + 1, sw.body, ue, p, t, T)
        ue[sw.base + off] = v
    end
    return nothing
end

@inline _recur_oplus(op::Symbol, a, b) = _oplus(op, a, b)

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

function _recur_fold_static(
        fold::_ACFold, d::Int, acc, body::_Node, ue, p, t,
        ::Type{T}
    ) where {T}
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
# `_RecurrenceSweep` carrying the function, or the emitter's `_Decline`.
function _try_codegen_recurrence(sw::_RecurrenceSweep)
    ctx = _CGFunction(_codegen_node_budget())
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
        lo = _cg_geo!(ctx, sw.lo[ax], (sw.lo, ax))
        _cg_decode_digit!(seek, rv, len) do q
            Any[:(local $(isyms[ax]) = $(_cg_axis_index(lo, q, nothing)))]
        end
    end
    offv = _cg_name(ctx, "off")
    off = Any[0]
    for d in 1:rank
        st = _cg_geo!(ctx, sw.strides[d], (sw.strides, d), true)
        lo = _cg_geo!(ctx, sw.lo[d], (sw.lo, d))
        push!(off, :(($(isyms[d]) - $lo) * $st))
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
        err isa _Decline || rethrow()
        return err
    end
    base = _cg_geo!(ctx, sw.base, (sw, :base))
    ncells = _cg_geo!(ctx, sw.ncells, (sw, :ncells))
    ln = LineNumberNode(0, Symbol("ess-recurrence-sweep"))
    loop = quote
        $(ctx.nest.sink...)
        for $cv in 0:($ncells - 1)
            $(seek...)
            local $pcv = $offv + 1
            u[$base + $offv] = $cell
        end
    end
    f, fns = _cg_finish(ctx, (:u, :p, :t, :tabs), Expr(:macrocall, Symbol("@inbounds"), ln, loop))
    tabpack = _cg_tabpack(ctx, fns)
    return _RecurrenceSweep(
        sw.name, f, tabpack, sw.body, sw.fold, sw.out_refs, sw.cur,
        sw.order, sw.lo, sw.dims, sw.base, sw.strides, sw.ncells
    )
end

# `_NK_RECUR_GATHER` (mirrors `_eval_recur_gather`): each subscript evaluated and
# range-checked in dimension order, the later ones not evaluated once one is out
# of the frame; then the read is served only from a cell whose sweep position is
# before the current one, `c`.
function _cg_recur_gather(ctx::_CGFunction, kc::_CGScalarCtx, nd::_Node)
    rg = nd.payload::_RecurGather
    cv = get(kc.loops, rg.cur, nothing)
    cv === nothing && _decline(:loopvar_out_of_scope, "the recurrence cursor")
    rgv = _cg_name(ctx, "rga")
    base = _cg_geo!(ctx, rg.base, (rg, :base))
    inner = _cg_recur_gather_dim(ctx, kc, nd, rg, rgv, cv, 1, Any[0], Any[base], Symbol[])
    return Expr(:let, Expr(:block, :($rgv = $(_cg_tab!(ctx, rg)))), Expr(:block, inner))
end

function _cg_recur_gather_dim(
        ctx::_CGFunction, kc::_CGScalarCtx, nd::_Node, rg::_RecurGather,
        rgv::Symbol, cv::Symbol, d::Int, ord::Vector{Any},
        slot::Vector{Any}, subs::Vector{Symbol}
    )
    children = nd.children
    if d > length(children)
        return :(
            $(_cg_foldl(:+, ord)) < $cv ? u[$(_cg_foldl(:+, slot))] :
                _recur_unavailable_at($rgv, $cv, Int[$(subs...)])
        )
    end
    sd = _cg_name(ctx, "rgs")
    lo = _cg_geo!(ctx, rg.lo[d], (rg.lo, d))
    hi = _cg_geo!(ctx, rg.lo[d] + rg.dims[d] - 1, (rg, :hi, d))
    w = _cg_geo!(ctx, rg.sweep_w[d], (rg.sweep_w, d), true)
    st = _cg_geo!(ctx, rg.strides[d], (rg.strides, d), true)
    nsubs = vcat(subs, sd)
    nxt = _cg_recur_gather_dim(
        ctx, kc, nd, rg, rgv, cv, d + 1,
        push!(copy(ord), :(($sd - $lo) * $w)),
        push!(copy(slot), :(($sd - $lo) * $st)), nsubs
    )
    return Expr(
        :let,
        Expr(:block, :($sd = round(Int, $(_cg_emit(ctx, kc, children[d]))))),
        Expr(
            :block, :(
                ($lo <= $sd <= $hi) ? $nxt :
                    _recur_unavailable_at($rgv, $cv, Int[$(nsubs...)])
            )
        )
    )
end
