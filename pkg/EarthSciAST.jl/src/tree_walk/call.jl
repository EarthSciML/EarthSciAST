# tree_walk/call.jl — a template reference compiled as a CALL (esm-spec §9.6.4
# rule 2; design: callnode-design.md).
#
# A reference is never expanded: its template body is compiled ONCE per
# instance into a `_CallTarget`, and each use is an `_NK_CALL` node whose
# children are the argument values, evaluated in the caller. Inside the body a
# parameter (declared, or implicit: a name the body reads from its caller,
# `_tpl_augment`) is an `_NK_ARG` leaf. The body reads its caller only through
# its arguments, so one compiled body serves every use with the same instance.
#
# Which references are calls is decided in one place, `_tpl_is_called`
# (templates/frames.jl).
#
# ARGUMENT FRAMES (the walkers). The arguments of a running call live on one
# argument stack per build (`_ArgStack`); a target's `fp` is the stack position
# of its innermost running call. A call evaluates all its arguments first
# (pushing each as it is computed, so an argument that itself calls something
# pushes above it), then moves its target's `fp`, runs the body, and restores
# both. The template graph is acyclic (esm-spec §9.7.3), so a body never calls
# its own target, and an `_NK_ARG` always reads its own call's frame. The
# walkers are single-threaded (threads run only emitted code, where arguments
# are function arguments), so one stack per build is race-free.
#
# VALUE TYPES. An argument keeps its own type: a literal argument is a
# `Float64` even under a ForwardDiff walk, exactly as the literal is where the
# expansion would have put it (the `^` arm relies on a literal exponent staying
# a `Float64`). The stack therefore holds a `Float64` buffer and, under AD, a
# buffer of the value type with a flag per position saying which one holds it.

mutable struct _ArgStack
    f64::Vector{Float64}
    alt::Any                    # Vector{T} for the AD value type, made on first use
    isalt::Vector{Bool}         # position holds a value of the AD type
    top::Int
end
_ArgStack() = _ArgStack(Float64[], nothing, Bool[], 0)

# An ARRAY argument (frames.jl `_TplCallInfo.arrays`): the array a reference
# binds to an array parameter, passed at run time. `data` is the same payload
# the build's own gathers read (`_StateGather` for `:state` and `:block`,
# `_ConstGatherArray` for `:const` and `:live`), so a read through the argument
# is the gather the expansion would have compiled, bit for bit.
#
# A `:block` array is a state array stored as one block of the state vector
# (`run_base != 0`): its layout (strides and bounds) is part of the target, and
# its base slot is a SCALAR argument of the call (a `"\0base\0"` slot, its
# value the literal base). Two sites passing different state arrays of one
# layout (two tracers) are then the same call with a different literal, so
# every pass that merges cells or kernels by structure (a literal that differs
# becomes a per-member table) merges them, as it merged their expansions.
struct _ArrArg
    kind::Symbol
    data::Any
    name::String
end

mutable struct _CallTarget
    name::String                # the template, for messages
    key::String                 # the instance key it was compiled for
    slots::Vector{String}       # the body's scalar argument sentinels, in slot order
    arrslots::Vector{String}    # the body's array argument sentinels, in slot order
    arrkinds::Vector{Symbol}    # each array slot's kind (part of `key`)
    arrdims::Vector{Vector{Int}} # each const or live array slot's dimensions (part of `key`)
    body::_Node
    stack::_ArgStack
    fp::Int                     # stack position below the innermost running call's arguments
    nodes::Int                  # node count of `body` (emitter inline policy)
    curarrs::Vector{_ArrArg}    # the array arguments of the innermost running call
    passed::Vector{Int}         # per array slot: its position in a site's `arrays`, 0 for a block
    baseidx::Vector{Int}        # per array slot: the scalar slot of its base, 0 unless a block
    blocks::Vector{Any}         # per array slot: a block's layout (`_StateGather`), else nothing
end

# An array argument a body passes on to a call in it: array slot `j` of the
# running call of `target` (its caller's array, whatever that is at run time).
struct _FwdArr
    target::_CallTarget
    j::Int
end

# The array `a` is, through any forwarding, for the running calls.
@inline function _arr_resolve(a::_ArrArg)
    while a.data isa _FwdArr
        f = a.data::_FwdArr
        a = @inbounds f.target.curarrs[f.target.passed[f.j]]
    end
    return a
end

# A const or live array argument's dimensions, and a block's layout, also when
# forwarded (from the forwarding target's own key).
function _arrarg_dims(a::_ArrArg)
    a.data isa _FwdArr && return (a.data::_FwdArr).target.arrdims[(a.data::_FwdArr).j]
    return (a.data::_ConstGatherArray).dims
end
function _arrarg_block(a::_ArrArg)
    a.data isa _FwdArr && return (a.data::_FwdArr).target.blocks[(a.data::_FwdArr).j]::_StateGather
    return a.data::_StateGather
end

# One call site's payload: the target and the arrays this site passes. Sites
# with the same target and the same arrays are one object (`_call_site`), so
# passes that key a call by its payload treat them alike.
struct _CallSite
    target::_CallTarget
    arrays::Vector{_ArrArg}
end

# The array-gather read of a body (`_NK_ARG_GATHER`): array slot `j` of `target`.
struct _ArgGatherRef
    target::_CallTarget
    j::Int
end

# The call targets of one build: the template table and the compiled targets
# by instance key. Held on the build state (`_BuildState.calls`).
struct _CallTable
    tt::_TplTable
    targets::Dict{String, _CallTarget}
    stack::_ArgStack
    sites::Dict{Tuple{_CallTarget, Vector{UInt}}, _CallSite}
    # The count tables built from array arguments, by (array, lo, hi): one
    # object per table for the build (codegen_kernel.jl `_cg_site_count_tables`).
    ctabs::Dict{Tuple{UInt, Int, Int}, Any}
    # One `_ArrArg` per const or live array (by the identity of its data), so
    # two sites passing the same array are the same `_CallSite`.
    arrs::Dict{Tuple{Symbol, UInt}, _ArrArg}
    # Targets by the structure of their compiled body (`_call_canon`): two
    # instances that compile to the same function are one target.
    bystruct::Dict{String, _CallTarget}
    # Per instance key, the slot names of ITS bindings (`slots`, `arrslots`):
    # a target shared by structure reads each instance's own names; and the
    # last reference `_call_target` answered, with its names, for
    # `_call_args` / `_call_arrays` right after it.
    keyslots::Dict{String, Tuple{Vector{String}, Vector{String}}}
    last::Vector{Any}
end
_CallTable(reg) = _CallTable(
    _TplTable(reg), Dict{String, _CallTarget}(), _ArgStack(),
    Dict{Tuple{_CallTarget, Vector{UInt}}, _CallSite}(), Dict{Tuple{UInt, Int, Int}, Any}(),
    Dict{Tuple{Symbol, UInt}, _ArrArg}(), Dict{String, _CallTarget}(),
    Dict{String, Tuple{Vector{String}, Vector{String}}}(), Any[nothing, nothing]
)

# The slot names `expr`'s bindings are read by (`_call_target` answered it last).
function _call_names(tg::_CallTarget, expr::OpExpr)
    ct = _call_table()
    (ct !== nothing && (ct::_CallTable).last[1] === expr) || return (tg.slots, tg.arrslots)
    return (ct::_CallTable).last[2]::Tuple{Vector{String}, Vector{String}}
end

# The build's one `_ArrArg` of kind `k` over the source object `src`.
function _arrarg_interned(mk, k::Symbol, src)
    ct = _call_table()
    ct === nothing && return mk()
    return get!(mk, (ct::_CallTable).arrs, (k, objectid(src)))
end

# The body compile's argument map (`_compile(::VarExpr)` reads `idx`, the
# resolve of `index(<array sentinel>, …)` reads `arr`).
struct _ArgMap
    target::_CallTarget
    idx::Dict{String, Int}
    arr::Dict{String, Int}
end

_call_table() = _build_state().calls

_no_call_table(name) = TreeWalkError(
    "E_TREEWALK_UNRESOLVED_TEMPLATE_REF",
    "template reference '$(name)' reached compile with no template registry in the build"
)

# ---- Compile -------------------------------------------------------------------

"""
    _compile_call(expr, var_map, param_syms, memo) -> _Node

The `_NK_CALL` of the reference `expr`: its target (compiled on first use) and
its arguments, compiled in the caller's context.
"""
function _compile_call(expr::OpExpr, var_map, param_syms, memo::_MaybeMemo)
    ct = _call_table()
    ct === nothing && throw(_no_call_table(expr.name))
    tg = _call_target(ct, expr)
    kids = _Node[_compile(a, var_map, param_syms, memo) for a in _call_args(tg, expr)]
    return _call_node(tg, kids, _call_arrays(tg, expr))
end

# Any compiler of expressions to `_Node` (`_compile`, the setup geometry
# compiler) compiles a reference the same way: the target from `_call_target`,
# the arguments (`_call_args`, in slot order) compiled in its own context, the
# arrays (`_call_arrays`), and `_call_node`.
function _call_node(tg::_CallTarget, kids::Vector{_Node}, arrs::Vector{_ArrArg} = _ArrArg[])
    length(arrs) == count(!=(0), tg.passed) || throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_OP",
            "template '$(tg.name)': a call site passes $(length(arrs)) of its $(count(!=(0), tg.passed)) array arguments"
        )
    )
    _count!(:call_sites)
    return _mknode(kind = _NK_CALL, op = Symbol(tg.name), payload = _call_site(tg, arrs), children = kids)
end

# The one `_CallSite` of `tg` passing `arrs`.
function _call_site(tg::_CallTarget, arrs::Vector{_ArrArg})
    ct = _call_table()
    ct === nothing && return _CallSite(tg, arrs)
    key = (tg, UInt[objectid(a.data) for a in arrs])
    return get!(() -> _CallSite(tg, arrs), (ct::_CallTable).sites, key)
end

# The array each array slot of `tg` reads at the reference `expr`: its binding
# as the resolve left it (`_resolve_call_bindings` turns an array binding into
# an `__arrarg` marker carrying the `_ArrArg`).
function _call_arrays(tg::_CallTarget, expr::OpExpr)
    isempty(tg.arrslots) && return _ArrArg[]
    b = expr.bindings === nothing ? Dict{String, ASTExpr}() : expr.bindings
    out = _ArrArg[]
    for (j, s) in enumerate(_call_names(tg, expr)[2])
        a = _call_arrarg(tg, b, s)
        a.kind === tg.arrkinds[j] || throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "template '$(tg.name)': array argument $(repr(s)) is a $(a.kind) array, " *
                    "the target was compiled for a $(tg.arrkinds[j]) array"
            )
        )
        # A block is passed by its base, a scalar argument (`_call_args`).
        tg.passed[j] == 0 || push!(out, a)
    end
    return out
end

# The `_ArrArg` the reference binds to array slot `s` (resolved to its marker).
function _call_arrarg(tg::_CallTarget, b::AbstractDict, s::String)
    v = if startswith(s, _TPL_INA)
        # An array read inside a binding compiled into the instance.
        p, k = rsplit(s[(ncodeunits(_TPL_INA) + 1):end], '\0'; limit = 2)
        _inl_arrays(b[String(p)])[parse(Int, k)]
    else
        _call_arg(b, s)
    end
    (v isa OpExpr && v.op == "__arrarg" && v.value isa _ArrArg) || throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_OP",
            "template '$(tg.name)': the array argument $(repr(s)) reached compile " *
                "unresolved"
        )
    )
    return v.value::_ArrArg
end

# The binding expression of each argument slot of `tg` at the reference `expr`.
function _call_args(tg::_CallTarget, expr::OpExpr)
    b = expr.bindings === nothing ? Dict{String, ASTExpr}() : expr.bindings
    slots = _call_names(tg, expr)[1]
    out = Vector{ASTExpr}(undef, length(slots))
    for (i, s) in enumerate(slots)
        if startswith(s, _TPL_IN)
            # A leaf of a compound binding compiled into the instance.
            p, k = rsplit(s[(ncodeunits(_TPL_IN) + 1):end], '\0'; limit = 2)
            out[i] = _inl_leaves(b[String(p)])[parse(Int, k)]
        elseif startswith(s, _TPL_BASE)
            # A block array's base slot: the literal base of the array bound.
            a = _call_arrarg(tg, b, s[(ncodeunits(_TPL_BASE) + 1):end])
            if a.data isa _FwdArr
                # Passed on: the base is the forwarding body's own base argument.
                f = a.data::_FwdArr
                out[i] = VarExpr(_TPL_BASE * f.target.arrslots[f.j])
            else
                out[i] = NumExpr(Float64((a.data::_StateGather).run_base))
            end
        else
            out[i] = _call_arg(b, s)
        end
    end
    return out
end

# The binding of argument sentinel `s` in the bindings `b` of a reference.
function _call_arg(b::AbstractDict, s::String)
    if startswith(s, _TPL_ARG)
        p = s[(ncodeunits(_TPL_ARG) + 1):end]
        v = get(b, p, nothing)
        v === nothing && throw(
            ExpressionTemplateError(
                ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                "apply_expression_template missing binding for param '$p'"
            )
        )
        return v
    end
    # An implicit parameter the reference does not carry reads the caller's
    # name of the same spelling (`_tpl_frame`).
    v = get(b, s, nothing)
    return v === nothing ? VarExpr(s[(ncodeunits(_TPL_FREE) + 1):end]) : v
end

# The target of the reference `expr` in the open build.
function _call_target(expr::OpExpr)
    ct = _call_table()
    ct === nothing && throw(_no_call_table(expr.name))
    return _call_target(ct, expr)
end

# The fixed parameters of a reference (`info.fixed`: reduction or output range
# bounds) with their integer literal values, into `S`.
function _call_fixed!(S::Dict{String, Any}, name, info::_TplCallInfo, b::AbstractDict)
    for s in info.fixed
        p = s[(ncodeunits(_TPL_ARG) + 1):end]
        v = _call_arg(b, s)
        iv = v isa IntExpr ? Int(v.value) : v isa NumExpr && isinteger(v.value) ? Int(v.value) :
            throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "template '$name': parameter '$p' bounds a range and needs an integer literal"
            )
        )
        S[p] = iv
    end
    return S
end

# The target of reference `call`: one per INSTANCE, keyed by the template,
# the value of each fixed parameter (a reduction bound, substituted into the
# instance's body), and the kind of each array argument. Arrays themselves are
# run-time data (`_CallSite`), so every array of one kind shares the target.
function _call_target(ct::_CallTable, call::OpExpr)
    name = String(call.name)
    def = _tpl_def(ct.tt, name)
    def.closed === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_OP",
            "template '$name' has a parameter in a structural position; the build " *
                "does not compile it as a call yet"
        )
    )
    info = _tpl_call_info(ct.tt, name)
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    S = Dict{String, Any}()
    arrkind = Dict{String, Symbol}()
    arrdims = Dict{String, Vector{Int}}()
    blocks = Dict{String, _StateGather}()
    io = IOBuffer()
    print(io, name)
    if info !== nothing
        _call_fixed!(S, name, info, b)
        for p in sort!(collect(keys(S)))
            print(io, '\x01', p, '=', S[p])
        end
        hp = _call_has_lanes(call) ? _call_hoist_plan(ct.tt, def, S, _call_outs(info, call)) : nothing
        asrc = Tuple{String, ASTExpr}[]
        for s in sort!(collect(info.arrays))
            # An array every read of which the caller makes (`_call_hoist_plan`)
            # is no argument.
            hp === nothing || !(s in hp.whole) || continue
            push!(asrc, (s, _call_arg(b, s)))
        end
        # The arrays read inside bindings compiled into the instance.
        for p in sort!(collect(def.params))
            v = get(b, p, nothing)
            (v === nothing || !_inl_is_marked(v)) && continue
            for (k, m) in enumerate(_inl_arrays(v))
                push!(asrc, (_TPL_INA * p * "\0" * string(k), m))
            end
        end
        for (s, v) in asrc
            k = (v isa OpExpr && v.value isa _ArrArg) ? (v.value::_ArrArg).kind : :unresolved
            arrkind[s] = k
            print(io, '\x02', s, '=', k)
            # A const or live array's dimensions are part of the instance:
            # a subscript the body proves inside them reads directly.
            if k === :const || k === :live
                d = _arrarg_dims(v.value::_ArrArg)
                arrdims[s] = copy(d)
                print(io, '/', join(d, 'x'))
            elseif k === :block
                # A block's layout is part of the instance; its base is an argument.
                sg = _arrarg_block(v.value::_ArrArg)
                print(io, '/', join(sg.strides, ','), '/', join(sg.lo, ','), '/', join(sg.hi, ','), '/', sg.len)
                blocks[s] = sg
            end
        end
    end
    outs = info === nothing ? String[] : info.outs
    isempty(outs) || print(io, '\x03', "elem")
    hp = info === nothing || !_call_has_lanes(call) ? nothing : _call_hoist_plan(ct.tt, def, S, outs)
    hp === nothing || print(io, '\x04', "lanes")
    # Compound bindings read only on some paths, compiled into the instance.
    inl = info === nothing ? Dict{String, ASTExpr}() : _call_inlined(ct.tt, info, def, S, b)
    for sn in sort!(collect(keys(inl)))
        print(io, '\x05', sn, '=', _inl_key(b[sn[(ncodeunits(_TPL_ARG) + 1):end]]))
    end
    key = String(take!(io))
    got = get(ct.targets, key, nothing)
    if got !== nothing
        ct.last[1] = call
        ct.last[2] = ct.keyslots[key]
        return got
    end
    if !isempty(outs)
        haskey(b, _TPL_OUT * outs[1]) || throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "array-valued template '$name' is read other than through `index`"
            )
        )
    end
    inst = _tpl_inst_closed(ct.tt, def, S)
    ibody = _call_ibody(ct.tt, def, S, outs)
    # Each read the caller makes is the argument `"\0lane\0k"`.
    hp === nothing || (ibody = hp.body)
    isempty(inl) || (ibody = _tpl_subst_scoped(ibody, inl, IdDict{OpExpr, ASTExpr}()))
    arrslots = sort!(collect(keys(arrkind)))
    # Scalar slots: the argument sentinels in the order the body first reads
    # them (so two instances whose bodies have one structure have one slot
    # order, `_call_canon`), then any the body does not read.
    cand = String[_TPL_ARG * p for p in def.params if !haskey(S, p)]
    append!(cand, String[_TPL_FREE * n for n in inst.free])
    append!(cand, String[_TPL_OUT * o for o in outs])
    hp === nothing || append!(cand, String[_TPL_LANE * string(k) for k in eachindex(hp.gathers)])
    filter!(s -> !haskey(arrkind, s) && !(hp !== nothing && s in hp.whole) && !haskey(inl, s), cand)
    # A declared parameter the body never reads as a value is no argument
    # (its binding is never made, as in the expansion).
    info === nothing || filter!(s -> !startswith(s, _TPL_ARG) || s in info.scalars, cand)
    for (sn, sk) in inl
        p = sn[(ncodeunits(_TPL_ARG) + 1):end]
        append!(cand, String[_TPL_IN * p * "\0" * string(k) for k in 1:_inl_count(b[p])])
    end
    slots = _call_first_reads(ibody, Set{String}(cand))
    append!(slots, sort!(setdiff(cand, slots)))
    append!(slots, String[_TPL_BASE * s for s in arrslots if haskey(blocks, s)])
    passed = zeros(Int, length(arrslots))
    np = 0
    for (j, s) in enumerate(arrslots)
        haskey(blocks, s) || (passed[j] = (np += 1))
    end
    tg = _CallTarget(
        replace(name, '\0' => '·'), key, slots, arrslots, Symbol[arrkind[s] for s in arrslots],
        Vector{Int}[get(arrdims, s, Int[]) for s in arrslots],
        _mknode(kind = _NK_LITERAL), ct.stack, 0, 0, _ArrArg[],
        passed, Int[haskey(blocks, s) ? findfirst(==(_TPL_BASE * s), slots) : 0 for s in arrslots],
        Any[get(blocks, s, nothing) for s in arrslots]
    )
    am = _ArgMap(
        tg, Dict{String, Int}(s => i for (i, s) in enumerate(slots)),
        Dict{String, Int}(s => j for (j, s) in enumerate(arrslots))
    )
    st = _build_state()
    saved = st.argmap
    st.argmap = am
    body = try
        # The body binds nothing of the caller's: an empty state map and no
        # parameters. Every name it reads is an argument; an `index` of an
        # array argument resolves to an argument gather (`_arg_gather_resolve`).
        # One memo for both passes: a body is a DAG (a shared sub-term, such
        # as an interpolation's bracket index, is read many times), and an
        # unmemoized pass would walk it as a tree.
        bm = _BuildMemo()
        rb = _resolve_indices(
                ibody, Dict{String, Tuple{Vector{Int}, Vector{Int}}}(), _EMPTY_VARMAP,
                _EMPTY_CONST_ARRAYS, _EMPTY_PGATHER, bm
            )
        _compile(rb, _EMPTY_VARMAP, Set{Symbol}(), bm)
    finally
        st.argmap = saved
    end
    tg.body = body
    tg.nodes = _call_body_size(body)
    # One target per compiled structure: an instance whose body compiles to
    # the function another instance already has calls that one.
    canon = _call_canon(tg)
    ct.keyslots[key] = (slots, arrslots)
    ct.last[1] = call
    ct.last[2] = ct.keyslots[key]
    if canon !== nothing
        same = get(ct.bystruct, canon, nothing)
        if same !== nothing
            ct.targets[key] = same
            _count!(:call_targets_shared)
            return same
        end
        ct.bystruct[canon] = tg
    end
    ct.targets[key] = tg
    _count!(:call_targets)
    return tg
end

# The output indices `call` binds (an element call), else none.
_call_outs(info::_TplCallInfo, call::OpExpr) = _tpl_is_elem(call) ? info.outs : String[]

# The body a call to `def` with fixed values `S` compiles, as an AST: the
# instance's prepared body, or for an element call its element (the `faq`'s
# expression with each output index read as the argument `"\0out\0o"`).
# One object per (template, `S`, element), so the hoist plan below can name
# its nodes by identity.
function _call_ibody(tt::_TplTable, def::_TplDef, S::Dict{String, Any}, outs::Vector{String})
    memo = _tpl_memo(tt, nothing, :call_ibody, () -> Dict{Tuple{String, String, Bool}, ASTExpr}())
    skey = join(sort!([k * "\0" * string(v) for (k, v) in S]), "\x01")
    return get!(memo, (def.name, skey, !isempty(outs))) do
        ibody = _call_iset_ranges(tt, _tpl_inst_closed(tt, def, S).body, IdDict{OpExpr, ASTExpr}())
        isempty(outs) && return ibody
        m = Dict{String, ASTExpr}(o => VarExpr(_TPL_OUT * o) for o in outs)
        _tpl_subst_scoped((ibody::OpExpr).expr_body, m, IdDict{OpExpr, ASTExpr}())
    end
end

# `e` with each scalar reduction's range over a whole interval index set
# (`{"from": S}`) read as the dense range `[1, size(S)]` it denotes: the same
# indices in the same order, in the form a call body loops over.
function _call_iset_ranges(tt::_TplTable, e::ASTExpr, memo::IdDict{OpExpr, ASTExpr})
    e isa OpExpr || return e
    r = get(memo, e, nothing)
    r === nothing || return r
    r = map_children(c -> _call_iset_ranges(tt, c, memo), e)
    if _is_faq_op(r.op) && r.ranges !== nothing && (r.output_idx === nothing || isempty(r.output_idx)) &&
            any(v -> v isa IndexSetRef, values(r.ranges))
        rg = empty(r.ranges)
        for (k, v) in r.ranges
            n = v isa IndexSetRef ? _tpl_iset_extent(tt, v) : nothing
            rg[k] = n === nothing ? v : Any[1, n]
        end
        r = reconstruct(r; ranges = rg)
    end
    memo[e] = r
    return r
end

# ---- Reads the caller makes ("lanes") --------------------------------------------
# A read of an array argument at subscripts that are arguments or arguments
# plus a literal (`q[i+1, j, k]` in an element body), made on every path that
# runs the body, is made by the CALLER instead and passed as a scalar
# argument (`"\0lane\0k"` => `index(q_bound, s′...)`, the subscripts read as
# the call's bindings). The value is the same read of the same array at the
# same subscripts, so the bits are; what changes is where it is made:
#
#   * the body is then a function of values only, the shape a stencil sub-
#     kernel had: two templates that differ only in WHICH cells they read
#     (a face flux at the interior and at each boundary row) compile to the
#     same function (`_call_canon`), called with different reads;
#   * in the stencil tier the reads are lanes of the caller, so the kernels of
#     different region classes and tracers merge by structure, as their
#     expansions did;
#   * an array bound to an observed the interpreter inlines is read in the
#     caller, where the inlining is.
#
# A read made only on some paths stays in the body (made in the caller, it
# could fail where the body would not have made it).

const _TPL_LANE = "\0lane\0"

struct _HoistPlan
    gathers::Vector{OpExpr}     # the read each lane makes, lane k = gathers[k]
    body::ASTExpr               # the body with each such read the argument `"\0lane\0k"`
    whole::Set{String}          # the array sentinels every read of which is a lane
end

# The array sentinels `call` passes as array arguments: its template's
# arrays, less those whose every read the caller makes (lanes).
function _call_array_slots(tt::_TplTable, call::OpExpr)
    info = _tpl_call_info(tt, call.name)
    info === nothing && return nothing
    _call_has_lanes(call) || return info.arrays
    def = _tpl_def(tt, call.name)
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    S = _call_fixed!(Dict{String, Any}(), call.name, info, b)
    return setdiff(info.arrays, _call_hoist_plan(tt, def, S, _call_outs(info, call)).whole)
end

_call_has_lanes(call::OpExpr) = call.bindings !== nothing && any(k -> startswith(k, _TPL_LANE), keys(call.bindings))

_hoist_int(x) = x isa IntExpr || (x isa NumExpr && isinteger(x.value))
_hoist_arg(x) = x isa VarExpr && (_tpl_is_sentinel(x.name) || startswith(x.name, _TPL_OUT) || startswith(x.name, _TPL_IN))
# A subscript the caller reads as a lane: integers and arguments under `+`
# and `-` (affine in the arguments with unit coefficients).
function _hoist_sub(x)
    (_hoist_int(x) || _hoist_arg(x)) && return true
    x isa OpExpr && (x.op == "+" || x.op == "-") && 1 <= length(x.args) <= 2 && _tpl_structless(x) || return false
    return all(_hoist_sub, x.args)
end

function _call_hoist_plan(tt::_TplTable, def::_TplDef, S::Dict{String, Any}, outs::Vector{String})
    memo = _tpl_memo(tt, nothing, :call_hoist, () -> Dict{Tuple{String, String, Bool}, _HoistPlan}())
    skey = join(sort!([k * "\0" * string(v) for (k, v) in S]), "\x01")
    return get!(memo, (def.name, skey, !isempty(outs))) do
        info = _tpl_call_info(tt, def.name)::_TplCallInfo
        body = _call_ibody(tt, def, S, outs)
        st = (; tt, arrays = info.arrays, gathers = OpExpr[], keep = Set{String}(), has = IdDict{OpExpr, Bool}())
        nbody = _hoist_rw(body, false, st)
        # An array with a read left in the body stays an array argument; its
        # other reads are still made by the caller.
        _HoistPlan(st.gathers, nbody, setdiff(info.arrays, st.keep))
    end
end

# Does `e` hold a read of an array argument?
function _hoist_has(e::ASTExpr, st)
    e isa OpExpr || return false
    got = get(st.has, e, nothing)
    got === nothing || return got
    r = (e.op == "index" && !isempty(e.args) && e.args[1] isa VarExpr && (e.args[1]::VarExpr).name in st.arrays) ||
        (_tpl_is_call(e) && e.bindings !== nothing && any(v -> v isa VarExpr && v.name in st.arrays, values(e.bindings)))
    r || foreach_child(c -> (r = r || _hoist_has(c, st)), e)
    return st.has[e] = r
end

# The body with every read made on every path at lane subscripts a lane, one
# lane per OCCURRENCE (a read node reached twice is two lanes): two instances
# whose bodies differ only in which cells they read then have the same lanes
# in the same places, and so the same compiled body (`_call_canon`). `cond`:
# the node is evaluated only on some paths.
function _hoist_rw(e::ASTExpr, cond::Bool, st)
    (e isa OpExpr && _hoist_has(e, st)) || return e
    if _tpl_is_call(e)
        inner = _tpl_call_info(st.tt, e.name)
        b = e.bindings::AbstractDict
        nb = nothing
        for k in sort!(collect(keys(b)))
            v = b[k]
            # An array passed on to the inner call stays an array argument.
            if v isa VarExpr && v.name in st.arrays
                push!(st.keep, v.name)
                continue
            end
            s = startswith(k, _TPL_FREE) || startswith(k, _TPL_OUT) ? k : _TPL_ARG * k
            # A binding the inner call passes as a value is made where the
            # inner call is (`_tpl_is_called`).
            c = cond || !(inner !== nothing && (s in inner.uncond || _tpl_plain_binding(v)))
            r = _hoist_rw(v, c, st)
            r === v && continue
            nb === nothing && (nb = Dict{String, ASTExpr}(b))
            nb[k] = r
        end
        return nb === nothing ? e : reconstruct(e; bindings = nb)
    end
    if e.op == "index" && _tpl_structless(e) && length(e.args) >= 2 &&
            e.args[1] isa VarExpr && (e.args[1]::VarExpr).name in st.arrays
        if !cond && all(_hoist_sub, @view e.args[2:end])
            push!(st.gathers, e)
            return VarExpr(_TPL_LANE * string(length(st.gathers)))
        end
        push!(st.keep, (e.args[1]::VarExpr).name)
        return e
    end
    if _is_faq_op(e.op)
        # A reduction's terms may be none: everything in it is conditional.
        return map_children(c -> _hoist_rw(c, true, st), e)
    end
    return map_children(e) do c
        j = findfirst(a -> a === c, e.args)
        _hoist_rw(c, j === nothing ? true : cond || _op_arg_conditional(e.op, j), st)
    end
end

# `call` with its lanes: each read of its plan as the binding
# `"\0lane\0k" => index(<array bound>, <subscripts read as the bindings>)`.
function _tpl_with_lanes(tt::_TplTable, call::OpExpr)
    info = _tpl_call_info(tt, call.name)
    (info === nothing || isempty(info.arrays)) && return call
    _call_has_lanes(call) && return call
    outs = _call_outs(info, call)
    isempty(info.outs) || !isempty(outs) || return call      # a whole array: its view does this
    def = _tpl_def(tt, call.name)
    def.closed === nothing && return call
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    S = _call_fixed!(Dict{String, Any}(), call.name, info, b)
    hp = _call_hoist_plan(tt, def, S, outs)
    isempty(hp.gathers) && return call
    nb = copy(b)
    m = Dict{String, ASTExpr}()
    for (k, g) in enumerate(hp.gathers)
        for x in g.args
            _hoist_bind!(m, x, b)
        end
        nb[_TPL_LANE * string(k)] = _tpl_subst_scoped(g, m, IdDict{OpExpr, ASTExpr}())
    end
    return reconstruct(call; bindings = nb)
end
function _hoist_bind!(m, x, b)
    if x isa VarExpr
        haskey(m, x.name) || (m[x.name] = _call_arg(b, x.name))
    elseif x isa OpExpr
        foreach(a -> _hoist_bind!(m, a, b), x.args)
    end
    return
end

# The sentinels of `cand` that `e` reads, in first-read order (bindings of a
# nested call in name order).
function _call_first_reads(e::ASTExpr, cand::Set{String})
    out = String[]
    seen = Set{String}()
    vis = IdDict{OpExpr, Nothing}()
    function walk(x)
        if x isa VarExpr
            (x.name in cand && !(x.name in seen)) && (push!(seen, x.name); push!(out, x.name))
            return
        end
        x isa OpExpr || return
        haskey(vis, x) && return
        vis[x] = nothing
        if _tpl_is_call(x)
            foreach(walk, _operands(x))
            return
        end
        foreach(walk, x.args)
        foreach_child(c -> any(a -> a === c, x.args) || walk(c), x)
        return
    end
    walk(e)
    return out
end

# A structural key of target `tg`'s compiled body, equal for two targets
# whose bodies are the same function of their slots; `nothing` when the body
# holds a node this key does not describe (no sharing then).
function _call_canon(tg::_CallTarget)
    io = IOBuffer()
    print(io, length(tg.slots), '|', tg.arrkinds, '|', tg.arrdims, '|')
    for (j, bl) in enumerate(tg.blocks)
        bl === nothing && continue
        sg = bl::_StateGather
        print(io, j, ':', sg.strides, sg.lo, sg.hi, sg.len, ';')
    end
    print(io, tg.baseidx, '|')
    ids = _NodeIdMap{Int}()
    ok = Ref(true)
    nid = Ref(0)
    function walk(n::_Node)
        got = get(ids, n, 0)
        got == 0 || return got
        for c in n.children
            walk(c)
        end
        k = n.kind
        pl = n.payload
        print(io, '[', Int(k), ' ', n.op, ' ', reinterpret(UInt64, n.literal), ' ', n.idx, ' ', n.sym, ' ')
        if k === _NK_ARG
            print(io, 'A')
        elseif k === _NK_ARG_GATHER
            print(io, 'G', (pl::_ArgGatherRef).j)
        elseif k === _NK_CALL
            print(io, 'F', objectid(pl))
        elseif pl !== nothing
            ok[] = false
        end
        for c in n.children
            print(io, ' ', ids[c])
        end
        print(io, ']')
        return ids[n] = (nid[] += 1)
    end
    walk(tg.body)
    return ok[] ? String(take!(io)) : nothing
end

const _EMPTY_VARMAP = Dict{String, Int}()

const _TPL_BASE = "\0base\0"
const _TPL_IN = "\0in\0"
const _TPL_INA = "\0ina\0"

# ---- Compound bindings compiled into the instance -------------------------------
# A parameter the body reads only on some paths, bound to a compound
# expression (frames.jl `_tpl_inlinable`), is compiled INTO the instance (the
# user's bound-expression rule): the binding's operator skeleton is part of the
# instance key and is substituted into the body, and its leaves (names and
# literals) are arguments (`"\0in\0p\0k"`), so the binding is evaluated only
# where the body reads it. A leaf is an argument, not part of the key, so a
# per-cell substitution (a loop index becoming a number) does not make an
# instance per cell; a literal exponent stays in the skeleton (`x^2`).

function _call_inlined(tt::_TplTable, info::_TplCallInfo, def::_TplDef, S, b::AbstractDict)
    out = Dict{String, ASTExpr}()
    for p in def.params
        haskey(S, p) && continue
        v = get(b, p, nothing)
        v === nothing && continue
        _call_inl_mode(tt, info, def, p, v) === :none && continue
        k = Ref(0)
        a = Ref(0)
        out[_TPL_ARG * p] = _inl_is_marked(v) ? _inl_mskel(v, p, k, a) : _inl_skel(v, p, k)
    end
    return out
end

# How the binding `v` of parameter `p` reaches the body: `:none` (passed as a
# value, or an array, or never read), `:plain` (a compound binding of names,
# literals and elementwise operators read on some paths only, compiled into
# the instance with its names and literals as arguments), `:marked` (one that
# reads an array, or reads a name the body binds: compiled into the instance
# with its leaves marked where the reference's bindings resolve,
# `_call_mark_inlined`).
function _call_inl_mode(tt::_TplTable, info::_TplCallInfo, def::_TplDef, p::String, v::ASTExpr)
    sn = _TPL_ARG * p
    (sn in info.arrays || sn in info.fixed || !(sn in info.scalars)) && return :none
    _inl_is_marked(v) && return :marked
    B = _tpl_body_binders(tt, def.name)
    rb = !isempty(B) && _tpl_reads_any(v, B)
    if !rb
        sn in info.uncond && return :none
        _tpl_plain_binding(v) && return :none
    end
    _tpl_inlinable(v) || return :none
    return (rb || _inl_has_index(v)) ? :marked : :plain
end

_inl_has_index(v::ASTExpr) = v isa OpExpr && (v.op == "index" || any(_inl_has_index, v.args))

# A marked binding (`_call_mark_inlined`): its caller values are
# `__inleaf(value)` nodes, its arrays `__arrarg` markers, and a bare name in it
# is one the body binds (it stays a name, read where the body binds it).
_inl_is_marked(v::ASTExpr) = v isa OpExpr && (v.op == "__inleaf" || v.op == "__arrarg" || any(_inl_is_marked, v.args))

_inl_leaf(x, parent, j) = x isa VarExpr || ((x isa NumExpr || x isa IntExpr) && !(parent == "^" && j == 2))
function _inl_skel(v::ASTExpr, p::String, k::Base.RefValue{Int}, parent = "", j = 0)
    _inl_leaf(v, parent, j) && return VarExpr(_TPL_IN * p * "\0" * string(k[] += 1))
    v isa OpExpr || return v
    return reconstruct(v; args = ASTExpr[_inl_skel(a, p, k, v.op, i) for (i, a) in enumerate(v.args)])
end
function _inl_mskel(v::ASTExpr, p::String, k::Base.RefValue{Int}, a::Base.RefValue{Int})
    v isa OpExpr || return v
    v.op == "__inleaf" && return VarExpr(_TPL_IN * p * "\0" * string(k[] += 1))
    v.op == "__arrarg" && return VarExpr(_TPL_INA * p * "\0" * string(a[] += 1))
    return reconstruct(v; args = ASTExpr[_inl_mskel(x, p, k, a) for x in v.args])
end
function _inl_leaves(v::ASTExpr, out = ASTExpr[], parent = "", j = 0)
    if _inl_is_marked(v)
        _inl_mleaves!(out, v, "__inleaf")
        return ASTExpr[x.args[1] for x in out]
    end
    if _inl_leaf(v, parent, j)
        push!(out, v)
    elseif v isa OpExpr
        for (i, a) in enumerate(v.args)
            _inl_leaves(a, out, v.op, i)
        end
    end
    return out
end
function _inl_mleaves!(out, v::ASTExpr, op::String)
    v isa OpExpr || return out
    v.op == op && (push!(out, v); return out)
    (v.op == "__inleaf" || v.op == "__arrarg") && return out
    foreach(x -> _inl_mleaves!(out, x, op), v.args)
    return out
end
# The array markers of a marked binding, in skeleton order.
_inl_arrays(v::ASTExpr) = _inl_mleaves!(ASTExpr[], v, "__arrarg")
_inl_count(v::ASTExpr) = length(_inl_leaves(v))
function _inl_key(v::ASTExpr, parent = "", j = 0)
    if _inl_is_marked(v) || (v isa OpExpr && (v.op == "__inleaf" || v.op == "__arrarg"))
        v isa OpExpr || return v isa VarExpr ? "V" * v.name : string(v)
        v.op == "__inleaf" && return "#"
        if v.op == "__arrarg"
            a = v.value::_ArrArg
            return string("A", a.kind)
        end
        return string("(", v.op, " ", join((_inl_key(x) for x in v.args), " "), ")")
    end
    _inl_leaf(v, parent, j) && return "#"
    v isa OpExpr || return string(v)
    return string("(", v.op, " ", join((_inl_key(a, v.op, i) for (i, a) in enumerate(v.args)), " "), ")")
end

# The reference `call` with each binding that is compiled into its instance as
# a marked binding (`_call_inl_mode`) rewritten: every maximal part that reads
# no name the body binds is the caller value `__inleaf(leaf(part))`; an array
# read at a name the body binds has its array as `arr(name)`, an `__arrarg`
# marker; a name the body binds stays. `leaf` and `arr` are the compiler's
# own (the resolve's, the setup geometry compiler's).
function _call_mark_inlined(leaf, arr, tt::_TplTable, call::OpExpr)
    info = _tpl_call_info(tt, call.name)
    (info === nothing || call.bindings === nothing) && return call
    def = _tpl_def(tt, call.name)
    def.closed === nothing && return call
    B = _tpl_body_binders(tt, call.name)
    nb = nothing
    for p in def.params
        v = get(call.bindings, p, nothing)
        (v === nothing || _inl_is_marked(v)) && continue
        _call_inl_mode(tt, info, def, p, v) === :marked || continue
        nb === nothing && (nb = Dict{String, ASTExpr}(call.bindings))
        nb[p] = _inl_mark(leaf, arr, v, B)
    end
    return nb === nothing ? call : reconstruct(call; bindings = nb)
end
function _inl_mark(leaf, arr, v::ASTExpr, B::Set{String}, parent = "", j = 0)
    v isa VarExpr && v.name in B && return v
    if (v isa NumExpr || v isa IntExpr) && parent == "^" && j == 2
        return v
    end
    if !(v isa OpExpr) || !_tpl_reads_any(v, B)
        return OpExpr("__inleaf", ASTExpr[leaf(v)])
    end
    if v.op == "index" && v.args[1] isa VarExpr
        return reconstruct(v; args = ASTExpr[arr(v.args[1]), (_inl_mark(leaf, arr, x, B, "index", i + 1) for (i, x) in enumerate(v.args[2:end]))...])
    end
    return reconstruct(v; args = ASTExpr[_inl_mark(leaf, arr, x, B, v.op, i) for (i, x) in enumerate(v.args)])
end

function _call_body_size(n::_Node)
    seen = _NodeIdMap{Nothing}()
    c = Ref(0)
    function walk(x)
        haskey(seen, x) && return
        seen[x] = nothing
        c[] += 1
        foreach(walk, x.children)
    end
    walk(n)
    return c[]
end

# The `_NK_ARG` leaf for `name` when a call body is being compiled and `name`
# is one of its argument sentinels; `nothing` otherwise.
@inline function _arg_leaf(name::String)
    am = _build_state().argmap
    am === nothing && return nothing
    i = get((am::_ArgMap).idx, name, 0)
    i == 0 && return nothing
    return _mknode(kind = _NK_ARG, idx = i, payload = (am::_ArgMap).target)
end

# `index(<array argument sentinel>, subs…)` inside a body being compiled: the
# argument gather over the resolved subscripts, or `nothing` when `name` is no
# array argument of the body.
function _arg_gather_resolve(name::String, subs::Vector{ASTExpr}, rc)
    am = _build_state().argmap
    am === nothing && return nothing
    j = get((am::_ArgMap).arr, name, 0)
    j == 0 && return nothing
    return OpExpr(
        "__arg_gather", ASTExpr[_resolve_indices(a, rc) for a in subs];
        value = _Lowered(_NK_ARG_GATHER, _ArgGatherRef((am::_ArgMap).target, j))
    )
end

# The `__arrarg` marker for the array a reference binds to an array parameter
# (`_resolve_call_bindings`): a state array, a live forcing buffer or a const
# array by name, or an inline `const` array.
function _arr_arg_marker(v::ASTExpr, rc)
    (v isa OpExpr && v.op == "__arrarg") && return v
    # In a body being compiled, an array argument of the body passed on to a
    # call in it (forwarded at run time, `_FwdArr`).
    am = _build_state().argmap
    if v isa VarExpr && am !== nothing && haskey((am::_ArgMap).arr, v.name)
        otg = (am::_ArgMap).target
        j = (am::_ArgMap).arr[v.name]
        a = _arrarg_interned(Symbol("fwd", j), otg) do
            _ArrArg(otg.arrkinds[j], _FwdArr(otg, j), v.name)
        end
        return OpExpr("__arrarg", ASTExpr[]; value = a)
    end
    a = if v isa OpExpr && v.op == "const" && v.value isa AbstractVector
        vals, cname = _intern_inline_const(v, rc.const_arrays)
        _arrarg_interned(:const, vals) do
            _ArrArg(:const, _const_gather_payload(vals, cname), cname)
        end
    elseif v isa VarExpr
        n = v.name
        src = _array_source(n, rc.array_var_info, rc.pgather, rc.const_arrays)
        if src === :state
            lo, hi = rc.array_var_info[n]
            sg = _state_gather_payload(n, lo, hi, rc.var_map)
            _ArrArg(sg.run_base != 0 ? :block : :state, sg, n)
        elseif src === :forcing
            pg = rc.pgather[n]::_PGatherArray
            _arrarg_interned(:live, pg) do
                nd = length(pg.dims)
                strides = Vector{Int}(undef, nd)
                acc = 1
                for d in 1:nd
                    strides[d] = acc
                    acc *= pg.dims[d]
                end
                _ArrArg(:live, _ConstGatherArray(pg.flat, strides, collect(Int, pg.dims), fill(:live, nd), n), n)
            end
        elseif src === :const
            ca = rc.const_arrays[n]
            _arrarg_interned(:const, ca) do
                _ArrArg(:const, _const_gather_payload(ca, n), n)
            end
        else
            throw(
                TreeWalkError(
                    "E_TREEWALK_INDEX_NOT_ARRAY",
                    "'$(n)' is bound to an array parameter of a template but is not an " *
                        "array the build can pass (a state array, a forcing buffer or a const array)"
                )
            )
        end
    else
        throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "an array parameter of a template is bound to an expression; the build " *
                    "passes only named or inline const arrays yet"
            )
        )
    end
    return OpExpr("__arrarg", ASTExpr[]; value = a)
end

# ---- Walk ------------------------------------------------------------------------

@inline function _argstack_alt(st::_ArgStack, ::Type{T}) where {T}
    a = st.alt
    a isa Vector{T} && return a
    na = Vector{T}(undef, length(st.f64))
    st.alt = na
    return na
end

# Room for position `i` on the stack.
@noinline function _argstack_grow!(st::_ArgStack, i::Int)
    n = max(i, 2 * length(st.f64), 16)
    resize!(st.f64, n)
    resize!(st.isalt, n)
    st.alt === nothing || resize!(st.alt, n)
    return nothing
end

@inline function _argstack_push!(st::_ArgStack, i::Int, v::Float64, ::Type{T}) where {T}
    i > length(st.f64) && _argstack_grow!(st, i)
    @inbounds st.f64[i] = v
    @inbounds st.isalt[i] = false
    return nothing
end
@inline function _argstack_push!(st::_ArgStack, i::Int, v, ::Type{T}) where {T}
    i > length(st.f64) && _argstack_grow!(st, i)
    a = _argstack_alt(st, T)
    @inbounds a[i] = v
    @inbounds st.isalt[i] = true
    return nothing
end

@inline function _argstack_read(st::_ArgStack, i::Int, ::Type{Float64})
    return @inbounds st.f64[i]
end
@inline function _argstack_read(st::_ArgStack, i::Int, ::Type{T}) where {T}
    @inbounds st.isalt[i] || return @inbounds st.f64[i]
    return @inbounds (st.alt::Vector{T})[i]
end

# The call itself, given an evaluator `ev(child)` for the caller's context (the
# scalar walker or the access-kernel walker).
@inline function _run_call(ev::F, n::_Node, u, p, t, ::Type{T}) where {F, T}
    site = n.payload::_CallSite
    tg = site.target
    st = tg.stack
    base = st.top
    ch = n.children
    @inbounds for i in eachindex(ch)
        v = ev(ch[i])
        _argstack_push!(st, base + i, v, T)
        st.top = base + i
    end
    old = tg.fp
    oldarrs = tg.curarrs
    tg.fp = base
    tg.curarrs = site.arrays
    r = try
        _eval_node(tg.body, u, p, t, T)
    finally
        tg.fp = old
        tg.curarrs = oldarrs
        st.top = base
    end
    return r
end

# `_NK_ARG_GATHER`: the read of array argument `j` of the running call, at
# the subscripts `n.children`, exactly as the gather of that array would read
# it (`_eval_state_gather_at`, `_eval_const_gather_at`).
function _eval_arg_gather(n::_Node, u, p, t, ::Type{T}) where {T}
    ref = n.payload::_ArgGatherRef
    tg = ref.target
    bi = @inbounds tg.baseidx[ref.j]
    bi == 0 || return _eval_block_gather_at(
        tg.blocks[ref.j]::_StateGather, _argstack_int(tg.stack, tg.fp + bi), n.children, u, p, t, T
    )
    a = _arr_resolve(@inbounds tg.curarrs[tg.passed[ref.j]])
    a.kind === :state && return _eval_state_gather_at(a.data::_StateGather, n.children, u, p, t, T)
    return _eval_const_gather_at(a.data::_ConstGatherArray, n.children, u, p, t, T)
end

# A block array's read: `_eval_state_gather_at` with the run base an argument.
function _eval_block_gather_at(sg::_StateGather, base::Int, children::Vector{_Node}, u, p, t, ::Type{T}) where {T}
    off = 0
    @inbounds for d in eachindex(children)
        sub = round(Int, _eval_node(children[d], u, p, t, T))
        (sg.lo[d] <= sub <= sg.hi[d]) || return zero(eltype(u))   # ghost cell
        off += (sub - sg.lo[d]) * sg.strides[d]
    end
    @inbounds return u[base + off]
end

# A base slot's value (always a Float64 literal or table entry).
@inline function _argstack_int(st::_ArgStack, i::Int)
    @inbounds st.isalt[i] && throw(
        TreeWalkError("E_TREEWALK_UNSUPPORTED_OP", "a block array's base argument is not a number")
    )
    return unsafe_trunc(Int, @inbounds st.f64[i])
end

@inline _eval_arg(n::_Node, ::Type{T}) where {T} =
    (tg = n.payload::_CallTarget; _argstack_read(tg.stack, tg.fp + n.idx, T))

# ---- Array-valued templates ------------------------------------------------------
# An array-valued template (its body a `faq` over its output indices, frames.jl
# `_TplCallInfo.outs`) is read two ways, both rewritten ONCE at the build entry
# (`_tpl_whole_views`), so no later phase tests for them:
#
#   * its ELEMENT, `index(ref, s...)`, is the ELEMENT CALL: the same reference
#     with each output index `o` bound to its subscript (`"\0out\0o" => s`). It
#     is a scalar call like any other; its target's body is the `faq`'s
#     expression with the output indices read as those arguments
#     (`_call_target`). A subscript is an index expression: pure and cheap, so
#     it is passed as a value whatever the body does with it.
#   * the WHOLE ARRAY, where the reference stands as an array (an equation's
#     right-hand side, a `makearray` region value), is the aggregate over the
#     template's output indices and ranges whose element is the element call:
#
#         ref  ==  faq(output_idx = o, ranges = R, expr = ref[o => o])
#
#     This is the definition of an array value read whole, not an expansion:
#     the body stays in the template, and every phase that handles an array
#     producer handles this one; substituting the output indices (the
#     producer rule every phase already applies) substitutes into the element
#     call's bindings. `R` is the instance's own ranges (a fixed range bound
#     substituted, `_tpl_inst_closed`).

# The rank of the array `e` denotes when it is an array-valued reference (not
# an element call), else 0.
function _tpl_view_rank(tt::_TplTable, e)
    _tpl_is_call(e) || return 0
    info = _tpl_call_info(tt, (e::OpExpr).name)
    (info === nothing || isempty(info.outs)) && return 0
    _tpl_is_elem(e::OpExpr) && return 0
    return length(info.outs)
end

_tpl_is_elem(e::OpExpr) = e.bindings !== nothing && any(k -> startswith(k, _TPL_OUT), keys(e.bindings))

# The element of the array-valued reference `call` at `subs`.
function _elem_call(tt::_TplTable, call::OpExpr, subs::AbstractVector)
    outs = (_tpl_call_info(tt, call.name)::_TplCallInfo).outs
    length(outs) == length(subs) || throw(
        TreeWalkError(
            "E_TREEWALK_ARRAYOP_INDEX_NDIM",
            "template '$(call.name)' is an array of rank $(length(outs)) read with $(length(subs)) subscripts"
        )
    )
    nb = call.bindings === nothing ? Dict{String, ASTExpr}() : copy(call.bindings)
    for (o, s) in zip(outs, subs)
        nb[_TPL_OUT * o] = s
    end
    return reconstruct(call; bindings = nb)
end

# The whole-array view of the array-valued reference `call`. The output index
# names are the body's own unless the reference's bindings read one of them.
function _tpl_whole_view(tt::_TplTable, call::OpExpr)
    info = _tpl_call_info(tt, call.name)::_TplCallInfo
    def = _tpl_def(tt, call.name)
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    S = _call_fixed!(Dict{String, Any}(), call.name, info, b)
    body = _tpl_inst_closed(tt, def, S).body::OpExpr
    reads = Set{String}()
    for v in values(b)
        union!(reads, _tpl_free_leaves(v))
    end
    names = Dict{String, String}()
    for o in info.outs
        n = o
        while n in reads
            n *= "′"
        end
        names[o] = n
    end
    ranges = body.ranges === nothing ? nothing :
        Dict{String, Any}(names[String(k)] => v for (k, v) in body.ranges)
    oi = String[names[o] for o in info.outs]
    el = _tpl_with_lanes(tt, _elem_call(tt, call, ASTExpr[VarExpr(n) for n in oi]))
    # The aggregate's operand list stays as the body spells it, with each
    # parameter read as its binding.
    args = ASTExpr[a isa VarExpr && _tpl_is_sentinel(a.name) ? _call_arg(b, a.name) : a for a in body.args]
    return reconstruct(body; output_idx = Any[oi...], ranges = ranges, expr_body = el, args = args)
end

# `e` with every element read of an array-valued reference an element call
# and every whole-array use its view. Applied once at the build entry.
function _tpl_whole_views(tt::_TplTable, e::ASTExpr, memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}())
    e isa OpExpr || return e
    r = get(memo, e, nothing)
    r === nothing || return r
    if e.op == "index" && _tpl_structless(e) && length(e.args) >= 2 &&
            _tpl_view_rank(tt, e.args[1]) == length(e.args) - 1
        a1 = map_children(c -> _tpl_whole_views(tt, c, memo), e.args[1]::OpExpr)
        r = _tpl_with_lanes(tt, _elem_call(tt, a1, ASTExpr[_tpl_whole_views(tt, a, memo) for a in e.args[2:end]]))
    else
        r = map_children(c -> _tpl_whole_views(tt, c, memo), e)
        if _tpl_view_rank(tt, r) > 0
            r = _tpl_whole_view(tt, r::OpExpr)
        elseif _tpl_is_call(r) && _tpl_call_info(tt, (r::OpExpr).name) === nothing
            # An aggregate or makearray body: its view (above).
            v = _tpl_agg_view(tt, r::OpExpr)
            v === nothing || (r = v)
        elseif _tpl_is_call(r)
            r = _tpl_with_lanes(tt, r::OpExpr)
        end
    end
    memo[e] = r
    return r
end

# ---- Aggregate and makearray bodies: the loop header in the caller -------------------
# A template whose body is an array that is not a plain `faq` over its output
# indices (a reduction with contracted ranges, a join, a filter, a
# `makearray` of regions, or a whole-array reference to such a template) is
# read whole through its VIEW: the body's loop structure only (output and
# contracted ranges, join clauses, semiring, the filter's position, a
# makearray's regions), with each LEAF (the term, the filter, a region's
# value) an element call of that PART of the template:
#
#     ref  ==  faq(output_idx = o, ranges = R, join = J, filter = part₂(…, i, j),
#                  expr = part₁(…, i, j))
#
# Each part is a template of its own, registered once in the build's
# registry (`<name>\0part\0<k>`, the template's parameters, the leaf as its
# body), so its arithmetic stays in the template and is compiled once per
# instance; the loop indices it reads are its implicit parameters, bound to
# the view's loops (named as the body names them, so a binding reading one is
# captured there exactly as the expansion captures it). Every phase that
# handles an aggregate, a join or a makearray handles the view as it handled
# the expansion. An element read `index(ref, s…)` is `index(view, s…)`, as it
# was `index(expansion, s…)`.

const _TPL_PART = "\0part\0"
const _TPL_LEAF = "\0leaf\0"

_tpl_part_name(name, k::Int) = string(name, _TPL_PART, k)

# The skeleton of template `name`: its body's header in the body's own
# sentinel space with leaf `k` the placeholder `"\0leaf\0k"`, and the number
# of parts (registered by this call); `nothing` when the body is not such an
# array (a scalar template, a structural one, a node outside the class).
function _tpl_skel(tt::_TplTable, name::AbstractString)
    memo = _tpl_memo(tt, nothing, :agg_skel, () -> Dict{String, Any}())
    haskey(memo, name) && return memo[name]
    memo[String(name)] = nothing
    def = _tpl_def(tt, name)
    def.closed === nothing && return nothing
    info = _tpl_call_info(tt, name)
    info !== nothing && isempty(info.outs) && return nothing
    decl = _TemplateDecl(tt.reg[name])
    parts = Any[]
    h = _tpl_skel_node!(tt, parts, def.closed.body, decl.body)
    h === nothing && return nothing
    raw = tt.reg[name]
    for (k, pb) in enumerate(parts)
        pn = _tpl_part_name(name, k)
        haskey(tt.reg, pn) && continue
        nd = OrderedDict{String, Any}()
        for (kk, v) in pairs(raw)
            nd[string(kk)] = v
        end
        nd["body"] = pb
        tt.reg[pn] = nd
    end
    return memo[String(name)] = (h, length(parts))
end

function _tpl_leaf!(parts, raw)
    push!(parts, raw)
    return VarExpr(_TPL_LEAF * string(length(parts)))
end

function _tpl_skel_node!(tt::_TplTable, parts, e, raw)
    e isa OpExpr || return nothing
    if _is_faq_op(e.op) && e.output_idx !== nothing && !isempty(e.output_idx)
        all(x -> x isa AbstractString, e.output_idx) || return nothing
        (e.expr_body !== nothing && e.key === nothing && e.values === nothing &&
            e.lower === nothing && e.upper === nothing) || return nothing
        rx = _raw_get(raw, "expr")
        rx === nothing && return nothing
        le = _tpl_leaf!(parts, rx)
        lf = nothing
        if e.filter !== nothing
            rf = _raw_get(raw, "filter")
            rf === nothing && return nothing
            lf = _tpl_leaf!(parts, rf)
        end
        return reconstruct(e; expr_body = le, filter = lf)
    end
    if e.op == "makearray" && e.values !== nothing
        rv = _raw_get(raw, "values")
        (rv isa AbstractVector && length(rv) == length(e.values)) || return nothing
        vals = ASTExpr[]
        for (k, v) in enumerate(e.values)
            h = if v isa OpExpr && ((_is_faq_op(v.op) && v.output_idx !== nothing && !isempty(v.output_idx)) ||
                    v.op == "makearray" || (_tpl_is_call(v) && !_tpl_is_elem(v)))
                _tpl_skel_node!(tt, parts, v, rv[k])
            else
                # A scalar region value: one leaf.
                _tpl_leaf!(parts, rv[k])
            end
            h === nothing && return nothing
            push!(vals, h)
        end
        return reconstruct(e; values = vals)
    end
    if _tpl_is_call(e) && !_tpl_is_elem(e)
        # A whole-array reference in the body: its template's skeleton with
        # its parameters read as its bindings; each of its parts a part here
        # whose body is that part's call with this reference's bindings.
        sk = _tpl_skel(tt, e.name)
        sk === nothing && return nothing
        h, n = sk
        rb = _raw_get(raw, "bindings")
        h = _tpl_subst_scoped(h, _tpl_sentinel_map(e), IdDict{OpExpr, ASTExpr}())
        lm = Dict{String, ASTExpr}()
        for j in 1:n
            lm[_TPL_LEAF * string(j)] = _tpl_leaf!(parts, OrderedDict{String, Any}(
                "op" => APPLY_EXPRESSION_TEMPLATE_OP, "args" => Any[],
                "name" => _tpl_part_name(e.name, j),
                "bindings" => rb === nothing ? OrderedDict{String, Any}() : rb,
            ))
        end
        return _tpl_subst_scoped(h, lm, IdDict{OpExpr, ASTExpr}())
    end
    return nothing
end

# Each sentinel of `call`'s template mapped to its binding at `call` (an
# implicit parameter with no binding: its own name).
function _tpl_sentinel_map(call::OpExpr)
    m = Dict{String, ASTExpr}()
    b = call.bindings
    b === nothing && return m
    for (k, v) in b
        startswith(k, _TPL_OUT) && continue
        m[startswith(k, _TPL_FREE) ? k : _TPL_ARG * k] = v
    end
    return m
end

# The view of the reference `call` (above), `nothing` when its template has
# no skeleton. Leaves are the part calls, each with the reference's bindings
# and the loop indices it reads bound to the view's loops.
function _tpl_agg_view(tt::_TplTable, call::OpExpr; lanes::Bool = true)
    _tpl_is_elem(call) && return nothing
    _tpl_call_info(tt, call.name) === nothing || return nothing
    sk = _tpl_skel(tt, call.name)
    sk === nothing && return nothing
    h, n = sk
    m = _tpl_sentinel_map(call)
    for s in _tpl_free_leaves_all(h)
        _tpl_is_sentinel(s) && !haskey(m, s) && startswith(s, _TPL_FREE) &&
            (m[s] = VarExpr(s[(ncodeunits(_TPL_FREE) + 1):end]))
    end
    h = _tpl_subst_scoped(h, m, IdDict{OpExpr, ASTExpr}())
    lm = Dict{String, ASTExpr}()
    for k in 1:n
        leaf = _tpl_part_call(tt, call, _tpl_part_name(call.name, k))
        lanes && _tpl_call_info(tt, leaf.name) !== nothing && (leaf = _tpl_with_lanes(tt, leaf))
        lm[_TPL_LEAF * string(k)] = leaf
    end
    return _tpl_subst_scoped(h, lm, IdDict{OpExpr, ASTExpr}())
end

# The call of part `pn` of the reference `call`: the reference's bindings of
# what the part reads (a parameter the part never reads has no binding, as
# its binding is never made), the loop indices it reads bound to their own
# names (the view's loops).
function _tpl_part_call(tt::_TplTable, call::OpExpr, pn::String)
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    def = _tpl_def(tt, pn)
    info = _tpl_call_info(tt, pn)
    free = def.closed === nothing ? _tpl_generic_free(tt, def) : def.closed.free
    nb = Dict{String, ASTExpr}()
    for (k, v) in b
        if startswith(k, _TPL_FREE)
            k[(ncodeunits(_TPL_FREE) + 1):end] in free && (nb[k] = v)
        elseif startswith(k, _TPL_OUT) || startswith(k, _TPL_LANE)
            continue
        else
            s = _TPL_ARG * k
            (info === nothing || s in info.scalars || s in info.arrays || s in info.fixed ||
                !(k in def.params)) && (nb[k] = v)
        end
    end
    for n in free
        haskey(nb, _TPL_FREE * n) || (nb[_TPL_FREE * n] = VarExpr(n))
    end
    return _tpl_structural_ref(tt, reconstruct(call; name = pn, bindings = nb))
end

# Every variable leaf name in `e` (sentinels included, binders ignored).
function _tpl_free_leaves_all(e::ASTExpr)
    out = Set{String}()
    seen = IdDict{OpExpr, Nothing}()
    function walk(x)
        x isa VarExpr && (push!(out, x.name); return)
        x isa OpExpr || return
        haskey(seen, x) && return
        seen[x] = nothing
        foreach_child(walk, x)
    end
    walk(e)
    return out
end

# The references in `model` read through `index` whose template has an
# aggregate or makearray body (no element call, `_tpl_call_info` is
# `nothing`): an element of such a template is not read through its view.
function _tpl_elem_read_aggs(tt::_TplTable, model)
    out = IdDict{OpExpr, Nothing}()
    foreach_expression(model) do e, _, _
        foreach_subexpr(e) do x
            (x isa OpExpr && x.op == "index" && !isempty(x.args) && _tpl_is_call(x.args[1])) || return
            r = x.args[1]::OpExpr
            _tpl_call_info(tt, r.name) === nothing && (out[r] = nothing)
        end
    end
    return out
end

# Whether the build reads the reference `call` through its view: it has one
# and every leaf is a call the build compiles.
function _tpl_agg_called(tt::_TplTable, call::OpExpr)
    v = try
        _tpl_agg_view(tt, call; lanes = false)
    catch err
        (err isa ExpressionTemplateError || err isa TreeWalkError) || rethrow()
        nothing
    end
    v === nothing && return false
    ok = true
    seen = IdDict{OpExpr, Nothing}()
    function walk(x)
        ok || return
        x isa OpExpr || return
        haskey(seen, x) && return
        seen[x] = nothing
        if _tpl_is_call(x) && occursin(_TPL_PART, x.name)
            ok = _tpl_is_called(tt, x)
            return
        end
        foreach_child(walk, x)
    end
    walk(v)
    return ok
end

# ---- Value operands -------------------------------------------------------------------
# The operands of `e` read as VALUES: a call's bindings except the arrays its
# body indexes (an array argument is a whole array, legitimately bare), every
# other node's `args`. A walker asking "which values does this compute from"
# (the bare-array check) uses this; one asking "which names does it read" uses
# `_operands` (frames.jl).
function _value_operands(e::OpExpr)
    _tpl_is_call(e) || return e.args
    ops = _call_operands(e)
    ct = _call_table()
    ct === nothing && return ops
    arrs = _tpl_array_slots((ct::_CallTable).tt, e.name)
    (arrs === nothing || isempty(arrs)) && return ops
    b = e.bindings::AbstractDict
    return ASTExpr[
        b[k] for k in sort!(collect(keys(b)))
            if !((startswith(k, _TPL_FREE) ? k : _TPL_ARG * k) in arrs)
    ]
end

# The operands of `e` as reads of the caller's cells (the range need
# analysis): a call's value operands, and the bare name of each array it still
# passes whole (its body reads it at cells the caller cannot see, so the whole
# array is read); an array every read of which the caller makes (lanes) is
# read only through those lanes. Every other node's `args`.
function _read_operands(e::OpExpr)
    _tpl_is_call(e) || return e.args
    ct = _call_table()
    ct === nothing && return _call_operands(e)
    passed = _call_array_slots((ct::_CallTable).tt, e)
    ops = _value_operands(e)
    passed === nothing && return ops
    b = e.bindings::AbstractDict
    for k in sort!(collect(keys(b)))
        s = startswith(k, _TPL_FREE) ? k : _TPL_ARG * k
        s in passed && push!(ops, b[k])
    end
    return ops
end

# ---- Generic IR helpers -------------------------------------------------------------
# A pass over the compiled form sees a call as an operator over its argument
# children; the body is reached once per target through `_ir_targets`.

_ir_is_call(n::_Node) = n.kind === _NK_CALL

# The targets reachable from `roots` (bodies included, each once), nested first.
function _ir_targets(roots)
    out = _CallTarget[]
    seen = IdDict{_CallTarget, Nothing}()
    nseen = _NodeIdMap{Nothing}()
    function walk(x::_Node)
        haskey(nseen, x) && return
        nseen[x] = nothing
        foreach(walk, x.children)
        if x.kind === _NK_CALL
            tg = (x.payload::_CallSite).target
            if !haskey(seen, tg)
                seen[tg] = nothing
                walk(tg.body)
                push!(out, tg)
            end
        end
    end
    for r in roots
        walk(r)
    end
    return out
end

# ---- Build-time evaluators ------------------------------------------------------------
# A build-time evaluator that meets a reference reads its body in the
# reference's frame (`_tpl_frame`): each argument is evaluated in the caller's
# environment and bound to its sentinel, then the body is evaluated with those
# bindings. Nothing is copied or substituted. `ev(e, env)` is the evaluator;
# an argument whose evaluation fails is left unbound, so the body fails only if
# it reads it, as the expansion would.
function _eval_through_call(ev::F, expr::OpExpr, env::Dict{String, V}) where {F, V}
    ct = _call_table()
    ct === nothing && throw(_no_call_table(expr.name))
    def = _tpl_def(ct.tt, expr.name)
    if def.closed === nothing
        # A parameter in a structural position: the instance's own prepared
        # body (one frame per instance, so per distinct structural value).
        fr = _tpl_frame(ct.tt, expr, nothing)
        body, slots, args = fr.body, collect(keys(fr.args)), s -> fr.args[s]
    else
        # The template's prepared body, with the reference's bindings as its
        # arguments. No frame: a build-time evaluator may run per cell, and a
        # frame per distinct argument value would be kept for the whole build.
        closed = def.closed::_TplClosed
        b = expr.bindings === nothing ? Dict{String, ASTExpr}() : expr.bindings
        slots = String[_TPL_ARG * p for p in def.params]
        append!(slots, String[_TPL_FREE * n for n in closed.free])
        body = closed.body
        args = s -> _call_arg(b, s)
    end
    inner = Dict{String, V}()
    for s in slots
        try
            inner[s] = ev(args(s), env)
        catch err
            err isa TreeWalkError || rethrow()
        end
    end
    return ev(body, inner)
end

# ---- Operator predicates through a call ------------------------------------------------
# Whether any operator in the body of the reference `call` (transitively through
# nested references, each template once) satisfies `pred(op::String)`. A phase
# that asks "which operators does this expression use" asks it through here at
# a reference, never by expanding. With no template table in reach the answer
# is `true` (the conservative one for every caller: "some operator is outside
# what I handle").
function _call_body_any_op(pred, call::OpExpr)
    ct = _call_table()
    ct === nothing && return true
    memo = _tpl_memo(ct.tt, nothing, :body_ops, () -> Dict{String, Set{String}}())
    return any(pred, _call_body_ops!(memo, ct.tt, String(call.name)))
end

function _call_body_ops!(memo::Dict{String, Set{String}}, tt::_TplTable, name::String)
    got = get(memo, name, nothing)
    got === nothing || return got
    ops = Set{String}()
    memo[name] = ops
    def = _tpl_def(tt, name)
    body = _call_elem_body(tt, def)
    body === nothing && (push!(ops, APPLY_EXPRESSION_TEMPLATE_OP); return ops)
    foreach_subexpr(body) do e
        e isa OpExpr || return
        if _tpl_is_call(e)
            union!(ops, _call_body_ops!(memo, tt, String(e.name)))
        else
            push!(ops, e.op)
        end
    end
    return ops
end

# A structural measure `f(body, memo::IdDict{OpExpr, Int}) -> Int` of the body
# of the reference `call`'s template (its prepared body, every parameter a
# sentinel), once per template (`key` names the measure), 0 when no table is
# in reach or the template has a parameter in a structural position. A phase
# that asks how an expression is built (how deep its reductions nest) asks it
# of a call through here.
function _call_body_measure(f, call::OpExpr, key::Symbol)
    ct = _call_table()
    ct === nothing && return 0
    tt = (ct::_CallTable).tt
    memo = _tpl_memo(tt, nothing, key, () -> Dict{String, Int}())
    return get!(memo, String(call.name)) do
        def = _tpl_def(tt, call.name)
        body = _call_elem_body(tt, def)
        body isa OpExpr ? f(body, IdDict{OpExpr, Int}()) : 0
    end
end

# The body one call of the reference `call` evaluates (`_call_elem_body`,
# every parameter a sentinel) and the map from the names that body reads to
# the caller's names: `rd(n)` is the set of names the caller reads for the
# body's name `n` (a sentinel: its binding's free names; an implicit one the
# call carries no binding for: its own name; an element's output index: its
# subscript's free names), `nothing` for a name the body binds itself.
# `nothing` when no table is in reach. A phase that asks which of the
# caller's names a part of a body depends on asks it here.
function _call_body_reads(call::OpExpr)
    ct = _call_table()
    ct === nothing && return nothing
    tt = (ct::_CallTable).tt
    body = _call_elem_body(tt, _tpl_def(tt, call.name))
    body isa OpExpr || return nothing
    b = call.bindings
    function rd(n::String)
        key = startswith(n, _TPL_ARG) ? n[(ncodeunits(_TPL_ARG) + 1):end] :
            startswith(n, _TPL_FREE) ? n : _TPL_OUT * n
        x = b === nothing ? nothing : get(b, key, nothing)
        if x === nothing
            startswith(n, _TPL_FREE) && return Set{String}([n[(ncodeunits(_TPL_FREE) + 1):end]])
            return nothing
        end
        return _hoist_free_names!(Set{String}(), x, Set{String}())
    end
    return body, rd
end

# The body the reference `call` evaluates, as an AST: its instance's prepared
# body with the fixed parameters (`_TplCallInfo.fixed`) substituted, the
# element's expression for an element call; `nothing` when no table is in
# reach or the template is not called. A phase that asks what a call loops
# over asks it here.
function _call_inst_body(call::OpExpr)
    ct = _call_table()
    ct === nothing && return nothing
    tt = (ct::_CallTable).tt
    info = _tpl_call_info(tt, call.name)
    info === nothing && return nothing
    def = _tpl_def(tt, call.name)
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    S = try
        _call_fixed!(Dict{String, Any}(), call.name, info, b)
    catch err
        err isa TreeWalkError || rethrow()
        return nothing
    end
    return _call_ibody(tt, def, S, _call_outs(info, call))
end

# The body one call of `def` evaluates: its prepared body, or for an
# array-valued template (always called through its element) the element's
# expression.
function _call_elem_body(tt::_TplTable, def::_TplDef)
    def.closed === nothing && return nothing
    body = def.closed.body
    info = _tpl_call_info(tt, def.name)
    (info === nothing || isempty(info.outs)) && return body
    return (body::OpExpr).expr_body
end

# `call` with a binding for each implicit parameter of its template
# (`"\0free\0n" => n`, as `_tpl_augment` writes them) that it does not carry
# yet; `call` itself when it carries them all or no template table is in reach.
function _call_with_implicit(call::OpExpr)
    ct = _call_table()
    ct === nothing && return call
    def = _tpl_def(ct.tt, call.name)
    free = def.closed === nothing ? _tpl_generic_free(ct.tt, def) : def.closed.free
    isempty(free) && return call
    b = call.bindings
    missing_any = b === nothing || any(n -> !haskey(b, _TPL_FREE * n), free)
    missing_any || return call
    nb = b === nothing ? Dict{String, ASTExpr}() : copy(b)
    for n in free
        k = _TPL_FREE * n
        haskey(nb, k) || (nb[k] = VarExpr(n))
    end
    return reconstruct(call; bindings = nb)
end

# ---- Survey of the references the build still expands ------------------------------
# With `ENV["ESS_TPL_SURVEY"]` naming a file, each reference the build entry
# expanded is appended to it as one line: template name, tab, why the gate
# refused it (`_tpl_refusal`). A diagnostic for the remaining expansion sites.
function _tpl_survey(tt::_TplTable, sites)
    path = get(ENV, "ESS_TPL_SURVEY", "")
    (isempty(path) || isempty(sites)) && return nothing
    open(path, "a") do io
        for ap in values(sites)
            why = try
                _tpl_refusal(tt, ap)
            catch err
                "error: " * first(sprint(showerror, err), 120)
            end
            println(io, "entry\t", replace(String(ap.name), '\0' => '·'), "\t", why)
        end
    end
    return nothing
end

function _tpl_refusal(tt::_TplTable, call::OpExpr)
    def = _tpl_def(tt, call.name)
    def.closed === nothing && return "structural parameter bound to other than a name or number: " *
        join(def.structural, ",")
    info = _tpl_call_info(tt, call.name)
    if info === nothing
        ops = Set{String}()
        foreach_subexpr(def.closed.body) do e
            e isa OpExpr || return
            if _tpl_is_call(e)
                _tpl_call_info(tt, e.name) === nothing && _tpl_skel(tt, e.name) === nothing &&
                    push!(ops, "ref " * replace(String(e.name), '\0' => '·'))
                return
            end
            (e.op in _TPL_CALL_OPS || e.op == "index") && return
            if _is_faq_op(e.op)
                bits = String["faq"]
                e.output_idx === nothing || isempty(e.output_idx) || push!(bits, "out")
                e.join === nothing && e.join_gates === nothing || push!(bits, "join")
                e.filter === nothing || push!(bits, "filter")
                e.ranges === nothing || any(v -> v isa IndexSetRef, values(e.ranges)) && push!(bits, "from-set")
                push!(ops, join(bits, "+"))
                return
            end
            push!(ops, e.op)
        end
        b = def.closed.body
        top = b isa OpExpr ? b.op : string(typeof(b))
        return "body (top $top): " * join(sort!(collect(ops)), ",")
    end
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    bad = String[]
    for p in def.params
        v = get(b, p, nothing)
        v === nothing && (push!(bad, "$p unbound"); continue)
        s = _TPL_ARG * p
        kind = s in info.arrays ? "array" : s in info.fixed ? "fixed" :
            s in info.uncond ? "value" : s in info.scalars ? "conditional" : "unread"
        vop = v isa OpExpr ? first(JSON3.write(serialize_expression(v)), 160) : v isa VarExpr ? "name" : "literal"
        push!(bad, "$p:$kind=$vop")
    end
    return "binding: " * join(bad, " ")
end
