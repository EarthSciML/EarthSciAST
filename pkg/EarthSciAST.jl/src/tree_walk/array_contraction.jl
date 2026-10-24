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
# order (the first contracted index fastest), so this tier and the interpreter
# fold in one association; and the output odometer is a division rather than a
# nested loop, so a chunk can start at any cell. That order is this binding's,
# not the spec's: esm-spec §4.3.1 reduces over the contracted indices as a SET
# and pins an order only for a single-index scan, and CONFORMANCE_SPEC §5.2
# holds any other contraction across bindings to the §5.9 simulation
# tolerance, not to the bit (Rust's interpreter varies the last contracted
# index fastest).
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
struct _ArrayContraction{F,TB,M}
    f::F
    tabs::TB
    tcache::_SecTCache
    mask::M                     # `nothing`, or the TABLE fold's `_ACMask`
    # The build's way back to this emission: `(outs, emit)`, `emit(consumer)`
    # re-emitting the same nest with a state consumer (`_ac_take_consumers`);
    # `nothing` once a consumer is in, when the builder kept none, and on every
    # contraction a section holds (`_ac_drop_remit`). The closure captures the
    # nest's whole fold, per-entry columns included, so a contraction that
    # outlived the build with it would keep a second copy of its table.
    remit::Union{Nothing,Tuple{Vector{Int},Function}}
end
_ArrayContraction(f, tabs, tcache::_SecTCache, mask = nothing) =
    _ArrayContraction(f, tabs, tcache, mask, nothing)
_with_remit(g::_ArrayContraction, outs::Vector{Int}, emit) =
    _ArrayContraction(g.f, g.tabs, g.tcache, g.mask, (outs, emit))
_ac_drop_remit(g::_ArrayContraction) = g.remit === nothing ? g :
    _ArrayContraction(g.f, g.tabs, g.tcache, g.mask, nothing)

# A TABLE fold whose term is `ifelse(gate, term, 0)` under `+`, with a gate
# that reads only build constants and parameters (the regrid's `A_ij > atol`
# filter), has a gate that is fixed while `p` is. The call then folds only the
# entries whose gate holds, over compacted copies of the per-entry columns its
# term reads, and `f` here refills those copies (and the compacted segments)
# whenever the primal of `p` moved since the last fill (`stamp`, `_pprimal`):
# the gate is tested against zero, which a dual number answers from its value,
# so a dual-valued `p` with the primal of the last fill keeps it, and one copy
# serves both value types. `fills` counts the refills. Bit-identical to
# folding every entry: a closed gate adds the `Float64` 0 to an accumulator
# seeded with +0.0, which leaves it unchanged (a sum seeded with +0.0 is never
# -0.0, and a dual number's partials pass through `+ 0.0` untouched).
mutable struct _ACMask{F}
    f::F
    stamp::Any
    fills::Int
end

# Emission context for a scalar spine. `loops` maps a loop counter `Ref` — the
# object an `_NK_LOOPVAR` leaf carries and the nest's odometer or fold drives —
# to the generated local holding that counter's current value. Keyed by identity,
# because that is how the walker resolves it: the leaf and its loop share one
# `Ref`, and two loops over the same index name in different equations are
# different objects.
# `spans` holds, for the counters whose values the build knows, the least and
# greatest value they take, so a gather the counter subscripts directly can
# drop a range test that cannot fail.
# `nest`, inside the whole-array nest, is its output geometry and the cell
# ordinal's local, `(refs, los, steps, lens, cv)`: what a ragged loop in the term
# needs to lay its rows out per cell (`_ac_ragged_entries`).
struct _CGScalarCtx
    loops::IdDict{Any,Symbol}
    entry::Any      # `nothing`, or the TABLE fold's `_ACEntries` while its term is emitted
    spans::IdDict{Any,Tuple{Int,Int}}
    nest::Any
end
_CGScalarCtx(loops, entry, spans) = _CGScalarCtx(loops, entry, spans, nothing)
_CGScalarCtx(loops, entry) = _CGScalarCtx(loops, entry, IdDict{Any,Tuple{Int,Int}}())
_CGScalarCtx() = _CGScalarCtx(IdDict{Any,Symbol}(), nothing)

# A gather subscript that is a loop counter itself: the counter's local, an
# `Int` already (the walker's `round(Int, T(counter))` is that integer), and
# its span when the build knows it; `nothing` for any other subscript.
function _cg_counter_subscript(kc, c::_Node)
    (kc isa _CGScalarCtx && c.kind === _NK_LOOPVAR) || return nothing
    s = get(kc.loops, c.payload, nothing)
    s === nothing && return nothing
    return (s, get(kc.spans, c.payload, nothing))
end

# Whether a slot table is one ascending run (`tbl[k] == tbl[1] + k - 1`): a
# state array laid out as one column-major block, whose slot is then its first
# slot plus the offset, with no table load.
_cg_slot_run(tbl::AbstractVector{Int}) =
    !isempty(tbl) && all(k -> @inbounds(tbl[k]) == @inbounds(tbl[1]) + k - 1, eachindex(tbl))

# ---- Scalar spine node → expression (mirrors `_eval_node`) ------------------
function _cg_emit(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    _cg_budget!(ctx)
    # A subtree a ragged loop computed once ahead of its row (`_cg_ragged_loop`).
    hoisted = get(kc.loops, nd, nothing)
    hoisted === nothing || return hoisted
    k = nd.kind
    if k === _NK_LITERAL
        return nd.literal
    elseif k === _NK_STATE
        return _cg_uread(_cg_slot_side(ctx.nst, nd.idx, nd.idx),
                         _cg_geo!(ctx, nd.idx, (nd, :idx)))
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
    elseif k === _NK_RECUR_GATHER
        return _cg_recur_gather(ctx, kc, nd)
    elseif k === _NK_LOOPVAR
        s = get(kc.loops, nd.payload, nothing)
        s === nothing && throw(_CodegenDecline(:loopvar_out_of_scope))
        # A contracted or output index is an integer, read as the `Float64`
        # the per-cell build's literal for it is: under a `Dual` value type a
        # counter converted to the value type would take arithmetic on it
        # through the dual rules (a division by `1 + 0.1i` differentiates as
        # a quotient of duals) and round its partials differently.
        return :(Float64($s))
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
    elseif k === _NK_RAGGED_LOOP
        return _cg_ragged_loop(ctx, kc, nd)
    elseif k === _NK_CACHED
        # The scalar prelude's CSE scratch. A contraction body is compiled with
        # `memo=nothing` and never goes through `_cse_compile_scalar`, so this
        # cannot appear today; declining by name keeps it from being emitted as
        # a silently wrong read if it ever can.
        throw(_CodegenDecline(:cached_scalar_slot))
    elseif k === _NK_CONTRACTION_LOOP
        return _cg_nest_contraction_loop(ctx, kc, nd)
    elseif k === _NK_OP
        return _cg_emit_op(ctx, kc, nd)
    end
    throw(_CodegenDecline(:unknown_kind))
end

# `_NK_RAGGED_LOOP`, `_eval_ragged_loop` term for term: the terms folded left
# to right into the `Float64` 0̄ (the node's literal, which is also an empty
# row's value). The seed is a `Float64`, so under a `Dual` value type the first
# term's partials pass through `0̄ ⊕ term` untouched.
#
# Inside the whole-array nest, with bounds that read only the cell (its output
# counters and build constants), the rows are laid out at build as entries, the
# TABLE fold's CSR form (`_ac_ragged_entries`): cell `c` folds entries
# `seg[c]:seg[c+1]-1`, and a gather whose subscripts are fixed per entry reads
# a per-entry column. Elsewhere the bounds are evaluated per call.
#
# A subtree of the body that does not read the row's counter (`u[i]`, a
# parameter, `area[i]`) is computed once per non-empty row, ahead of the loop
# (`_ragged_hoists`): the same value every term would compute.
function _cg_ragged_loop(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    spec = nd.payload::_RaggedLoop
    ch = nd.children
    haskey(kc.loops, spec.ref) && throw(_CodegenDecline(:ragged_loop_reentered))
    fnsym = _cg_oplus_fn(nd.op)
    nd.op in (:+, :*, :max, :min) || throw(_CodegenDecline(:unsupported_op))
    seed = nd.literal
    kv = _cg_name(ctx, "rk")
    acc = _cg_name(ctx, "racc")
    en = _ac_ragged_entries(ctx, kc, nd)
    # The row's bounds, its emptiness test, its iteration and the counter's
    # binding per term.
    if en !== nothing
        s0 = _cg_name(ctx, "rs0")
        s1 = _cg_name(ctx, "rs1")
        segv = _ac_entry_local(ctx, en.fold.seg)
        kcolv = _ac_entry_local(ctx, en.fold.cols[1])
        cv = kc.nest.cv
        bounds = (:($s0 = $segv[$cv]), :($s1 = $segv[$cv + 1] - 1))
        empty = :($s1 < $s0)
        iter = :($(en.ev) = $s0:$s1)
        bind = :(local $kv = $kcolv[$(en.ev)])
        tkc = _CGScalarCtx(kc.loops, en, kc.spans, kc.nest)
    else
        lo = _cg_name(ctx, "rlo")
        hi = _cg_name(ctx, "rhi")
        lox = _cg_emit(ctx, kc, ch[2])
        hix = _cg_emit(ctx, kc, ch[3])
        st = _cg_geo!(ctx, spec.step, (spec, :step), true)
        bounds = (:($lo = round(Int, $lox)), :($hi = round(Int, $hix)))
        empty = :(isempty($lo:$st:$hi))
        iter = :($kv = $lo:$st:$hi)
        bind = nothing
        tkc = kc
    end
    hoists = _ragged_hoists(ch[1], spec.ref)
    pre = Any[]
    for h in hoists
        hv = _cg_name(ctx, "rh")
        push!(pre, :(local $hv = $(_cg_emit(ctx, kc, h))))
        kc.loops[h] = hv
    end
    kc.loops[spec.ref] = kv
    term = try
        _cg_emit(ctx, tkc, ch[1])
    finally
        delete!(kc.loops, spec.ref)
        foreach(h -> delete!(kc.loops, h), hoists)
    end
    return quote
        let
            local $(bounds[1])
            local $(bounds[2])
            if $empty
                $(nd.literal)
            else
                $(pre...)
                local $acc = $seed
                $(Expr(:for, iter, Expr(:block, bind, :($acc = $fnsym($acc, $term)))))
                $acc
            end
        end
    end
end

# The subtrees of a ragged loop's body to compute once per row: the largest
# ones that read no counter `ref` and are not a literal or a bare counter,
# reached through operands every term evaluates. An `ifelse` branch and an
# `and` / `or` operand past the first are evaluated lazily, so nothing under
# them is lifted (the row would evaluate what a term might not).
function _ragged_hoists(body::_Node, ref)
    out = _Node[]
    reads = IdDict{_Node,Bool}()
    _ragged_hoists!(out, body, ref, reads)
    return out
end
function _reads_ref(nd::_Node, ref, memo::IdDict{_Node,Bool})
    got = get(memo, nd, nothing)
    got === nothing || return got
    r = (nd.kind === _NK_LOOPVAR && nd.payload === ref) ||
        (nd.kind === _NK_RAGGED_LOOP && (nd.payload::_RaggedLoop).ref === ref) ||
        any(c -> _reads_ref(c, ref, memo), nd.children)
    memo[nd] = r
    return r
end
function _ragged_hoists!(out::Vector{_Node}, nd::_Node, ref, memo::IdDict{_Node,Bool})
    if !_reads_ref(nd, ref, memo)
        (nd.kind === _NK_LITERAL || nd.kind === _NK_LOOPVAR || nd.kind === _NK_TIME) ||
            any(x -> x === nd, out) || push!(out, nd)
        return out
    end
    lazy = nd.kind === _NK_OP && nd.op in (:ifelse, :and, :or)
    for (j, c) in enumerate(nd.children)
        lazy && j > 1 && break
        _ragged_hoists!(out, c, ref, memo)
    end
    return out
end

# A ragged loop's rows as TABLE entries over the nest's cells: `_ACEntries`
# whose fold holds the row starts `seg` and the contracted counter's value at
# each entry. `nothing` (the per-call form) outside the nest, inside a TABLE
# fold's term, when a bound reads anything but the cell's output counters and
# build constants, or when a bound does not evaluate at some cell (the call
# then evaluates it, and raises its error, only where it is reached).
function _ac_ragged_entries(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    (kc.nest === nothing || kc.entry !== nothing) && return nothing
    nest = kc.nest
    spec = nd.payload::_RaggedLoop
    lo_n, hi_n = nd.children[2], nd.children[3]
    (_ac_cell_only(lo_n, nest.refs) && _ac_cell_only(hi_n, nest.refs)) || return nothing
    ncells = prod(nest.lens; init = 1)
    seg = Vector{Int}(undef, ncells + 1)
    kcol = Int[]
    seg[1] = 1
    ord = zeros(Int, length(nest.refs))
    saved = Int[r[] for r in nest.refs]
    try
        for c in 1:ncells
            for d in eachindex(nest.refs)
                nest.refs[d][] = nest.los[d] + ord[d] * nest.steps[d]
            end
            lo = round(Int, _eval_node(lo_n, Float64[], NamedTuple(), 0.0, Float64))
            hi = round(Int, _eval_node(hi_n, Float64[], NamedTuple(), 0.0, Float64))
            append!(kcol, lo:spec.step:hi)
            seg[c + 1] = length(kcol) + 1
            for d in eachindex(ord)
                ord[d] += 1
                ord[d] < nest.lens[d] && break
                ord[d] = 0
            end
        end
    catch err
        (err isa EarthSciASTError || err isa InexactError) || rethrow()
        return nothing
    finally
        for d in eachindex(nest.refs)
            nest.refs[d][] = saved[d]
        end
    end
    fold = _ACFold(Base.RefValue{Int}[spec.ref], nd.op, nd.literal, seg, Vector{Int}[kcol])
    return _ACEntries(_cg_name(ctx, "rent"), fold, nest.refs, nest.los, nest.steps,
                      nest.lens, IdDict{Any,Vector{Int}}())
end

# Whether a node reads only literals, build-constant arrays and the given loop
# counters, so its value at each cell is the build's to know.
function _ac_cell_only(nd::_Node, refs)
    k = nd.kind
    if k === _NK_LOOPVAR
        return any(r -> r === nd.payload, refs)
    end
    (k === _NK_LITERAL || k === _NK_CONST_GATHER ||
     (k === _NK_OP && nd.op !== :fn)) || return false
    return all(c -> _ac_cell_only(c, refs), nd.children)
end

_cg_oplus_fn(op::Symbol) =
    op === :+ ? :+ : op === :* ? :* : op === :max ? :max : op === :min ? :min :
    op === :or ? :_or_combine : throw(_CodegenDecline(:unsupported_op))

# `_NK_CONTRACTION_LOOP` as a counted loop, `_eval_contraction_loop` step for
# step, for every emitter that writes one (the nest's term below, the scalar
# codegen tier's units). The accumulator starts at the node's `Float64` seed as
# it is, not converted to the value type, and each step is `acc = acc ⊕ term`
# with the counter bound for the term's loop-var leaves. With the seed
# `_first_term_seed` (resolve.jl) the fold is the unroll's from its first term,
# and under a `Dual` value type the first term's partials pass through
# `seed ⊕ term` untouched. `lo`, `st` and `hi` are the range's bounds as the
# caller emits them; `span`, when given, is the counter's least and greatest
# value, which lets a gather the counter subscripts drop its range test.
function _cg_contraction_loop(ctx::_CGCtx, kc, nd::_Node, lo, st, hi; span=nothing)
    spec = nd.payload::_ContractLoop
    haskey(kc.loops, spec.ref) && throw(_CodegenDecline(:contraction_loop_reentered))
    fnsym = _cg_oplus_fn(nd.op)
    kv = _cg_name(ctx, "lk")
    acc = _cg_name(ctx, "lacc")
    kc.loops[spec.ref] = kv
    span === nothing || (kc.spans[spec.ref] = span)
    term = try
        _cg_emit(ctx, kc, nd.children[1])
    finally
        delete!(kc.loops, spec.ref)
        span === nothing || delete!(kc.spans, spec.ref)
    end
    return quote
        let
            local $acc = $(nd.literal)
            for $kv in $lo:$st:$hi
                $acc = $fnsym($acc, $term)
            end
            $acc
        end
    end
end

# A scalar reduction nested in a nest's term (`_NEST_SCALAR_LOOPS`). Its bounds
# are build-time integers read through the geometry tables, and its counter's
# span is known.
function _cg_nest_contraction_loop(ctx::_CGCtx, kc::_CGScalarCtx, nd::_Node)
    spec = nd.payload::_ContractLoop
    rng = spec.lo:spec.step:spec.hi
    isempty(rng) && return nd.literal
    lo = _cg_geo!(ctx, spec.lo, (spec, :lo))
    st = _cg_geo!(ctx, spec.step, (spec, :step), true)
    hi = _cg_geo!(ctx, spec.hi, (spec, :hi))
    return _cg_contraction_loop(ctx, kc, nd, lo, st, hi;
                                span=extrema((first(rng), last(rng))))
end

# `_NK_CONST_GATHER`: evaluate the subscripts in dimension order, resolve each on
# its own axis through the SAME `_const_gather_sub` the walker calls (so an
# out-of-range subscript takes the array's declared boundary policy, including
# its throw), linearize with the build-time strides, read the flat buffer. The
# `let` bindings are sequential, which is the walker's subscript order.
function _cg_const_gather(ctx::_CGCtx, kc, nd::_Node)
    cg = nd.payload::_ConstGatherArray
    children = nd.children
    if kc isa _CGScalarCtx
        pre = _ac_const_gather_entries(kc, cg, children)
        pre === nothing ||
            return :($(_ac_entry_local(ctx, pre, kc.entry))[$((kc.entry::_ACEntries).ev)])
    end
    cgv = _cg_name(ctx, "cga")
    binds = Any[:($cgv = $(_cg_tab!(ctx, cg)))]
    off = Any[1]
    for d in eachindex(children)
        sd = _cg_name(ctx, "cgs")
        cs = _cg_counter_subscript(kc, children[d])
        sub = cs === nothing ? :(round(Int, $(_cg_emit(ctx, kc, children[d])))) : cs[1]
        push!(binds, :($sd = _const_gather_sub($cgv, $d, $sub)))
        push!(off, :(($sd - 1) * $(_cg_geo!(ctx, cg.strides[d], (cg.strides, d), true))))
    end
    return Expr(:let, Expr(:block, binds...),
                Expr(:block, :($cgv.flat[$(_cg_foldl(:+, off))])))
end

# The element a const gather reads at each TABLE entry, by `_const_gather_sub`
# as the call would resolve it; `nothing` when the gather is not resolvable per
# entry or some entry's subscript would throw, which stays the call's error.
function _ac_const_gather_entries(kc::_CGScalarCtx, cg::_ConstGatherArray, children)
    cols = _ac_entry_cols(kc, children)
    cols === nothing && return nothing
    nent = length(cols[1])
    for d in eachindex(cols), e in 1:nent
        x = cols[d][e]
        n = cg.dims[d]
        (1 <= x <= n || (n >= 1 && (cg.boundary[d] === :periodic ||
                                    cg.boundary[d] === :clamp))) || return nothing
    end
    vals = Vector{Float64}(undef, nent)
    for e in 1:nent
        lin = 1
        for d in eachindex(cols)
            lin += (_const_gather_sub(cg, d, cols[d][e]) - 1) * cg.strides[d]
        end
        vals[e] = cg.flat[lin]
    end
    return vals
end

# The slot a state gather reads at each TABLE entry, 0 where a subscript is out
# of its axis (the zero ghost); `nothing` when it is not resolvable per entry.
function _ac_state_gather_entries(kc::_CGScalarCtx, sg::_StateGather, children)
    cols = _ac_entry_cols(kc, children)
    cols === nothing && return nothing
    nent = length(cols[1])
    slots = Vector{Int}(undef, nent)
    for e in 1:nent
        off = 0
        for d in eachindex(cols)
            x = cols[d][e]
            if !(sg.lo[d] <= x <= sg.hi[d])
                off = -1
                break
            end
            off += (x - sg.lo[d]) * sg.strides[d]
        end
        slots[e] = off < 0 ? 0 : sg.slot_flat[off + 1]
    end
    return slots
end

# `_NK_STATE_GATHER`: the walker checks each subscript against its axis and
# returns 0̄ at the FIRST out-of-range one, so the later subscripts are not
# evaluated. Nested conditionals reproduce that exactly — a flat guard chain
# would evaluate every subscript first, which a subscript that throws out of
# range would turn into a different program.
function _cg_state_gather(ctx::_CGCtx, kc, nd::_Node)
    sg = nd.payload::_StateGather
    children = nd.children
    if kc isa _CGScalarCtx
        pre = _ac_state_gather_entries(kc, sg, children)
        if pre !== nothing
            col = _ac_entry_local(ctx, pre, kc.entry)
            ev = (kc.entry::_ACEntries).ev
            side = _cg_slot_side(ctx.nst, _cg_table_extent(ctx, pre)...)
            all(!=(0), pre) && return _cg_uread(side, :($col[$ev]))
            sv = _cg_name(ctx, "esl")
            return :(let $sv = $col[$ev]
                         $sv == 0 ? zero(eltype(u)) : $(_cg_uread(side, sv))
                     end)
        end
    end
    sgv = _cg_name(ctx, "sga")
    inner = _cg_state_gather_dim(ctx, kc, nd, sg, sgv, 1, Any[0])
    return Expr(:let, Expr(:block, :($sgv = $(_cg_tab!(ctx, sg)))),
                Expr(:block, inner))
end

function _cg_state_gather_dim(ctx::_CGCtx, kc, nd::_Node,
                              sg::_StateGather, sgv::Symbol, d::Int, off::Vector{Any})
    children = nd.children
    if d > length(children)
        side = _cg_slot_side(ctx.nst, _cg_table_extent(ctx, sg.slot_flat)...)
        _cg_slot_run(sg.slot_flat) &&
            return _cg_uread(side, :($(_cg_geo!(ctx, sg.slot_flat[1], (sg.slot_flat, :run))) +
                                     $(_cg_foldl(:+, off))))
        return _cg_uread(side, :($sgv.slot_flat[$(_cg_foldl(:+, off)) + 1]))
    end
    sd = _cg_name(ctx, "sgs")
    lo = _cg_geo!(ctx, sg.lo[d], (sg.lo, d))
    hi = _cg_geo!(ctx, sg.hi[d], (sg.hi, d))
    sd_stride = _cg_geo!(ctx, sg.strides[d], (sg.strides, d), true)
    nxt = _cg_state_gather_dim(ctx, kc, nd, sg, sgv, d + 1,
                               push!(copy(off), :(($sd - $lo) * $sd_stride)))
    cs = _cg_counter_subscript(kc, children[d])
    cs === nothing && return Expr(:let,
        Expr(:block, :($sd = round(Int, $(_cg_emit(ctx, kc, children[d]))))),
        Expr(:block, :(($lo <= $sd <= $hi) ? $nxt : zero(eltype(u)))))
    span = cs[2]
    inside = span !== nothing && sg.lo[d] <= span[1] && span[2] <= sg.hi[d]
    return Expr(:let, Expr(:block, :($sd = $(cs[1]))),
                Expr(:block, inside ? nxt : :(($lo <= $sd <= $hi) ? $nxt : zero(eltype(u)))))
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
#     accumulator across the whole nest: a fold per contracted index would
#     start each from its own 0̄ and add up the partial folds, a different
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

# A TABLE fold fixes every loop counter its term can read at each entry: the
# contracted ones are the entry's table columns, the output ones follow from the
# entry's cell. So a gather whose subscripts are all bare counters reads the same
# element at entry `e` on every call, and the emitter resolves it at build into a
# per-entry column (`_ac_entry_cols`): a const gather becomes the gathered values,
# a state gather the slots it reads (0 where it reads the zero ghost). The call
# then loads `col[ent]` where it would decode subscripts, apply the boundary
# policy and look the slot up per term; the value read is the same element.
struct _ACEntries
    ev::Symbol                         # the generated entry counter
    fold::_ACFold
    out_refs::Vector{Base.RefValue{Int}}
    los::Vector{Int}
    steps::Vector{Int}
    lens::Vector{Int}
    vals::IdDict{Any,Vector{Int}}      # counter → its value at each entry (filled lazily)
    # While `compact[]`, a per-entry column bound for the term is a compacted
    # copy (`_ACMask`): `pairs` holds each (original, copy) local pair.
    compact::Base.RefValue{Bool}
    pairs::Vector{Tuple{Symbol,Symbol}}
end
_ACEntries(ev, fold, out_refs, los, steps, lens, vals) =
    _ACEntries(ev, fold, out_refs, los, steps, lens, vals, Ref(false),
               Tuple{Symbol,Symbol}[])

function _ac_entry_vals!(en::_ACEntries, ref)
    got = get(en.vals, ref, nothing)
    got === nothing || return got
    f = en.fold
    r = findfirst(x -> x === ref, f.refs)
    if r !== nothing
        return en.vals[ref] = f.cols[r]
    end
    d = findfirst(x -> x === ref, en.out_refs)
    d === nothing && return nothing
    v = Vector{Int}(undef, f.seg[end] - 1)
    div_d = prod(@view en.lens[1:d-1]; init = 1)
    for c in 1:(length(f.seg) - 1)
        x = en.los[d] + (div((c - 1), div_d) % en.lens[d]) * en.steps[d]
        for e in f.seg[c]:(f.seg[c+1] - 1)
            v[e] = x
        end
    end
    return en.vals[ref] = v
end

# The per-entry value of each subscript in `children`, or `nothing` unless every
# one is fixed per entry: a bare counter the TABLE fold fixes, or a const gather
# of such subscripts (a connectivity read, `F[eoc[i, k]]`), taken as the
# integer `round(Int, ·)` the call would take of it.
function _ac_entry_cols(kc::_CGScalarCtx, children)
    en = kc.entry
    en === nothing && return nothing
    cols = Vector{Vector{Int}}(undef, length(children))
    for d in eachindex(children)
        ch = children[d]
        if ch.kind === _NK_LOOPVAR
            v = _ac_entry_vals!(en::_ACEntries, ch.payload)
            v === nothing && return nothing
            cols[d] = v
        elseif ch.kind === _NK_CONST_GATHER
            vals = _ac_const_gather_entries(kc, ch.payload::_ConstGatherArray, ch.children)
            vals === nothing && return nothing
            all(x -> isfinite(x) && abs(x) < 2.0^62, vals) ||
                return nothing
            cols[d] = Int[round(Int, x) for x in vals]
        else
            return nothing
        end
    end
    return cols
end

# A per-entry column bound to a local ahead of the cell loop; under a
# compacting entry context, its compacted copy (paired with the original).
function _ac_entry_local(ctx::_CGCtx, col, en=nothing)
    s = _cg_name(ctx, "ecol")
    if en isa _ACEntries && en.compact[]
        so = _cg_name(ctx, "ecol")
        push!(ctx.geosink, :(local $so = $(_cg_tab!(ctx, col))))
        push!(ctx.geosink, :(local $s = $(_cg_tab!(ctx, copy(col)))))
        push!(en.pairs, (so, s))
        return s
    end
    push!(ctx.geosink, :(local $s = $(_cg_tab!(ctx, col))))
    return s
end

# A lane-spec `interp.*` payload reaches `_cg_emit_fn` only from a kernel-CLASS
# merge, which no scalar spine goes through. Declining keeps that arm's address
# arithmetic a kernel-only concern instead of a `MethodError` escaping the
# emitter's decline protocol.
_cg_boxaddr(::_CGCtx, ::_CGScalarCtx, ::Int, ::Int, ::Int, ::Int, ::Vector{Int}, key) =
    throw(_CodegenDecline(:lane_spec_on_scalar_spine))

function _try_codegen_array_contraction(refs::Vector{Base.RefValue{Int}},
        los::Vector{Int}, steps::Vector{Int}, lens::Vector{Int},
        outs::Vector{Int}, body::_Node; fold::Union{Nothing,_ACFold}=nothing,
        nst::Int=0, consumer=nothing)
    _codegen_disabled() && return :codegen_disabled
    ctx = _CGCtx(_codegen_node_budget(); nst=nst)
    cons = nothing
    if consumer !== nothing
        Kc, ix, delta = consumer
        _cg_note_nest!(ctx, Kc)
        cons = (K = Kc, ix = ix, delta = delta, store = true, invsyms = _cg_inv!(ctx, Kc))
    end
    entries = fold !== nothing && _acfold_is_table(fold) ?
        _ACEntries(_cg_name(ctx, "ent"), fold, refs, los, steps, lens,
                   IdDict{Any,Vector{Int}}()) : nothing
    cv = _cg_name(ctx, "c")
    kc = _CGScalarCtx(IdDict{Any,Symbol}(), entries, IdDict{Any,Tuple{Int,Int}}(),
                      (refs = refs, los = los, steps = steps, lens = lens, cv = cv))
    rv = _cg_name(ctx, "r")
    seek = Any[:(local $rv = $cv - 1)]
    # The same odometer stepped instead of divided: `start` decomposes the
    # chunk's first cell once, `step` advances it after each cell, carrying
    # into the next dimension when one wraps. The counters take the values the
    # division gives, cell for cell.
    start = Any[:(local $rv = $cv - 1)]
    stepper = Any[]
    qs = Symbol[]
    for d in eachindex(refs)
        iv = _cg_name(ctx, "oi")
        kc.loops[refs[d]] = iv
        lo = _cg_geo!(ctx, los[d], (los, d))
        len = _cg_geo!(ctx, lens[d], (lens, d))
        st = _cg_geo!(ctx, steps[d], (steps, d), true)
        push!(seek, :(local $iv = $lo + ($rv % $len) * $st))
        push!(seek, :($rv = div($rv, $len)))
        qv = _cg_name(ctx, "q")
        push!(qs, qv)
        push!(start, :(local $qv = $rv % $len))
        push!(start, :(local $iv = $lo + $qv * $st))
        push!(start, :($rv = div($rv, $len)))
        push!(stepper, (qv, iv, lo, len, st))
        lens[d] >= 1 && (kc.spans[refs[d]] =
            extrema((los[d], los[d] + (lens[d] - 1) * steps[d])))
    end
    advance = nothing
    for (qv, iv, lo, len, st) in reverse(stepper[2:end])
        inner = advance === nothing ? Any[] : Any[advance]
        advance = quote
            $qv += 1
            $iv += $st
            if $qv == $len
                $qv = 0
                $iv = $lo
                $(inner...)
            end
        end
    end
    # The chunk walked a row of the first output dimension at a time: the
    # cells of a row are one counted loop, the odometer carries between rows.
    function rowloop(store)
        isempty(stepper) && return quote
            $store
        end
        q1, iv1, lo1, len1, st1 = stepper[1]
        nr = _cg_name(ctx, "nrow"); is = _cg_name(ctx, "ivs")
        cs = _cg_name(ctx, "cs"); kk = _cg_name(ctx, "kk")
        return quote
            while true
                local $nr = min($len1 - $q1, $bv - $cv + 1)
                local $is = $iv1
                local $cs = $cv
                for $kk in 0:($nr - 1)
                    local $iv1 = $is + $kk * $st1
                    local $cv = $cs + $kk
                    $store
                end
                $cv = $cs + $nr - 1
                $cv == $bv && break
                $cv += 1
                $q1 = 0
                $iv1 = $lo1
                $(advance === nothing ? nothing : advance)
            end
        end
    end
    kvs = Symbol[]
    if fold !== nothing
        for (j, r) in enumerate(fold.refs)
            kv = _cg_name(ctx, "kk")
            kc.loops[r] = kv
            push!(kvs, kv)
            if !_acfold_is_table(fold)
                rg = fold.ranges[j]
                isempty(rg) || (kc.spans[r] = extrema((first(rg), last(rg))))
            end
        end
    end
    gated = entries === nothing ? nothing : _ac_param_gate(body, fold)
    maskloop = nothing
    cell = try
        if gated === nothing
            term = _cg_emit(ctx, kc, body)
            fold === nothing ? term : _cg_fold(ctx, fold, cv, kvs, term,
                                               entries === nothing ? nothing : entries.ev)
        else
            cell, maskloop = _ac_emit_gated(ctx, kc, entries, gated..., cv, kvs, seek,
                                            length(outs))
            cell
        end
    catch err
        err isa _CodegenDecline || rethrow()
        return err.reason
    end
    outsv = _cg_tab!(ctx, outs)
    ln = LineNumberNode(0, Symbol("ess-array-contraction"))
    ov = _cg_name(ctx, "outs")
    # Output slots that are one ascending run are their first slot plus the
    # cell's ordinal, with no table load.
    outref = (!isempty(outs) && _cg_slot_run(outs)) ?
        :($(_cg_geo!(ctx, outs[1], (outs, :run))) + $cv - 1) : :($ov[$cv])
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    tv = _cg_name(ctx, "ab")
    ncells = _cg_geo!(ctx, length(outs))
    # On a two-buffer slot space, `du` as the buffer every output cell is in.
    oside = isempty(outs) ? :x : _cg_slot_side(nst, extrema(outs)...)
    dstore = oside === :x ? :du : :(_cg_dview(du, Val($(QuoteNode(oside)))))
    loop = if cons === nothing
        quote
            $(ctx.geosink...)
            local $ov = $outsv
            local $tv = _chunk_ordinals($ncells, _cgci, _cgnc)
            local $av = $tv[1]
            local $bv = $tv[2]
            let du = $dstore
                if $av < $bv
                    local $cv = $av + 1
                    $(start...)
                    $(rowloop(:(du[$outref] = $cell)))
                end
            end
        end
    else
        # With a state consumer (`_ac_take_consumers`): the cell's value as the
        # observed store converts it, stored, then the consumer's cell computed
        # from it, as the consumer would read it back from the buffer.
        dv = _cg_name(ctx, "dobs")
        olv = _cg_name(ctx, "oln")
        xv = _cg_name(ctx, "x")
        cstmts = try
            _cg_scan_consumer_cell(ctx, cons, olv, xv)
        catch err
            err isa _CodegenDecline || rethrow()
            return err.reason
        end
        quote
            $(ctx.geosink...)
            $(ctx.prologue...)
            local $ov = $outsv
            local $tv = _chunk_ordinals($ncells, _cgci, _cgnc)
            local $av = $tv[1]
            local $bv = $tv[2]
            local $dv = $dstore
            for $cv in ($av + 1):$bv
                $(seek...)
                local $olv = $ov[$cv]
                local $xv = convert(eltype($dv), $cell)
                $dv[$olv] = $xv
                $(cstmts...)
            end
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
    mask = nothing
    if maskloop !== nothing
        mex = Expr(:function, Expr(:tuple, :du, :u, :p, :t, :tabs, :_cgci, :_cgnc),
            Expr(:block, grpstmts...,
                 :(local _cgT = _rhs_value_type(u, p, t)),
                 ctx.helpers...,
                 Expr(:macrocall, Symbol("@inbounds"), ln,
                      quote
                          $(ctx.geosink...)
                          $maskloop
                      end),
                 :(return nothing)))
        mask = _ACMask(RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
                           @__MODULE__, @__MODULE__, mex), _CSE_INVALID, 0)
    end
    tabpack = ntuple(g -> Vector{ctx.tab_types[g]}(ctx.tab_objs[g]), ngrp)
    # Output slots are globally unique — each was claimed in `covered` at build,
    # which throws on a second claim — so the cell axis chunks like the kernel
    # section's, and for the same reason: every ⊕-fold is inside one cell.
    return _ArrayContraction(f, tabpack,
                             _SecTCache(length(outs), true, _ac_work(length(outs), fold, body)),
                             mask)
end

# `(gate, term)` when `body` is `ifelse(gate, term, 0.0)` folded under `+` from
# +0.0 over a TABLE, and the gate reads nothing that can change while `p`
# stands still: literals, parameters, the loop counters (fixed per entry) and
# build-constant arrays. `nothing` otherwise.
function _ac_param_gate(body::_Node, fold::Union{Nothing,_ACFold})
    (fold !== nothing && _acfold_is_table(fold) && fold.op === :+ &&
     fold.zerobar === 0.0) || return nothing
    (body.kind === _NK_OP && body.op === :ifelse && length(body.children) == 3) ||
        return nothing
    gate, term, other = body.children
    (other.kind === _NK_LITERAL && other.literal === 0.0) || return nothing
    _ac_param_only(gate) || return nothing
    return (gate, term)
end

function _ac_param_only(nd::_Node)
    k = nd.kind
    (k === _NK_LITERAL || k === _NK_PARAM || k === _NK_LOOPVAR ||
     k === _NK_CONST_GATHER || k === _NK_OP) || return false
    return all(_ac_param_only, nd.children)
end

# The gated TABLE fold: the cell folds its compacted entries `segc[c]:segc[c+1]-1`
# with the term alone, and the returned mask loop refills `segc` and every
# compacted column from the gate, entry by entry in table order.
function _ac_emit_gated(ctx::_CGCtx, kc::_CGScalarCtx, entries::_ACEntries,
                        gate::_Node, term::_Node, cv::Symbol, kvs::Vector{Symbol},
                        seek::Vector{Any}, ncells::Int)
    fold = entries.fold
    ev = entries.ev
    gx = _cg_emit(ctx, kc, gate)
    sego = _ac_entry_local(ctx, fold.seg)
    obinds = Any[:(local $(kvs[r]) = $(_ac_entry_local(ctx, fold.cols[r]))[$ev])
                 for r in eachindex(kvs)]
    entries.compact[] = true
    tx = _cg_emit(ctx, kc, term)
    cbinds = Any[:(local $(kvs[r]) = $(_ac_entry_local(ctx, fold.cols[r], entries))[$ev])
                 for r in eachindex(kvs)]
    entries.compact[] = false
    segc = _ac_entry_local(ctx, copy(fold.seg))
    acc = _cg_name(ctx, "acc")
    kv = _cg_name(ctx, "k")
    nc = _cg_geo!(ctx, ncells)
    cell = quote
        local $acc = $(fold.zerobar)
        for $ev in $segc[$cv]:($segc[$cv + 1] - 1)
            $(cbinds...)
            $acc = $acc + $tx
        end
        $acc
    end
    copies = Any[:($c[$kv] = $o[$ev]) for (o, c) in entries.pairs]
    maskloop = quote
        local $kv = 0
        $segc[1] = 1
        for $cv in 1:$nc
            $(seek...)
            for $ev in $sego[$cv]:($sego[$cv + 1] - 1)
                $(obinds...)
                if $gx != 0
                    $kv += 1
                    $(copies...)
                end
            end
            $segc[$cv + 1] = $kv + 1
        end
    end
    return cell, maskloop
end

# Refill a gated fold's compacted entries when the primal of `p` moved since
# the last fill. On the calling thread, before any chunk runs.
@inline function _ac_mask_refresh!(m::_ACMask, tabs, du, u, p, t)
    _pprimal_same(m.stamp, p) && return nothing
    m.f(du, u, p, t, tabs, 1, 1)
    m.stamp = _pstamp(_pprimal(p))
    m.fills += 1
    return nothing
end

# The work the threading verdict weighs, in node evaluations: each output
# cell's store, plus the term's nodes once per fold term (once per cell with no
# fold), so a contraction whose cells each fold many terms (a dense
# contraction, a TABLE fold's admitted pairs) is chunked at fewer cells than a
# section whose cells are one expression each.
function _ac_work(ncells::Int, fold::Union{Nothing,_ACFold}, body::_Node)
    tw = _node_work(body)
    fold === nothing && return Base.Checked.checked_mul(ncells, 1 + tw)
    terms = if _acfold_is_table(fold)
        fold.seg[end] - 1
    else
        per = 1
        for r in fold.ranges
            per = Base.Checked.checked_mul(per, length(r))
        end
        Base.Checked.checked_mul(ncells, per)
    end
    return Base.Checked.checked_add(ncells, Base.Checked.checked_mul(terms, tw))
end

# The fold around the term for cell `cv`: `acc = acc ⊕ term` innermost, with the
# contracted counters `kvs` bound by the loops (STATIC) or from the cell's table
# entries (TABLE). The seed is the `Float64` 0̄ itself, as the per-cell fold
# (`_eval_contraction`) seeds it: under a `Dual` value type `0̄ ⊕ term` then
# carries the term's partials exactly, where a seed converted to the value type
# would add zero partials to them and turn a `-0.0` partial into `0.0`.
function _cg_fold(ctx::_CGCtx, fold::_ACFold, cv::Symbol, kvs::Vector{Symbol}, term,
                  ev::Union{Nothing,Symbol}=nothing)
    fnsym = _cg_oplus_fn(fold.op)
    acc = _cg_name(ctx, "acc")
    upd = :($acc = $fnsym($acc, $term))
    loop = if _acfold_is_table(fold)
        ev === nothing && (ev = _cg_name(ctx, "ent"))
        segv = _ac_entry_local(ctx, fold.seg)
        binds = Any[:(local $(kvs[r]) = $(_ac_entry_local(ctx, fold.cols[r]))[$ev])
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
    g.mask === nothing || _ac_mask_refresh!(g.mask, g.tabs, du, u, p, t)
    _run_cg_maybe_threaded!(g.f, g.tabs, du, u, p, t, g.tcache)
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

# The section is what the right-hand side keeps, so the re-emission closures
# (`remit`), which only the build's consumer pass reads, are dropped here.
_make_contraction_section(acs::AbstractVector) =
    _ContractionSection(Tuple(map(_ac_drop_remit, acs)))

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

# ---- State consumers of an observed's nest -----------------------------------
# An observed filled by a contraction on every call, and read by exactly one
# state kernel through one affine descriptor that maps the kernel's cells onto
# the observed's cells one to one and in order (the regrid's
# `D(F_tgt[j]) = F_rg[j] - F_tgt[j]`), lets the nest compute that kernel's cell
# right after its own, from the value it just stored — the rule a fused scan
# takes its consumer by (`_scan_consumer`, scan_fused.jl). The state kernel
# section then leaves the consumer out, which saves its pass over the observed
# and, threaded, puts it in the nest's dispatch. The observed is still stored,
# for any other reader. A kernel already taken (`consumed`) is not offered
# again; a nest whose re-emission declines keeps its plain form.
function _ac_take_consumers(acs::AbstractVector, Ks::AbstractVector{_AccKernel},
                            nst::Int, consumed::IdDict{Any,Bool})
    (isempty(acs) || nst <= 0 || _codegen_disabled()) && return acs
    out = similar(acs, 0)
    for g in acs
        r = g.remit
        if r === nothing
            push!(out, g)
            continue
        end
        outs, emit = r
        free = _AccKernel[K for K in Ks if !haskey(consumed, K)]
        c = _scan_consumer(outs, free, nst)
        g2 = c === nothing ? nothing : emit(c)
        if g2 isa _ArrayContraction
            consumed[c[1]] = true
            _tally_cascade!(:array_contraction_consumer)
            push!(out, g2)
        else
            push!(out, g)
        end
    end
    return out
end
