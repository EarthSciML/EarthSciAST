# Build-time lane-table interning (tree_walk/acc_merge.jl `_lane_intern`,
# `ESS_LANE_INTERN_DISABLE=1` oracle) + the clamp/edge-bound collapse
# (tree_walk/oop.jl `_oop_lane_bound`).
#
# WHAT THIS PINS.
#   1. SHARING IS IN THE BUILD PRODUCT. After a default build, content-equal
#      interp tables inside a merged kernel's `_Interp*LaneSpec.specs` are the
#      SAME object (`===`) — counted by `objectid` — even when they were minted
#      from different const spellings (`[10, 20]` vs `[10.0, 20.0]`) or
#      distinct-but-equal vectors, which AST interning cannot unify (it keys
#      const payload vectors by identity). With `ESS_LANE_INTERN_DISABLE=1`
#      every member keeps its own mint — today's un-interned build — so the
#      distinct-object count rises back to the member count, and
#      `Base.summarysize` shows the share is real memory.
#   2. BIT-IDENTITY. du is `===` per element (NaN/-0.0 count; never ≈) between
#      the default build and the ESS_LANE_INTERN_DISABLE=1 /
#      ESS_KERNEL_CLASS_MERGE_DISABLE=1 / ESS_STENCIL_DISABLE=1 /
#      ESS_CODEGEN_DISABLE=1 oracles, at Float64 (both `:inplace` and `:oop`)
#      and under ForwardDiff Dual via the Jacobian.
#   3. THE CLAMP-BOUND COLLAPSE IS SOUND. `_oop_lane_bound` collapses an
#      all-BITWISE-equal boundary column to its one scalar (so a trace embeds a
#      scalar constant, not an O(lanes) tensor — the gap
#      test/reactant_lane_dedup_test.jl documents), keeps `-0.0`≠`0.0` columns
#      intact, unifies all-NaN, and is the identity under the kill switch. The
#      branch-free lane evaluators (the TRACER's program — reached here by
#      evaluating at a non-`Real` value type on host data) stay `===` to the
#      per-lane scalar-core reference over sweeps covering both clamps, the
#      knots, NaN, and a lane-INVARIANT scalar query — the case where a
#      collapsed bound must NOT collapse the result's lane axis.
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

# Build with the intern pool / class merge / stencil / codegen toggled.
function _lti_build(model, ics; intern::Bool=true, merged::Bool=true,
                    stencil::Bool=true, codegen::Bool=true, form::Symbol=:inplace)
    withenv("ESS_LANE_INTERN_DISABLE" => (intern ? nothing : "1"),
            "ESS_KERNEL_CLASS_MERGE_DISABLE" => (merged ? nothing : "1"),
            "ESS_STENCIL_DISABLE" => (stencil ? nothing : "1"),
            "ESS_CODEGEN_DISABLE" => (codegen ? nothing : "1")) do
        ESM._build_evaluator_impl(model; initial_conditions=ics, form=form)
    end
end

_lti_du(f!, u, p, t) = (d = similar(u); fill!(d, 0.0); f!(d, u, p, t); d)
_lti_bitsame(a, b) = size(a) == size(b) && all(a .=== b)
# Probes cross both clamp bounds of the [0, 4] axes (interp queries are state
# reads), so the clamp arms — the code the bound collapse touches — really run.
_lti_probe(n, k) =
    Float64[-1.5 + 7.0 * abs(sin(1.3i + 0.7k)) + 0.01i for i in 1:n]

# Collect every distinct `_Interp*LaneSpec` of type `LaneT` reachable from the
# retained kernel list (build with codegen OFF so kernels are introspectable —
# same route as codegen_lanespec_test.jl).
function _lti_lanespecs(f!, ::Type{LaneT}) where {LaneT}
    out = LaneT[]
    seen = IdDict{Any,Nothing}()
    function visit(nd)
        haskey(seen, nd) && return
        seen[nd] = nothing
        if nd.kind === ESM._NK_OP && nd.op === :fn &&
           nd.payload isa Tuple{String,LaneT}
            h = nd.payload[2]
            any(x -> x === h, out) || push!(out, h)
        end
        foreach(visit, nd.children)
        return
    end
    function visitk(K)
        visit(K.spine)
        foreach(visit, K.cse.recipes)
        foreach(visit, K.cse.inv_recipes)
        foreach(visitk, K.subs)
        return
    end
    foreach(visitk, getfield(getfield(f!, :kernel_section), :kernels))
    return out
end

_lti_nuniq(specs) = length(unique(map(objectid, specs)))

_lti_vars(names...) =
    Dict{String,ESM.ModelVariable}(n => ESM.ModelVariable(ESM.UnknownVariable)
                                   for n in names)
_lti_eq(x, body, N) = ESM.Equation(_ao1(_Didx(x, _v("i")), "i", 1, N),
                                   _ao1(body, "i", 1, N))
_lti_ics(names, N) =
    Dict("$x[$k]" => 2.0 + sin(0.3k + 0.1j) for (j, x) in enumerate(names), k in 1:N)

# ---- fixtures: SIX members, TWO distinct table contents ----------------------
#
# a1/a2/a3 carry table-content A (a1 as Float64 literals, a2 as INT literals —
# the coercion-equal spelling AST interning cannot unify — a3 as a distinct
# copy of the Float64 vector); b1/b2/b3 carry content B the same way. One merge
# class of 6 members: un-interned the lane table holds 6 distinct spec objects
# (one mint per member; each member's own lanes already shared its mint),
# interned it holds 2 — one per DISTINCT CONTENT, a property of the document.

const _LTI_AX  = [0.0, 1.0, 2.0, 3.0, 4.0]
const _LTI_TA  = [10.0, 20.0, 40.0, 80.0, 160.0]
const _LTI_TAi = [10, 20, 40, 80, 160]
const _LTI_TB  = [-3.0, 5.0, -11.0, 17.0, -23.0]
const _LTI_TBi = [-3, 5, -11, 17, -23]

function _lti_linear_model(N)
    body(x, tbl) = _op("+",
        _op("fn", _const(tbl), _const(_LTI_AX), _idx(x, _v("i")); name="interp.linear"),
        _op("*", _n(-0.5), _idx(x, _v("i"))))
    ESM.Model(_lti_vars("a1", "a2", "a3", "b1", "b2", "b3"),
              [_lti_eq("a1", body("a1", _LTI_TA), N),
               _lti_eq("a2", body("a2", _LTI_TAi), N),
               _lti_eq("a3", body("a3", copy(_LTI_TA)), N),
               _lti_eq("b1", body("b1", _LTI_TB), N),
               _lti_eq("b2", body("b2", _LTI_TBi), N),
               _lti_eq("b3", body("b3", copy(_LTI_TB)), N)])
end

const _LTI_BAX = [0.0, 1.0, 2.0]
const _LTI_BTA  = Any[Any[1.0, 2.0, 3.0], Any[4.0, 5.0, 6.0], Any[7.0, 8.0, 9.0]]
const _LTI_BTAi = Any[Any[1, 2, 3], Any[4, 5, 6], Any[7, 8, 9]]
const _LTI_BTB  = Any[Any[-9.0, 3.0, -1.0], Any[2.5, -4.0, 0.5], Any[-0.25, 8.0, -6.0]]

function _lti_bilinear_model(N)
    body(x, tbl) = _op("fn", _const(tbl), _const(_LTI_BAX), _const(_LTI_BAX),
                       _idx(x, _v("i")), _idx(x, _op("+", _v("i"), _i(1)));
                       name="interp.bilinear")
    ESM.Model(_lti_vars("u", "v", "w"),
              [_lti_eq("u", body("u", _LTI_BTA), N),
               _lti_eq("v", body("v", _LTI_BTAi), N),
               _lti_eq("w", body("w", _LTI_BTB), N)])
end

const _LTI_SSA  = [1.0, 2.0, 3.0, 4.0]
const _LTI_SSAi = [1, 2, 3, 4]
const _LTI_SSB  = [0.5, 1.5, 1.5, 3.5]

function _lti_searchsorted_model(N)
    body(x, xs) = _op("fn", _idx(x, _v("i")), _const(xs); name="interp.searchsorted")
    ESM.Model(_lti_vars("u", "v", "w"),
              [_lti_eq("u", body("u", _LTI_SSA), N),
               _lti_eq("v", body("v", _LTI_SSAi), N),
               _lti_eq("w", body("w", _LTI_SSB), N)])
end

# One flavour's sharing + differential pins. `members` is the merge-class
# member count, `ncontent` the distinct table-content count.
function _lti_flavour(model, ics, ::Type{LaneT}; members::Int, ncontent::Int,
                      N::Int, jacobian::Bool=true) where {LaneT}
    # Introspection builds (codegen off so the kernel list is retained).
    fon, u0, p, _, _, don = _lti_build(model, ics; codegen=false)
    foff, v0, q, _, _, _ = _lti_build(model, ics; codegen=false, intern=false)
    fun, w0, r, _, _, dun = _lti_build(model, ics; codegen=false, merged=false)

    # The fixture is real: the class merge fired and minted a lane spec. (A
    # stencil-shaped body may additionally mint small boundary-class lane
    # specs; the interned and oracle builds have identical kernel structure,
    # so the collections pair up positionally.)
    @test don.n_acc_kernels < dun.n_acc_kernels
    hs_on = _lti_lanespecs(fon, LaneT)
    hs_off = _lti_lanespecs(foff, LaneT)
    @test length(hs_on) == length(hs_off) >= 1
    for (hon, hoff) in zip(hs_on, hs_off)
        @test length(hon.specs) == length(hoff.specs)
        # Every lane's content is preserved lane-by-lane vs the oracle, the
        # canonical set never over-merges two distinct contents, and the
        # knot-major lane columns — what the evaluators/backends broadcast —
        # are bitwise unchanged by interning.
        @test all(l -> ESM._fn_spec_content_equal(hon.specs[l], hoff.specs[l]),
                  eachindex(hon.specs))
        reps = unique(objectid, hon.specs)
        for i in eachindex(reps), j in (i + 1):length(reps)
            @test !ESM._fn_spec_content_equal(reps[i], reps[j])
        end
        for f in fieldnames(LaneT)
            f === :specs && continue
            @test isequal(getfield(hon, f), getfield(hoff, f))
        end
    end

    # (a)+(b) on the MAIN class (the most lanes): content-equal lane tables
    # are `===` after an interned build — distinct objects == distinct
    # CONTENTS — while the oracle build keeps one object per MEMBER mint; the
    # share is real memory, not just aliasing in a count.
    h_on = argmax(h -> length(h.specs), hs_on)
    h_off = argmax(h -> length(h.specs), hs_off)
    @test length(h_on.specs) >= members * (N - 1)
    @test _lti_nuniq(h_on.specs) == ncontent
    @test _lti_nuniq(h_off.specs) == members
    @test Base.summarysize(h_on) < Base.summarysize(h_off)

    # (c) bit-identity against every oracle, on the default (codegen-on) build.
    fc, uc, pc, _, _, _ = _lti_build(model, ics)
    fi, ui, pi_, _, _, _ = _lti_build(model, ics; intern=false)
    fm, um, pm, _, _, _ = _lti_build(model, ics; merged=false)
    fs, us, ps, _, _, _ = _lti_build(model, ics; stencil=false)
    @test uc == ui && uc == um && uc == us && uc == u0
    for k in 1:4, t in (0.0, 0.7, 3.25)
        u = k == 1 ? copy(uc) : _lti_probe(length(uc), k)
        duc = _lti_du(fc, u, pc, t)
        @test _lti_bitsame(duc, _lti_du(fi, u, pi_, t))   # ≡ intern kill switch
        @test _lti_bitsame(duc, _lti_du(fm, u, pm, t))    # ≡ unmerged
        @test _lti_bitsame(duc, _lti_du(fs, u, ps, t))    # ≡ per-cell scalar
        @test _lti_bitsame(duc, _lti_du(fon, u, p, t))    # ≡ codegen-disabled
    end
    # `:oop` emitter too — the branch-free forms' host consumer.
    gc = _lti_build(model, ics; form=:oop)[1]
    gi = _lti_build(model, ics; form=:oop, intern=false)[1]
    for k in 1:3, t in (0.0, 0.7)
        u = k == 1 ? copy(uc) : _lti_probe(length(uc), k)
        @test _lti_bitsame(gc(u, pc, t), gi(u, pi_, t))
        @test _lti_bitsame(gc(u, pc, t), _lti_du(fc, u, pc, t))
    end
    # ForwardDiff Dual (values + partials via the Jacobian).
    if jacobian
        Jc = ForwardDiff.jacobian(uu -> _lti_du(fc, uu, pc, 0.4), uc)
        Ji = ForwardDiff.jacobian(uu -> _lti_du(fi, uu, pi_, 0.4), ui)
        @test _lti_bitsame(Jc, Ji)
    end
    return nothing
end

@testset "build-time lane-table interning" begin

    @testset "interp.linear: 6 members, 2 contents (N=$N)" for N in (5, 16)
        _lti_flavour(_lti_linear_model(N),
                     _lti_ics(("a1", "a2", "a3", "b1", "b2", "b3"), N),
                     ESM._InterpLinearLaneSpec; members=6, ncontent=2, N=N)
    end

    @testset "interp.bilinear: 3 members, 2 contents (N=$N)" for N in (6,)
        _lti_flavour(_lti_bilinear_model(N), _lti_ics(("u", "v", "w"), N),
                     ESM._InterpBilinearLaneSpec; members=3, ncontent=2, N=N)
    end

    @testset "interp.searchsorted: 3 members, 2 contents (N=$N)" for N in (6,)
        # Piecewise-constant: Jacobian partials are trivially zero — values
        # are still pinned through the Dual path.
        _lti_flavour(_lti_searchsorted_model(N), _lti_ics(("u", "v", "w"), N),
                     ESM._InterpSearchsortedLaneSpec; members=3, ncontent=2, N=N)
    end

    @testset "mint-site interning: content-equal scalar specs share one object" begin
        # No lane spec involved: two equations whose specs are content-equal
        # merge into one class carrying the REP's scalar spec, but the mint
        # itself must already share — pin `_build_interp_spec` through the
        # pool directly under an installed pool.
        prev = ESM._LANE_INTERN_POOL[]
        ESM._LANE_INTERN_POOL[] = Dict{ESM._LaneInternKey,Any}()
        try
            s1 = ESM._build_interp_spec("interp.linear",
                                        Any[_LTI_TA, _LTI_AX])
            s2 = ESM._build_interp_spec("interp.linear",
                                        Any[_LTI_TAi, copy(_LTI_AX)])
            s3 = ESM._build_interp_spec("interp.linear",
                                        Any[_LTI_TB, _LTI_AX])
            @test s1 === s2
            @test s1 !== s3
        finally
            ESM._LANE_INTERN_POOL[] = prev
        end
        # Pool off (outside a build): the mint is fresh per call — today's
        # behavior, and what the ESS_LANE_INTERN_DISABLE=1 build sees.
        t1 = ESM._build_interp_spec("interp.linear", Any[_LTI_TA, _LTI_AX])
        t2 = ESM._build_interp_spec("interp.linear", Any[_LTI_TA, _LTI_AX])
        @test t1 !== t2 && ESM._fn_spec_content_equal(t1, t2)
    end

    @testset "_oop_lane_bound: bitwise all-equal collapses, nothing else" begin
        c = [2.5, 2.5, 2.5, 2.5]
        @test ESM._oop_lane_bound(c) === 2.5              # scalar, not a column
        nn = [NaN, NaN, NaN]
        r = ESM._oop_lane_bound(nn)
        @test r isa Float64 && isnan(r)                   # NaN unifies (isequal)
        z = [0.0, -0.0, 0.0]
        @test ESM._oop_lane_bound(z) === z                # signed zeros stay split
        m = [1.0, 2.0, 1.0]
        @test ESM._oop_lane_bound(m) === m                # mixed column untouched
        one_lane = [7.0]
        @test ESM._oop_lane_bound(one_lane) === 7.0
        withenv("ESS_LANE_INTERN_DISABLE" => "1") do
            @test ESM._oop_lane_bound(c) === c            # kill switch: identity
        end
    end

    # ---- the branch-free lane evaluators: the TRACER's program, run on host
    # data by evaluating at a non-`Real` value type (`Number` is not `<: Real`,
    # so dispatch takes the generic branch-free methods — the ones a Reactant
    # trace executes — while every operand is an ordinary Float64 container).
    # Reference: the `T <: Real` host dispatch, which calls each lane's
    # ORIGINAL scalar core — the identity the merge is defined by.

    @testset "branch-free bilinear ≡ per-lane cores under the bound collapse" begin
        band(b) = ESM._InterpBilinearSpec(
            [Float64[b + 0.01j + 0.1i for j in 0:2] for i in 0:2],
            copy(_LTI_BAX), copy(_LTI_BAX))
        # 2 bands × 5 cells: shared axis content across all 10 lanes (the
        # collapse fires on all four bounds), tables differing per band.
        specs = ESM._InterpBilinearSpec[band(Float64(1 + (l - 1) ÷ 5)) for l in 1:10]
        h = ESM._InterpBilinearLaneSpec(specs, 1, 0, 0, 1)
        L = length(h.specs)
        # Sweep spans both clamps, every knot, interior blends, and NaN.
        xs = Float64[-0.7, 0.0, 0.31, 1.0, 1.62, 2.0, 2.9, NaN, 0.5, 1.99]
        ys = Float64[2.6, 2.0, 1.75, 1.0, 0.42, 0.0, -0.3, 0.25, NaN, 1.0]
        ref = ESM._oop_interp_bilinear_lanes(h, xs, ys, Float64)
        got = ESM._oop_interp_bilinear_lanes(h, xs, ys, Number)
        @test length(got) == L && all(got .=== ref)
        # Kill switch: the lane-wide-bound program computes the same bits.
        goff = withenv("ESS_LANE_INTERN_DISABLE" => "1") do
            ESM._oop_interp_bilinear_lanes(h, xs, ys, Number)
        end
        @test all(goff .=== ref)
        # Lane-INVARIANT scalar query: the collapsed bound must not collapse
        # the lane axis (the `Lq` trap) — the result keeps its L lanes, on
        # both clamp arms and in range.
        for yq in (-0.5, 1.25, 2.5)
            gs = ESM._oop_interp_bilinear_lanes(h, xs, yq, Number)
            rs = ESM._oop_interp_bilinear_lanes(h, xs, fill(yq, L), Float64)
            @test length(gs) == L && all(gs .=== rs)
        end
        # BOTH queries scalar — the maximally collapsed program still owes one
        # value per lane (tables differ per lane).
        gb = ESM._oop_interp_bilinear_lanes(h, 0.75, 1.25, Number)
        rb = ESM._oop_interp_bilinear_lanes(h, fill(0.75, L), fill(1.25, L), Float64)
        @test length(gb) == L && all(gb .=== rb)
    end

    @testset "branch-free linear ≡ per-lane cores under the edge collapse" begin
        # All 6 lanes share ONE content (axis AND table all-equal columns):
        # every one of the four edge reads collapses to a scalar — the
        # maximally collapsible case — while the result must keep 6 lanes.
        sp = ESM._InterpLinearSpec(copy(_LTI_TA), copy(_LTI_AX))
        h1 = ESM._InterpLinearLaneSpec(ESM._InterpLinearSpec[sp for _ in 1:6],
                                       1, 0, 0, 1)
        xs = Float64[-2.0, 0.0, 1.5, 3.99, 4.0, 6.3]
        @test all(ESM._oop_interp_linear_lanes(h1, xs, Number) .===
                  ESM._oop_interp_linear_lanes(h1, xs, Float64))
        g1 = ESM._oop_interp_linear_lanes(h1, 2.25, Number)
        @test length(g1) == 6
        @test all(g1 .=== ESM._oop_interp_linear_lanes(h1, fill(2.25, 6), Float64))
        # Mixed edge columns (a second content): bounds stay lane-wide, and
        # the program is still `===` the cores — clamp arms included.
        sp2 = ESM._InterpLinearSpec(copy(_LTI_TB), [0.5, 1.0, 2.0, 3.0, 3.5])
        h2 = ESM._InterpLinearLaneSpec(
            ESM._InterpLinearSpec[l <= 3 ? sp : sp2 for l in 1:6], 1, 0, 0, 1)
        xs2 = Float64[-2.0, 0.4, 5.0, 0.6, 3.6, NaN]
        @test all(ESM._oop_interp_linear_lanes(h2, xs2, Number) .===
                  ESM._oop_interp_linear_lanes(h2, xs2, Float64))
    end
end
