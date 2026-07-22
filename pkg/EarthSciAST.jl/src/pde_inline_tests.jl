# ===========================================================================
# pde_inline_tests — the §6.6.5-capable inline-test runner over the tree-walk
# simulation pathway (the PDE dual of run_tests.jl's MTK scalar runner).
#
# A PDE model's inline tests (esm-spec §6.6.5) assert REDUCTIONS of a spatial
# field — `reduce: L2_error | Linf_error` against a `reference` (an analytic
# expression or a `from_file` JSON snapshot), or the pure collapsers
# `integral | mean | max | min` — or point-sample it via `coords`. The
# MTK-based `run_esm_tests` cannot compile
# `aggregate`/`makearray` discretizations; this runner drives the official
# tree-walk pipeline instead: `simulate` (build_evaluator → seed ICs → solve
# via the SciMLBase extension) then per-assertion field reduction.
#
# `[[library-exposes-rhs-not-solver]]`: the caller supplies the ODE algorithm
# (`alg = Tsit5()` with OrdinaryDiffEqTsit5 loaded), exactly as for `simulate`.
#
# Cross-binding pinned conventions (identical in the Julia / Python / Rust
# bindings; the esm-spec leaves these open, so determinism requires pinning):
#
# 1. `coords` point-sampling — coords values are positions in INDEX space
#    (1-based, fractional allowed) along the named interval index sets;
#    sampling picks the NEAREST grid index, with exact half-way ties rounding
#    DOWN toward the lower index (`idx = ceil(c - 1/2)`). Keys must name the
#    asserted field's index sets; a strict subset pins only when every
#    remaining dimension has exactly one sample; the resolved index must lie
#    in `1:size`. Mutually exclusive with `reduce`.
# 2. `integral` reduce — the uniform-cell Riemann sum under a UNIT total
#    domain measure per axis: `integral = Σ field / N_cells = mean(field)`.
#    Authors of non-unit physical domains must scale the expectation until
#    the spec grows a measure concept. This is exactly the measure convention
#    under which the relative-L2 reduction is measure-free (the per-cell
#    measure cancels between numerator and denominator).
# 3. `from_file` references — `{type: "from_file", path, format?}`: `path`
#    resolves relative to the .esm file's directory (`base_dir`, defaulting
#    to the loaded path's directory, else the working directory); the default
#    and only v1 `format` is "json" — a row-major nested JSON array exactly
#    matching the field's shape (validated; mismatch is a clear error). The
#    loaded array is used exactly like an evaluated inline reference in the
#    error-norm reductions.
#
# Public surface:
# - `evaluate_cellwise(expr, cells; …)` — official per-cell evaluation of an
#   array-valued expression (grid geometry / §6.6.5 analytic references),
#   through the same `_index_at_cell → _resolve_indices → _compile` machinery
#   the evaluator uses for coordinate-expression `ic` seeding.
# - `field_reduce(kind, actual; reference=…)` — the §6.6.5 reduction semantics
#   (relative L2, absolute Linf, integral/mean/max/min).
# - `run_pde_tests(input; model_name, alg, reltol, abstol)` — run every inline
#   test of the selected model(s); returns per-assertion results carrying the
#   ACTUAL reduction values (conformance runners record these).
#
# SHARED frame: `run_pde_tests` and `run_esm_tests` are the SAME runner
# skeleton — `_run_test_frame!` in run_tests.jl (per-test/per-assertion loop,
# §6.6.4 tolerance resolution, §6.6.3 pass predicate, wall-time split,
# `AssertionResult` construction, JUnit emission) — with different execution
# ENGINES plugged in. This file contributes the `SimulateTestEngine`
# (tree-walk simulate + field lookup) and the §6.6.5 evaluation machinery it
# drives; the MTK engine lives beside the frame in run_tests.jl.
# ===========================================================================

"""
    PdeTestError(msg)

A §6.6.5 inline-test evaluation failed: an ill-formed `coords` / `reduce`
assertion, a `from_file` reference that is missing or shape-mismatched, an
asserted variable with no field, or a per-test discretization injection
(§9.7.10 form C) that could not build. `run_pde_tests` catches it per
assertion and records the message on the failing [`PdeAssertionResult`](@ref).
"""
struct PdeTestError <: Exception
    msg::String
end
Base.showerror(io::IO, e::PdeTestError) = print(io, "PdeTestError: ", e.msg)

"""
    PdeAssertionResult

Alias of [`AssertionResult`](@ref) — the two inline-test runners share ONE
result type (and one JUnit emitter). Kept as a name because `run_pde_tests`'
results were historically a distinct struct; the old field spellings survive
as virtual properties on `AssertionResult` (`r.model` ≡ `r.container_name`,
`r.passed` ≡ `r.status == PASS`).

For results produced by [`run_pde_tests`](@ref): `container_kind` is always
`:model`, `file` is `""` (the PDE runner takes one document, not a discovery
walk — pass `file=...` to [`write_junit_xml`](@ref) to label the batch), and
`reduce`/`rtol`/`atol` carry the assertion's declared reduction and the
resolved §6.6.4 tolerances.
"""
const PdeAssertionResult = AssertionResult

# ============================================================
# wall2 Phase D — OPTIONAL BLAS accelerator for the linear mat-vec observed
# ============================================================
#
# The Phase C compile-once evaluator folds the contraction `conc[out…] =
# Σ_c A[c,out…]·E[c]` SEQUENTIALLY per output cell (a type-stable
# `_NK_CONTRACTION`, ~47 µs/cell, zero per-cell alloc). For this SPECIAL linear
# sum-product shape the entire field is one matrix product `conc = A' · E`, which
# a single BLAS `mul!` evaluates far faster. This layer recognises that shape and
# takes the BLAS path; it FALLS BACK (returns `nothing`) to Phase C — the
# bit-identical-to-oracle baseline — for everything else, and is engaged only via
# the opt-in `evaluate_cellwise(…; blas_accel=true)` flag.
#
# HONEST correctness: BLAS sums each dot product in a blocked/SIMD order that
# differs from Phase C's sequential fold, so the result is NOT bit-identical — it
# agrees to a few ULPs (machine precision), which the Phase D tests pin at
# rtol 1e-10. Phase C remains the bit-exact baseline.
#
# Reuse: the SEMIRING guard (`_pd_oplus == ("+",0)`) and the body-shape predicate
# (`_pd_matvec_factors`) are the SAME ones the pushdown auto-rewrite (`_pd_detect`,
# pushdown_rewrite.jl) fires on — factored there and shared here, not duplicated.

# Collect every aggregate/arrayop node reachable in `e` (walking `args` and
# `expr_body`), so the accelerator can require EXACTLY ONE reduction.
function _blas_collect_aggregates!(acc::Vector{OpExpr}, e)
    if e isa OpExpr
        _is_aggregate_op(e.op) && push!(acc, e)
        for a in e.args
            _blas_collect_aggregates!(acc, a)
        end
        e.expr_body === nothing || _blas_collect_aggregates!(acc, e.expr_body)
    end
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
    return (reconstruct(e; args=newargs), n)
end

# conc[out…] = Σ_{c∈crange} A[c,out…]·E[c] via ONE BLAS `mul!`. `A` is reshaped to
# a (N_c × ∏out) matrix that SHARES its buffer (no copy for a dense `Float64`
# array), and `conc = Asel' · Esel` is written into a preallocated vector; a strict
# sub-`crange` selects rows through a strided view (still one gemv). The result is
# reshaped to the output extents column-major — matching A's storage and the
# const-gather read order — so `conc[out…]` equals the contracted value.
function _blas_matvec(A::AbstractArray, E::AbstractArray,
                      crange::AbstractUnitRange, out_sizes::Tuple)
    Af = A isa Array{Float64} ? A : Array{Float64}(A)   # dense Float64 ⇒ no copy
    Ef = E isa Vector{Float64} ? E : Vector{Float64}(E)
    N_c = size(Af, 1)
    K = prod(out_sizes; init=1)
    Amat = reshape(Af, N_c, K)                          # shares Af's buffer
    full = (first(crange) == 1 && last(crange) == N_c)
    Asel = full ? Amat : view(Amat, crange, :)
    Esel = full ? Ef   : view(Ef, crange)
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
    _evaluate_cellwise_blas(expr, cells, const_arrays, registered_functions, params)

The wall2 Phase D BLAS fast path. Returns the evaluated field `Vector{Float64}`
when `expr` is (or elementwise-wraps) the linear sum-product mat-vec
`conc[out…] = Σ_c A[c,out…]·E[c]` over const arrays `A`/`E`, else `nothing` (⇒ the
caller falls back to the Phase C compile-once path). Rank-1 and rank-≥2 output are
both handled (via a reshape to `(N_c × ∏out)`). NOT bit-identical to Phase C — see
the module note — but agrees to machine precision.
"""
function _evaluate_cellwise_blas(expr::ASTExpr,
                                 cells::AbstractVector{<:AbstractVector{<:Integer}},
                                 const_arrays::AbstractDict,
                                 registered_functions::AbstractDict,
                                 params::AbstractDict)
    nidx = length(first(cells))
    (nidx >= 1 && all(c -> length(c) == nidx, cells)) || return nothing

    # Exactly one reduction anywhere in the (otherwise elementwise) tree.
    aggs = _blas_collect_aggregates!(OpExpr[], expr)
    length(aggs) == 1 || return nothing
    agg = aggs[1]

    # SEMIRING GUARD — the additive (+,0) monoid ONLY (mirrors `_pd_detect`; a
    # max/min-semiring contraction of the same shape is left to Phase C).
    oz = _pd_oplus(agg); oz === nothing && return nothing
    (oz[1] == "+" && oz[2] == 0.0) || return nothing
    # A PLAIN contraction only — no relational join / filter / value-invention.
    (agg.join === nothing && agg.join_gates === nothing && agg.filter === nothing &&
     agg.distinct === nothing && agg.key === nothing) || return nothing

    out_syms = _blas_out_syms(agg)
    (out_syms !== nothing && length(out_syms) == nidx) || return nothing

    # Exactly one contracted index (the cell axis summed over), disjoint from outputs.
    ranges = agg.ranges === nothing ? Dict{String,Any}() : agg.ranges
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
    # not map to one contiguous gemv slice ⇒ bail to Phase C.
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
    # per cell via the Phase C compile-once path, binding the aggregate's OWN output
    # symbols. A collision with a param / the time symbol ⇒ bail to Phase C.
    for s in out_syms
        (s == "t" || haskey(params, s)) && return nothing
    end
    concname = "__esm_blas_conc"
    haskey(const_arrays, concname) && return nothing
    gather = OpExpr("index", ASTExpr[VarExpr(concname),
                                     (VarExpr(s) for s in out_syms)...])
    expr2, nrep = _blas_subst(expr, agg, gather)
    nrep == 1 || return nothing
    aug = Dict{String,Any}(String(k) => v for (k, v) in const_arrays)
    aug[concname] = conc
    ce = _cellwise_compile_once(expr2, nidx, aug, registered_functions, params;
                                bind_syms=out_syms)
    ce === nothing && return nothing
    return _eval_cells(ce, cells)
end

"""
    evaluate_cellwise(expr, cells; const_arrays=Dict(), registered_functions=Dict(),
                      params=Dict()) -> Vector{Float64}

Evaluate an array-valued expression (elementwise ops over array-producing
`aggregate`/`makearray` nodes — e.g. a grid-geometry template expanded by a
§9.7 import, or a §6.6.5 analytic `reference`) at each 1-based integer cell of
`cells`, returning one Float64 per cell. This is the public entry to the same
build-time machinery `build_evaluator` uses to seed coordinate-expression `ic`
fields.

STATE references are not in scope. Model PARAMETERS (load-time constants) ARE:
pass their resolved values as `params` (name → value, e.g. a build's
`BuildInspection.params`) and a parameter-dependent expression resolves. This
is what lets a parameter-backed rank≥2 observed / analytic reference be
asserted directly (esm-spec §6.6.5) instead of erroring with
`E_TREEWALK_UNBOUND_VARIABLE`.
"""
function evaluate_cellwise(expr::ASTExpr, cells::AbstractVector{<:AbstractVector{<:Integer}};
                           const_arrays::AbstractDict=Dict{String,Any}(),
                           registered_functions::AbstractDict=Dict{String,Function}(),
                           params::AbstractDict=Dict{String,Float64}(),
                           blas_accel::Bool=false)::Vector{Float64}
    isempty(cells) && return Float64[]
    # OPT-IN BLAS accelerator (wall2 Phase D): when `blas_accel=true` and the
    # observed is (or elementwise-wraps) the linear sum-product mat-vec
    # `conc[out…] = Σ_c A[c,out…]·E[c]` over const arrays, evaluate the WHOLE field
    # with one BLAS `mul!` (`conc = A' * E`) instead of the Phase C per-cell
    # contraction. It is a PURE OPTIMISATION layered on Phase C: it returns
    # `nothing` (⇒ falls through to the compile-once path below, byte-identical)
    # on ANY shape it does not recognise, and its result agrees with Phase C to
    # machine precision (BLAS sums in a different order — NOT bit-identical).
    # `blas_accel=false` (default) skips it entirely ⇒ behaviour is unchanged.
    if blas_accel
        blas = _evaluate_cellwise_blas(expr, cells, const_arrays,
                                       registered_functions, params)
        blas === nothing || return blas
    end
    # Compile-once fast path (wall2 Phase C — THE Wall #2 fix): resolve+compile the
    # observed body ONCE with the output indices bound as parameters, then evaluate
    # each cell by rebinding only those params. Applies only when every cell shares
    # one output rank; it is a pure optimisation and returns `nothing` (→ per-cell
    # fallback below, output byte-identical) on any unsupported construct.
    nidx = length(first(cells))
    if nidx >= 1 && all(c -> length(c) == nidx, cells)
        ce = _cellwise_compile_once(expr, nidx, const_arrays, registered_functions, params)
        ce === nothing || return _eval_cells(ce, cells)
    end
    return Float64[_eval_cellwise(expr, collect(Int, c);
                                  const_arrays=const_arrays,
                                  registered_functions=registered_functions,
                                  params=params)
                   for c in cells]
end

"""
    field_reduce(kind, actual; reference=nothing) -> Float64

Collapse a spatial field to the scalar a §6.6.5 `reduce` assertion compares
(esm-spec §6.6.5):

- `"L2_error"`  — `‖actual − reference‖₂ / ‖reference‖₂` (relative L2 over the
  domain; requires `reference`).
- `"Linf_error"` — `max |actual − reference|` (absolute supremum norm; requires
  `reference`).
- `"integral"` — the uniform-cell Riemann sum under a UNIT total domain
  measure per axis: `Σ field / N_cells`, i.e. exactly `mean`. This is the
  pinned cross-binding convention (the same measure convention under which
  the relative-L2 reduction is measure-free); non-unit physical domains must
  be scaled by the author until the spec grows a measure concept.
- `"mean" | "max" | "min"` — pure collapsers of `actual`.
"""
function field_reduce(kind::AbstractString, actual::AbstractVector{<:Real};
                      reference::Union{Nothing,AbstractVector{<:Real}}=nothing)::Float64
    k = String(kind)
    if k == "L2_error" || k == "Linf_error"
        reference === nothing &&
            throw(ArgumentError("field_reduce: `$(k)` requires a reference field"))
        length(reference) == length(actual) ||
            throw(ArgumentError("field_reduce: actual has $(length(actual)) cells " *
                                "but reference has $(length(reference))"))
        diff = Float64[Float64(a) - Float64(r) for (a, r) in zip(actual, reference)]
        if k == "L2_error"
            refnorm = sqrt(sum(abs2(Float64(r)) for r in reference))
            refnorm == 0.0 &&
                throw(ArgumentError("field_reduce: L2_error reference has zero norm"))
            return sqrt(sum(abs2, diff)) / refnorm
        end
        return maximum(abs, diff)
    elseif k == "mean" || k == "integral"
        isempty(actual) && throw(ArgumentError("field_reduce: empty field"))
        return sum(Float64(a) for a in actual) / length(actual)
    elseif k == "max"
        return Float64(maximum(actual))
    elseif k == "min"
        return Float64(minimum(actual))
    end
    throw(ArgumentError("field_reduce: unsupported reduce kind '$(k)'"))
end

# Collect the (cell-index-tuple, flat-slot) pairs of one array state from a
# var_map. Flattening may prefix element names with the owning model
# ("Heat.u[3]"); a name matches when its element stem equals `model.variable`
# qualified, or `variable` bare. Sorted by cell tuple so callers get a
# deterministic pairing.
#
# Model-qualified-first, exactly like `_scalar_slot`: two sibling components
# sharing an array field name (each a `u`) both bare-match `variable`, so a
# single OR-pass would MIS-COLLECT the union of both models' cells. We therefore
# collect the exact qualified / exact-bare stems first, and only fall back to
# the bare-suffix match when no exact stem is present (a bare-keyed single-model
# build). Same qualified-first hardening as the Python `state_cells`.
function _state_cells(var_map::AbstractDict, variable::AbstractString,
                      model::AbstractString)
    qualified = String(model) * "." * String(variable)
    exact = Tuple{Vector{Int},Int}[]
    fallback = Tuple{Vector{Int},Int}[]
    for (name, slot) in var_map
        # `_parse_cell_key` (tree_walk.jl) is the single inverse of
        # `_cell_key`'s "name[i,j]" encoding — no local regex.
        parsed = _parse_cell_key(String(name))
        parsed === nothing && continue
        stem, cell = parsed
        if stem == qualified || stem == String(variable)
            push!(exact, (cell, Int(slot)))
        else
            bare = occursin('.', stem) ? String(split(stem, '.'; limit=2)[2]) : stem
            bare == String(variable) && push!(fallback, (cell, Int(slot)))
        end
    end
    out = isempty(exact) ? fallback : exact
    sort!(out; by=first)
    return out
end

# Build-time scalar-parameter scope for §6.6.5 cellwise references, with bare
# aliases. `BuildInspection.params` is keyed by the FLATTENED parameter name
# (e.g. "M.k") — matching a resolved observed expression, which flattening
# qualifies. A test author's analytic `reference`, however, names the parameter
# BARE ("k"). So we expose BOTH: the flattened key verbatim, plus an
# unambiguous bare alias (the final dotted segment). On a bare-name collision
# across subsystems the flattened key stays authoritative and the ambiguous
# alias is dropped (the qualified reference still resolves).
function _param_scope_with_aliases(params::AbstractDict)::Dict{String,Float64}
    bare_name(s) = String(split(s, '.')[end])   # final dotted segment; s itself when undotted
    out = Dict{String,Float64}(String(k) => Float64(v) for (k, v) in params)
    counts = Dict{String,Int}()
    for k in keys(params)
        bare = bare_name(String(k))
        counts[bare] = get(counts, bare, 0) + 1
    end
    for (k, v) in params
        s = String(k)
        bare = bare_name(s)
        (bare != s && counts[bare] == 1 && !haskey(out, bare)) &&
            (out[bare] = Float64(v))
    end
    return out
end

# A §6.6.5 assertion may target an ARRAY OBSERVED (e.g. a rule output surfaced
# "for direct assertion", like the MPAS `div_flux`) rather than a state: an
# observed carries no ODE slot, so its field is evaluated from the build's
# RESOLVED observed expression (BuildInspection.observed_exprs) through the same
# official `evaluate_cellwise` machinery as an analytic `reference`, with the
# build's const-array registry AND resolved scalar parameters
# (BuildInspection.params — load-time constants) in scope. STATE-FREE observeds
# only — a state-dependent observed's references stay unbound and error like
# before; a PARAMETER-dependent one now resolves (esm-spec §6.6.5).
# Cells are enumerated from the declared shape's interval index sets. Returns
# `(field, cells)` or `nothing` when the variable is not such an observed.
function _observed_field(insp::BuildInspection, file::EsmFile,
                         mname::AbstractString, variable::AbstractString)
    model = get(file.models, String(mname), nothing)
    model === nothing && return nothing
    v = get(model.variables, String(variable), nothing)
    (v !== nothing && v.type == ObservedVariable && v.shape !== nothing &&
     !isempty(v.shape)) || return nothing
    exts = Int[]
    for s in v.shape
        iset = get(file.index_sets, String(s), nothing)
        (iset !== nothing && iset.kind == "interval" && iset.size !== nothing) ||
            return nothing
        push!(exts, Int(iset.size))
    end
    qualified = String(mname) * "." * String(variable)
    expr = get(insp.observed_exprs, qualified,
               get(insp.observed_exprs, String(variable), nothing))
    expr === nothing && return nothing
    # `vec` flattens the comprehension to a `Vector{Vector{Int}}` for ANY rank:
    # over a rank≥2 `CartesianIndices` the comprehension yields a `Matrix`
    # (higher-D array), and `sort!` on that throws `UndefKeywordError: dims`.
    # The trailing `sort!` fixes the cell order to lexicographic (row-major,
    # last index fastest) regardless of the flatten order — matching
    # `_state_cells` and the Python (`np.ndindex`) / Rust (row-major enum)
    # observed-field ordering, so `field`/`reference` pair cell-for-cell.
    cells = sort!(vec(Vector{Int}[collect(Int, Tuple(I))
                                  for I in CartesianIndices(Tuple(exts))]))
    field = evaluate_cellwise(expr, cells; const_arrays=insp.const_arrays,
                              params=_param_scope_with_aliases(insp.params))
    return (field, cells)
end

# Flat slot of a SCALAR state / scalar OBSERVED by model-qualified name
# (preferred) or bare name; 0 if absent.
#
# Flattening qualifies every element with its owning model ("arrh.k"), and a
# coupled build routinely reuses the same bare observed/state name across
# sibling components — several reaction-rate coefficients all named `k`. So the
# model-qualified name MUST win: a lone bare-name match returns whichever `k`
# happens to come first in `var_map` iteration (NON-DETERMINISTIC for a `Dict`),
# reading the WRONG component's value for every model's `k` assertion. We
# therefore do two passes — an exact qualified / exact-bare match first, then a
# bare-suffix fallback (reached only when no exact element is present, e.g. a
# bare-keyed single-model build). Byte-identical selection to the Python
# `_scalar_slot`.
function _scalar_slot(var_map::AbstractDict, variable::AbstractString,
                      model::AbstractString)::Int
    qualified = String(model) * "." * String(variable)
    for (name, slot) in var_map
        s = String(name)
        (s == qualified || s == String(variable)) && return Int(slot)
    end
    for (name, slot) in var_map
        s = String(name)
        bare = occursin('.', s) ? String(split(s, '.'; limit=2)[2]) : s
        bare == String(variable) && return Int(slot)
    end
    return 0
end

# The asserted variable's declared spatial shape (ordered index-set names).
# Errors when the variable is missing or scalar — a `coords` assertion is
# ill-formed on a 0-D variable per esm-spec §6.6.5.
function _variable_shape(file::EsmFile, mname::AbstractString,
                         variable::AbstractString)::Vector{String}
    model = file.models === nothing ? nothing : get(file.models, String(mname), nothing)
    model === nothing && throw(PdeTestError("model '$(mname)' not found"))
    v = get(model.variables, String(variable), nothing)
    v === nothing && throw(PdeTestError(
        "variable '$(variable)' is not declared in model '$(mname)'"))
    (v.shape === nothing || isempty(v.shape)) && throw(PdeTestError(
        "`coords` requires a spatially-shaped variable; '$(variable)' is scalar"))
    return String[String(s) for s in v.shape]
end

# Resolve a §6.6.5 `coords` map to a concrete 1-based cell tuple over `shape`
# (the field's ordered index-set names), per the pinned cross-binding
# convention: coords values are positions in INDEX space (1-based, fractional
# allowed) along interval index sets; sampling = nearest grid index with exact
# half-way ties rounding DOWN (`idx = ceil(c - 1/2)`). A strict subset of
# dimensions may be pinned only when every remaining dimension is singleton.
function _coords_cell(coords::AbstractDict, shape::Vector{String},
                      index_sets::AbstractDict)::Vector{Int}
    for k in keys(coords)
        String(k) in shape ||
            throw(PdeTestError("`coords` names unknown dimension '$(k)' " *
                  "(field dimensions: $(join(shape, ", ")))"))
    end
    cell = Int[]
    for s in shape
        iset = get(index_sets, s, nothing)
        (iset !== nothing && iset.kind == "interval" && iset.size !== nothing) ||
            throw(PdeTestError("`coords` sampling requires interval index sets " *
                  "with a declared size; '$(s)' is not one"))
        n = Int(iset.size)
        if haskey(coords, s)
            c = Float64(coords[s])
            idx = ceil(Int, c - 0.5)  # nearest index; exact ties round DOWN
            (1 <= idx <= n) ||
                throw(PdeTestError("`coords` position $(c) along '$(s)' resolves " *
                      "to index $(idx), outside 1..$(n)"))
            push!(cell, idx)
        else
            n == 1 ||
                throw(PdeTestError("`coords` leaves dimension '$(s)' unpinned " *
                      "with $(n) samples; a strict subset pins only when every " *
                      "remaining dimension is singleton"))
            push!(cell, 1)
        end
    end
    return cell
end

# Walk a row-major nested JSON array to the value at 1-based `cell`,
# validating each level's extent against `exts` (the field's per-dimension
# extents). The full Cartesian cell sweep visits every node, so ragged or
# mis-sized payloads always surface a shape-mismatch error.
function _nested_at(data, cell::Vector{Int}, exts::Vector{Int})::Float64
    node = data
    for (d, i) in enumerate(cell)
        node isa AbstractVector ||
            throw(PdeTestError("from_file reference shape mismatch along " *
                  "dimension $(d): expected a nested array of length $(exts[d])"))
        length(node) == exts[d] ||
            throw(PdeTestError("from_file reference shape mismatch along " *
                  "dimension $(d): expected length $(exts[d]), found $(length(node))"))
        node = node[i]
    end
    (node isa Real && !(node isa Bool)) ||
        throw(PdeTestError("from_file reference shape mismatch at cell " *
              "[$(join(cell, ","))]: expected a number"))
    return Float64(node)
end

# Load a `{type: "from_file", path, format?}` reference (esm-spec §6.6.5) as
# the per-cell reference field over `cell_tuples`, per the pinned
# cross-binding convention: `path` resolves relative to `base_dir` (the .esm
# file's directory); the default and only v1 `format` is "json" — a row-major
# nested array exactly matching the field's shape.
function _from_file_reference(ref::AbstractDict, base_dir::AbstractString,
                              cell_tuples::Vector{Vector{Int}})::Vector{Float64}
    fmt_raw = get(ref, "format", nothing)
    fmt = fmt_raw === nothing ? "json" : lowercase(String(fmt_raw))
    fmt == "json" ||
        throw(PdeTestError("from_file reference format '$(fmt)' is not supported " *
              "(v1 supports \"json\" only)"))
    path_raw = get(ref, "path", nothing)
    path_raw === nothing && throw(PdeTestError("from_file reference is missing `path`"))
    p = String(path_raw)
    resolved = isabspath(p) ? p : joinpath(String(base_dir), p)
    isfile(resolved) ||
        throw(PdeTestError("from_file reference file not found: $(resolved)"))
    data = JSON3.read(read(resolved, String))
    isempty(cell_tuples) &&
        throw(PdeTestError("from_file reference: field has no cells"))
    nd = length(cell_tuples[1])
    exts = Int[maximum(c[d] for c in cell_tuples) for d in 1:nd]
    return Float64[_nested_at(data, c, exts) for c in cell_tuples]
end

"""
    _ephemeral_injected_file(file, source_path, mname, imports, base_dir) -> EsmFile

esm-spec §9.7.10 form C: build a throwaway [`EsmFile`](@ref) in which component
`mname` has the test's `imports` (raw §9.7.2 entries) appended to its own
`expression_template_imports`, so the ordinary import resolver + §9.6.3 fixpoint
lower its rewrite-targets under the test-chosen discretization. The persisted
`file` is never mutated. The raw base is re-read from `source_path` when `input`
was a path (relative `ref`s resolve against its directory), else re-serialized
from the loaded `file` (`base_dir` anchors the injected `ref`s). This is what
lets one test suite exercise a discretization-agnostic PDE leaf under several
schemes with no conflict between tests.
"""
function _ephemeral_injected_file(file::EsmFile, source_path::Union{Nothing,AbstractString},
                                  mname::AbstractString, imports, base_dir::AbstractString)::EsmFile
    raw = source_path !== nothing ?
        _to_native_json(JSON3.read(read(String(source_path), String))) :
        serialize_esm_file(file)
    injected = false
    for kind in ("models", "reaction_systems")
        comps = get(raw, kind, nothing)
        comps isa AbstractDict || continue
        haskey(comps, String(mname)) || continue
        comp = comps[String(mname)]
        comp isa AbstractDict || continue
        existing = get(comp, "expression_template_imports", nothing)
        base = existing === nothing ? Any[] : Any[e for e in existing]
        for e in imports
            push!(base, _to_native_json(e))
        end
        comp["expression_template_imports"] = base
        injected = true
        break
    end
    injected || throw(PdeTestError(
        "component '$(mname)' not found for per-test injection (esm-spec §9.7.10)"))
    f = load(IOBuffer(JSON3.write(raw)); base_path=String(base_dir))
    resolve_subsystem_refs!(f, String(base_dir))
    return f
end

# Relative slack when matching an assertion's `time` against the solver's
# saved time points: `saveat` hits the requested times only to solver/Float64
# precision, so accept the nearest saved point within this relative tolerance
# (scaled by `max(1, |t|)`). 1e-9 sits far above Float64 roundoff accumulation
# yet far below any two distinct assertion times in practice.
const _SAVED_TIME_RTOL = 1e-9

# ---------------------------------------------------------------------------
# Per-assertion evaluation — the §6.6.5 scalar-selection / reduction machinery,
# split out of `run_pde_tests` so the driver stays a flat loop. Returns the
# scalar `actual`; throws [`PdeTestError`](@ref) on any spec-relevant failure
# (the driver records it as an `ERROR` result).
# ---------------------------------------------------------------------------
function _evaluate_assertion(a, sim, insp::BuildInspection, eval_file::EsmFile,
                             mname::AbstractString,
                             resolved_base::AbstractString)::Float64
    ti = argmin(abs.(sim.t .- a.time))
    abs(sim.t[ti] - a.time) <= _SAVED_TIME_RTOL * max(1.0, abs(a.time)) ||
        throw(PdeTestError("no saved state at t=$(a.time) (nearest $(sim.t[ti]))"))
    state = sim.u[ti]

    if a.coords === nothing && a.reduce === nothing
        slot = _scalar_slot(sim.var_map, a.variable, String(mname))
        slot == 0 && throw(PdeTestError("scalar state '$(a.variable)' not found"))
        return state[slot]
    end

    # `coords` validation runs BEFORE field materialization so a coords
    # assertion on a scalar variable fails with the §6.6.5 coords-specific
    # message.
    coords_target = nothing
    if a.coords !== nothing
        shape = _variable_shape(eval_file, String(mname), String(a.variable))
        coords_target = _coords_cell(a.coords, shape, eval_file.index_sets)
    end

    cells = _state_cells(sim.var_map, a.variable, String(mname))
    local field::Vector{Float64}, cell_tuples::Vector{Vector{Int}}
    if !isempty(cells)
        field = Float64[state[slot] for (_, slot) in cells]
        cell_tuples = [c for (c, _) in cells]
    else
        # No ODE slots: try a state-free ARRAY OBSERVED (a rule output
        # asserted directly, §6.6.5).
        obs = _observed_field(insp, eval_file, String(mname), String(a.variable))
        obs === nothing && throw(PdeTestError(
            "array state '$(a.variable)' has no cells in var_map"))
        field, cell_tuples = obs
    end

    if coords_target !== nothing
        pos = findfirst(==(coords_target), cell_tuples)
        pos === nothing && throw(PdeTestError("no grid sample at cell " *
            "[$(join(coords_target, ","))] of '$(a.variable)'"))
        return field[pos]
    end

    ref = nothing
    if a.reference !== nothing
        if a.reference isa ASTExpr
            # Model parameters (load-time constants) are in scope for a §6.6.5
            # analytic `reference`; state is not. `insp.params` carries the
            # build's resolved scalar params (override-or-default).
            ref = evaluate_cellwise(a.reference, cell_tuples;
                                    const_arrays=insp.const_arrays,
                                    params=_param_scope_with_aliases(insp.params))
        elseif a.reference isa AbstractDict &&
               string(get(a.reference, "type", "")) == "from_file"
            ref = _from_file_reference(a.reference, resolved_base, cell_tuples)
        else
            throw(PdeTestError("unsupported `reference` shape $(typeof(a.reference))"))
        end
    end
    return field_reduce(a.reduce, field; reference=ref)
end

# esm-spec §9.7.10 form C: resolve the file test `t` runs against. A test
# that injects a discretization runs against an EPHEMERAL instance of
# component `mname` with the test's imports appended to its scope and its
# rewrite-targets lowered; the persisted `file` is never mutated. A test with
# no injection runs against the file as loaded. Returns the failure message
# `String` when the ephemeral build could not be built.
function _resolve_test_target(file::EsmFile, input, mname::AbstractString, t,
                              resolved_base::AbstractString)::Union{EsmFile,String}
    isempty(t.expression_template_imports) && return file
    try
        src = input isa AbstractString ? String(input) : nothing
        return _ephemeral_injected_file(file, src, String(mname),
            t.expression_template_imports, resolved_base)
    catch err
        return "per-test discretization injection failed: " *
               "$(sprint(showerror, err))"
    end
end

# ---------------------------------------------------------------------------
# Simulate engine — the tree-walk execution strategy plugged into the unified
# per-test frame (`_run_test_frame!`, run_tests.jl). Per test: resolve the
# §9.7.10 form-C injection target, `simulate` with the assertion times as
# `saveat`, then evaluate each assertion against the saved fields. `simulate`
# flattens the file (models + coupling) into ONE runnable system named
# "Flattened", so no model_name is passed; element names keep their
# owning-model prefix, which the `_state_cells` / `_scalar_slot` lookups
# resolve per assertion.
# ---------------------------------------------------------------------------
struct SimulateTestEngine
    file::EsmFile            # document as loaded
    input::Any               # original `run_pde_tests` input (path or EsmFile)
    mname::String
    resolved_base::String
    alg::Any
    reltol::Float64
    abstol::Float64
end

# Per-test handle: the successful simulation plus the build-observability sink
# (assertions on ARRAY OBSERVEDS evaluate their resolved expression from
# `insp` — see `_observed_field`) and the file the assertions resolve shapes
# against (the ephemeral injected file when the test injects a discretization).
struct _SimulateHandle
    sim::SimulationResult
    insp::BuildInspection
    eval_file::EsmFile
end

function _engine_setup(e::SimulateTestEngine, t)
    target = _resolve_test_target(e.file, e.input, e.mname, t, e.resolved_base)
    target isa String && return target   # injection failed
    times = sort!(unique(Float64[a.time for a in t.assertions]))
    insp = BuildInspection()
    local sim
    try
        sim = simulate(target, (t.time_span.start, t.time_span.stop);
                       alg=e.alg, reltol=e.reltol, abstol=e.abstol,
                       saveat=times, parameters=t.parameter_overrides,
                       initial_conditions=t.initial_conditions,
                       inspect=insp)
    catch err
        return "simulate failed: $(sprint(showerror, err))"
    end
    sim.success || return "solver retcode $(sim.retcode): $(sim.message)"
    return _SimulateHandle(sim, insp, target)
end

_engine_actual(e::SimulateTestEngine, h::_SimulateHandle, a) =
    _evaluate_assertion(a, h.sim, h.insp, h.eval_file, e.mname,
                        e.resolved_base)

_engine_error_message(::SimulateTestEngine, err) =
    "assertion evaluation failed: $(sprint(showerror, err))"

"""
    run_pde_tests(input; model_name=nothing, alg=nothing,
                  reltol=DEFAULT_TEST_RELTOL, abstol=DEFAULT_TEST_ABSTOL,
                  base_dir=nothing) -> Vector{PdeAssertionResult}

Run every inline test (esm-spec §6.6, including the §6.6.5 PDE assertions) of
the selected model(s) of `input` (a path or a loaded [`EsmFile`](@ref)) through
the official tree-walk simulation pathway, and return one
[`PdeAssertionResult`](@ref) per assertion — carrying the ACTUAL reduction
value alongside pass/fail, so conformance harnesses can record and
cross-compare the numbers.

Per test: `simulate(input, (time_span.start, time_span.stop); alg, reltol,
abstol, saveat=<assertion times>)` with the test's `initial_conditions` /
`parameter_overrides` applied; then per assertion the asserted variable's field
is read at the assertion time and either point-sampled per its `coords`
(positions in 1-based INDEX space; nearest grid index, exact ties rounding
DOWN — the pinned cross-binding convention) or collapsed per its `reduce`
(error norms evaluate the `reference` — an analytic expression cellwise via
[`evaluate_cellwise`](@ref), or a `{type: "from_file", path, format?}` JSON
snapshot resolved against `base_dir`). An assertion with neither `coords` nor
`reduce` samples a scalar state. `base_dir` defaults to the .esm file's
directory when `input` is a path, else the working directory.

Tolerances resolve per esm-spec §6.6.4 (assertion > test > model > default
`rel=1e-6`); the pass predicate is the same `isapprox` check `run_esm_tests`
uses, and the results are the same [`AssertionResult`](@ref) type the MTK
runner produces — both runners are the SAME frame (`_run_test_frame!` in
run_tests.jl) with different execution engines plugged in, so tolerance
resolution, the pass predicate, per-test wall-time accounting, and JUnit
emission ([`write_junit_xml`](@ref), with `file=...` labeling the batch)
cannot drift apart. `alg` is REQUIRED (e.g. `Tsit5()` with
OrdinaryDiffEqTsit5 loaded) — the solve runs in the SciMLBase extension.
`reltol`/`abstol` default to the shared inline-test solver tolerances
`DEFAULT_TEST_RELTOL` / `DEFAULT_TEST_ABSTOL`.
"""
function run_pde_tests(input; model_name::Union{Nothing,AbstractString}=nothing,
                       alg=nothing,
                       reltol::Float64=DEFAULT_TEST_RELTOL,
                       abstol::Float64=DEFAULT_TEST_ABSTOL,
                       base_dir::Union{Nothing,AbstractString}=nothing)
    file = input isa AbstractString ? load(String(input)) : input
    file isa EsmFile ||
        throw(ArgumentError("run_pde_tests expects a path or EsmFile, got $(typeof(input))"))
    resolved_base = base_dir !== nothing ? String(base_dir) :
        (input isa AbstractString ? dirname(abspath(String(input))) : pwd())
    results = PdeAssertionResult[]
    file.models === nothing && return results
    for (mname, model) in file.models
        model_name !== nothing && String(mname) != String(model_name) && continue
        isempty(model.tests) && continue
        engine = SimulateTestEngine(file, input, String(mname),
                                    resolved_base, alg, reltol, abstol)
        _run_test_frame!(results, engine, "", :model, String(mname),
                         model.tolerance, model.tests)
    end
    return results
end
