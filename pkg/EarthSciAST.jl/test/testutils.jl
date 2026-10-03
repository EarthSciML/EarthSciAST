# Shared test prelude for the EarthSciAST.jl suite.
#
# Every test file that needs the shared repo root, the canonical
# expression-builder helpers, the JSON-normalization helper, or the
# missing-fixture skip idiom does `include("testutils.jl")` near its top.
# The `isdefined` guard below makes that include idempotent, so each file
# still runs standalone
# (`julia --project -e 'using EarthSciAST, Test; include("test/<file>")'`)
# AND under runtests.jl (where many files include this prelude) without
# double-definition warnings.
#
# The guard is per-INCLUDING-MODULE (`@__MODULE__`), not `Main`: a test file
# that wraps itself in a `module` gets its own copy of the prelude. Guarding on
# `Main` instead made the prelude a silent no-op inside such a module (Main's
# bindings are not visible there), so every name it defines —
# `TESTUTILS_REPO_ROOT` above all — was UndefVarError under runtests.jl while
# the same file passed standalone. Top-level (Main-scoped) files are unaffected:
# runtests.jl loads the prelude into Main once and every later top-level include
# still short-circuits exactly as before.
if !isdefined(@__MODULE__, :ESM_TESTUTILS_LOADED)

const ESM_TESTUTILS_LOADED = true

using Test
using JSON3
using EarthSciAST

# Absolute path of the repository root (the directory containing the shared
# `tests/` fixture tree, `esm-schema.json`, `esm-spec.md`, ...).
const TESTUTILS_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

# ---------------------------------------------------------------------------
# Canonical expression-builder quartet (+ the `index` shorthand built on it).
# These keep hand-built AST fixtures readable.
# ---------------------------------------------------------------------------
_n(x) = EarthSciAST.NumExpr(Float64(x))
_i(x) = EarthSciAST.IntExpr(Int64(x))
_v(n) = EarthSciAST.VarExpr(String(n))
_op(op, args...; kw...) =
    EarthSciAST.OpExpr(String(op), EarthSciAST.ASTExpr[args...]; kw...)
_idx(v, is...) = _op("index", _v(v), is...)

# Derived shorthands shared by the tree-walk / data-refresh test files
# (previously redefined per-file with identical bodies, producing
# method-overwrite warnings under runtests.jl). `_D_idx`/`_faq1d` are the
# historical spellings of `_Didx`/`_ao1` — kept as forwarding aliases so both
# call styles keep working.
_D(v) = _op("D", _v(v); wrt="t")
_Didx(v, is...) = _op("D", _idx(v, is...); wrt="t")
_D_idx(v, is...) = _Didx(v, is...)
_ao1(body, idx, lo, hi) = EarthSciAST.OpExpr("faq",
    EarthSciAST.ASTExpr[];
    output_idx=Any[idx], expr_body=body, ranges=Dict(idx => [lo, hi]))
_faq1d(body, idx, lo, hi) = _ao1(body, idx, lo, hi)
_const(val) = EarthSciAST.OpExpr("const",
    EarthSciAST.ASTExpr[]; value=val)

# 1-D second-difference stencil faq over the FULL range, so the two end
# cells gather an out-of-range (ghost) neighbour and form their own boundary
# kernels — the canonical "interior kernel + boundary kernels" decomposition.
# Shared by tree_walk_vectorized_test.jl and tree_walk_allocation_test.jl.
function _stencil_model(N)
    vars = Dict("u" => EarthSciAST.ModelVariable(
        EarthSciAST.UnknownVariable))
    body = _op("+",
        _idx("u", _op("-", _v("i"), _i(1))),
        _op("*", _n(-2.0), _idx("u", _v("i"))),
        _idx("u", _op("+", _v("i"), _i(1))))
    EarthSciAST.Model(vars, [EarthSciAST.Equation(
        _ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(body, "i", 1, N))])
end

# ---------------------------------------------------------------------------
# JSON normalization: recursively convert any JSON3.Object / AbstractDict /
# JSON3.Array / AbstractVector tree into plain Dict{String,Any} / Any[]
# so structurally-equal payloads compare `==` regardless of container type.
# ---------------------------------------------------------------------------
_normj(x) =
    (x isa AbstractDict || x isa JSON3.Object) ?
        Dict{String,Any}(string(k) => _normj(v) for (k, v) in pairs(x)) :
    (x isa AbstractVector || x isa JSON3.Array) ?
        Any[_normj(v) for v in x] : x

"""
    corpus_is_resource_error(e) -> Bool

Errors a fixture-corpus sweep must never swallow. Those sweeps tolerate a model
that cannot build standalone by catching everything and skipping it — which
also catches the process running out of memory or stack. Resource exhaustion
then reads as an ordinary skip and the run stays green having tested nothing,
which is exactly how a fixture whose grid exhausted the allocator sat in the
corpus unnoticed. Rethrow these; skip on the rest.

This is a BACKSTOP, not the primary defence. The library is expected to deliver
these three unwrapped — `EarthSciAST._is_resource_error` marks the same set,
and every speculative-evaluation `catch` in `src/` that would otherwise decline
or rebrand consults it first — precisely so a resource error never reaches a
sweep disguised as a `TreeWalkError`, which this predicate could not recognise.
Keep the backstop anyway: it costs nothing and it is what catches the next
`catch` site that forgets.
"""
corpus_is_resource_error(e) =
    e isa OutOfMemoryError || e isa StackOverflowError || e isa InterruptException

"""
    _require_fixture(path) -> Bool

Return `true` when the fixture file (or directory) at `path` exists. When it
is missing, record a standardized `@test_skip` in the enclosing testset (so
the gap is visible in the summary as Broken, never silently green) and
return `false`. Use as:

    if _require_fixture(fixture_path)
        ... tests that consume the fixture ...
    end
"""
function _require_fixture(path::AbstractString)
    ispath(path) && return true
    @warn "Fixture not found — skipping" path
    @test_skip ispath(path)
    return false
end

# Zero-allocation harness (rhs_alloc_bytes / built_rhs_alloc_bytes) — shared
# by the tree-walk allocation and data-refresh tests. It carries its own
# include guard, so a direct `include("zero_alloc_harness.jl")` elsewhere
# stays harmless.
include("zero_alloc_harness.jl")

# A `u0` giving 0.0 to every ODE state (a `D` target on some equation's LHS)
# of `doc` — a path, JSON text or a parsed `Dict` — that declares no `default`.
# Several corpus documents leave their states' starting values to the harness;
# built without one they are refused (`E_TREEWALK_MISSING_INITIAL_VALUE`,
# esm-spec §11.4). Keys are `Model.var`, which `esm_problem` broadcasts over an
# array state's cells.
function harness_u0(doc)
    d = doc isa AbstractString ?
        JSON3.read(isfile(doc) ? read(doc, String) : doc, Dict{String,Any}) : doc
    d_target(lhs) = if lhs isa AbstractDict && get(lhs, "op", nothing) == "D"
        a = lhs["args"][1]
        a isa AbstractString ? a :
            (a isa AbstractDict && get(a, "op", nothing) == "index" ? a["args"][1] : nothing)
    elseif lhs isa AbstractDict && get(lhs, "op", nothing) == "faq"
        d_target(lhs["expr"])
    else
        nothing
    end
    out = Dict{String,Float64}()
    for (mname, m) in get(d, "models", Dict{String,Any}())
        m isa AbstractDict || continue
        vars = get(m, "variables", Dict{String,Any}())
        for eq in get(m, "equations", Any[])
            t = d_target(get(eq, "lhs", nothing))
            t isa AbstractString || continue
            v = get(vars, t, nothing)
            v isa AbstractDict && !haskey(v, "default") && (out["$mname.$t"] = 0.0)
        end
    end
    return out
end

end # ESM_TESTUTILS_LOADED guard
