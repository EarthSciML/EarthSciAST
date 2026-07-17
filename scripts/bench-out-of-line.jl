#!/usr/bin/env julia
# RFC out-of-line-expression-templates §12 measurement stack (in-repo, no
# external data). Measures the reference cross-product cost of the committed
# `tests/bench/transport_3axis_7cubed.esm` benchmark:
#
#   * REPRESENTATION (load-time): distinct AST objects in the equation RHS under
#     the Option-A Expand image vs the Option-B reference-preserving load.
#   * BUILD (tree-walk): `_build_branch_template` spine-template count and
#     `_compile` node-lowering count, plus wall-clock, for the tree-walk build.
#
# Run: julia --project=pkg/EarthSciAST.jl scripts/bench-out-of-line.jl
#
# The two build columns are the fast path vs `ESS_TEMPLATE_REF_DISABLE=1`
# (Expand-at-build). Numbers are reported honestly — the RFC's ~100-200x is a
# prediction; whatever this prints is the result.

using EarthSciAST
using EarthSciAST: resolve_template_machinery, lower_expression_templates, Expand,
    JSONLikeDict, _BENCH_ON, _BENCH_COMPILE_CALLS, _BENCH_BRANCH_TEMPLATES,
    _BENCH_BODY_VARIANTS, _bench_reset!,
    build_evaluator, load, flatten
using JSON3

const ROOT = normpath(joinpath(@__DIR__, ".."))
const FIX = joinpath(ROOT, "tests", "bench", "transport_3axis_7cubed.esm")
# The compile-once measurement fixture (RFC step c): full-rank region bodies, so
# the affine box processor fires and the 5×5×5 branch-key cross-product is real.
const FIX_FULLRANK = joinpath(ROOT, "tests", "bench", "transport_3axis_7cubed_fullrank.esm")

_count_distinct(x, seen=Base.IdSet{Any}()) = begin
    (x isa AbstractDict || x isa AbstractVector) || return 0
    x in seen && return 0
    push!(seen, x)
    n = 1
    vals = x isa AbstractDict ? (v for (_, v) in x) : x
    for v in vals; n += _count_distinct(v, seen); end
    n
end

function representation()
    raw = JSON3.read(read(FIX, String))
    resolved = resolve_template_machinery(raw, dirname(FIX))
    loadedB = lower_expression_templates(resolved === nothing ? raw : resolved)
    dB = loadedB isa JSONLikeDict ? getfield(loadedB, :data) : loadedB
    expA = Expand(loadedB)
    rhsB = dB["models"]["Transport"]["equations"][1]["rhs"]
    rhsA = expA["models"]["Transport"]["equations"][1]["rhs"]
    println("── representation (load-time) ──")
    println("  RHS distinct AST objects  Option A (Expand): ", _count_distinct(rhsA))
    println("  RHS distinct AST objects  Option B (refs):   ", _count_distinct(rhsB))
    println("  whole-doc distinct objects A / B:            ",
            _count_distinct(expA), " / ", _count_distinct(dB))
end

function build_once(fix::AbstractString, disable::Bool)
    withenv("ESS_TEMPLATE_REF_DISABLE" => (disable ? "1" : nothing)) do
        # Fast path (default): references survive load and are CARRIED into the
        # FlattenedSystem (`expand_refs=false`), then compiled once per (use
        # site, region class) as sub-kernels by the affine build (RFC §7.7
        # "compile references natively"). Under `ESS_TEMPLATE_REF_DISABLE=1`
        # load already expanded, so `expand_refs` is moot and the build fuses
        # the expanded spine. Both are bit-identical (gate 3); this measures the
        # build cost. (An earlier revision passed `expand_refs = !disable`,
        # which expanded at flatten on BOTH columns — the fast column never
        # carried a reference.)
        build_evaluator(flatten(load(fix); expand_refs = false))
    end
end

function build_measure(fix::AbstractString, label; disable::Bool)
    _BENCH_ON[] = true
    _bench_reset!()
    t = @elapsed build_once(fix, disable)
    branches = _BENCH_BRANCH_TEMPLATES[]
    compiles = _BENCH_COMPILE_CALLS[]
    variants = _BENCH_BODY_VARIANTS[]
    _BENCH_ON[] = false
    println("── build ($label) ──")
    println("  _build_branch_template calls (spine templates): ", branches)
    println("  compiled template-body variants (sub-kernels):  ", variants)
    println("  _compile calls (node-lowerings):                ", compiles)
    println("  wall-clock (build, warm):                       ", round(t; digits = 3), " s")
    return (branches, compiles, t)
end

representation()
# Warm JIT once per fixture (uncounted) so the reported build numbers are
# lowering counts, not first-call compilation of the runner itself.
for fix in (FIX, FIX_FULLRANK)
    try
        build_once(fix, false)
    catch e
        println("NOTE: warm build threw: ", sprint(showerror, e))
    end
end
println()
println("═══ ", basename(FIX), " (reduced-rank faces → per-cell path; representation fixture) ═══")
build_measure(FIX, "fast path (default)"; disable = false)
build_measure(FIX, "ESS_TEMPLATE_REF_DISABLE=1 (fused)"; disable = true)
println()
println("═══ ", basename(FIX_FULLRANK), " (full-rank bodies → affine path; compile-once fixture) ═══")
fast = build_measure(FIX_FULLRANK, "fast path (compile-once)"; disable = false)
slow = build_measure(FIX_FULLRANK, "ESS_TEMPLATE_REF_DISABLE=1 (fused)"; disable = true)
println("── summary (", basename(FIX_FULLRANK), ") ──")
println("  branch templates fast / fused: ", fast[1], " / ", slow[1])
println("  node-lowerings   fast / fused: ", fast[2], " / ", slow[2])
