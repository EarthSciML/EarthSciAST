# Whole-array contraction nest (ess-array-contraction).
#
# An array-producing aggregate `out[i…] = ⊕_{k…} body(i…, k…)` is compiled to ONE
# term node plus one flat slot vector, and emitted as a loop NEST: the output
# indices iterate in the generated section, the contracted ones in the fold the
# emitter writes around the term (`_ACFold`).
#
# WHY THE TIER EXISTS. The tiers it sits below both scale the BUILD with an
# extent of the equation: the affine tier unrolls the reduction into ∏|k…| terms
# per structural group before it can model anything, and the per-cell contraction
# loop compiles one node per output cell. A dense source-receptor contraction —
# `conc[rcv] = Σ_s SR[s,rcv]·E[s]` over tens of thousands of cells each way — is
# unaffordable on both: the unroll is the product of the two extents, the
# per-cell loop the output extent. Here the build sees each extent only as a loop
# bound and an integer slot table, so it is O(1) in the contracted extent and
# O(cells) MACHINE WORDS (not AST nodes) in the output extent.
#
# WHY IT IS A SECTION over `du` rather than a node kind, the reason scan.jl gives
# for its prefix folds: the access-kernel / affine / codegen / oop-merge passes
# all model per-cell scalar terms, and a section is invisible to every one of
# them.
#
# THE NEST IS CODE, not a tree. The output odometer, the contracted loops and the
# ⊕-fold are emitted as Julia and compiled once through
# RuntimeGeneratedFunctions, exactly as the access-kernel tier
# (codegen_kernel.jl) compiles its loop nests. There is no interpreted form of
# this tier: `native` admits it and emits it, `interpreter` turns it off and the
# equation takes the per-cell path, and an equation the emitter cannot model is
# refused by name at build. The emission is itself O(1) in BOTH extents, so the
# grid-flat build the tier exists for is not spent to buy the compiled call.
#
# BIT-IDENTITY with the per-cell path is what the tier is tested on, and is
# structural: every arm below is `_eval_node`'s arm rewritten as an expression,
# in the same child order, with the same seeds and the same short-circuits. In
# particular the ⊕-fold is the per-cell expansion's (`_eval_contraction`): one
# accumulator seeded from the `Float64` 0̄, the terms in `Iterators.product`
# order (the first contracted index fastest), which conformance pins for
# reductions; and the output odometer is a division rather than a nested loop,
# so a chunk can start at any cell.
#
# What the emitter models is the SCALAR `_Node` spine — the kinds `_eval_node`
# dispatches on. `_cg_emit`'s other method models the ACCESS-KERNEL spine
# (`_NK_ACCESS` / `_NK_REDUCE` / `_NK_SUBCALL`), a disjoint set of kinds over the
# same `_Node` type, so the two are methods of one generic function on two
# context types and the op ladder (`_cg_emit_op` / `_cg_emit_fn`, the registry
# rows) is shared rather than written twice.

# One contraction of a build: its generated function, the by-type tab containers
# it reads, and its threading verdict. Concretely parameterized so the callers
# hold it in a tuple and every call site is statically dispatched — an abstractly
# typed field here would box `t` on every right-hand-side call, which the tier's
# zero-allocation property does not allow.
struct _ArrayContraction{F,TB}
    f::F
    tabs::TB
    tcache::_SecTCache
end

# Emission context for a scalar spine. `loops` maps a loop counter `Ref` — the
# object an `_NK_LOOPVAR` leaf carries and an `_NK_CONTRACTION_LOOP` drives — to
# the generated local holding that counter's current value. Keyed by identity,
# because that is how the walker resolves it: the leaf and its loop share one
# `Ref`, and two loops over the same index name in different equations are
# different objects.
struct _CGScalarCtx
    loops::IdDict{Any,Symbol}
end
_CGScalarCtx() = _CGScalarCtx(IdDict{Any,Symbol}())

# A lane-spec `interp.*` payload reaches `_cg_emit_fn` only from a kernel-CLASS
# merge, which no scalar spine goes through. Declining keeps that arm's address
# arithmetic a kernel-only concern instead of a `MethodError` escaping the
# emitter's decline protocol.
_cg_boxaddr(::_CGCtx, ::_CGScalarCtx, ::Int, ::Int, ::Int, ::Int, ::Vector{Int}, key) =
    throw(_CodegenDecline(:lane_spec_on_scalar_spine))

# ---- Scalar spine node → expression (mirrors `_eval_node`) ------------------
function _cg_emit(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    _cg_budget!(ctx)
    k = nd.kind
    if k === _NK_LITERAL
        return nd.literal
    elseif k === _NK_STATE
        return :(u[$(_cg_geo!(ctx, nd.idx, (nd, :idx)))])
    elseif k === _NK_PARAM
        return :(_read_param(p, $(QuoteNode(nd.sym)), $(nd.idx)))
    elseif k === _NK_TIME
        return :t
    elseif k === _NK_PARAM_GATHER
        # The aliased flat buffer at a build-fixed offset, as the walker's arm
        # reads it; the tab container is `Vector{Float64}`, so the element type
        # is concrete without the walker's type assert.
        buf = _cg_tab!(ctx, nd.payload::Vector{Float64})
        return :($buf[$(_cg_geo!(ctx, nd.idx, (nd, :idx)))])
    elseif k === _NK_CONST_GATHER
        return _cg_const_gather(ctx, kc, nd)
    elseif k === _NK_STATE_GATHER
        return _cg_state_gather(ctx, kc, nd)
    elseif k === _NK_LOOPVAR
        s = get(kc.loops, nd.payload, nothing)
        s === nothing && throw(_CodegenDecline(:loopvar_out_of_scope))
        # `T(ref[])` — a contracted or output index is an integer, so this is a
        # constant of the value type and carries no derivative.
        return :(_cgT($s))
    elseif k === _NK_CONTRACTION_LOOP
        return _cg_contraction_loop(ctx, kc, nd)
    elseif k === _NK_CONTRACTION
        # Seeded sequential ⊕-fold in child order, `_eval_contraction` arm for
        # arm (the seed is the node's 0̄, a `Float64` there and here).
        ch = nd.children
        isempty(ch) && return nd.literal
        fnsym = _cg_oplus_fn(nd.op)
        exprs = Any[nd.literal]
        for c in ch
            push!(exprs, _cg_emit(ctx, kc, c))
        end
        return _cg_foldl(fnsym, exprs)
    elseif k === _NK_CACHED
        # The scalar prelude's CSE scratch. A contraction body is compiled with
        # `memo=nothing` and never goes through `_cse_compile_scalar`, so this
        # cannot appear today; declining by name keeps it from being emitted as
        # a silently wrong read if it ever can.
        throw(_CodegenDecline(:cached_scalar_slot))
    elseif k === _NK_OP
        return _cg_emit_op(ctx, kc, nd)
    end
    throw(_CodegenDecline(:unknown_kind))
end

_cg_oplus_fn(op::Symbol) =
    op === :+ ? :+ : op === :* ? :* : op === :max ? :max : op === :min ? :min :
    throw(_CodegenDecline(:unsupported_op))

# `_NK_CONST_GATHER`: evaluate the subscripts in dimension order, resolve each on
# its own axis through the SAME `_const_gather_sub` the walker calls (so an
# out-of-range subscript takes the array's declared boundary policy, including
# its throw), linearize with the build-time strides, read the flat buffer. The
# `let` bindings are sequential, which is the walker's subscript order.
function _cg_const_gather(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    cg = nd.payload::_ConstGatherArray
    children = nd.children
    cgv = _cg_name(ctx, "cga")
    binds = Any[:($cgv = $(_cg_tab!(ctx, cg)))]
    off = Any[1]
    for d in eachindex(children)
        sd = _cg_name(ctx, "cgs")
        push!(binds, :($sd = _const_gather_sub($cgv, $d,
                            round(Int, $(_cg_emit(ctx, kc, children[d]))))))
        push!(off, :(($sd - 1) * $(_cg_geo!(ctx, cg.strides[d], (cg.strides, d), true))))
    end
    return Expr(:let, Expr(:block, binds...),
                Expr(:block, :($cgv.flat[$(_cg_foldl(:+, off))])))
end

# `_NK_STATE_GATHER`: the walker checks each subscript against its axis and
# returns 0̄ at the FIRST out-of-range one, so the later subscripts are not
# evaluated. Nested conditionals reproduce that exactly — a flat guard chain
# would evaluate every subscript first, which a subscript that throws out of
# range would turn into a different program.
function _cg_state_gather(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    sg = nd.payload::_StateGather
    children = nd.children
    sgv = _cg_name(ctx, "sga")
    inner = _cg_state_gather_dim(ctx, kc, nd, sg, sgv, 1, Any[0])
    return Expr(:let, Expr(:block, :($sgv = $(_cg_tab!(ctx, sg)))),
                Expr(:block, inner))
end

function _cg_state_gather_dim(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node,
                              sg::_StateGather, sgv::Symbol, d::Int, off::Vector{Any})
    children = nd.children
    d > length(children) &&
        return :(u[$sgv.slot_flat[$(_cg_foldl(:+, off)) + 1]])
    sd = _cg_name(ctx, "sgs")
    lo = _cg_geo!(ctx, sg.lo[d], (sg.lo, d))
    hi = _cg_geo!(ctx, sg.hi[d], (sg.hi, d))
    sd_stride = _cg_geo!(ctx, sg.strides[d], (sg.strides, d), true)
    nxt = _cg_state_gather_dim(ctx, kc, nd, sg, sgv, d + 1,
                               push!(copy(off), :(($sd - $lo) * $sd_stride)))
    return Expr(:let,
        Expr(:block, :($sd = round(Int, $(_cg_emit(ctx, kc, children[d]))))),
        Expr(:block, :(($lo <= $sd <= $hi) ? $nxt : zero(eltype(u)))))
end

# `_NK_CONTRACTION_LOOP`: the static range walked in `_expand_int_range` order,
# `acc = acc ⊕ body` from the node's 0̄ — the fold `_eval_contraction_loop`
# performs, statement for statement. The seed is the `Float64` 0̄ itself, as the
# unrolled fold (`_eval_contraction`, the interpreter's form of the same
# reduction) seeds it: under a `Dual` value type `0̄ ⊕ term` then carries the
# term's partials exactly, where a seed converted to the value type would add
# zero partials to them and turn a `-0.0` partial into `0.0`. The counter is a
# plain loop local here instead of the shared `Ref` the walker writes, which is
# also what makes the emitted nest safe to run on several threads.
function _cg_contraction_loop(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    spec = nd.payload::_ContractLoop
    op = nd.op
    fnsym = _cg_oplus_fn(op)
    acc = _cg_name(ctx, "acc")
    kv = _cg_name(ctx, "kk")
    haskey(kc.loops, spec.ref) && throw(_CodegenDecline(:loopvar_reused))
    kc.loops[spec.ref] = kv
    body = try
        _cg_emit(ctx, kc, nd.children[1])
    finally
        delete!(kc.loops, spec.ref)
    end
    step = Expr(:(=), acc, Expr(:call, fnsym, acc, body))
    lo = _cg_geo!(ctx, spec.lo, (spec.ref, :lo))
    st = _cg_geo!(ctx, spec.step, (spec.ref, :step), true)
    hi = _cg_geo!(ctx, spec.hi, (spec.ref, :hi))
    return Expr(:let, Expr(:block, :($acc = $(nd.literal))),
        Expr(:block,
             Expr(:for, :($kv = $lo:$st:$hi),
                  Expr(:block, step)),
             acc))
end

# ---- One contraction → its generated function -------------------------------
# Every extent, bound and fixed slot is run-time geometry (`_cg_geo!`,
# codegen_kernel.jl), read into locals ahead of the cell loop, so the function is
# the same for every size of the arrays it contracts.
#
# The output odometer decomposes cell `c` by division, dimension 1 varying
# fastest — the order `Iterators.product(range_iters...)` walked when `outs` was
# filled — so the loop is correct from any starting cell and a chunk needs no
# carried state. `outs[c]` is the cell's flat `du` slot.
#
# Returns an `_ArrayContraction`, or the emitter's decline reason as a `Symbol`
# — which the caller turns into a refusal, there being no other form of this
# tier to fall back to.
#
# THE FOLD AS DATA (`fold`, an `_ACFold`). `body` is then the bare TERM, with
# no contraction loops in it, and the emitter writes the fold around it: ONE
# accumulator, seeded from the 0̄, `acc = acc ⊕ term` over the contracted
# tuples in the order the per-cell expansion enumerates them. Two forms:
#
#   * STATIC — constant ranges, walked as nested loops, the first contracted
#     index innermost (the expansion's `Iterators.product` order). One
#     accumulator across the whole nest: nested `_NK_CONTRACTION_LOOP`s would
#     each fold from their own 0̄ and add up the partial folds, a different
#     association once there are two contracted indices.
#   * TABLE — a contraction whose admitted tuples differ per output cell (a join
#     gate drops some, a ragged bound gives each cell its own length) cannot be
#     a static loop, so the tuples are data: cell `c`'s are entries
#     `seg[c]:seg[c+1]-1` of the per-dim value columns.
struct _ACFold
    refs::Vector{Base.RefValue{Int}}   # the contracted indices' loop counters
    op::Symbol                         # ⊕
    zerobar::Float64                   # its 0̄
    ranges::Vector{StepRange{Int,Int}} # STATIC: each counter's range (empty for TABLE)
    seg::Vector{Int}                   # TABLE: length ncells + 1
    cols::Vector{Vector{Int}}          # TABLE: per contracted dim, its value at each entry
end
_ACFold(refs, op::Symbol, zerobar::Float64, ranges::Vector{StepRange{Int,Int}}) =
    _ACFold(refs, op, zerobar, ranges, Int[], Vector{Int}[])
_ACFold(refs, op::Symbol, zerobar::Float64, seg::Vector{Int}, cols::Vector{Vector{Int}}) =
    _ACFold(refs, op, zerobar, StepRange{Int,Int}[], seg, cols)
_acfold_is_table(f::_ACFold) = !isempty(f.seg)

function _try_codegen_array_contraction(refs::Vector{Base.RefValue{Int}},
        los::Vector{Int}, steps::Vector{Int}, lens::Vector{Int},
        outs::Vector{Int}, body::_Node; fold::Union{Nothing,_ACFold}=nothing)
    _codegen_disabled() && return :codegen_disabled
    ctx = _CGCtx(_codegen_node_budget())
    kc = _CGScalarCtx()
    cv = _cg_name(ctx, "c")
    rv = _cg_name(ctx, "r")
    seek = Any[:(local $rv = $cv - 1)]
    for d in eachindex(refs)
        iv = _cg_name(ctx, "oi")
        kc.loops[refs[d]] = iv
        lo = _cg_geo!(ctx, los[d], (los, d))
        len = _cg_geo!(ctx, lens[d], (lens, d))
        st = _cg_geo!(ctx, steps[d], (steps, d), true)
        push!(seek, :(local $iv = $lo + ($rv % $len) * $st))
        push!(seek, :($rv = div($rv, $len)))
    end
    kvs = Symbol[]
    if fold !== nothing
        for r in fold.refs
            kv = _cg_name(ctx, "kk")
            kc.loops[r] = kv
            push!(kvs, kv)
        end
    end
    cell = try
        term = _cg_emit(ctx, kc, body)
        fold === nothing ? term : _cg_fold(ctx, fold, cv, kvs, term)
    catch err
        err isa _CodegenDecline || rethrow()
        return err.reason
    end
    outsv = _cg_tab!(ctx, outs)
    ln = LineNumberNode(0, Symbol("ess-array-contraction"))
    ov = _cg_name(ctx, "outs")
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    tv = _cg_name(ctx, "ab")
    ncells = _cg_geo!(ctx, length(outs))
    loop = quote
        $(ctx.geosink...)
        local $ov = $outsv
        local $tv = _chunk_ordinals($ncells, _cgci, _cgnc)
        local $av = $tv[1]
        local $bv = $tv[2]
        for $cv in ($av + 1):$bv
            $(seek...)
            du[$ov[$cv]] = $cell
        end
    end
    ngrp = length(ctx.tab_types)
    grpstmts = Any[:(local $(_cg_grp_sym(g)) = tabs[$g]) for g in 1:ngrp]
    ex = Expr(:function, Expr(:tuple, :du, :u, :p, :t, :tabs, :_cgci, :_cgnc),
        Expr(:block, grpstmts...,
             :(local _cgT = _rhs_value_type(u, p, t)),
             ctx.helpers...,
             Expr(:macrocall, Symbol("@inbounds"), ln, loop),
             :(return nothing)))
    f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
        @__MODULE__, @__MODULE__, ex)
    tabpack = ntuple(g -> Vector{ctx.tab_types[g]}(ctx.tab_objs[g]), ngrp)
    # Output slots are globally unique — each was claimed in `covered` at build,
    # which throws on a second claim — so the cell axis chunks like the kernel
    # section's, and for the same reason: every ⊕-fold is inside one cell.
    return _ArrayContraction(f, tabpack, _SecTCache(length(outs), true))
end

# The fold around the term for cell `cv`: the `Float64` 0̄ (the static nest's
# `_cg_contraction_loop` seed), then `acc = acc ⊕ term` innermost, with the
# contracted counters `kvs` bound by the loops (STATIC) or from the cell's
# table entries (TABLE).
function _cg_fold(ctx::_CGCtx, fold::_ACFold, cv::Symbol, kvs::Vector{Symbol}, term)
    fnsym = _cg_oplus_fn(fold.op)
    acc = _cg_name(ctx, "acc")
    upd = :($acc = $fnsym($acc, $term))
    loop = if _acfold_is_table(fold)
        ev = _cg_name(ctx, "ent")
        segv = _cg_tab!(ctx, fold.seg)
        binds = Any[:(local $(kvs[r]) = $(_cg_tab!(ctx, fold.cols[r]))[$ev])
                    for r in eachindex(kvs)]
        quote
            for $ev in $segv[$cv]:($segv[$cv + 1] - 1)
                $(binds...)
                $upd
            end
        end
    else
        l = upd
        for r in eachindex(kvs)
            rg = fold.ranges[r]
            lo = _cg_geo!(ctx, first(rg), (fold.ranges, r, :lo))
            st = _cg_geo!(ctx, step(rg), (fold.ranges, r, :step), true)
            hi = _cg_geo!(ctx, last(rg), (fold.ranges, r, :hi))
            l = Expr(:for, :($(kvs[r]) = $lo:$st:$hi), Expr(:block, l))
        end
        l
    end
    return quote
        local $acc = $(fold.zerobar)
        $loop
        $acc
    end
end

@inline function _run_acgen!(g::_ArrayContraction, du, u, p, t, ::Type{T}) where {T}
    if T === Float64 && _cg_threads_available() &&
       _sec_prep_threads!(g.tcache).state == 1
        _run_cg_section_threaded!(g.f, g.tabs, du, u, p, t, g.tcache)
    else
        g.f(du, u, p, t, g.tabs, 1, 1)
    end
    return nothing
end

# ---- The right-hand side's contraction section ------------------------------
# The emitted contractions ride in a TUPLE, walked by tail recursion so every
# generated function is called at its own concrete type; a `Vector` of them would
# box each call's `t` and cost an allocation per contraction per call. The same
# reasoning `_fill_obs_levels!` states for its levels.
struct _ContractionSection{G}
    gens::G                         # tuple of `_ArrayContraction`
end

_make_contraction_section(acs::AbstractVector) =
    _ContractionSection(Tuple(acs))

Base.isempty(s::_ContractionSection) = isempty(s.gens)

@inline _run_acgens!(::Tuple{}, du, u, p, t, ::Type{T}) where {T} = nothing
@inline function _run_acgens!(gs::Tuple, du, u, p, t, ::Type{T}) where {T}
    _run_acgen!(gs[1], du, u, p, t, T)
    return _run_acgens!(Base.tail(gs), du, u, p, t, T)
end

@inline function _apply_array_contractions!(du, u, p, t,
        s::_ContractionSection, ::Type{T}) where {T}
    _run_acgens!(s.gens, du, u, p, t, T)
    return nothing
end
