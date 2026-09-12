# ===========================================================================
# inline_tests — the §6.6.5-capable inline-test runner over the tree-walk
# simulation pathway (the PDE dual of run_tests.jl's MTK scalar runner).
#
# A PDE model's inline tests (esm-spec §6.6.5) assert REDUCTIONS of a spatial
# field — `reduce: L2_error | Linf_error` against a `reference` (an analytic
# expression or a `from_file` JSON snapshot), or the pure collapsers
# `integral | mean | max | min` — or point-sample it via `coords`. The
# MTK-based `run_esm_tests` cannot compile
# `faq`/`makearray` discretizations; this runner drives the official
# tree-walk pipeline instead: `esm_problem` + `solve` (build_evaluator → seed ICs → solve
# via the SciMLBase extension) then per-assertion field reduction.
#
# `[[library-exposes-rhs-not-solver]]`: the caller supplies the ODE algorithm
# (`alg = Tsit5()` with OrdinaryDiffEqTsit5 loaded), exactly as for `solve`.
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
# - `run_inline_tests(inputs; model_name, alg, reltol, abstol, base_dir,
#   options_for)` — run every inline test of the selected component(s) of one
#   or many documents; returns per-assertion results carrying the ACTUAL
#   reduction values (conformance runners record these).
# - `InlineTestOptions` — the per-document override record a caller's
#   `options_for` callback returns.
#
# This entry was called `run_pde_tests` until it grew the ability to run a whole
# corpus. The name was always too narrow — the §6.6.5 spatial reductions are one
# assertion FORM, and the same runner has always executed the plain pointwise
# assertions of an ODE document through the same frame — so it is now
# `run_inline_tests`, with no deprecated alias (the old spelling is exactly the
# misunderstanding the rename exists to remove).
#
# SHARED frame: `run_inline_tests` and `run_esm_tests` are the SAME runner
# skeleton — `_run_test_frame!` in run_tests.jl (per-test/per-assertion loop,
# §6.6.4 tolerance resolution, §6.6.3 pass predicate, wall-time split,
# `AssertionResult` construction, JUnit emission) — with different execution
# ENGINES plugged in. This file contributes the `SimulateTestEngine`
# (tree-walk solve + field lookup) and the §6.6.5 evaluation machinery it
# drives; the MTK engine lives beside the frame in run_tests.jl.
# ===========================================================================

"""
    InlineTestError(msg)

A §6.6.5 inline-test evaluation failed: an ill-formed `coords` / `reduce`
assertion, a `from_file` reference that is missing or shape-mismatched, an
asserted variable with no field, or a per-test discretization injection
(§9.7.10 form C) that could not build. `run_inline_tests` catches it per
assertion and records the message on the failing [`AssertionResult`](@ref).
"""
struct InlineTestError <: EarthSciASTError
    msg::String
end
Base.showerror(io::IO, e::InlineTestError) = print(io, "InlineTestError: ", e.msg)

# `PdeAssertionResult` used to be aliased here, back when this runner's results
# were a distinct struct. Both inline-test runners have long shared ONE result
# type — [`AssertionResult`](@ref), defined in run_tests.jl, with one JUnit
# emitter — so the alias named nothing of its own, and its "Pde" was the same
# too-narrow word this file's rename removed. Deleted rather than kept: a second
# spelling for one type is exactly what makes a reader think there are two.
#
# For results this runner produces, `container_kind` is `:model` or
# `:reaction_system` after the component the test hangs off (both carry
# `tests`); `file` is `""` on an assertion row — the runner is handed its
# documents rather than discovering them, so pass `file=...` to
# [`write_junit_xml`](@ref) to label the batch — and is the document's path on
# the `<load>` row a batch emits for an unreadable file; and `reduce` / `rtol` /
# `atol` carry the assertion's declared reduction and the resolved §6.6.4
# tolerances.

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

# Collect every faq node reachable in `e` (walking `args` and
# `expr_body`), so the accelerator can require EXACTLY ONE reduction.
function _blas_collect_aggregates!(acc::Vector{OpExpr}, e)
    if e isa OpExpr
        _is_faq_op(e.op) && push!(acc, e)
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
`faq`/`makearray` nodes — e.g. a grid-geometry template expanded by a
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

# The TRAJECTORY SAMPLE as an evaluation scope: every state of `var_map`, read
# out of the flat state vector `state` and re-assembled into the shape its
# references expect — an array state as an `Array{Float64}` addressed by its own
# 1-based cell tuple, under its flattened stem (`"PB.u"`, from the `"PB.u[3]"`
# cell keys); a scalar state as a `Float64`.
#
# This is what makes a STATE-DEPENDENT observed readable at an assertion time.
# `evaluate_cellwise` binds names from two scopes — `const_arrays` (arrays) and
# `params` (scalars) — and STATE was in neither, so `dudt = D(D(u,lev),lev)`
# could only ever fail with `E_TREEWALK_UNBOUND_VARIABLE: PB.u`. Handing it the
# solved state at the assertion time binds exactly the names the resolved
# observed expression reads, and nothing else: the values are the solver's own,
# so the observed is evaluated at the state the trajectory actually had.
#
# A stem whose cell keys do not tile a dense box (a partial or ragged layout) is
# skipped rather than guessed at. `_parse_cell_key` (tree_walk.jl) is the single
# inverse of the `name[i,j]` cell-key encoding.
function _state_scope(var_map::AbstractDict, state::AbstractVector)
    arrays = Dict{String,Any}()
    scalars = Dict{String,Float64}()
    cells = Dict{String,Vector{Tuple{Vector{Int},Int}}}()
    for (name, slot) in var_map
        s = String(name)
        i = Int(slot)
        (1 <= i <= length(state)) || continue
        parsed = _parse_cell_key(s)
        if parsed === nothing
            scalars[s] = Float64(state[i])
        else
            stem, cell = parsed
            push!(get!(cells, String(stem), Tuple{Vector{Int},Int}[]), (cell, i))
        end
    end
    for (stem, entries) in cells
        nd = length(first(entries)[1])
        all(e -> length(e[1]) == nd, entries) || continue
        exts = Int[maximum(e[1][d] for e in entries) for d in 1:nd]
        (prod(exts) == length(entries) && all(>(0), exts)) || continue
        arr = Array{Float64}(undef, exts...)
        for (cell, slot) in entries
            arr[cell...] = Float64(state[slot])
        end
        arrays[stem] = arr
    end
    return arrays, scalars
end

# Extents of a declared `shape`, one per axis, or `nothing` when any axis is not
# sized at build time. Shared by the observed-field materialization and the
# per-cell lift of an author-level observed body, so both enumerate the same
# cells from the same index-set registry.
function _shape_extents(insp::BuildInspection, file::EsmFile,
                        shape)::Union{Vector{Int},Nothing}
    exts = Int[]
    for s in shape
        iset = get(file.index_sets, String(s), nothing)
        iset === nothing && return nothing
        e = if iset.kind == "interval"
            iset.size
        elseif iset.kind == "categorical"
            iset.members === nothing ? nothing : length(iset.members)
        elseif iset.kind == "derived"
            # A DERIVED axis is sized by value invention, which has already run
            # by the time an observed field is requested. `derived_extents` is
            # keyed by the PRODUCER id, so resolve through `from_faq` — without
            # this an observed shaped on an invented axis (ISRM's per-source
            # `E_VOC` over `emis_src_cells`) is simply unreadable, even though
            # the same axis resolves fine one level down when the observed is a
            # producer of something else.
            iset.from_faq === nothing ? nothing :
                get(insp.derived_extents, String(iset.from_faq), nothing)
        else
            nothing
        end
        e === nothing && return nothing
        push!(exts, Int(e))
    end
    return exts
end

# The const-array key holding `<mname>.<name>`'s materialized buffer, or
# `nothing` when the build materialized no such field FOR THIS COMPONENT.
#
# QUALIFIED-FIRST, the array analog of `_scalar_slot` / `_state_cells` (§6.6,
# §6.6.5): the model-qualified key wins outright, and the BARE key is this
# component's only when no model qualifies that suffix — a bare-keyed registry
# is the single-model build. Reading the bare key while some `<other>.<name>`
# exists would answer an `M2` assertion with `M1`'s buffer, which is exactly
# what the two-pass rule elsewhere in this file exists to prevent.
function _const_array_key(insp::BuildInspection, mname::AbstractString,
                          name::AbstractString)::Union{String,Nothing}
    qual = String(mname) * "." * String(name)
    haskey(insp.const_arrays, qual) && return qual
    haskey(insp.const_arrays, String(name)) || return nothing
    suffix = "." * String(name)
    any(k -> endswith(String(k), suffix), keys(insp.const_arrays)) && return nothing
    return String(name)
end

# The component's OWN defining equation for `variable`, lowered to the per-cell
# form `evaluate_cellwise` consumes and rewritten into the build's FLATTENED
# name scope. This is the fallback for an observed the build published in
# neither `observed_exprs` nor `observed_defs` (#176) — an observed the
# elementwise fold inlined into its readers and dropped, which for a DEAD one
# (nothing reads it) means dropped outright.
#
# Three rewrites, in this order:
#
#  1. NAMED PRODUCERS. A reference to another observed of the same component is
#     replaced by that observed's published body when the build has one, and
#     otherwise — the same deadness, one level down — by ITS authored body,
#     resolved recursively. A name the build materialized into a const array is
#     left alone: the buffer is the cheaper and more faithful answer.
#  2. PER-CELL LIFT. The authored body is a WHOLE-ARRAY expression (`2 * u`),
#     while `evaluate_cellwise` walks one output cell at a time. Wrapping it in
#     a `faq` over the declared shape — through the same
#     `_index_array_leaves` the build's own promotion uses, with §4.3.4 name
#     alignment — is exactly the form the published map would have carried, and
#     its ranges are the extents already resolved for the cell enumeration, so
#     nothing here re-derives an axis.
#  3. QUALIFICATION. The authored equation names its operands as the AUTHOR
#     wrote them (`base`), while the build's const-array and parameter scopes
#     — and the trajectory sample `_state_scope` builds — are keyed by the
#     flattened name (`M.base`, `M.u`). Each bare leaf that resolves under
#     `<model>.<name>` in any of those scopes is rewritten to it; one that does
#     not is left untouched, so an unresolvable reference still raises the
#     unbound-variable error it earns rather than being silently renamed.
#     Including the state scopes here is what lets a DEAD observed that reads
#     STATE compose with the state-dependent path: this function makes it reach
#     the scope, and the sample makes its `u` resolve once it is `M.u`.
#
# Returns `nothing` when `variable` has no defining equation in the component,
# or when it reappears on its OWN dependency chain (a cycle is the build's to
# diagnose). `chain` is the path from the asserted name down to this one, NOT
# the set of everything visited: two siblings that read the same dead observed
# are a DIAMOND, not a cycle, and each must resolve it.
function _authored_observed_body(insp::BuildInspection, file::EsmFile, model::Model,
                                 mname::AbstractString, variable::AbstractString,
                                 exts::Vector{Int},
                                 chain::Vector{String}=String[];
                                 state_arrays::AbstractDict=Dict{String,Any}(),
                                 state_scalars::AbstractDict=Dict{String,Float64}())
    String(variable) in chain && return nothing
    chain = vcat(chain, String(variable))
    body = observed_definition(model, String(variable))
    body === nothing && return nothing

    observed_here = Set{String}(observed_unknowns(model))
    var_shapes = Dict{String,Vector{String}}()
    for (n, mv) in model.variables
        mv.shape === nothing && continue
        var_shapes[String(n)] = String[String(x) for x in mv.shape]
    end
    arrayvars = Set{String}(String(n) for (n, mv) in model.variables
                            if _is_array_shape(mv.shape))

    # (1) Resolve the other observeds this body names.
    subs = Dict{String,ASTExpr}()
    for n in free_variables(body)
        name = String(n)
        (name == String(variable) || !(name in observed_here)) && continue
        qual = String(mname) * "." * name
        _const_array_key(insp, mname, name) === nothing || continue
        producer = get(insp.observed_exprs, qual, get(insp.observed_exprs, name, nothing))
        if producer === nothing
            nested = get(model.variables, name, nothing)
            nested === nothing && continue
            nshape = nested.shape === nothing ? String[] : nested.shape
            nexts = _shape_extents(insp, file, nshape)
            producer = nexts === nothing ? nothing :
                _authored_observed_body(insp, file, model, mname, name, nexts, chain;
                                        state_arrays=state_arrays,
                                        state_scalars=state_scalars)
        end
        producer === nothing || (subs[name] = producer)
    end
    isempty(subs) || (body = substitute(body, subs))

    # (2) Lift the whole-array body to the per-cell `faq` form — through the
    # BUILD'S OWN `_lift_to_faq` (shape_promotion.jl), with the resolved
    # extents as ranges. Sharing it is the point: the `_p<k>` loop convention
    # and the §4.3.4 alignment then cannot drift from the promotion that minted
    # the published bodies this one stands in for.
    if !isempty(exts)
        body = _lift_to_faq(body, get(var_shapes, String(variable), String[]),
                                arrayvars, var_shapes; bounds=exts)
    end

    # (3) Rewrite bare operand names into the build's flattened scope.
    renames = Dict{String,ASTExpr}()
    for n in free_variables(body)
        name = String(n)
        haskey(renames, name) && continue
        qual = String(mname) * "." * name
        (haskey(insp.const_arrays, qual) || haskey(insp.params, qual) ||
         haskey(state_arrays, qual) || haskey(state_scalars, qual)) || continue
        renames[name] = VarExpr(qual)
    end
    isempty(renames) || (body = substitute(body, renames))
    return body
end

# A §6.6.5 assertion may target an ARRAY OBSERVED (e.g. a rule output surfaced
# "for direct assertion", like the MPAS `div_flux`) rather than a state: an
# observed carries no ODE slot, so its field is evaluated from the build's
# RESOLVED observed expression (BuildInspection.observed_exprs) through the same
# official `evaluate_cellwise` machinery as an analytic `reference`, with the
# build's const-array registry AND resolved scalar parameters
# (BuildInspection.params — load-time constants) in scope.
#
# `state_arrays` / `state_scalars` (from `_state_scope`) add the TRAJECTORY
# SAMPLE to those two scopes, which is what makes a STATE-DEPENDENT observed
# readable: esm-spec §6.6.5 admits ANY shaped variable in a `coords` / `reduce`
# assertion, and §5.23 makes a reference denote its expansion, so `g = 2*u` and
# a lowered `dudt = D(D(u,lev),lev)` are assertable at a time exactly like the
# scalar observeds already were. With an empty state scope this is the previous
# state-free-only behaviour, value for value.
#
# Three sources, in this order, so an observed is readable however the build
# chose to treat it: the published body, the materialized buffer for one the
# build folded into the const-array registry, and — for one the build dropped
# from both, the DEAD case of #176 — the component's own defining equation
# (`_authored_observed_body`).
#
# ONE DIAGNOSTIC CHANGES, deliberately (CONFORMANCE_SPEC §5.27.3). A declared
# observed whose defining equation cannot be evaluated here — it names something
# the document never declares, a provider array not yet fetched — used to fall
# out of this function as `nothing` and be reported by the caller as
# "array state '<v>' has no cells in var_map". It now reaches the evaluator and
# raises `E_TREEWALK_UNBOUND_VARIABLE: <name>`, which `run_tests.jl` turns into
# the same ERROR verdict with the unresolved operand named. An UNDECLARED
# variable is unaffected: it never gets this far (`observed_unknowns` gate
# above) and still earns the var_map message.
#
# Cells are enumerated from the declared shape's interval index sets. Returns
# `(field, cells)` or `nothing` when the variable is not such an observed.
function _observed_field(insp::BuildInspection, file::EsmFile,
                         mname::AbstractString, variable::AbstractString;
                         state_arrays::AbstractDict=Dict{String,Any}(),
                         state_scalars::AbstractDict=Dict{String,Float64}())
    # `models === nothing` for a document that is reaction systems only, whose
    # components declare SPECIES rather than variables and so have no observed
    # to find here; the assertion falls through to the scalar-slot path.
    model = file.models === nothing ? nothing : get(file.models, String(mname), nothing)
    model === nothing && return nothing
    v = get(model.variables, String(variable), nothing)
    (v !== nothing && String(variable) in observed_unknowns(model)) || return nothing
    # A SHAPELESS observed is rank 0, not unreadable: `E_NOx = Σ_r annual[r]·…`
    # contracts its only axis away and is a single number, which the Rust
    # `observed_field(prob, name)` returns and this refused to. One empty cell
    # index is exactly what `evaluate_cellwise` wants for it (its compile-once
    # fast path is already gated on `nidx >= 1`).
    shape = v.shape === nothing ? String[] : v.shape
    exts = _shape_extents(insp, file, shape)
    exts === nothing && return nothing
    qualified = String(mname) * "." * String(variable)
    # The fully-substituted form: self-contained, always evaluable, and the only
    # form a build without `observed_defs` publishes. This stays the FALLBACK.
    inlined = get(insp.observed_exprs, qualified,
                  get(insp.observed_exprs, String(variable), nothing))
    # The UN-inlined form: cheap when its producers can be materialized (they
    # are then evaluated once instead of per output cell), but it references
    # them BY NAME — so it is only usable if every one of them resolves.
    raw = get(insp.observed_defs, qualified,
              get(insp.observed_defs, String(variable), nothing))
    expr = inlined === nothing ? raw : inlined
    # `vec` flattens the comprehension to a `Vector{Vector{Int}}` for ANY rank:
    # over a rank≥2 `CartesianIndices` the comprehension yields a `Matrix`
    # (higher-D array), and `sort!` on that throws `UndefKeywordError: dims`.
    # The trailing `sort!` fixes the cell order to lexicographic (row-major,
    # last index fastest) regardless of the flatten order — matching
    # `_state_cells` and the Python (`np.ndindex`) / Rust (row-major enum)
    # observed-field ordering, so `field`/`reference` pair cell-for-cell.
    cells = sort!(vec(Vector{Int}[collect(Int, Tuple(I))
                                  for I in CartesianIndices(Tuple(exts))]))
    # NEITHER form published, but the build MATERIALIZED the field: an observed
    # whose body is build-once (a document-literal `const` array, a setup
    # geometry buffer) is dropped from the observed graph precisely because its
    # value already sits in the const-array registry. Read the buffer — it is
    # both the cheaper answer and the one every reader of that observed saw.
    if expr === nothing
        bufkey = _const_array_key(insp, String(mname), String(variable))
        buf = bufkey === nothing ? nothing : insp.const_arrays[bufkey]
        if buf isa AbstractArray && eltype(buf) <: Real && size(buf) == Tuple(exts)
            return (Float64[Float64(buf[c...]) for c in cells], cells)
        end
    end
    # NEITHER form published (#176). The build's observed graph is keyed by what
    # SURVIVED lowering, and the elementwise array-observed fold
    # (`_fold_elementwise_array_observeds`) inlines such an observed into its
    # readers and DROPS its equation — so a diagnostic nothing else reads, the
    # ordinary shape of a quantity computed for a test, reaches neither map and
    # the assertion failed with "has no cells in var_map". Fall back to the
    # component's OWN defining equation, lowered to the same per-cell form and
    # evaluated in the same scope, so an observed is assertable whether or not
    # the dynamics happen to consume it (esm-spec §6.6.5 admits any shaped
    # variable; §5.23 makes a reference denote its expansion).
    if expr === nothing
        expr = _authored_observed_body(insp, file, model, String(mname),
                                       String(variable), exts;
                                       state_arrays=state_arrays,
                                       state_scalars=state_scalars)
    end
    expr === nothing && return nothing
    params = _param_scope_with_aliases(insp.params)
    # The trajectory sample wins over a same-named build constant: a name that
    # is a STATE is not a constant, and its value at this time is the answer.
    isempty(state_scalars) || (params = merge(params, Dict{String,Float64}(
        String(k) => Float64(v) for (k, v) in state_scalars)))
    const_scope = isempty(state_arrays) ? insp.const_arrays :
        merge(Dict{String,Any}(String(k) => v for (k, v) in insp.const_arrays),
              Dict{String,Any}(String(k) => v for (k, v) in state_arrays))
    # Try the cheap path FIRST, and fall back on any failure. The un-inlined
    # definition names its producers, so it only evaluates when every one of
    # them was materialized; a producer this build-time scope cannot evaluate
    # (a deferred/gated provider array that is not yet fetched, one reading
    # STATE, an unsized axis) leaves a dangling reference and raises
    # E_TREEWALK_UNBOUND_VARIABLE. The inlined form has no such dependency, so
    # falling back to it makes this change strictly an optimisation: identical
    # values when it succeeds, previous behaviour exactly when it cannot.
    # The producer-materializing fast path runs against `const_scope`, NOT the
    # build's const arrays alone, so it serves both kinds of target. Gating it on
    # an empty state scope instead would have disabled it outright: the assertion
    # callsite always seeds `state_scalars` with `t`, so `isempty(state_scalars)`
    # is never true there and the MPAS `div_flux` case — state-free, and the very
    # case this path was written for — would have paid the per-output-cell
    # re-execution it exists to remove. Seeding the scope with the trajectory
    # sample instead lets a STATE-DEPENDENT target's producers materialize too,
    # at that sample: `raw` names them, they are filled once each in dependency
    # order, and the target is then one cellwise pass over buffers. Values are
    # the inlined form's either way — a producer neither form can evaluate here
    # simply stays un-materialized and its reader inlines it, and any failure
    # still falls through to the self-contained body below.
    if raw !== nothing
        try
            ca = _materialized_obs_scope(insp, file, mname, String(variable), params;
                                         base=const_scope)
            if ca !== const_scope                # something actually materialized
                return (evaluate_cellwise(raw, cells; const_arrays=ca, params=params),
                        cells)
            end
        catch
            # fall through to the inlined form below
        end
    end
    field = evaluate_cellwise(expr, cells; const_arrays=const_scope, params=params)
    return (field, cells)
end

"""
    _materialized_obs_scope(insp, file, mname, target, params; base) -> const-array scope

Materialize the ARRAY-shaped observed producers `target` depends on, once each in
dependency order, and return `base` augmented with those buffers.

`base` is the array scope the producers are evaluated AGAINST as well as the map
that is extended, and defaults to `insp.const_arrays` — the build-time answer.
A §6.6.5 assertion passes the build's const arrays PLUS the trajectory sample
(`_state_scope`), which is what lets a STATE-DEPENDENT target use this path at
all: its producers read the solved state, so against `insp.const_arrays` alone
every one of them fails to resolve and the whole chain re-executes per output
cell of the consumer.

Why this exists. `evaluate_cellwise` walks the expression once PER OUTPUT CELL, so
an array observed inlined into its readers is re-executed at every cell of the
consumer's field. The ISRM model composes `E_p[c]` — a spatial join, an aggregate
over source cells x ALL emission records with rectangle-containment comparisons —
into `conc_p[rcv] = Σ_s SR_p[s,rcv]·E_p[s]`, into `TotalPM25`, into `deathsK`. So
evaluating `deathsK` re-ran the entire spatial join once per receptor cell:
`5 · |ppl| · |records|` terms at each of 52,411 cells, ~1.7e13 evaluations at full
scale. Materializing each producer once makes it O(1) in the consumer's cell count.

This is deliberately SEPARATE from the RHS-side factoring
(`_collect_materialized_array_obs`), which roots liveness at the `D`/`ic` equations
and so factors nothing at all for a pure-algebraic model — no state, every result
an observed — which is exactly the shape that suffers most here. The root for the
build-time path is the observed the caller asked for.

Values are the same computation, to within float reassociation. A buffer holds
what that observed's own published body computes at that index, and the reduction
order WITHIN each aggregate is untouched. What can move is the order BETWEEN them:
a consumer that used to inline `a + b + c` and now reads three buffers is summing
the same three numbers, but the un-inlined and the fully substituted bodies are
not always the same expression tree, and float addition does not associate. So
materializing a producer that previously could not be materialized may move a
downstream field in its last bits — observed at 5e-15 on the ISRM point document
when the `observed_exprs` fallback below was added. Nothing semantic changes, and
nothing about WHICH terms are summed.

Returns `base` ITSELF (by identity, which is how the caller detects the no-op)
when there is nothing to materialize, so models whose observeds are scalar or
independent keep the previous behaviour and cost.
"""
function _materialized_obs_scope(insp::BuildInspection, file::EsmFile,
                                 mname::AbstractString, target::AbstractString,
                                 params::AbstractDict;
                                 base::AbstractDict=insp.const_arrays)
    isempty(insp.observed_defs) && return base
    model = get(file.models, String(mname), nothing)
    model === nothing && return base

    # TWO published forms of an observed's body, and this needs BOTH.
    #
    #   `observed_defs`  — UN-inlined: names its producers, so it is cheap to
    #                      evaluate once every producer is a buffer, but it only
    #                      resolves when every one of them IS.
    #   `observed_exprs` — fully substituted: always self-contained, and the only
    #                      form published for an observed the build inlined away.
    #
    # The second is not a redundant copy. An intermediate the build folded into
    # its readers — a rank-2 projected coordinate feeding a rank-1 length, say —
    # appears in `observed_exprs` and NOT in `observed_defs`, and it is not a
    # const array either. Traversing only the un-inlined map therefore stops at
    # the first such name: its readers' definitions reference it, the reference
    # is unbound, and EVERY producer above it fails in turn. The chain is then
    # inlined into the consumer and re-executed per output cell, which is the
    # exact cost this function exists to remove — silently, because the failure
    # is a caught exception and the fallback is merely slow, not wrong.
    raw_def(n) = get(insp.observed_defs, String(mname) * "." * n,
                     get(insp.observed_defs, n, nothing))
    res_def(n) = get(insp.observed_exprs, String(mname) * "." * n,
                     get(insp.observed_exprs, n, nothing))
    function lookup(n)                      # traversal: prefer the un-inlined form
        d = raw_def(n)
        return d === nothing ? res_def(n) : d
    end
    # Extents of an array observed from its declared shape. Goes through the
    # build's own resolver so a DATA-DERIVED axis works too — the ISRM emission
    # binning is shaped on `emis_src_cells`, whose size value invention
    # discovers, and an interval-only lookup would skip exactly the observed
    # that matters most. `nothing` ⇒ not materializable (scalar / unsized axis).
    observed_here = Set{String}(observed_unknowns(model))
    function extents(n)
        v = get(model.variables, n, nothing)
        (v !== nothing && n in observed_here &&
         v.shape !== nothing && !isempty(v.shape)) || return nothing
        ex = Int[]
        for s in v.shape
            iset = get(file.index_sets, String(s), nothing)
            iset === nothing && return nothing
            e = if iset.kind == "interval"
                iset.size
            elseif iset.kind == "categorical"
                iset.members === nothing ? nothing : length(iset.members)
            elseif iset.kind == "derived"
                # `derived_extents` is keyed by the PRODUCER id, so follow the
                # set's `from_faq`. Without this the ISRM emission binning —
                # shaped on the value-invented `emis_src_cells` — is skipped,
                # and skipping it leaves every consumer above it unresolvable.
                iset.from_faq === nothing ? nothing :
                    get(insp.derived_extents, String(iset.from_faq), nothing)
            else
                nothing
            end
            (e === nothing || Int(e) <= 0) && return nothing
            push!(ex, Int(e))
        end
        return isempty(ex) ? nothing : ex
    end

    # Post-order DFS from the target over observed→observed references: a name is
    # emitted only after everything it reads, so a single left-to-right pass fills
    # buffers in dependency order. Cycles cannot occur (the build already rejects
    # them), but `onstack` keeps this total even if one slipped through.
    order = String[]; done = Set{String}(); onstack = Set{String}()
    function visit(n)
        (n in done || n in onstack) && return
        push!(onstack, n)
        def = lookup(n)
        if def !== nothing
            for r in EarthSciAST._referenced_var_names(def)
                lookup(String(r)) === nothing || visit(String(r))
            end
        end
        delete!(onstack, n); push!(done, n); push!(order, n)
    end
    visit(String(target))

    ca = Dict{String,Any}(base)
    materialized = 0
    for n in order
        n == String(target) && continue        # the caller evaluates this one
        haskey(ca, n) && continue              # already supplied by the caller
        lookup(n) === nothing && continue
        ex = extents(n); ex === nothing && continue
        any(<=(0), ex) && continue
        cells = sort!(vec(Vector{Int}[collect(Int, Tuple(I))
                                      for I in CartesianIndices(Tuple(ex))]))
        # Try the un-inlined body first — it reads the buffers already filled, so
        # it is the cheap one — and fall back to the fully substituted body when
        # it cannot resolve. Both compute the same number: the substituted form
        # is literally what the consumer would otherwise have recomputed inline.
        # A producer neither form can evaluate here (one reading STATE, say) just
        # stays un-materialized, and its readers inline it exactly as before.
        vals = nothing
        for cand in (raw_def(n), res_def(n))
            cand === nothing && continue
            vals = try
                evaluate_cellwise(cand, cells; const_arrays=ca, params=params)
            catch
                nothing
            end
            vals === nothing || break
        end
        (vals !== nothing && length(vals) == length(cells)) || continue
        buf = Array{Float64}(undef, Tuple(ex)...)
        @inbounds for (i, c) in enumerate(cells)
            buf[CartesianIndex(Tuple(c))] = vals[i]
        end
        ca[n] = buf
        materialized += 1
    end
    return materialized == 0 ? base : ca
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
                      model::AbstractString,
                      renames::AbstractDict=Dict{String,String}())::Int
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
    # A THIRD pass, for a name an `operator_compose` renaming match DELETED
    # (§4.7.1 step 4). A test is written against the component that owns it, and
    # a merge can fold that component's state onto another's — the quantity the
    # assertion names still exists, under the survivor's spelling. LAST, so a
    # live row always wins: resolution may never shadow a variable the flattened
    # system really has (CONFORMANCE_SPEC §5.35).
    if !isempty(renames)
        survivor = get(renames, qualified, get(renames, String(variable), nothing))
        if survivor !== nothing
            for (name, slot) in var_map
                String(name) == survivor && return Int(slot)
            end
        end
    end
    return 0
end

# Whether `name` occurs FREE in `expr`: as a variable reference not bound by an
# enclosing `faq` / `makearray` loop symbol (`output_idx`, a
# `ranges` key) or an `integral`'s integration variable. A binder shadows the
# name for its whole subtree.
#
# Deliberately NOT `free_variables`: that function also reports a node's `wrt`,
# the symbol a derivative differentiates WITH RESPECT TO. `wrt` is a
# differentiation target named by the node, not a value read from the enclosing
# scope, and it is added AFTER binder subtraction — so a reference containing
# `deriv(u, wrt: "x")` would be wrapped here but by neither the Rust
# `mentions_free` nor the Python `_mentions_free`, which ignore `wrt`. That is
# exactly the kind of cross-binding divergence CONFORMANCE_SPEC §5.30 exists to
# close. Mirrors those two functions.
_mentions_free(::ASTExpr, ::AbstractString) = false
_mentions_free(expr::VarExpr, name::AbstractString) = expr.name == name
function _mentions_free(expr::OpExpr, name::AbstractString)::Bool
    String(name) in _bound_symbols(expr) && return false
    return any(c -> _mentions_free(c, name), child_exprs(expr))
end

# The ARRAY half of the §6.6.5 build-time clash scope: every name the build's
# array registries bind, plus each one's UNAMBIGUOUS bare alias — the same alias
# rule `_param_scope_with_aliases` applies to the scalar half, and the rule under
# which a flattened `M.table` is readable as `table`. Accepts any number of
# name-keyed collections (`insp.const_arrays`, `insp.setup_arrays`), so a binding
# that keeps its build arrays in more than one registry passes all of them.
# The Python (`_array_scope_names`) and Rust (`array_scope_names`) mirrors derive
# the same set.
function _array_scope_names(regs...)::Set{String}
    names = Set{String}()
    for r in regs
        r === nothing && continue
        for k in keys(r)
            push!(names, String(k))
        end
    end
    counts = Dict{String,Int}()
    for n in names
        b = _bare_param_name(n)
        b == n && continue
        counts[b] = get(counts, b, 0) + 1
    end
    out = copy(names)
    for n in names
        b = _bare_param_name(n)
        (b != n && counts[b] == 1 && !(b in out)) && push!(out, b)
    end
    return out
end

"""
    bind_dimension_names(expr, dims, scope=Dict{String,Float64}(),
                         arrays=Set{String}()) -> ASTExpr

esm-spec §6.6.5: an inline `reference`'s free variables are the domain DIMENSION
NAMES. For a field shaped over index sets those are the asserted variable's
`shape` entries, each bound at every grid point to the 1-based position along
its axis — the same index space `coords` reads (convention 1) — so
`index(table, lev)` reads the cell's entry of a lookup array and
`sin(pi * (x - 0.5) / N)` is the cell-centre analytic form, with no explicit
gather. A reference that mentions a dimension name FREE (`_mentions_free`, for
which every binder's own loop symbols shadow it) is turned into the whole field
by wrapping it in a `faq` whose output indices ARE the dimension names
(in shape order, each ranging over its index set); one that mentions none — a
literal, a parameter expression, or a `faq` that already produces the
field under its own loop symbols — is returned untouched, so nothing that
evaluated before evaluates differently. Mirrors the Python / Rust
`bind_dimension_names`.

"Nothing that evaluated before evaluates differently" holds only because a
dimension name the BUILD-TIME SCOPE ALREADY BINDS is rejected here: wrapping
would silently shadow that other meaning with the cell's index — the same
expression, a different number, no diagnostic. One name meaning two things in
one scope is an ill-formed document, so it is a fault. esm-spec §6.6.5 makes the
clash scope the WHOLE build-time scope, in two halves:

  * `scope` — the scalar parameter scope (flattened names plus their
    unambiguous bare aliases, `_param_scope_with_aliases`); and
  * `arrays` — the build-time ARRAY names (`_array_scope_names` over
    `insp.const_arrays` / `insp.setup_arrays`), likewise with bare aliases.

The array half is not decorative here: Julia hands `evaluate_cellwise` its
`const_arrays`, so a `const` array named after a shape index set (an array `lev`
over the index set `lev`) is a name the reference could already read, and
checking only the parameter half would rebind it to the cell index in silence.
"""
function bind_dimension_names(expr::ASTExpr, dims::AbstractVector{<:AbstractString},
                              scope::AbstractDict=Dict{String,Float64}(),
                              arrays=Set{String}())::ASTExpr
    isempty(dims) && return expr
    mentioned = String[String(d) for d in dims if _mentions_free(expr, String(d))]
    isempty(mentioned) && return expr
    clash = findfirst(d -> haskey(scope, d) || d in arrays, mentioned)
    clash === nothing || throw(InlineTestError(
        "inline `reference` mentions '$(mentioned[clash])', which is both a dimension " *
        "of the asserted field and a name the build-time scope already binds " *
        "($(haskey(scope, mentioned[clash]) ? "a parameter" : "a build-time array")). " *
        "esm-spec §6.6.5 binds a free dimension name to the cell's 1-based position, " *
        "which would shadow it. Rename one of them, or gather explicitly with " *
        "`aggregate(i from $(mentioned[clash]); …)`."))
    names = String[String(d) for d in dims]
    return OpExpr("faq", ASTExpr[];
                  output_idx=Any[names...],
                  ranges=Dict{String,Any}(d => IndexSetRef(d) for d in names),
                  expr_body=expr)
end

# The asserted variable's declared spatial shape (ordered index-set names).
# Errors when the variable is missing or scalar — a `coords` assertion is
# ill-formed on a 0-D variable per esm-spec §6.6.5.
function _variable_shape(file::EsmFile, mname::AbstractString,
                         variable::AbstractString)::Vector{String}
    model = file.models === nothing ? nothing : get(file.models, String(mname), nothing)
    if model === nothing
        # A reaction system declares SPECIES, and a species is 0-D. The answer
        # is therefore the coords-specific rejection, not "model not found":
        # the component exists, and what is ill-formed is asking a scalar for
        # a grid cell.
        file.reaction_systems !== nothing &&
            haskey(file.reaction_systems, String(mname)) &&
            throw(InlineTestError(
                "`coords` requires a spatially-shaped variable; '$(variable)' is scalar"))
        throw(InlineTestError("model '$(mname)' not found"))
    end
    v = get(model.variables, String(variable), nothing)
    v === nothing && throw(InlineTestError(
        "variable '$(variable)' is not declared in model '$(mname)'"))
    (v.shape === nothing || isempty(v.shape)) && throw(InlineTestError(
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
            throw(InlineTestError("`coords` names unknown dimension '$(k)' " *
                  "(field dimensions: $(join(shape, ", ")))"))
    end
    cell = Int[]
    for s in shape
        iset = get(index_sets, s, nothing)
        (iset !== nothing && iset.kind == "interval" && iset.size !== nothing) ||
            throw(InlineTestError("`coords` sampling requires interval index sets " *
                  "with a declared size; '$(s)' is not one"))
        n = Int(iset.size)
        if haskey(coords, s)
            c = Float64(coords[s])
            idx = ceil(Int, c - 0.5)  # nearest index; exact ties round DOWN
            (1 <= idx <= n) ||
                throw(InlineTestError("`coords` position $(c) along '$(s)' resolves " *
                      "to index $(idx), outside 1..$(n)"))
            push!(cell, idx)
        else
            n == 1 ||
                throw(InlineTestError("`coords` leaves dimension '$(s)' unpinned " *
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
            throw(InlineTestError("from_file reference shape mismatch along " *
                  "dimension $(d): expected a nested array of length $(exts[d])"))
        length(node) == exts[d] ||
            throw(InlineTestError("from_file reference shape mismatch along " *
                  "dimension $(d): expected length $(exts[d]), found $(length(node))"))
        node = node[i]
    end
    (node isa Real && !(node isa Bool)) ||
        throw(InlineTestError("from_file reference shape mismatch at cell " *
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
        throw(InlineTestError("from_file reference format '$(fmt)' is not supported " *
              "(v1 supports \"json\" only)"))
    path_raw = get(ref, "path", nothing)
    path_raw === nothing && throw(InlineTestError("from_file reference is missing `path`"))
    p = String(path_raw)
    resolved = isabspath(p) ? p : joinpath(String(base_dir), p)
    isfile(resolved) ||
        throw(InlineTestError("from_file reference file not found: $(resolved)"))
    data = JSON3.read(read(resolved, String))
    isempty(cell_tuples) &&
        throw(InlineTestError("from_file reference: field has no cells"))
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
    injected || throw(InlineTestError(
        "component '$(mname)' not found for per-test injection (esm-spec §9.7.10)"))
    f = load_string(JSON3.write(raw); base_path=String(base_dir))
    resolve_subsystem_refs!(f, String(base_dir))
    # The ephemeral file is a BUILD input (and the file this test's §6.6.5
    # `reference` expressions evaluate against), and the raw base may have come
    # straight off disk — so it gets the same §9.5.3 lowering `run_inline_tests`
    # gave the persisted one. In place: this file exists only for this test.
    return lower_table_lookups!(f)
end

# Relative slack when matching an assertion's `time` against the solver's
# saved time points: `saveat` hits the requested times only to solver/Float64
# precision, so accept the nearest saved point within this relative tolerance
# (scaled by `max(1, |t|)`). 1e-9 sits far above Float64 roundoff accumulation
# yet far below any two distinct assertion times in practice.
const _SAVED_TIME_RTOL = 1e-9

# ---------------------------------------------------------------------------
# Per-assertion evaluation — the §6.6.5 scalar-selection / reduction machinery,
# split out of `run_inline_tests` so the driver stays a flat loop. Returns the
# scalar `actual`; throws [`InlineTestError`](@ref) on any spec-relevant failure
# (the driver records it as an `ERROR` result).
# ---------------------------------------------------------------------------
function _evaluate_assertion(a, sim, var_map::AbstractDict,
                             insp::BuildInspection, eval_file::EsmFile,
                             mname::AbstractString,
                             resolved_base::AbstractString,
                             renames::AbstractDict=Dict{String,String}())::Float64
    ti = argmin(abs.(sim.t .- a.time))
    abs(sim.t[ti] - a.time) <= _SAVED_TIME_RTOL * max(1.0, abs(a.time)) ||
        throw(InlineTestError("no saved state at t=$(a.time) (nearest $(sim.t[ti]))"))
    state = sim.u[ti]

    if a.coords === nothing && a.reduce === nothing
        slot = _scalar_slot(var_map, a.variable, String(mname), renames)
        slot == 0 && throw(InlineTestError("scalar state '$(a.variable)' not found"))
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

    cells = _state_cells(var_map, a.variable, String(mname))
    local field::Vector{Float64}, cell_tuples::Vector{Vector{Int}}
    if !isempty(cells)
        field = Float64[state[slot] for (_, slot) in cells]
        cell_tuples = [c for (c, _) in cells]
    else
        # No ODE slots: an ARRAY OBSERVED asserted directly (§6.6.5). The
        # trajectory sample at this time is put in scope alongside the build's
        # constants and parameters, so a STATE-DEPENDENT observed evaluates at
        # the state the solver had; a state-free one never reads those names and
        # is unaffected.
        state_arrays, state_scalars = _state_scope(var_map, state)
        state_scalars["t"] = Float64(sim.t[ti])
        obs = _observed_field(insp, eval_file, String(mname), String(a.variable);
                              state_arrays=state_arrays, state_scalars=state_scalars)
        obs === nothing && throw(InlineTestError(
            "array state '$(a.variable)' has no cells in var_map"))
        field, cell_tuples = obs
    end

    if coords_target !== nothing
        pos = findfirst(==(coords_target), cell_tuples)
        pos === nothing && throw(InlineTestError("no grid sample at cell " *
            "[$(join(coords_target, ","))] of '$(a.variable)'"))
        return field[pos]
    end

    ref = nothing
    if a.reference !== nothing
        if a.reference isa ASTExpr
            # Model parameters (load-time constants) are in scope for a §6.6.5
            # analytic `reference`; state is not. `insp.params` carries the
            # build's resolved scalar params (override-or-default). The field's
            # dimension names are in scope too, bound per cell
            # (`bind_dimension_names`).
            dims = try
                _variable_shape(eval_file, String(mname), String(a.variable))
            catch err
                err isa InlineTestError ? String[] : rethrow()
            end
            scope = _param_scope_with_aliases(insp.params)
            # The ARRAY half of the §6.6.5 clash scope: `evaluate_cellwise`
            # binds `const_arrays` by name, so an array named after a shape
            # index set is a name the reference could already read and the
            # wrap would silently rebind it to the cell index (issue #226).
            arrays = _array_scope_names(insp.const_arrays, insp.setup_arrays)
            ref = evaluate_cellwise(bind_dimension_names(a.reference, dims, scope, arrays),
                                    cell_tuples;
                                    const_arrays=insp.const_arrays, params=scope)
        elseif a.reference isa AbstractDict &&
               string(get(a.reference, "type", "")) == "from_file"
            ref = _from_file_reference(a.reference, resolved_base, cell_tuples)
        else
            throw(InlineTestError("unsupported `reference` shape $(typeof(a.reference))"))
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
# §9.7.10 form-C injection target, `solve` with the assertion times as
# `saveat`, then evaluate each assertion against the saved fields. The solve
# flattens the file (models + coupling) into ONE runnable system named
# "Flattened", so no model_name is passed; element names keep their
# owning-model prefix, which the `_state_cells` / `_scalar_slot` lookups
# resolve per assertion.
# ---------------------------------------------------------------------------
struct SimulateTestEngine
    file::EsmFile            # document as loaded
    input::Any               # original `run_inline_tests` input (path or EsmFile)
    mname::String
    resolved_base::String
    alg::Any
    reltol::Float64
    abstol::Float64
    # Caller-supplied SEEDS from an `InlineTestOptions` (empty when there is
    # none). They sit BENEATH each test's own maps — see `_engine_setup`.
    seed_p::AbstractDict
    seed_u0::AbstractDict
end

SimulateTestEngine(file, input, mname, resolved_base, alg, reltol, abstol) =
    SimulateTestEngine(file, input, mname, resolved_base, alg, reltol, abstol,
                       Dict{String,Any}(), Dict{String,Any}())

# Per-test handle: the successful simulation plus the build-observability sink
# (assertions on ARRAY OBSERVEDS evaluate their resolved expression from
# `insp` — see `_observed_field`) and the file the assertions resolve shapes
# against (the ephemeral injected file when the test injects a discretization).
struct _SimulateHandle
    sim::Any                      # the SciML solution `solve(prob, alg)` returned
    var_map::Dict{String,Int}     # state-element name → flat index (from the problem)
    insp::BuildInspection
    eval_file::EsmFile
    # The states an `operator_compose` renaming match DELETED, mapped onto the
    # survivors (issue #230). An assertion names its component's LOCAL variable,
    # which a merge may have folded onto another component's.
    merged_renames::Dict{String,String}
end

# Qualify a test's override keys with the component that OWNS the test.
#
# esm-spec §6.6.2 keys `parameter_overrides` / `initial_conditions` by LOCAL
# name — local to the ENCLOSING component, since a test "exercises one model in
# isolation" (§6.6). The runner hands them to `esm_problem`, which resolves against
# the WHOLE flattened document, where that locality is gone: two mounted
# components that each declare a `T` flatten to `M1.T` / `M2.T`, and the bare
# `T` in `M2`'s test is then AMBIGUOUS document-wide even though it is
# unambiguous where it was written.
#
# So re-attach the scope the runner still knows: a key whose `<model>.<key>`
# form names a real variable of the flattened system is rewritten to it. A key
# that does not (already qualified, a scoped reference the prefix would double
# up, or simply wrong) passes through untouched, so `esm_problem` reports on it
# exactly as it would have.
_overrides_or_empty(o) = o === nothing ? Dict{String,Any}() : o

# Lay a caller's SEED under a test's own override map (esm-spec §6.6.2). The
# document is authoritative about its own test, so the test's key wins; the
# seed only supplies what the document left unsaid.
#
# The merge happens BEFORE `_scope_to_component`, so a seed key and a test key
# naming the same variable collide on the one spelling. Merging afterwards
# would instead hand `esm_problem` both `T` and `M.T` — two keys designating
# one parameter, with two values.
function _seeded_overrides(seed::AbstractDict, authored)
    isempty(seed) && return authored
    out = Dict{String,Any}()
    for (k, v) in seed
        out[String(k)] = v
    end
    authored === nothing && return out
    for (k, v) in authored
        out[String(k)] = v
    end
    return out
end

function _scope_to_component(overrides, mname, target)
    (overrides === nothing || isempty(overrides)) && return overrides
    known, renames = try
        flat = flatten(target)
        (union(Set{String}(String(n) for n in keys(flat.parameters)),
               Set{String}(String(n) for n in keys(flat.state_variables))),
         flat.metadata.merged_variable_renames)
    catch
        return overrides   # let `esm_problem` report the real failure
    end
    # `Any`-valued: esm-spec §6.6.2 admits a scalar or INLINE ARRAY DATA (a
    # shaped variable's whole column), and re-scoping must not flatten the
    # second to a number.
    out = Dict{String,Any}()
    for (rawk, v) in overrides
        k = String(rawk)
        q = string(mname, ".", k)
        # An `operator_compose` renaming match may have DELETED the very name
        # this component's test keys on (§4.7.1 step 4): `Sink.O3` folded onto
        # `Chem.ozone` leaves the scoped spelling naming nothing, and the key
        # then falls through as a bare local that resolves to nothing
        # document-wide. Resolve it onto the survivor instead
        # (CONFORMANCE_SPEC §5.35).
        out[q in known ? q : get(renames, q, k)] = v
    end
    return out
end

function _engine_setup(e::SimulateTestEngine, t)
    target = _resolve_test_target(e.file, e.input, e.mname, t, e.resolved_base)
    target isa String && return target   # injection failed
    times = sort!(unique(Float64[a.time for a in t.assertions]))
    insp = BuildInspection()
    local prob, sim
    try
        prob = esm_problem(target, (t.time_span.start, t.time_span.stop);
                           p=_overrides_or_empty(_scope_to_component(
                               _seeded_overrides(e.seed_p, t.parameter_overrides),
                               e.mname, target)),
                           u0=_scope_to_component(
                               _seeded_overrides(e.seed_u0, t.initial_conditions),
                               e.mname, target),
                           inspect=insp)
        sim = _solve_problem(prob, e.alg; reltol=e.reltol, abstol=e.abstol,
                             saveat=times)
    catch err
        return "simulation failed: $(sprint(showerror, err))"
    end
    # `retcode` is a SciML `ReturnCode` (§2.5.3); compare it by name so this
    # core file stays solver-free.
    Symbol(sim.retcode) === :Success ||
        return "solver retcode $(sim.retcode)"
    return _SimulateHandle(sim, prob.var_map, insp, target,
                           Dict{String,String}(prob.merged_renames))
end

_engine_actual(e::SimulateTestEngine, h::_SimulateHandle, a) =
    _evaluate_assertion(a, h.sim, h.var_map, h.insp, h.eval_file, e.mname,
                        e.resolved_base, h.merged_renames)

_engine_error_message(::SimulateTestEngine, err) =
    "assertion evaluation failed: $(sprint(showerror, err))"

"""
    InlineTestOptions(; model_name=nothing, alg=nothing, reltol=nothing,
                      abstol=nothing, base_dir=nothing,
                      initial_conditions=nothing, parameter_overrides=nothing)

Per-document overrides for [`run_inline_tests`](@ref), returned by its
`options_for` callback.

Every field is optional, and a field left `nothing` INHERITS the value passed
to `run_inline_tests` itself — so a callback that cares about one document's
solver and nothing else returns `InlineTestOptions(alg=Rodas5())` and the rest
of the run is unchanged.

This record exists so that site-specific policy stays at the site. A CI gate
over a model corpus routinely carries basename-keyed tables — a stiff-solver
map, an initial-condition seed for the documents whose tests do not state one
— and each of those is a reason the gate could not call the library entry and
re-implemented esm-spec §6.6 instead. One callback absorbs all of them without
this module learning anything about the corpus.

`initial_conditions` / `parameter_overrides` are SEEDS: they are laid BENEATH
each test's own maps, so a test that states a value keeps it and a test that is
silent gets the caller's. They are merged with the test's map before
`_scope_to_component` runs, and so are keyed and resolved exactly like a test's
own keys — which is what makes the precedence well defined.
"""
Base.@kwdef struct InlineTestOptions
    model_name::Union{Nothing,AbstractString} = nothing
    alg::Any = nothing
    reltol::Union{Nothing,Float64} = nothing
    abstol::Union{Nothing,Float64} = nothing
    base_dir::Union{Nothing,AbstractString} = nothing
    initial_conditions::Union{Nothing,AbstractDict} = nothing
    parameter_overrides::Union{Nothing,AbstractDict} = nothing
end

# The document's TEST-BEARING components, models first and then reaction
# systems, each in the document's own key order.
#
# esm-spec §6.6 hangs `tests` off a component, and the schema gives
# `reaction_systems` the same `tests` / `tolerance` members it gives `models`.
# This runner iterated `models` alone until issue #194, so a chemical
# mechanism's inline tests were neither run nor reported — the silent half of a
# coverage gap, since a component with no rows and a component that was never
# looked at are indistinguishable in the result list. `run_file_tests!` in
# run_tests.jl has always walked both maps; this brings the simulate runner
# into line with it, `container_kind` and all.
#
# Reaction-system species are 0-D, so their assertions take the pointwise
# (scalar-slot) form; nothing about the build changes, because the whole
# document is flattened either way and a species becomes an ordinary state.
function _test_components(file::EsmFile, model_name)
    out = Tuple{String,Symbol,Any}[]
    for (kind, container) in ((:model, file.models),
                              (:reaction_system, file.reaction_systems))
        container === nothing && continue
        for (name, component) in container
            model_name !== nothing && String(name) != String(model_name) && continue
            isempty(component.tests) && continue
            push!(out, (String(name), kind, component))
        end
    end
    return out
end

# Every `.esm` document under `dir`, recursively, SORTED — a result list whose
# order depends on the filesystem is not comparable between two runs, let alone
# between two machines.
function _esm_files_under(dir::AbstractString)
    found = String[]
    for (root, _, files) in walkdir(String(dir))
        for f in files
            endswith(f, ".esm") && push!(found, joinpath(root, f))
        end
    end
    return sort!(found)
end

# Resolve `run_inline_tests`' `inputs` to a flat vector of documents: a path
# stays a path, a directory expands to the `.esm` files under it, an `EsmFile`
# stays itself. An `AbstractString` and an `EsmFile` are SINGLE inputs — neither
# is iterated element-wise.
function _expand_inputs(inputs)
    items = (inputs isa AbstractString || inputs isa EsmFile) ? Any[inputs] :
        (applicable(iterate, inputs) ? collect(Any, inputs) :
         throw(ArgumentError("run_inline_tests expects a path, an EsmFile, a " *
                             "directory or an iterable of those, got $(typeof(inputs))")))
    out = Any[]
    for item in items
        if item isa EsmFile
            push!(out, item)
        elseif item isa AbstractString
            p = String(item)
            isdir(p) ? append!(out, _esm_files_under(p)) : push!(out, p)
        else
            throw(ArgumentError("run_inline_tests: $(typeof(item)) is not a path or EsmFile"))
        end
    end
    return out
end

# The one ERROR row a document that could not be LOADED contributes to a batch.
# A corpus run must not lose a file to one bad document, and must not lose it
# SILENTLY either — a document that vanishes from the result list is
# indistinguishable from one that passed. Same shape `run_file_tests!` already
# emits for an unparseable file.
_load_failure_result(path::AbstractString, err) = AssertionResult(
    String(path), :file, "<parse>", "<load>", 0, "", NaN, NaN, nothing,
    ERROR, "load failed: $(sprint(showerror, err))", 0.0)

# Fold one document's `InlineTestOptions` onto the call-level defaults: a field
# the override left `nothing` inherits, every other field wins.
_opt_or(::Nothing, _field, fallback) = fallback
_opt_or(o::InlineTestOptions, field::Symbol, fallback) =
    (v = getfield(o, field); v === nothing ? fallback : v)
_opt_dict(::Nothing, _field) = Dict{String,Any}()
_opt_dict(o::InlineTestOptions, field::Symbol) =
    (v = getfield(o, field); v === nothing ? Dict{String,Any}() : v)

"""
    run_inline_tests(inputs; model_name=nothing, alg=nothing,
                     reltol=DEFAULT_TEST_RELTOL, abstol=DEFAULT_TEST_ABSTOL,
                     base_dir=nothing, options_for=nothing)
        -> Vector{AssertionResult}

Run every inline test (esm-spec §6.6, including the §6.6.5 PDE assertions) of
the selected component(s) of `inputs` through the official tree-walk simulation
pathway, and return one [`AssertionResult`](@ref) per assertion — carrying
the ACTUAL reduction value alongside pass/fail, so conformance harnesses can
record and cross-compare the numbers.

`inputs` is a path to a `.esm` file, a loaded [`EsmFile`](@ref), a DIRECTORY
(walked recursively for `*.esm`, sorted), or any iterable of those. Results are
concatenated in input order.

Both kinds of test-bearing component are run: `models` first, then
`reaction_systems`, which the schema gives the same `tests` member and which
this runner skipped entirely until it was fixed.

Per test: `solve(esm_problem(input, (time_span.start, time_span.stop)), alg;
reltol, abstol, saveat=<assertion times>)` with the test's `initial_conditions`
/ `parameter_overrides` applied; then per assertion the asserted variable's field
is read at the assertion time and either point-sampled per its `coords`
(positions in 1-based INDEX space; nearest grid index, exact ties rounding
DOWN — the pinned cross-binding convention) or collapsed per its `reduce`
(error norms evaluate the `reference` — an analytic expression cellwise via
[`evaluate_cellwise`](@ref), or a `{type: "from_file", path, format?}` JSON
snapshot resolved against `base_dir`). An assertion with neither `coords` nor
`reduce` samples a scalar state. `base_dir` defaults to the .esm file's
directory when the document came from a path, else the working directory.

`options_for` is the seam for site-specific policy. It is called once per
resolved document — with the document's path when it came from one, else the
`EsmFile`, and BEFORE the document is loaded, so a basename-keyed callback is
asked about an unreadable file too and wants a default rather than an indexing
error — and returns an [`InlineTestOptions`](@ref) whose non-`nothing`
fields override the keywords above for that document (or `nothing` to change
nothing). It exists so that a corpus gate's basename-keyed tables — a
stiff-solver map, an initial-condition seed — can stay in the gate instead of
forcing it to re-implement §6.6 to get at them.

A document that fails to LOAD throws when `inputs` names a single document,
exactly as before. In a BATCH — an iterable or a directory — it instead
contributes one ERROR row naming the path, so one unreadable file cannot cost
the run every other file's verdicts.

Tolerances resolve per esm-spec §6.6.4 — PER FIELD over four levels
(assertion > test > model > the implementation default `rel=1e-6`), each of
`rel` and `abs` taken from the innermost level that declares it; the pass
predicate is the same `isapprox` check `run_esm_tests`
uses, and the results are the same [`AssertionResult`](@ref) type the MTK
runner produces — both runners are the SAME frame (`_run_test_frame!` in
run_tests.jl) with different execution engines plugged in, so tolerance
resolution, the pass predicate, per-test wall-time accounting, and JUnit
emission ([`write_junit_xml`](@ref), with `file=...` labeling the batch)
cannot drift apart. `alg` is REQUIRED (e.g. `Tsit5()` with
OrdinaryDiffEqTsit5 loaded) — the solve runs in the SciMLBase extension.
`reltol`/`abstol` default to `nothing`, and that is load bearing rather than
merely tidy: it is what keeps the DOCUMENT's own opinion expressible. Each
resolves per esm-spec §2.2.2, most-specific first — an `options_for` override,
then the keyword here, then this document's `solver.reltol` / `solver.abstol`
(§2.2), then the shared inline-test defaults `DEFAULT_TEST_RELTOL` /
`DEFAULT_TEST_ABSTOL`. The runner defaults sit at the BOTTOM of the chain
because they are binding defaults, not a caller's opinion, so a document that
declares its own integration accuracy gets it without every caller naming it.
Passing a value explicitly overrides the document, which is why a concrete
default here would silently have suppressed it. These are INTEGRATION
tolerances and are a different quantity from the §6.6.4 assertion tolerance
above.

This entry was called `run_pde_tests` until it grew the ability to run a whole
corpus. The name was always too narrow — the §6.6.5 spatial reductions are one
assertion FORM, and the same runner has always executed the plain pointwise
assertions of an ODE document through the same frame — so it is now
`run_inline_tests`, with no deprecated alias.
"""
function run_inline_tests(inputs; model_name::Union{Nothing,AbstractString}=nothing,
                          alg=nothing,
                          reltol::Union{Float64,Nothing}=nothing,
                          abstol::Union{Float64,Nothing}=nothing,
                          base_dir::Union{Nothing,AbstractString}=nothing,
                          options_for=nothing)
    documents = _expand_inputs(inputs)
    batch = !((inputs isa EsmFile) ||
              (inputs isa AbstractString && !isdir(String(inputs))))
    results = AssertionResult[]
    for document in documents
        o = options_for === nothing ? nothing : options_for(document)
        (o === nothing || o isa InlineTestOptions) || throw(ArgumentError(
            "options_for must return an InlineTestOptions or nothing, got $(typeof(o))"))
        file = document
        if document isa AbstractString
            file = try
                load_path(String(document))
            catch err
                batch || rethrow()
                push!(results, _load_failure_result(document, err))
                continue
            end
        end
        file isa EsmFile || throw(ArgumentError(
            "run_inline_tests expects a path or EsmFile, got $(typeof(document))"))
        _run_document_tests!(results, file, document, o;
                             model_name, alg, reltol, abstol, base_dir)
    end
    return results
end

# Run one document's inline tests, appending to `results`. `document` is the
# path it was loaded from, or the `EsmFile` itself — it anchors `from_file`
# references and the §9.7.10 per-test injection. The per-document body of
# `run_inline_tests`.
function _run_document_tests!(results, file::EsmFile, document, o;
                              model_name, alg, reltol, abstol, base_dir)
    # esm-spec §9.5.3, at the build boundary rather than at load (§9.5.4 wants
    # the authored form to round-trip). `esm_problem` lowers the flattened
    # system it builds, but the file kept HERE is also an evaluated artifact:
    # `_evaluate_assertion` reads a §6.6.5 `reference` expression straight off
    # it. The pure form leaves a caller's `EsmFile` untouched, and returns it
    # as-is — no copy — for the documents that declare no tables.
    file = lower_table_lookups(file)
    d_model_name = _opt_or(o, :model_name, model_name)
    d_alg        = _opt_or(o, :alg, alg)
    # esm-spec §2.2.2, most-specific first: an `options_for` override, then the
    # keyword, then THIS DOCUMENT's `solver` block, then the runner defaults
    # (which `_test_integration_tolerances` supplies as its own fallback). A
    # `nothing` at either of the first two levels is what lets the next one
    # speak. INTEGRATION tolerances; the §6.6.4 assertion tolerance is separate.
    doc_reltol, doc_abstol = _test_integration_tolerances(file.solver)
    d_reltol     = Float64(_opt_or(o, :reltol, reltol === nothing ? doc_reltol : reltol))
    d_abstol     = Float64(_opt_or(o, :abstol, abstol === nothing ? doc_abstol : abstol))
    d_base_dir   = _opt_or(o, :base_dir, base_dir)
    seed_p       = _opt_dict(o, :parameter_overrides)
    seed_u0      = _opt_dict(o, :initial_conditions)
    resolved_base = d_base_dir !== nothing ? String(d_base_dir) :
        (document isa AbstractString ? dirname(abspath(String(document))) : pwd())
    for (mname, kind, component) in _test_components(file, d_model_name)
        engine = SimulateTestEngine(file, document, mname, resolved_base,
                                    d_alg, d_reltol, d_abstol, seed_p, seed_u0)
        _run_test_frame!(results, engine, "", kind, mname,
                         component.tolerance, component.tests)
    end
    return results
end
