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
if !isdefined(Main, :ESM_TESTUTILS_LOADED)

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
    EarthSciAST.OpExpr(String(op), EarthSciAST.Expr[args...]; kw...)
_idx(v, is...) = _op("index", _v(v), is...)

# Derived shorthands shared by the tree-walk / data-refresh test files
# (previously redefined per-file with identical bodies, producing
# method-overwrite warnings under runtests.jl). `_D_idx`/`_arrayop1d` are the
# historical spellings of `_Didx`/`_ao1` — kept as forwarding aliases so both
# call styles keep working.
_D(v) = _op("D", _v(v); wrt="t")
_Didx(v, is...) = _op("D", _idx(v, is...); wrt="t")
_D_idx(v, is...) = _Didx(v, is...)
_ao1(body, idx, lo, hi) = EarthSciAST.OpExpr("arrayop",
    EarthSciAST.Expr[];
    output_idx=Any[idx], expr_body=body, ranges=Dict(idx => [lo, hi]))
_arrayop1d(body, idx, lo, hi) = _ao1(body, idx, lo, hi)
_const(val) = EarthSciAST.OpExpr("const",
    EarthSciAST.Expr[]; value=val)

# 1-D second-difference stencil arrayop over the FULL range, so the two end
# cells gather an out-of-range (ghost) neighbour and form their own boundary
# kernels — the canonical "interior kernel + boundary kernels" decomposition.
# Shared by tree_walk_vectorized_test.jl and tree_walk_allocation_test.jl.
function _stencil_model(N)
    vars = Dict("u" => EarthSciAST.ModelVariable(
        EarthSciAST.StateVariable))
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

end # ESM_TESTUTILS_LOADED guard
