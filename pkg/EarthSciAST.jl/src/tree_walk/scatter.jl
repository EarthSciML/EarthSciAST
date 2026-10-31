# One-pass scatter for an equality filter on an output index (esm-spec §4.3.1).
#
# A `faq` whose `filter` is a conjunction holding, for one or more output
# indices `j_d`, a conjunct `j_d == e_d` (or `e_d == j_d`) where `e_d` reads
# none of the node's output indices,
#
#     out[j] = ⊕_{i : i + 1 == j} a[i]·λ[i]
#
# admits each point of the contracted box into exactly one output cell, the
# one `(e_1, …)` names. Folded as written, every output cell tests every point
# of the contracted box, O(cells × points). Here the build makes ONE pass over
# the contracted box per combination of the free (unpinned) output indices and
# folds each point's term into the cell its keys name.
#
# THE ORDER IS THE NAIVE ONE. The pass visits the contracted box in the order
# the per-cell expansion does (`_foreach_aggregate_term`: `Iterators.product`
# over the contracted iterators, the first sorted name fastest), and a node
# with an equality conjunct is never a scan, so it folds ascending. Each output
# cell then receives exactly the terms the naive fold admits, in the same order
# and the same association, so the result is the interpreter's bit for bit
# under every ⊕, `max` and `min` with NaNs included. A point the naive fold
# guards out contributes the identity there and nothing here, which is the
# same value: a `+` accumulator seeded with +0.0 is never -0.0, `x * 1 == x`,
# and a `max`/`min` identity never beats the accumulator.
#
# TWO FORMS.
#   * STATIC keys (every `e_d` reads only index names, literals, folded
#     metaparameters and `const` gathers): the scatter map is a function of the
#     box alone. The build evaluates it once, sorts the admitted points by
#     output cell stably (so each cell keeps them in visit order), and hands the
#     whole-array nest the result as its TABLE fold (`_ACFold` with `seg` /
#     `cols`). The nest then folds each cell over its own entries, so it can
#     chunk over cells and stays bit-identical.
#   * RUN-TIME keys (an `e_d` reads a state, a parameter, an observed or `t`):
#     the generated pass (`_try_codegen_scatter`) evaluates each key per point
#     on every call. It chunks only over the free output indices, each chunk
#     owning the cells with its free coordinates, and keeps the pinned pass
#     sequential in visit order.
#
# What it does not take falls through to the tiers below it unchanged: a join
# gate, a ragged contracted bound, a ⊕ other than +, *, max, min, or a term or
# key that does not resolve with its indices symbolic.

# The equality conjuncts that pin output indices, and the conjuncts left over.
struct _ScatterSpec
    pins::Vector{Tuple{Int, ASTExpr}}   # (position in the output indices, its key `e`)
    rem::Union{Nothing, ASTExpr}        # the remaining conjuncts, in order, or `nothing`
end

# The conjuncts of `f`, nested `and`s flattened in order.
function _scatter_conjuncts!(out::Vector{ASTExpr}, f::ASTExpr)
    if f isa OpExpr && (f::OpExpr).op == "and" && (f::OpExpr).expr_body === nothing
        for a in (f::OpExpr).args
            _scatter_conjuncts!(out, a)
        end
    else
        push!(out, f)
    end
    return out
end

# A `_ScatterSpec` when the faq qualifies (see the header), else `nothing`.
function _detect_equality_scatter(
        idx_names::Vector{String}, contract_names::Vector{String}, contract_ranges,
        contract_const, agg_gates, agg_filter, oplus::String
    )
    agg_filter === nothing && return nothing
    agg_gates === nothing || return nothing
    isempty(contract_names) && return nothing
    isempty(idx_names) && return nothing
    (oplus == "+" || oplus == "*" || oplus == "max" || oplus == "min") || return nothing
    conj = _scatter_conjuncts!(ASTExpr[], agg_filter)
    pins = Tuple{Int, ASTExpr}[]
    rest = ASTExpr[]
    pinned(pos) = any(p -> p[1] == pos, pins)
    reads_out(e) = any(n -> n in idx_names, _referenced_var_names(e))
    function pin_of(x, e)
        x isa VarExpr || return nothing
        at = findfirst(==((x::VarExpr).name), idx_names)
        (at === nothing || pinned(at) || reads_out(e)) && return nothing
        return at
    end
    for c in conj
        if c isa OpExpr && (c::OpExpr).op == "==" && length((c::OpExpr).args) == 2
            a, b = (c::OpExpr).args
            pos = pin_of(a, b)
            if pos !== nothing
                push!(pins, (pos, b))
                continue
            end
            pos = pin_of(b, a)
            if pos !== nothing
                push!(pins, (pos, a))
                continue
            end
        end
        push!(rest, c)
    end
    isempty(pins) && return nothing
    # A ragged contracted range is laid out per combination of the FREE output
    # indices, so its bound must read no pinned one.
    pinned_names = Set{String}(idx_names[p] for (p, _) in pins)
    for (d, c) in enumerate(contract_const)
        c === nothing || continue
        for x in contract_ranges[d]
            x isa ASTExpr || continue
            any(n -> n in pinned_names, _referenced_var_names(x)) && return nothing
        end
    end
    rem = isempty(rest) ? nothing :
        length(rest) == 1 ? rest[1] : OpExpr("and", rest)
    return _ScatterSpec(pins, rem)
end

# Whether a compiled key reads only build-time values: literals, loop counters
# and `const` gathers of them, combined by plain operators.
function _scatter_static_node(n::_Node)
    k = n.kind
    k === _NK_LITERAL && return true
    k === _NK_LOOPVAR && return true
    (k === _NK_CONST_GATHER || k === _NK_OP) || return false
    return all(_scatter_static_node, n.children)
end

# A key's value as the `Float64` the naive filter compares the output index
# with (`==` on a dual number compares its value).
@inline _scatter_key(x::Float64) = x
@inline function _scatter_key(x::Real)
    v = _value(x)
    return v === x ? Float64(x) : _scatter_key(v)
end

# The cell ordinal (0-based) along one pinned axis that key value `x` names,
# or -1 when `x` is not an integer inside the axis's range.
@inline function _scatter_axis_pos(x::Float64, lo::Int, st::Int, len::Int)
    (isinteger(x) && -0x1p62 < x < 0x1p62) || return -1
    w = Int(x) - lo
    q = div(w, st)
    (q * st == w && 0 <= q < len) || return -1
    return q
end

# One pinned key at build: `aff` the `(pos, coef, c)` affine form over the
# contracted indices when it has one (no tree walk), else the compiled node
# and the counters its loop-var leaves read.
struct _ScatterKey
    aff::Union{Nothing, Tuple{Int, Int, Int}}
    node::_Node
    refs::Vector{Base.RefValue{Int}}
end

# The STATIC scatter map as a TABLE fold. One pass over the contracted box in
# visit order computes each point's pinned cell, and a stable counting sort
# groups the points by pinned cell, so each cell keeps them in visit order. The
# per-cell lists are then laid out over every output cell: with constant
# contracted ranges the box is the same for every combination of the free
# output indices, so one pass serves them all; a ragged range whose bound reads
# free output indices gets one pass per combination, over its own box.
function _scatter_table(
        contract_refs::Vector{Base.RefValue{Int}}, contract_ranges, contract_const,
        keys::Vector{_ScatterKey}, pinpos::Vector{Int}, idx_names::Vector{String},
        los::Vector{Int}, stps::Vector{Int}, lens::Vector{Int},
        oplus::String, zerobar::Float64, const_registry::AbstractDict
    )
    nd = length(lens)
    nc = length(contract_refs)
    free = Int[d for d in 1:nd if !(d in pinpos)]
    pstride = Vector{Int}(undef, length(pinpos))
    acc = 1
    for (r, d) in enumerate(pinpos)
        pstride[r] = acc
        acc *= lens[d]
    end
    npin = acc
    nfree = prod(Int[lens[d] for d in free]; init = 1)
    fixed = all(c -> c !== nothing, contract_const)
    gseg = Int[1]
    gcols = Vector{Int}[Int[] for _ in 1:nc]
    if fixed
        lists = Vector{Int}[collect(Int, c) for c in contract_const]
        _scatter_box!(gseg, gcols, lists, keys, pinpos, pstride, npin, los, stps, lens)
    else
        # One box per combination of the free output indices (the first free
        # index fastest), each over the ranges its bounds give there.
        env = Dict{String, Int}()
        lists = Vector{Vector{Int}}(undef, nc)
        for d in 1:nc
            contract_const[d] === nothing || (lists[d] = collect(Int, contract_const[d]))
        end
        qf = zeros(Int, length(free))
        for _ in 1:nfree
            for (r, d) in enumerate(free)
                env[idx_names[d]] = los[d] + qf[r] * stps[d]
            end
            for d in 1:nc
                contract_const[d] === nothing &&
                    (lists[d] = _expand_contract_range(contract_ranges[d], env, const_registry))
            end
            _scatter_box!(gseg, gcols, lists, keys, pinpos, pstride, npin, los, stps, lens)
            for r in eachindex(qf)
                qf[r] += 1
                qf[r] < lens[free[r]] && break
                qf[r] = 0
            end
        end
    end
    ncells = prod(lens; init = 1)
    seg = Vector{Int}(undef, ncells + 1)
    nent = 0
    # The table's length: each pinned list once per free combination.
    if fixed
        nent = Base.Checked.checked_mul(gseg[end] - 1, nfree)
    else
        nent = gseg[end] - 1
    end
    cols = [Vector{Int}(undef, nent) for _ in 1:nc]
    _scatter_layout!(seg, cols, gseg, gcols, pinpos, pstride, free, lens, npin, fixed)
    return _ACFold(contract_refs, Symbol(oplus), zerobar, seg, cols)
end

# One box: each point's pinned cell, then the admitted points grouped by cell
# (stable), appended to `gseg` (one entry per pinned cell) and `gcols`.
function _scatter_box!(
        gseg::Vector{Int}, gcols::Vector{Vector{Int}}, lists::Vector{Vector{Int}},
        keys::Vector{_ScatterKey}, pinpos::Vector{Int}, pstride::Vector{Int},
        npin::Int, los::Vector{Int}, stps::Vector{Int}, lens::Vector{Int}
    )
    nc = length(lists)
    clens = Int[length(c) for c in lists]
    npts = prod(clens; init = 1)
    pcell = Vector{Int32}(undef, npts)
    _scatter_map!(pcell, lists, keys, pinpos, pstride, los, stps, lens, clens)
    cnt = zeros(Int, npin + 1)
    @inbounds for q in pcell
        q >= 0 && (cnt[q + 2] += 1)
    end
    base = gseg[end]
    cnt[1] = base
    @inbounds for c in 1:npin
        cnt[c + 1] += cnt[c]
    end
    nadm = cnt[end] - base
    start = length(gcols[1]) + 1
    for d in 1:nc
        resize!(gcols[d], start - 1 + nadm)
    end
    at = cnt[1:npin]
    @inbounds for pt in 1:npts
        q = pcell[pt]
        q >= 0 || continue
        e = at[q + 1]
        at[q + 1] = e + 1
        rest = pt - 1
        for a in 1:nc
            gcols[a][e] = lists[a][rest % clens[a] + 1]
            rest = div(rest, clens[a])
        end
    end
    append!(gseg, @view cnt[2:end])
    return nothing
end

# Each contracted point's pinned cell (0-based sub-ordinal), or -1 for a point
# no cell admits. Points are numbered in visit order (the first contracted
# index fastest).
function _scatter_map!(
        pcell::Vector{Int32}, contract_lists::Vector{Vector{Int}},
        keys::Vector{_ScatterKey}, pinpos::Vector{Int}, pstride::Vector{Int},
        los::Vector{Int}, stps::Vector{Int}, lens::Vector{Int}, clens::Vector{Int}
    )
    nc = length(contract_lists)
    q = zeros(Int, nc)          # the odometer, 0-based per contracted axis
    vals = Int[isempty(c) ? 0 : c[1] for c in contract_lists]
    u0 = Float64[]
    @inbounds for pt in eachindex(pcell)
        cell = 0
        for r in eachindex(keys)
            key = keys[r]
            d = pinpos[r]
            pos = if key.aff !== nothing
                kp, coef, c = key.aff
                v = kp == 0 ? c : coef * vals[kp] + c
                w = v - los[d]
                qq = div(w, stps[d])
                (qq * stps[d] == w && 0 <= qq < lens[d]) ? qq : -1
            else
                for a in 1:nc
                    key.refs[a][] = vals[a]
                end
                x = _scatter_key(_eval_node(key.node, u0, nothing, 0.0, Float64))
                _scatter_axis_pos(x, los[d], stps[d], lens[d])
            end
            if pos < 0
                cell = -1
                break
            end
            cell += pos * pstride[r]
        end
        pcell[pt] = Int32(cell)
        for a in 1:nc
            q[a] += 1
            if q[a] < clens[a]
                vals[a] = contract_lists[a][q[a] + 1]
                break
            end
            q[a] = 0
            vals[a] = contract_lists[a][1]
        end
    end
    return pcell
end

# The per-cell lists laid out over every output cell (dimension 1 fastest):
# cell `c` with free ordinal `fo` and pinned ordinal `pq` takes the list
# `gseg[k]:gseg[k+1]-1` for `k = pq + 1` (one box) or `fo·npin + pq + 1` (a box
# per free combination).
function _scatter_layout!(
        seg::Vector{Int}, cols::Vector{Vector{Int}}, gseg::Vector{Int},
        gcols::Vector{Vector{Int}}, pinpos::Vector{Int}, pstride::Vector{Int},
        free::Vector{Int}, lens::Vector{Int}, npin::Int, fixed::Bool
    )
    nd = length(lens)
    nc = length(gcols)
    fstride = zeros(Int, nd)
    acc = 1
    for d in free
        fstride[d] = acc
        acc *= lens[d]
    end
    pst = zeros(Int, nd)
    for (r, d) in enumerate(pinpos)
        pst[d] = pstride[r]
    end
    ncells = length(seg) - 1
    seg[1] = 1
    e = 0
    qd = zeros(Int, nd)
    @inbounds for c in 1:ncells
        pq = 0
        fo = 0
        for d in 1:nd
            pq += qd[d] * pst[d]
            fo += qd[d] * fstride[d]
        end
        k = fixed ? pq + 1 : fo * npin + pq + 1
        for g in gseg[k]:(gseg[k + 1] - 1)
            e += 1
            for a in 1:nc
                cols[a][e] = gcols[a][g]
            end
        end
        seg[c + 1] = e + 1
        for d in 1:nd
            qd[d] += 1
            qd[d] < lens[d] && break
            qd[d] = 0
        end
    end
    return seg
end

# The RUN-TIME scatter: a generated pass that evaluates each key per point on
# every call. Per combination of the free output indices (the chunked axis):
# every pinned cell is set to 0̄ and marked unvisited, then the contracted box is
# walked in visit order; a point whose keys all name a cell folds its term into
# that cell. A cell's first term is folded onto the `Float64` 0̄ itself, as the
# per-cell fold seeds it (`_cg_fold`), so a dual-valued term's partials pass
# through untouched; later ones onto the value the cell holds.
function _try_codegen_scatter(
        out_refs::Vector{Base.RefValue{Int}},
        los::Vector{Int}, steps::Vector{Int}, lens::Vector{Int},
        outs::Vector{Int}, body::_Node,
        contract_refs::Vector{Base.RefValue{Int}},
        contract_ranges::Vector{StepRange{Int, Int}},
        keys::Vector{Tuple{_Node, Vector{Base.RefValue{Int}}, Vector{Base.RefValue{Int}}}},
        pinpos::Vector{Int}, op::Symbol, zerobar::Float64; nst::Int = 0
    )
    _codegen_disabled() && return :codegen_disabled
    ctx = _CGCtx(_codegen_node_budget(); nst = nst)
    kc = _CGScalarCtx()
    nd = length(out_refs)
    free = Int[d for d in 1:nd if !(d in pinpos)]
    stride = Vector{Int}(undef, nd)
    acc = 1
    for d in 1:nd
        stride[d] = acc
        acc *= lens[d]
    end
    ncells = acc
    nfree = prod(Int[lens[d] for d in free]; init = 1)
    npin = prod(Int[lens[d] for d in pinpos]; init = 1)
    fnsym = try
        _cg_oplus_fn(op)
    catch err
        err isa _CodegenDecline || rethrow()
        return err.reason
    end
    fc = _cg_name(ctx, "fc")
    rv = _cg_name(ctx, "r")
    base = _cg_name(ctx, "base")
    # The free output counters, decoded from the chunk ordinal.
    dec = Any[:(local $rv = $fc - 1), :(local $base = 0)]
    for d in free
        iv = _cg_name(ctx, "oi")
        kc.loops[out_refs[d]] = iv
        qv = _cg_name(ctx, "q")
        lo = _cg_geo!(ctx, los[d], (los, d))
        len = _cg_geo!(ctx, lens[d], (lens, d))
        st = _cg_geo!(ctx, steps[d], (steps, d), true)
        sd = _cg_geo!(ctx, stride[d], (stride, d), true)
        push!(dec, :(local $qv = $rv % $len))
        push!(dec, :(local $iv = $lo + $qv * $st))
        push!(dec, :($base += $qv * $sd))
        push!(dec, :($rv = div($rv, $len)))
    end
    # The pinned counters, bound per point from the keys.
    pinv = Symbol[]
    for d in pinpos
        iv = _cg_name(ctx, "oi")
        kc.loops[out_refs[d]] = iv
        push!(pinv, iv)
    end
    # The contracted counters: the term's and every key's loop-var leaves.
    kvs = Symbol[]
    for (j, r) in enumerate(contract_refs)
        kv = _cg_name(ctx, "kk")
        kc.loops[r] = kv
        push!(kvs, kv)
        rg = contract_ranges[j]
        isempty(rg) || (kc.spans[r] = extrema((first(rg), last(rg))))
    end
    for (_, crefs, orefs) in keys
        for (j, r) in enumerate(crefs)
            kc.loops[r] = kvs[j]
            kc.spans[r] = get(kc.spans, contract_refs[j], (0, 0))
            isempty(contract_ranges[j]) && delete!(kc.spans, r)
        end
        for (d, r) in enumerate(orefs)
            kc.loops[r] = kc.loops[out_refs[d]]
        end
    end
    ov = _cg_name(ctx, "outs")
    sv = _cg_name(ctx, "seen")
    seen = Vector{Bool}(undef, ncells)
    off = _cg_name(ctx, "off")
    # Per point: each key, its cell along its axis, or the next point.
    pbody = Any[:(local $off = $base)]
    stmts = try
        for (r, d) in enumerate(pinpos)
            ex = _cg_emit(ctx, kc, keys[r][1])
            xv = _cg_name(ctx, "x")
            qv = _cg_name(ctx, "q")
            lo = _cg_geo!(ctx, los[d], (los, d))
            len = _cg_geo!(ctx, lens[d], (lens, d))
            st = _cg_geo!(ctx, steps[d], (steps, d), true)
            sd = _cg_geo!(ctx, stride[d], (stride, d), true)
            push!(pbody, :(local $xv = _scatter_key($ex)))
            push!(pbody, :(local $qv = _scatter_axis_pos($xv, $lo, $st, $len)))
            push!(pbody, :($qv < 0 && continue))
            push!(pbody, :(local $(pinv[r]) = $lo + $qv * $st))
            push!(pbody, :($off += $qv * $sd))
        end
        term = _cg_emit(ctx, kc, body)
        tv = _cg_name(ctx, "tv")
        slv = _cg_name(ctx, "sl")
        cord = _cg_name(ctx, "co")
        push!(pbody, :(local $cord = $off + 1))
        push!(pbody, :(local $slv = $ov[$cord]))
        push!(pbody, :(local $tv = $term))
        push!(
            pbody, quote
                if $sv[$cord]
                    du[$slv] = $fnsym(du[$slv], $tv)
                else
                    du[$slv] = $fnsym($zerobar, $tv)
                    $sv[$cord] = true
                end
            end
        )
        pbody
    catch err
        err isa _CodegenDecline || rethrow()
        return err.reason
    end
    # The contracted loops, the first contracted index innermost.
    loop = Expr(:block, stmts...)
    for j in eachindex(kvs)
        rg = contract_ranges[j]
        lo = _cg_geo!(ctx, first(rg), (contract_ranges, j, :lo))
        st = _cg_geo!(ctx, step(rg), (contract_ranges, j, :step), true)
        hi = _cg_geo!(ctx, last(rg), (contract_ranges, j, :hi))
        loop = Expr(:for, :($(kvs[j]) = $lo:$st:$hi), Expr(:block, loop))
    end
    # The pinned cells of this chunk's free coordinates: 0̄, unvisited.
    pc = _cg_name(ctx, "pc")
    pr = _cg_name(ctx, "pr")
    po = _cg_name(ctx, "po")
    pdec = Any[:(local $pr = $pc - 1), :(local $po = $base + 1)]
    for d in pinpos
        len = _cg_geo!(ctx, lens[d], (lens, d))
        sd = _cg_geo!(ctx, stride[d], (stride, d), true)
        push!(pdec, :($po += ($pr % $len) * $sd))
        push!(pdec, :($pr = div($pr, $len)))
    end
    npinv = _cg_geo!(ctx, npin)
    init = quote
        for $pc in 1:$npinv
            $(pdec...)
            du[$ov[$po]] = $zerobar
            $sv[$po] = false
        end
    end
    outsv = _cg_tab!(ctx, outs)
    seenv = _cg_tab!(ctx, seen)
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    tv = _cg_name(ctx, "ab")
    nfreev = _cg_geo!(ctx, nfree)
    oside = isempty(outs) ? :x : _cg_slot_side(nst, extrema(outs)...)
    dstore = oside === :x ? :du : :(_cg_dview(du, Val($(QuoteNode(oside)))))
    ln = LineNumberNode(0, Symbol("faq-equality-scatter"))
    whole = quote
        $(ctx.geosink...)
        local $ov = $outsv
        local $sv = $seenv
        local $tv = _chunk_ordinals($nfreev, _cgci, _cgnc)
        local $av = $tv[1]
        local $bv = $tv[2]
        let du = $dstore
            for $fc in ($av + 1):$bv
                $(dec...)
                $init
                $loop
            end
        end
    end
    ngrp = length(ctx.tab_types)
    grpstmts = Any[:(local $(_cg_grp_sym(g)) = tabs[$g]) for g in 1:ngrp]
    ex = Expr(
        :function, Expr(:tuple, :du, :u, :p, :t, :tabs, :_cgci, :_cgnc),
        Expr(
            :block, grpstmts...,
            :(local _cgT = _rhs_value_type(u, p, t)),
            ctx.helpers...,
            Expr(:macrocall, Symbol("@inbounds"), ln, whole),
            :(return nothing)
        )
    )
    f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
        @__MODULE__, @__MODULE__, ex
    )
    tabpack = ntuple(g -> Vector{ctx.tab_types[g]}(ctx.tab_objs[g]), ngrp)
    npts = prod(length, contract_ranges; init = 1)
    kw = _node_work(body)
    for k in keys
        kw = Base.Checked.checked_add(kw, _node_work(k[1]))
    end
    work = Base.Checked.checked_add(
        ncells,
        Base.Checked.checked_mul(Base.Checked.checked_mul(nfree, npts), kw)
    )
    # Each chunk owns the cells of its free coordinates, and the pass inside a
    # chunk is sequential, so chunks never share a cell.
    return _ArrayContraction(f, tabpack, _SecTCache(nfree, true, work))
end

# `e` resolved and compiled once with every index symbolic: `(output counters,
# contracted counters, node)`, or `nothing` when it does not lower.
function _scatter_symbolic(
        e::ASTExpr, resolved_obs, idx_names, contract_names, array_var_info,
        var_map, const_registry, pgather, param_sym_set, reg_funcs
    )
    b = isempty(resolved_obs) ? e : _sub_preserving(e, resolved_obs)
    got = _resolve_array_contraction_term(
        b, idx_names, contract_names,
        array_var_info, var_map, const_registry, pgather; nest_scalar_loops = true
    )
    got === nothing && return nothing
    nd = try
        _compile(got[3], var_map, param_sym_set, reg_funcs)
    catch err
        _is_resource_error(err) && rethrow()
        return nothing
    end
    return (got[1], got[2], nd)
end

# The whole-array nest's entry for a scatter (`_try_compile_array_contraction`
# hands it a `_ScatterSpec`): the term guarded by the remaining conjuncts and
# each key resolved once with every index symbolic, then the STATIC table or the
# RUN-TIME pass. `nothing` with `covered` untouched for anything it cannot model.
function _try_compile_scatter(
        lhs_body::OpExpr, rhs_body::ASTExpr, covered::_Covered, sc::_ScatterSpec;
        idx_names::Vector{String}, ranges_dict, range_iters,
        contract_names::Vector{String}, contract_ranges, contract_const,
        rhs_oplus::String, rhs_zerobar::Float64,
        resolved_obs::Dict{String, ASTExpr}, array_var_info,
        var_map::AbstractDict{String, Int}, const_registry::AbstractDict,
        pgather::AbstractDict, param_sym_set, reg_funcs, obs_nst::Int = 0
    )
    term = sc.rem === nothing ? rhs_body :
        OpExpr("ifelse", ASTExpr[sc.rem, rhs_body, NumExpr(rhs_zerobar)])
    sym(e) = _scatter_symbolic(
        e, resolved_obs, idx_names, contract_names, array_var_info,
        var_map, const_registry, pgather, param_sym_set, reg_funcs
    )
    tgot = sym(term)
    if tgot === nothing
        _note_decline!(:array_contraction, :symbolic_body_did_not_lower)
        return nothing
    end
    out_refs, contract_refs, node = tgot
    kgots = Any[]
    for (_, e) in sc.pins
        g = sym(e)
        if g === nothing
            _note_decline!(:array_contraction, :symbolic_body_did_not_lower)
            return nothing
        end
        push!(kgots, g)
    end
    pinpos = Int[p for (p, _) in sc.pins]
    rngs = [_expand_int_range(ranges_dict[n]) for n in idx_names]
    los = Int[first(r) for r in rngs]
    stps = Int[step(r) for r in rngs]
    lens = Int[length(r) for r in rngs]
    static = all(g -> _scatter_static_node(g[3]), kgots)
    if static
        keys = _ScatterKey[]
        for (r, (_, e)) in enumerate(sc.pins)
            ee = isempty(resolved_obs) ? e : _sub_preserving(e, resolved_obs)
            push!(keys, _ScatterKey(_lhs_index_affine(ee, contract_names), kgots[r][3], kgots[r][2]))
        end
        fold = _scatter_table(
            contract_refs, contract_ranges, contract_const, keys, pinpos,
            idx_names, los, stps, lens, rhs_oplus, rhs_zerobar, const_registry
        )
        outs = _ac_claim_all_outs!(covered, lhs_body, idx_names, range_iters, var_map)
        gen = _try_codegen_array_contraction(
            out_refs, los, stps, lens, outs, node;
            fold = fold, nst = obs_nst
        )
        tier = :equality_scatter_table
    else
        cranges = StepRange{Int, Int}[]
        for c in contract_const
            (c isa AbstractRange && !isempty(c)) || (_note_decline!(:array_contraction, :scatter_ragged_or_empty); return nothing)
            push!(cranges, first(c):step(c):last(c))
        end
        outs = _ac_claim_all_outs!(covered, lhs_body, idx_names, range_iters, var_map)
        gen = _try_codegen_scatter(
            out_refs, los, stps, lens, outs, node, contract_refs, cranges,
            Tuple{_Node, Vector{Base.RefValue{Int}}, Vector{Base.RefValue{Int}}}[
                (g[3], g[2], g[1]) for g in kgots
            ],
            pinpos, Symbol(rhs_oplus), rhs_zerobar; nst = obs_nst
        )
        tier = :equality_scatter_pass
    end
    if gen isa Symbol
        _uncover!(covered, outs)
        _note_decline!(:array_contraction, gen)
        return nothing
    end
    _tally_cascade!(tier)
    return gen
end
