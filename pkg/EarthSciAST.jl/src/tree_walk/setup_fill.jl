# Construction-time fills compiled through the right-hand-side cascade.
#
# A field initial condition, a setup-time array and a `faq`-valued
# initialization equation each ask for the same thing: one value per cell of a
# box, from an expression that reads no state, computed once at construction.
# The per-cell reference answers it by resolving and compiling the expression
# at every cell (`_eval_cellwise`), and the compile-once forms by compiling it
# once and walking the compiled tree at every cell (`_CellEval`).
#
# This file answers it the way the right-hand side answers an array equation.
# The expression becomes the fill equation
#
#     faq(D(index(buf, l…)), l ∈ lo:hi) = <expression indexed at l…>
#
# into a build-owned buffer block `buf`, which goes through the same cascade an
# array state's equation takes (the affine tier, the prefix-scan split, the
# whole-array contraction nest) and on to code generation, and the emitted
# kernels run ONCE into the buffer. The kernels carry the box as run-time data,
# so two sizes of the same document emit the same code and share its compile;
# the build does no per-cell compile work, and the run is one pass over the
# box at emitted-code speed.
#
# The expression is indexed at `l…` by `_index_at_cell_sym`, the symbolic twin
# of the per-cell reference's `_index_at_cell`: every array-producing node is
# wrapped in `index(node, l…)` and elementwise operators are descended, so each
# cell computes the same operations on the same operands in the same order as
# the reference, and the result is bit-identical to it.
#
# A fill is all or nothing. Only a rule the cascade lands on a whole-array tier
# (`:affine`, `:scan`, `:array_contraction_codegen`) whose kernels were all
# emitted is accepted; anything else — a per-cell build, a kernel left to the
# interpreted runner, an expression the cascade cannot resolve, any error
# raised while trying — returns `nothing` and the caller keeps its existing
# route, which reproduces the document's own value or its own error.

# The buffer block's name. Engine-internal; it never appears in a document, a
# cell key or a report row.
const _SETUP_FILL_NAME = "__esm_setup_fill"

# The cascade tiers a fill may land on: whole-array forms whose build does not
# grow with the box.
const _SETUP_FILL_TIERS = (:affine, :scan, :array_contraction_codegen)

"""
    _SetupFill

A compiled fill over the box `lo:hi` (inclusive, per dimension): the kernel
section, the prefix-scan post-passes and the whole-array contraction section
the cascade produced for the fill equation, and the parameter tuple they read.
[`_run_setup_fill`](@ref) runs it once and returns the buffer, column-major
over the box (first index fastest).
"""
struct _SetupFill{S,C,P}
    lo::Vector{Int}
    hi::Vector{Int}
    n::Int
    section::S
    scans::Vector{_ScanFold}
    contractions::C
    p::P
    # The cascade tier the fill equation landed on (`_SETUP_FILL_TIERS`).
    tier::Symbol
end

# The parameter tuple and the name → position map `_compile` reads, from a
# name → value scope. Sorted, so two builds of one document agree on the tuple.
function _setup_fill_params(params::AbstractDict)
    names = sort!(String[String(k) for k in keys(params)])
    isempty(names) && return nothing, Dict{Symbol,Int}()
    syms = Symbol[Symbol(n) for n in names]
    vals = Float64[Float64(params[n]) for n in names]
    return NamedTuple{Tuple(syms)}(Tuple(vals)), Dict{Symbol,Int}(s => i for (i, s) in enumerate(syms))
end

# Fresh loop names for a fill of rank `nd`, qualified further in the
# (pathological) case that the expression already reads one of them.
function _setup_fill_loops(def::ASTExpr, nd::Int)
    loops = String["_sf$(d-1)" for d in 1:nd]
    clash = false
    foreach_subexpr_once(def) do x
        clash || (x isa VarExpr && x.name in loops && (clash = true))
        nothing
    end
    clash && (loops = String["_sf$(d-1)_$(_SETUP_FILL_NAME)" for d in 1:nd])
    return loops
end

"""
    _compile_setup_fill(def, lo, hi; const_arrays, p, param_sym_set, pgather,
                        reg_funcs) -> Union{_SetupFill,Nothing}

Compile the fill of the field expression `def` over the box `lo:hi` (see the
file header), or return `nothing` when no whole-array compiled form serves it.
`def` reads no state: its free names are scalar parameters (`p`, positioned by
`param_sym_set`), const arrays and live forcing buffers (`pgather`), and the
array producers it contains. Called only where the construction-time
compile-once forms are on, so a build with them off keeps the per-cell
reference untouched.
"""
function _compile_setup_fill(def::ASTExpr, lo::Vector{Int}, hi::Vector{Int};
                             const_arrays::AbstractDict, p, param_sym_set,
                             pgather::AbstractDict=Dict{String,_PGatherArray}(),
                             reg_funcs::AbstractDict=Dict{String,Any}())
    nd = length(lo)
    (nd >= 1 && length(hi) == nd && all(d -> lo[d] <= hi[d], 1:nd)) || return nothing
    loops = _setup_fill_loops(def, nd)
    ranges = Dict{String,Any}(loops[d] => Any[lo[d], hi[d]] for d in 1:nd)
    target = OpExpr("index", ASTExpr[VarExpr(_SETUP_FILL_NAME),
                                     (VarExpr(l) for l in loops)...])
    lhs = OpExpr("faq", ASTExpr[]; output_idx=Any[l for l in loops], ranges=ranges,
                 expr_body=OpExpr("D", ASTExpr[target]; wrt="t"))
    eq = Equation(lhs, _index_at_cell_sym(def, loops))
    box = (copy(lo), copy(hi))
    avi = Dict{String,Tuple{Vector{Int},Vector{Int}}}(_SETUP_FILL_NAME => box)
    layout = StateLayout(String[], [_SETUP_FILL_NAME => box])
    n = length(layout)
    reg = reg_funcs isa Dict{String,Any} ? reg_funcs :
          Dict{String,Any}(String(k) => v for (k, v) in reg_funcs)
    # A record of its own: the fill's cascade rows and refusals belong to the
    # fill, not to the rule the caller files, and the caller's report gets one
    # row for it (`_record_rule!`, at the call site).
    rec = _BuildRecord(_compiler_plan_now())
    return _with_build_record(rec) do
        try
            se, pcs, aks, sfs, acs = _compile_derivative_equations(Equation[eq],
                Dict{String,ASTExpr}(), avi, layout, const_arrays, pgather,
                param_sym_set, reg, n)
            (isempty(se) && isempty(pcs)) || return nothing
            tiers = Symbol[r.tier for r in rec.rules]
            (length(tiers) == 1 && tiers[1] in _SETUP_FILL_TIERS) || return nothing
            merged, _ = _merge_acc_kernel_classes(aks)
            section = _make_kernel_section(merged)
            _section_interprets(section) && return nothing
            return _SetupFill(box[1], box[2], n, section, sfs,
                              _make_contraction_section(acs), p, tiers[1])
        catch err
            # Running out of memory or stack, or an interrupt, says nothing
            # about whether this form serves the fill; everything else is a
            # decline, and the caller's route reproduces the document's own
            # value or error.
            _is_resource_error(err) && rethrow()
            return nothing
        end
    end
end

# True when a kernel section would run any kernel on the interpreted per-cell
# runner at Float64 (see `_KernelSection`'s call).
function _section_interprets(s::_KernelSection)
    isempty(s.kernels) && return false
    s.dualf !== nothing && s.f64cg && return !isempty(s.dual_resid)
    return true
end

"""
    _run_setup_fill(sf::_SetupFill) -> Vector{Float64}

Run the fill once and return its buffer: one value per cell of the box,
column-major (first index fastest), at simulation time `0.0`, the time every
construction-time evaluation is made at.
"""
function _run_setup_fill(sf::_SetupFill)
    buf = zeros(Float64, sf.n)
    # The fill reads no state, so its `u` is the buffer itself, as an observed
    # fill level's is.
    sf.section(buf, buf, sf.p, 0.0, Float64)
    isempty(sf.scans) || _apply_scan_folds!(buf, sf.scans)
    _apply_array_contractions!(buf, buf, sf.p, 0.0, sf.contractions, Float64)
    return buf
end

# `_run_setup_fill`, or `nothing` when the run raised: an out-of-range gather,
# say, which the caller's route then reports at the cell that raises it.
function _try_run_setup_fill(sf::_SetupFill)
    try
        return _run_setup_fill(sf)
    catch err
        _is_resource_error(err) && rethrow()
        return nothing
    end
end

# True when an array-producing node (`_is_array_producer`) occurs anywhere in `e`.
function _has_array_producer(e::ASTExpr)
    found = false
    foreach_subexpr_once(e) do x
        found || (_is_array_producer(x) && (found = true))
        nothing
    end
    return found
end

# The fill's value at cell `idx` of its box, read out of the buffer `buf`.
@inline function _setup_fill_at(sf::_SetupFill, buf::Vector{Float64}, idx)
    s = 0
    stride = 1
    @inbounds for d in eachindex(sf.lo)
        s += (idx[d] - sf.lo[d]) * stride
        stride *= sf.hi[d] - sf.lo[d] + 1
    end
    return @inbounds buf[s + 1]
end

"""
    _setup_fill_array(def, exts; const_arrays, params, reg_funcs) ->
        Union{Array{Float64},Nothing}

The dense array a setup-time materializer produces for `def` over `1:exts`,
through a compiled fill, or `nothing` when none serves it. `params` is the
setup scope's scalar name → value map.
"""
function _setup_fill_array(def::ASTExpr, exts::Vector{Int};
                           const_arrays::AbstractDict, params::AbstractDict,
                           reg_funcs::AbstractDict)
    _setup_compile_once_enabled() || return nothing
    (!isempty(exts) && all(>(0), exts)) || return nothing
    p, psyms = _setup_fill_params(params)
    sf = _compile_setup_fill(def, ones(Int, length(exts)), copy(exts);
                             const_arrays=const_arrays, p=p, param_sym_set=psyms,
                             reg_funcs=reg_funcs)
    sf === nothing && return nothing
    buf = _try_run_setup_fill(sf)
    return buf === nothing ? nothing : reshape(buf, exts...)
end

"""
    _field_ic_fill(rhs, cells, param_scope, registered_functions, const_arrays)
        -> Union{Tuple{_SetupFill,Vector{Float64}},Nothing}

A field `ic`'s coordinate expression filled over its target's cells, as the
fill and its buffer, or `nothing` when no compiled fill serves it. Only an
expression that contains an array producer is a coordinate expression; any
other is left to the cell-independent forms (`_field_ic_uniform`). The cells
must be the whole of their bounding box, inside the declared grid (every index
at least 1): the fill computes every cell of its box, and a cell the target
does not have must not be evaluated.
"""
function _field_ic_fill(rhs::ASTExpr, cells::_DiscoveredCells, param_scope::AbstractDict,
                        registered_functions::AbstractDict, const_arrays::AbstractDict)
    (rhs isa OpExpr && _setup_compile_once_enabled() && !isempty(cells)) || return nothing
    _has_array_producer(rhs) || return nothing
    lo, hi = _cellset_bbox(cells)
    all(>=(1), lo) || return nothing
    any(b -> b[1] == lo && b[2] == hi, cells.boxes) || return nothing
    p, psyms = _setup_fill_params(param_scope)
    sf = _compile_setup_fill(rhs, lo, hi; const_arrays=const_arrays, p=p,
                             param_sym_set=psyms, reg_funcs=registered_functions)
    sf === nothing && return nothing
    buf = _try_run_setup_fill(sf)
    return buf === nothing ? nothing : (sf, buf)
end

_colmajor_strides(hi::Vector{Int}) = Int[prod(hi[1:(d - 1)]; init = 1) for d in eachindex(hi)]

"""
    _init_equation_fill(agg, range_iters, var_map, const_arrays, pgather,
                        param_sym_set, reg_funcs, p)
        -> Union{Tuple{_SetupFill,Vector{Float64}},Nothing}

A `faq`-valued initialization equation's aggregate `agg` filled over its own
output ranges (`range_iters`, unit-step), as the fill and its buffer, or
`nothing` when no compiled fill serves it. The fill reads the build's scalar
parameters (`p`), const arrays and live forcing buffers. A body that reads a
state reads the initial state seeded so far (`u0`, the caller's override
included): each state it reads enters the fill as a snapshot of its current
values — a const array for an array state with unit origin, a literal for a
scalar — which is what the per-cell reference reads, since the equation's own
target is not among them. Any other state read is left to the caller's route.
"""
function _init_equation_fill(agg::OpExpr, range_iters, var_map, const_arrays::AbstractDict,
                             pgather::AbstractDict, param_sym_set, reg_funcs, p;
                             u0::Union{Nothing,Vector{Float64}} = nothing,
                             target::AbstractString = "")
    _setup_compile_once_enabled() || return nothing
    all(r -> !isempty(r) && step(r) == 1, range_iters) || return nothing
    # A pure map, as the per-cell reference reads it: that reference substitutes
    # the output indices into the body and nothing else.
    (agg.join_gates === nothing && agg.filter === nothing) || return nothing
    outs = Set{String}(_output_idx_strings(agg))
    all(k -> String(k) in outs, keys(_ranges_dict(agg))) || return nothing
    snap = nothing
    subs = Dict{String,ASTExpr}()
    for name in _referenced_var_names(agg)
        blk = _vm_block(var_map, name)
        (haskey(var_map, name) || blk !== nothing) || continue
        (u0 === nothing || name == target) && return nothing
        if blk !== nothing
            (all(==(1), blk.lo) && blk.strides == _colmajor_strides(blk.hi)) || return nothing
            snap === nothing && (snap = copy(const_arrays))
            snap[name] = reshape(u0[blk.base:(blk.base + blk.len - 1)], Tuple(blk.hi))
        else
            subs[name] = NumExpr(u0[var_map[name]])
        end
    end
    snap === nothing || (const_arrays = snap)
    isempty(subs) || (agg = _sub_preserving(agg, subs)::OpExpr)
    lo = Int[first(r) for r in range_iters]
    hi = Int[last(r) for r in range_iters]
    sf = _compile_setup_fill(agg, lo, hi; const_arrays=const_arrays, p=p,
                             param_sym_set=param_sym_set, pgather=pgather,
                             reg_funcs=reg_funcs)
    sf === nothing && return nothing
    buf = _try_run_setup_fill(sf)
    return buf === nothing ? nothing : (sf, buf)
end
