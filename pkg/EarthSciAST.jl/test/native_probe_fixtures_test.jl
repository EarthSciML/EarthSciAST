# Probe fixtures for native's emitter and lowering holes the corpus census does
# not reach (tests/fixtures/native_probes/, and two Julia-only documents under
# test/fixtures/, see below): each document must BUILD under
# `compiler = :native`, land on compile-once tiers only, and agree with
# `compiler = :interpreter` bit for bit (`===` per element, so a NaN or a -0.0
# counts), on the right-hand side and on its ForwardDiff Jacobian.
#
#   * rank5_stencil — an output box of rank 5 (the kernel's rank-N output
#     odometer, a box whose loop dims past the third are carried beside the
#     first three);
#   * rank4_contraction — a rank-4 output with a contraction, so the affine
#     tier's run-time fold loops a rank-5 box;
#   * fill_shared_invariant — a materialized observed's fill section carrying a
#     lane-invariant closed-function subtree that the state kernels share with
#     the scalar prelude (the shared-scratch read the fill section's emitter
#     does not take, `:foreign_scratch`): the state kernels read the shared
#     slot, and the fill level keeps its own copy in its own invariant tier;
#   * native_inline_const_subscript — inline `const` tables as index
#     subscripts: an enum-resolved (scalar `const`) subscript and a permutation
#     table inside a state subscript. It lives under test/fixtures/ rather than
#     tests/, because the Rust binding's compiled form has no array-valued
#     `const` yet, and every document under tests/ is in both bindings' native
#     census;
#   * native_neg_weight_gather — `-W[i] * u[P[i]]` with inline `const` tables
#     (also under test/fixtures/, for the same reason): the emitter shares
#     `-W[i]` as a per-cell recipe, which must keep its own `Float64` type
#     rather than become a dual number with zero partials, or every Jacobian
#     entry off the permutation turns from the reference's -0.0 into +0.0.
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")

const _NPF = EarthSciAST
const _NPF_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "fixtures", "native_probes")
_npf_path(f) = f in ("native_inline_const_subscript.esm", "native_neg_weight_gather.esm") ?
    joinpath(@__DIR__, "fixtures", f) : joinpath(_NPF_DIR, f)

function _npf_build(path, compiler)
    _NPF._reset_cascade_tally!()
    prob = _NPF.esm_problem(path, (0.0, 1.0); compiler = compiler)
    return prob, copy(_NPF._CASCADE_TALLY)
end

# A state off the initial one (no two elements equal), in `prob`'s layout.
_npf_state(prob) = Float64[prob.u0[i] + 0.3 + 0.01 * sin(1.7i) for i in eachindex(prob.u0)]

# `u` (in `from`'s layout) moved into `to`'s layout by state name.
function _npf_relayout(u, from, to)
    v = similar(to.u0)
    for (k, j) in to.var_map
        v[j] = u[from.var_map[k]]
    end
    return v
end

function _npf_du(prob, u)
    du = similar(u)
    fill!(du, NaN)
    prob.f!(du, u, prob.p, 0.4)
    return du
end

function _npf_agree(path)
    pn, tally = _npf_build(path, :native)
    pi_, _ = _npf_build(path, :interpreter)
    un = _npf_state(pn)
    ui = _npf_relayout(un, pn, pi_)
    dn, di = _npf_du(pn, un), _npf_du(pi_, ui)
    same = all(dn[pn.var_map[k]] === di[j] for (k, j) in pi_.var_map)
    Jn = ForwardDiff.jacobian((d, u) -> pn.f!(d, u, pn.p, 0.4), similar(un), un)
    Ji = ForwardDiff.jacobian((d, u) -> pi_.f!(d, u, pi_.p, 0.4), similar(ui), ui)
    jsame = all(isequal(Jn[pn.var_map[a], pn.var_map[b]], Ji[ia, ib])
                for (a, ia) in pi_.var_map for (b, ib) in pi_.var_map)
    tiers = Dict(_NPF.tier_histogram(_NPF.compiler_report(pn)))
    return (; same, jsame, tally, tiers, pn)
end

@testset "native probe fixtures" begin
    @testset "$(f)" for f in ("rank5_stencil.esm", "rank4_contraction.esm",
                              "fill_shared_invariant.esm",
                              "native_inline_const_subscript.esm",
                              "native_neg_weight_gather.esm")
        r = _npf_agree(_npf_path(f))
        @test r.same
        @test r.jsame
        # Compile-once tiers only: nothing scalarized per cell at build, and
        # nothing walked per cell on a call.
        @test isempty(setdiff(keys(r.tiers), (:affine, :scan, :array_contraction_codegen)))
        @test get(r.tally, :percell_acc, 0) == 0
        if f == "rank4_contraction.esm"
            @test get(r.tally, :affine_reduce, 0) == 1
        elseif f == "fill_shared_invariant.esm"
            # The fill equation is a rule of its own, and the state kernels'
            # shared-prelude reads were emitted.
            @test any(occursin("Fill.w", rr.rule) for rr in _NPF.compiler_report(r.pn).rules)
            @test get(r.tally, :cg_foreign_scratch_emit, 0) >= 1
        end
    end

    # The corpus's own categorical lookup (esm-spec §9.3): a const table read
    # at two enum-resolved subscripts, which both compilers used to reject.
    @testset "an enum-subscripted inline table (tests/valid)" begin
        r = _npf_agree(joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
                                "enums_categorical_lookup.esm"))
        @test r.same
        @test r.jsame
    end
end
