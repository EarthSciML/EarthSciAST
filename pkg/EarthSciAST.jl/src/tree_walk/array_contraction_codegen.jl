# Generated form of the whole-array contraction nest (ess-array-contraction).
#
# The section in array_contraction.jl walks ONE compiled body per OUTPUT CELL on
# every right-hand-side call. That is the one thing a compiled compiler promises
# not to do, and it is why `native` could not build a source-receptor document at
# all: the tier that makes such a document affordable to BUILD left an
# interpreter in the RHS. Here the same nest is emitted ONCE as code — the output
# odometer, the contracted loops and the ⊕-fold all as Julia — and compiled
# through RuntimeGeneratedFunctions, exactly as the access-kernel tier
# (codegen_kernel.jl) compiles its loop nests.
#
# The emission is O(1) in BOTH extents, like the nest it replaces: the output
# extent is a loop bound plus the same flat slot vector, and the contracted
# extent is a loop bound. So the property the tier exists for — build IR flat in
# the grid — is not spent to buy the compiled right-hand side.
#
# BIT-IDENTITY with the walker is the acceptance test, and is structural: every
# arm below is `_eval_node`'s arm rewritten as an expression, in the same child
# order, with the same seeds and the same short-circuits. In particular the
# ⊕-fold keeps `_eval_contraction_loop`'s order (innermost contracted index
# fastest, accumulator seeded from the node's 0̄), which conformance pins for
# reductions, and the output odometer keeps `_ac_seek!`'s division form rather
# than a nested loop, so a chunk can start at any cell.
#
# What the emitter models is the SCALAR `_Node` spine — the kinds `_eval_node`
# dispatches on. `_cg_emit`'s existing method models the ACCESS-KERNEL spine
# (`_NK_ACCESS` / `_NK_REDUCE` / `_NK_SUBCALL`), a disjoint set of kinds over the
# same `_Node` type, so the two are methods of one generic function on two
# context types and the op ladder (`_cg_emit_op` / `_cg_emit_fn`, the registry
# rows) is shared rather than written twice.

# One emitted contraction: its generated function, the by-type tab containers it
# reads, and its threading verdict. Concretely parameterized so the callers hold
# it in a tuple and every call site is statically dispatched — an abstractly
# typed field here would box `t` on every right-hand-side call, which the tier's
# zero-allocation property does not allow.
struct _ACGen{F,TB}
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
_cg_boxaddr(::_CGScalarCtx, ::Int, ::Int, ::Int, ::Int) =
    throw(_CodegenDecline(:lane_spec_on_scalar_spine))

# ---- Scalar spine node → expression (mirrors `_eval_node`) ------------------
function _cg_emit(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    _cg_budget!(ctx)
    k = nd.kind
    if k === _NK_LITERAL
        return nd.literal
    elseif k === _NK_STATE
        return :(u[$(nd.idx)])
    elseif k === _NK_PARAM
        return :(_read_param(p, $(QuoteNode(nd.sym)), $(nd.idx)))
    elseif k === _NK_TIME
        return :t
    elseif k === _NK_PARAM_GATHER
        # The aliased flat buffer at a build-fixed offset, as the walker's arm
        # reads it; the tab container is `Vector{Float64}`, so the element type
        # is concrete without the walker's type assert.
        return :($(_cg_tab!(ctx, nd.payload::Vector{Float64}))[$(nd.idx)])
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
        push!(off, :(($sd - 1) * $(cg.strides[d])))
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
    lo, hi = sg.lo[d], sg.hi[d]
    nxt = _cg_state_gather_dim(ctx, kc, nd, sg, sgv, d + 1,
                               push!(copy(off), :(($sd - $lo) * $(sg.strides[d]))))
    return Expr(:let,
        Expr(:block, :($sd = round(Int, $(_cg_emit(ctx, kc, children[d]))))),
        Expr(:block, :(($lo <= $sd <= $hi) ? $nxt : zero(eltype(u)))))
end

# `_NK_CONTRACTION_LOOP`: the static range walked in `_expand_int_range` order
# with the accumulator seeded from the node's 0̄ at the value type — the fold
# `_eval_contraction_loop` performs, statement for statement. The counter is a
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
    return Expr(:let, Expr(:block, :($acc = _cgT($(nd.literal)))),
        Expr(:block,
             Expr(:for, :($kv = $(spec.lo):$(spec.step):$(spec.hi)),
                  Expr(:block, step)),
             acc))
end

# ---- One contraction → its generated function -------------------------------
# The output odometer is `_ac_seek!`'s: cell `c` decomposed by division, dimension
# 1 varying fastest, so the loop is correct from any starting cell and a chunk
# needs no carried state. `outs[c]` is the cell's flat `du` slot, the same vector
# the walker reads.
#
# Returns an `_ACGen`, or the emitter's decline reason as a `Symbol`.
function _try_codegen_array_contraction(refs::Vector{Base.RefValue{Int}},
        los::Vector{Int}, steps::Vector{Int}, lens::Vector{Int},
        outs::Vector{Int}, body::_Node)
    _codegen_disabled() && return :codegen_disabled
    ctx = _CGCtx(_codegen_node_budget())
    kc = _CGScalarCtx()
    cv = _cg_name(ctx, "c")
    rv = _cg_name(ctx, "r")
    seek = Any[:(local $rv = $cv - 1)]
    for d in eachindex(refs)
        iv = _cg_name(ctx, "oi")
        kc.loops[refs[d]] = iv
        push!(seek, :(local $iv = $(los[d]) + ($rv % $(lens[d])) * $(steps[d])))
        push!(seek, :($rv = div($rv, $(lens[d]))))
    end
    cell = try
        _cg_emit(ctx, kc, body)
    catch err
        err isa _CodegenDecline || rethrow()
        _codegen_debug() &&
            println(stderr, "[ess-array-contraction/codegen] DECLINED: $(err.reason)")
        return err.reason
    end
    outsv = _cg_tab!(ctx, outs)
    ln = LineNumberNode(0, Symbol("ess-array-contraction"))
    ov = _cg_name(ctx, "outs")
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    tv = _cg_name(ctx, "ab")
    loop = quote
        local $ov = $outsv
        local $tv = _chunk_ordinals($(length(outs)), _cgci, _cgnc)
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
    _codegen_debug() &&
        println(stderr, "[ess-array-contraction/codegen] emitted ",
                length(outs), " output cells, ", ctx.nodes, " nodes, ",
                ngrp, " typed tab group(s)")
    # Output slots are globally unique — each was claimed in `covered` at build,
    # which throws on a second claim — so the cell axis chunks like the kernel
    # section's, and for the same reason: every ⊕-fold is inside one cell.
    return _ACGen(f, tabpack, _SecTCache(length(outs), true))
end

@inline function _run_acgen!(g::_ACGen, du, u, p, t, ::Type{T}) where {T}
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
    gens::G                         # tuple of `_ACGen`
    acs::Vector{_ArrayContraction}  # contractions still on the tree-walk runner
end

_make_contraction_section(acs::AbstractVector{_ArrayContraction}) =
    _ContractionSection(
        Tuple(ac.cg for ac in acs if ac.cg !== nothing),
        _ArrayContraction[ac for ac in acs if ac.cg === nothing])

Base.isempty(s::_ContractionSection) = isempty(s.gens) && isempty(s.acs)

@inline _run_acgens!(::Tuple{}, du, u, p, t, ::Type{T}) where {T} = nothing
@inline function _run_acgens!(gs::Tuple, du, u, p, t, ::Type{T}) where {T}
    _run_acgen!(gs[1], du, u, p, t, T)
    return _run_acgens!(Base.tail(gs), du, u, p, t, T)
end

@inline function _apply_array_contractions!(du, u, p, t,
        s::_ContractionSection, ::Type{T}) where {T}
    _run_acgens!(s.gens, du, u, p, t, T)
    isempty(s.acs) || _apply_array_contractions!(du, u, p, t, s.acs, T)
    return nothing
end
