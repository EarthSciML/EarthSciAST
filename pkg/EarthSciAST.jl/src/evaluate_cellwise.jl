# Cell-wise evaluation of an array-valued expression (`evaluate_cellwise`): the
# official per-cell evaluator for grid geometry, `ic` right-hand sides and
# analytic references, through the same `_index_at_cell → _resolve_indices →
# _compile` machinery the build uses, with a join-gated path for a reduction
# over a join and an opt-in BLAS path for the linear mat-vec shape.

# ============================================================
# OPTIONAL BLAS accelerator for the linear mat-vec observed
# ============================================================
#
# The compile-once evaluator folds the contraction `conc[out…] =
# Σ_c A[c,out…]·E[c]` SEQUENTIALLY per output cell. For this SPECIAL linear
# sum-product shape the entire field is one matrix product `conc = A' · E`, which
# a single BLAS `mul!` evaluates. This layer recognises that shape and takes the
# BLAS path; it FALLS BACK (returns `nothing`) to the compile-once evaluator, the
# bit-exact baseline, for everything else, and is engaged only via the opt-in
# `evaluate_cellwise(…; blas_accel=true)` flag.
#
# BLAS sums each dot product in a blocked/SIMD order that differs from the
# sequential fold, so the result is NOT bit-identical: it agrees to a few ULPs,
# which the tests pin at rtol 1e-10.
#
# Reuse: the SEMIRING guard (`_pd_oplus == ("+",0)`) and the body-shape predicate
# (`_pd_matvec_factors`) are the SAME ones the pushdown auto-rewrite (`_pd_detect`,
# pushdown_rewrite.jl) fires on — factored there and shared here, not duplicated.

# Collect every faq node reachable in `e`, so the accelerator can require
# EXACTLY ONE reduction.
function _blas_collect_aggregates!(acc::Vector{OpExpr}, e::ASTExpr)
    foreach_subexpr(x -> x isa OpExpr && _is_faq_op(x.op) && push!(acc, x), e)
    return acc
end

# The aggregate's `output_idx` as ordered `String`s, or `nothing` when it carries
# a literal singleton dimension (`Int 1`) rather than a symbol.
function _blas_out_syms(agg::OpExpr)
    oi = agg.output_idx
    oi === nothing && return nothing
    all(s -> s isa AbstractString, oi) || return nothing
    return String[String(s) for s in oi]
end

# Column-major strides for an output extent tuple (matches the `_ConstGatherArray`
# flattening convention: `strides[d] = prod(sz[1:d-1])`).
function _blas_colmajor_strides(sz::Tuple)
    st = Vector{Int}(undef, length(sz))
    acc = 1
    @inbounds for d in eachindex(sz)
        st[d] = acc
        acc *= sz[d]
    end
    return st
end

# Substitute `target` (matched by object identity) with `repl` in the elementwise
# arg-tree of `e`; returns `(new_expr, n_replaced)`. Descends `args` only — the
# wrapper around a nested aggregate is elementwise, so its operands live in `args`
# — and rebuilds only nodes on the path (field-preserving `reconstruct`).
function _blas_subst(e, target::OpExpr, repl::ASTExpr)
    e === target && return (repl, 1)
    e isa OpExpr || return (e, 0)
    n = 0
    newargs = Vector{ASTExpr}(undef, length(e.args))
    for (i, a) in enumerate(e.args)
        na, k = _blas_subst(a, target, repl)
        newargs[i] = na; n += k
    end
    n == 0 && return (e, 0)
    return (reconstruct(e; args = newargs), n)
end

# conc[out…] = Σ_{c∈crange} A[c,out…]·E[c] via ONE BLAS `mul!`. `A` is reshaped to
# a (N_c × ∏out) matrix that SHARES its buffer (no copy for a dense `Float64`
# array), and `conc = Asel' · Esel` is written into a preallocated vector; a strict
# sub-`crange` selects rows through a strided view (still one gemv). The result is
# reshaped to the output extents column-major — matching A's storage and the
# const-gather read order — so `conc[out…]` equals the contracted value.
function _blas_matvec(
        A::AbstractArray, E::AbstractArray,
        crange::AbstractUnitRange, out_sizes::Tuple
    )
    Af = A isa Array{Float64} ? A : Array{Float64}(A)   # dense Float64 ⇒ no copy
    Ef = E isa Vector{Float64} ? E : Vector{Float64}(E)
    N_c = size(Af, 1)
    K = prod(out_sizes; init = 1)
    Amat = reshape(Af, N_c, K)                          # shares Af's buffer
    full = (first(crange) == 1 && last(crange) == N_c)
    Asel = full ? Amat : view(Amat, crange, :)
    Esel = full ? Ef : view(Ef, crange)
    conc_flat = Vector{Float64}(undef, K)
    mul!(conc_flat, Asel', Esel)                        # BLAS gemv on A' (no transpose copy)
    return reshape(conc_flat, out_sizes)
end

# Gather the precomputed field `conc` (shape `out_sizes`, column-major) at each
# requested output cell, in `cells` order → `Vector{Float64}`.
function _blas_gather(conc::AbstractArray, cells::AbstractVector, out_sizes::Tuple)
    nidx = length(out_sizes)
    st = _blas_colmajor_strides(out_sizes)
    out = Vector{Float64}(undef, length(cells))
    @inbounds for i in eachindex(cells)
        cell = cells[i]
        off = 1
        for d in 1:nidx
            off += (Int(cell[d]) - 1) * st[d]
        end
        out[i] = conc[off]
    end
    return out
end

"""
    _evaluate_cellwise_blas(expr, cells, const_arrays, params)

The BLAS fast path. Returns the evaluated field `Vector{Float64}`
when `expr` is (or elementwise-wraps) the linear sum-product mat-vec
`conc[out…] = Σ_c A[c,out…]·E[c]` over const arrays `A`/`E`, else `nothing` (⇒ the
caller falls back to the compile-once path). Rank-1 and rank-≥2 output are
both handled (via a reshape to `(N_c × ∏out)`). NOT bit-identical to the compile-once path — see
the module note — but agrees to machine precision.
"""
function _evaluate_cellwise_blas(
        expr::ASTExpr,
        cells::AbstractVector{<:AbstractVector{<:Integer}},
        const_arrays::AbstractDict,
        params::AbstractDict,
        t::Float64 = 0.0
    )
    nidx = length(first(cells))
    (nidx >= 1 && all(c -> length(c) == nidx, cells)) || return nothing

    # Exactly one reduction anywhere in the (otherwise elementwise) tree.
    aggs = _blas_collect_aggregates!(OpExpr[], expr)
    length(aggs) == 1 || return nothing
    agg = aggs[1]

    # SEMIRING GUARD — the additive (+,0) monoid ONLY (mirrors `_pd_detect`; a
    # max/min-semiring contraction of the same shape is left to the compile-once path).
    oz = _pd_oplus(agg); oz === nothing && return nothing
    (oz[1] == "+" && oz[2] == 0.0) || return nothing
    # A PLAIN contraction only — no relational join / filter / value-invention.
    (
        agg.join === nothing && agg.join_gates === nothing && agg.filter === nothing &&
            agg.distinct === nothing && agg.key === nothing
    ) || return nothing

    out_syms = _blas_out_syms(agg)
    (out_syms !== nothing && length(out_syms) == nidx) || return nothing

    # Exactly one contracted index (the cell axis summed over), disjoint from outputs.
    ranges = agg.ranges === nothing ? Dict{String, Any}() : agg.ranges
    length(ranges) == 1 || return nothing
    c_sym = String(first(keys(ranges)))
    c_sym in out_syms && return nothing

    body = agg.expr_body
    body === nothing && return nothing
    facs = _pd_matvec_factors(body, c_sym, out_syms)   # SHARED predicate (pushdown_rewrite.jl)
    facs === nothing && return nothing
    Aname, Ename = facs

    A = get(const_arrays, String(Aname), nothing)
    E = get(const_arrays, String(Ename), nothing)
    (A isa AbstractArray && E isa AbstractArray) || return nothing
    (eltype(A) <: Real && eltype(E) <: Real) || return nothing
    (ndims(A) == nidx + 1 && ndims(E) == 1) || return nothing
    N_c = size(A, 1)
    length(E) == N_c || return nothing
    out_sizes = size(A)[2:end]

    # Contracted range → concrete UNIT range within 1:N_c. A stepped range would
    # not map to one contiguous gemv slice ⇒ bail to the compile-once path.
    rspec = ranges[c_sym]
    (rspec isa AbstractVector && _is_const_int_range(rspec)) || return nothing
    crange = _expand_int_range(rspec)
    (crange isa AbstractUnitRange) || return nothing
    (first(crange) >= 1 && last(crange) <= N_c) || return nothing

    # Every requested cell must be in-bounds for the output extents.
    for cell in cells
        @inbounds for d in 1:nidx
            (1 <= Int(cell[d]) <= out_sizes[d]) || return nothing
        end
    end

    conc = _blas_matvec(A, E, crange, out_sizes)   # Array{Float64} of shape out_sizes

    # BARE mat-vec: `expr` IS the aggregate ⇒ gather conc at each requested cell.
    expr === agg && return _blas_gather(conc, cells, out_sizes)

    # WRAPPED elementwise form `f(conc[out…])`: replace the aggregate with a gather
    # of the precomputed `conc`, then evaluate the (now array-producer-free) wrapper
    # per cell via the compile-once path, binding the aggregate's OWN output
    # symbols. A collision with a param / the time symbol ⇒ bail to the compile-once path.
    for s in out_syms
        (s == "t" || haskey(params, s)) && return nothing
    end
    concname = "__esm_blas_conc"
    haskey(const_arrays, concname) && return nothing
    gather = OpExpr(
        "index", ASTExpr[
            VarExpr(concname),
            (VarExpr(s) for s in out_syms)...,
        ]
    )
    expr2, nrep = _blas_subst(expr, agg, gather)
    nrep == 1 || return nothing
    aug = Dict{String, Any}(String(k) => v for (k, v) in const_arrays)
    aug[concname] = conc
    ce = _cellwise_compile_once(
        expr2, nidx, aug, params;
        bind_syms = out_syms, t = t
    )
    ce === nothing && return nothing
    return _eval_cells(ce, cells)
end

# ============================================================
# The JOIN-GATED aggregate, still on ONE compile
# ============================================================
#
# The compile-once path keeps the OUTPUT index symbolic and compiles the observed body once.
# It cannot do that for an aggregate carrying `join_gates`: which contracted
# tuples contribute is decided per output cell by a build-time join index (the
# §5.5.6 overlap broad phase, the §5.5.8 `on` match set), so the admitted term
# SEQUENCE differs cell by cell and no single straight-line body expresses it.
# `_resolve_index_of_faq` says so and declines; without this path the whole
# field would fall to the per-cell `_index_at_cell → _resolve_indices →
# _compile` walk, which under `compiler=:native` is a refusal, because
# re-deriving the program for every cell is the one thing a compiled compiler
# promises not to do.
#
# What is genuinely per-cell here is the KEY SEQUENCE, not the program. So this
# phase compiles the aggregate's TERM once with EVERY loop symbol — the output
# indices and the contracted indices alike — bound as a parameter
# (`_scalarwise_compile_once`), and then walks the gate's own admitted key
# sequence, rebinding the parameters and re-evaluating the same compiled node.
# One compile for the whole field, and the per-cell cost is arithmetic.
#
# ORDER, and therefore the floating-point answer. The key sequence comes from
# `_foreach_aggregate_term` — the SAME enumerator the per-cell expansion uses,
# with the same drive plan and the same `_join_admits` test — driven with a
# sentinel body whose substituted arguments spell the contracted tuple. The fold
# is the left fold `_combine_with_reducer`'s ⊕ compiles to (an n-ary `+`
# seeded with 0̄, then one term at a time; `*` accumulates `c[1]⊕c[2]` and
# `max`/`min` are emitted left-folded, where the 0̄ seed changes no bits), and
# an empty admitted set is the semiring identity 0̄ — so this agrees with the
# per-cell walk term for term.
#
# It is a PURE EXTENSION: `nothing` on any shape it does not recognise, and the
# caller falls through to exactly what it did before. `compiler=:interpreter`
# remains the simple oracle this is checked against (see the compiler-agreement
# testset in compiler_selection_test.jl); `native` is the universally available
# fast tier, and covering this shape is what keeps it universal.

# The sentinel body whose substitution reveals one admitted contracted tuple.
# A plain `OpExpr` with an op no evaluator knows: `_sub_preserving` rewrites its
# `VarExpr` arguments to `IntExpr`s exactly as it rewrites a real body's, and it
# is never compiled or evaluated — only read back.
const _GATED_KEYS_OP = "__esm_gate_keys"

# One ⊕ step of the fold, matching `_combine_with_reducer` + `_scalar_op`.
@inline _gated_oplus(oplus::String, a::Float64, b::Float64) =
    _oplus_numeric(Symbol(oplus), a, b)

# Evaluate the gated aggregate at every cell of `cells` by walking the gate's
# admitted key sequence and folding the once-compiled term `ce`.
function _gated_field(
        ce, out_syms::Vector{String}, contract_names::Vector{String},
        contract_iters, gates, oplus::String, zerobar::Float64,
        cells::AbstractVector
    )
    nidx = length(out_syms); nc = length(contract_names)
    sentinel = OpExpr(_GATED_KEYS_OP, ASTExpr[VarExpr(n) for n in contract_names])
    key = Vector{Int}(undef, nidx + nc)
    out = Vector{Float64}(undef, length(cells))
    for i in eachindex(cells)
        cell = cells[i]
        @inbounds for d in 1:nidx
            key[d] = Int(cell[d])
        end
        out_env = Dict{String, Int}(out_syms[d] => key[d] for d in 1:nidx)
        acc = zerobar
        _foreach_aggregate_term(
            sentinel, contract_names, contract_iters,
            gates, nothing, zerobar, out_env
        ) do term
            ks = (term::OpExpr).args
            @inbounds for d in 1:nc
                key[nidx + d] = Int((ks[d]::IntExpr).value)
            end
            v = ce(key)
            acc = _gated_oplus(oplus, acc, v)
        end
        out[i] = acc
    end
    return out
end

"""
    _evaluate_cellwise_gated(expr, cells, const_arrays, params, t)

The join-gated path. Returns the evaluated field `Vector{Float64}` when `expr` is — or
elementwise wraps — a single `faq` carrying resolved `join_gates`, else
`nothing` (⇒ the caller falls through to the per-cell walk).
"""
function _evaluate_cellwise_gated(
        expr::ASTExpr,
        cells::AbstractVector{<:AbstractVector{<:Integer}},
        const_arrays::AbstractDict,
        params::AbstractDict,
        t::Float64 = 0.0
    )
    nidx = length(first(cells))
    (nidx >= 1 && all(c -> length(c) == nidx, cells)) || return nothing

    # Exactly one reduction anywhere in the (otherwise elementwise) tree, and it
    # must be the gated one — an ungated aggregate is the compile-once path's business and has
    # already had its turn by the time this runs.
    aggs = _blas_collect_aggregates!(OpExpr[], expr)
    length(aggs) == 1 || return nothing
    agg = aggs[1]
    gates = agg.join_gates
    gates === nothing && return nothing
    # A PLAIN gated contraction: no value invention, no integral. Each of these
    # means something the term compile does not express.
    (
        agg.distinct === nothing && agg.key === nothing && agg.int_var === nothing &&
            agg.lower === nothing && agg.upper === nothing
    ) || return nothing
    body = agg.expr_body
    body === nothing && return nothing

    out_syms = _blas_out_syms(agg)
    (out_syms !== nothing && length(out_syms) == nidx) || return nothing

    ranges = agg.ranges === nothing ? Dict{String, Any}() : agg.ranges
    contract_names = _contracted_index_names(ranges, out_syms)
    isempty(contract_names) && return nothing
    # CONSTANT contracted bounds only. A ragged (expression-valued) bound is
    # resolved against the output cell, which is what the per-cell walk is for.
    contract_iters = Vector{Vector{Int}}()
    for n in contract_names
        r = ranges[n]
        (r isa AbstractVector && _is_const_int_range(r)) || return nothing
        push!(contract_iters, collect(_expand_int_range(r)))
    end

    # The aggregate's OWN output extents, which the wrapped form materializes
    # over. `1:N` only — a shifted or stepped output range does not address a
    # dense buffer the way the gather below reads it.
    out_sizes_v = Int[]
    for s in out_syms
        r = get(ranges, s, nothing)
        (r isa AbstractVector && _is_const_int_range(r)) || return nothing
        rr = _expand_int_range(r)
        (rr isa AbstractUnitRange && first(rr) == 1 && last(rr) >= 1) || return nothing
        push!(out_sizes_v, last(rr))
    end
    out_sizes = Tuple(out_sizes_v)
    for cell in cells
        @inbounds for d in 1:nidx
            (1 <= Int(cell[d]) <= out_sizes[d]) || return nothing
        end
    end

    oplus, zerobar = try
        _aggregate_oplus_identity(agg.semiring, agg.reduce)
    catch err
        _is_resource_error(err) && rethrow()
        return nothing
    end
    _is_numeric_reducer(oplus) || return nothing

    # The per-term body, with the aggregate's own `filter` folded in exactly as
    # `_foreach_aggregate_product` folds it: a runtime `ifelse(guard, term, 0̄)`.
    # The guard reads the same loop symbols the body does, so binding them as
    # parameters serves both.
    term = agg.filter === nothing ? body :
        OpExpr("ifelse", ASTExpr[agg.filter::ASTExpr, body, NumExpr(zerobar)])
    allsyms = String[out_syms...]
    append!(allsyms, contract_names)
    ce = _scalarwise_compile_once(
        term, allsyms, const_arrays, params; t = t
    )
    ce === nothing && return nothing

    # BARE: `expr` IS the aggregate, so the requested cells are the answer.
    expr === agg && return _gated_field(
        ce, out_syms, contract_names,
        contract_iters, gates, oplus, zerobar, cells
    )

    # WRAPPED elementwise form `f(agg[out…])`: materialize the aggregate's whole
    # field once, substitute a gather of it for the aggregate, and compile the
    # (now array-producer-free) wrapper once through the compile-once path — the same shape
    # the BLAS accelerator above uses, and for the same reason.
    for s in out_syms
        (s == "t" || haskey(params, s)) && return nothing
    end
    concname = "__esm_gated_conc"
    haskey(const_arrays, concname) && return nothing
    allcells = vec(
        Vector{Int}[
            collect(Int, Tuple(I))
                for I in CartesianIndices(out_sizes)
        ]
    )
    vals = _gated_field(
        ce, out_syms, contract_names, contract_iters,
        gates, oplus, zerobar, allcells
    )
    conc = Array{Float64}(undef, out_sizes...)
    @inbounds for (i, c) in enumerate(allcells)
        conc[CartesianIndex(Tuple(c))] = vals[i]
    end
    gather = OpExpr(
        "index", ASTExpr[
            VarExpr(concname),
            (VarExpr(s) for s in out_syms)...,
        ]
    )
    expr2, nrep = _blas_subst(expr, agg, gather)
    nrep == 1 || return nothing
    aug = Dict{String, Any}(String(k) => v for (k, v) in const_arrays)
    aug[concname] = conc
    ce2 = _cellwise_compile_once(
        expr2, nidx, aug, params;
        bind_syms = out_syms, t = t
    )
    ce2 === nothing && return nothing
    return _eval_cells(ce2, cells)
end

"""
    evaluate_cellwise(expr, cells; const_arrays=Dict(),
                      params=Dict()) -> Vector{Float64}

Evaluate an array-valued expression (elementwise ops over array-producing
`faq`/`makearray` nodes — e.g. a grid-geometry template expanded by a
§9.7 import, or a §6.6.5 analytic `reference`) at each 1-based integer cell of
`cells`, returning one Float64 per cell. This is the public entry to the same
build-time machinery `_build_evaluator` uses to seed coordinate-expression `ic`
fields.

STATE references are not in scope. Model PARAMETERS (load-time constants) ARE:
pass their resolved values as `params` (name → value, e.g. a build's
`BuildInspection.params`) and a parameter-dependent expression resolves. This
is what lets a parameter-backed rank≥2 observed / analytic reference be
asserted directly (esm-spec §6.6.5) instead of erroring with
`E_TREEWALK_UNBOUND_VARIABLE`.

TIME is its own argument, `t`, and NOT a `params` entry: the compiler maps the
name `t` to the evaluator's time slot rather than to a parameter read, so a
`params` entry spelled `"t"` never reaches a time-dependent body. It defaults
to `0.0`, which is the right value for every build-time caller; a §6.6
assertion passes its own `time` (esm-spec §6.6.3), which is what makes an
observed that is a function of `t` — a solar declination, an hour angle — read
correctly away from the start of the span.
"""
function evaluate_cellwise(
        expr::ASTExpr, cells::AbstractVector{<:AbstractVector{<:Integer}};
        const_arrays::AbstractDict = Dict{String, Any}(),
        params::AbstractDict = Dict{String, Float64}(),
        blas_accel::Bool = false,
        t::Float64 = 0.0
    )::Vector{Float64}
    isempty(cells) && return Float64[]
    # OPT-IN BLAS accelerator: when `blas_accel=true` and the
    # observed is (or elementwise-wraps) the linear sum-product mat-vec
    # `conc[out…] = Σ_c A[c,out…]·E[c]` over const arrays, evaluate the WHOLE field
    # with one BLAS `mul!` (`conc = A' * E`) instead of the compile-once per-cell
    # contraction. It is a PURE OPTIMISATION layered on the compile-once path: it returns
    # `nothing` (⇒ falls through to the compile-once path below, byte-identical)
    # on ANY shape it does not recognise, and its result agrees with the compile-once path to
    # machine precision (BLAS sums in a different order — NOT bit-identical).
    # `blas_accel=false` (default) skips it entirely ⇒ behaviour is unchanged.
    if blas_accel
        blas = _evaluate_cellwise_blas(
            expr, cells, const_arrays, params, t
        )
        blas === nothing || return blas
    end
    # Compile-once fast path: resolve+compile the
    # observed body ONCE with the output indices bound as parameters, then evaluate
    # each cell by rebinding only those params. Applies only when every cell shares
    # one output rank; it is a pure optimisation and returns `nothing` (→ per-cell
    # fallback below, output byte-identical) on any unsupported construct.
    #
    # RANK 0 (`nidx == 0`, the single empty cell of a SHAPELESS observed) goes
    # through the same door. There is no output index to bind, so "compile once
    # and evaluate every cell" is one compile and one evaluation. Declining it
    # would send every scalar observed to the per-cell walk and so to the strict
    # compiler's refusal.
    nidx = length(first(cells))
    if all(c -> length(c) == nidx, cells)
        ce = _cellwise_compile_once(
            expr, nidx, const_arrays,
            params; t = t
        )
        ce === nothing || return _eval_cells(ce, cells)
        # The GATED aggregate the plain compile-once form cannot keep symbolic:
        # its admitted terms are chosen per output cell by a build-time join
        # index, so one compiled body with the output index bound as a parameter
        # cannot express it. The join-gated path compiles the aggregate's TERM once instead —
        # every loop symbol, output and contracted alike, bound as a parameter —
        # and walks the gate's own admitted key sequence. Still one compile for
        # the whole field; `nothing` on any shape it does not recognise.
        gated = _evaluate_cellwise_gated(
            expr, cells, const_arrays, params, t
        )
        gated === nothing || return gated
    end
    _tally_cascade!(:cellwise_percell)
    # A body NO form can evaluate is the document's error, not a compiler's
    # refusal — an out-of-range const gather must still say
    # `E_TREEWALK_CONSTARRAY_OOB` — so a strict compiler's probe evaluates the
    # first cell, for its diagnostic only, and the refusal is raised when it
    # succeeds.
    lic = _percell_evaluation_license(
        "(build-time observed / reference)",
        "the build-time cellwise evaluator", length(cells);
        probe = pr -> _eval_cellwise(
            pr, expr, collect(Int, first(cells));
            const_arrays = const_arrays,
            params = params, t = t
        )
    )
    vals = Float64[
        _eval_cellwise(
            lic, expr, collect(Int, c);
            const_arrays = const_arrays,
            params = params, t = t
        )
            for c in cells
    ]
    _note_percell!()
    return vals
end
