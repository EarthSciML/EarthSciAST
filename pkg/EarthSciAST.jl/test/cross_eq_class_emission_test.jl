# CROSS-EQUATION + AFFINE-BOX direct class emission (acc_merge.jl
# `_cross_eq_class_emit_enabled`; build.jl `pooled_cells`; oop_merge.jl
# `_merge_acc_kernel_classes` direct stage).
#
# Direct class emission (test/direct_class_emission_test.jl) made PER-EQUATION
# per-cell classes grid-independent by construction, but two class families
# still reached lane-batched form only through the post-hoc repair pass:
#
#   1. CROSS-EQUATION classes — identical-shape kernels arising in DIFFERENT
#      equations (twin species balances, per-band photolysis). The scalarizer
#      now POOLS every per-cell equation's cell entries and runs
#      `_acc_from_cell_entries` ONCE, above the equation loop, so those cells
#      share a class kernel straight out of the emitter.
#   2. AFFINE-BOX classes — kernels the affine stencil path assembles per box
#      (including the subterm-granular LANE_EXPRTBL per-box tables,
#      `:affine_subtree_tbl`). These have no per-cell scalar trees to pool
#      (the box compiler exists to never scalarize), so their emitter sits at
#      the assembled-kernel level: `_merge_acc_kernel_classes` runs its class
#      rounds as a DIRECT emission stage (`:direct_classmerge_round{1,2}_merge`
#      tallies) before the counted repair pass.
#
# What must hold, and is asserted here:
#   (a) CROSS-EQUATION: identical-shape per-cell kernels from different
#       equations become ONE class kernel with repair-pass tallies ZERO
#       (`:classmerge_round1_merge` / `:classmerge_round2_merge` == 0).
#   (b) AFFINE-BOX: the box/table kernel classes are emitted by the direct
#       stage (its own merge tallies are non-zero) and the repair pass finds
#       NOTHING left to do.
#   (c) GRID INDEPENDENCE: for a multi-equation fixture the kernel count,
#       every structural diag counter, and the cascade tally are identical at
#       N and 3N; per-lane data grows exactly 3x.
#   (d) BIT-IDENTITY: du is `===` per element (NaN/-0.0 count) against the
#       per-cell scalar reference (`compiler=:interpreter`) — kernels emitted
#       and left on the per-cell runner, and through ForwardDiff Duals.
#   (e) CORPUS: over tests/valid + tests/conformance the repair pass performs
#       NO merge anywhere — every class the corpus contains was emitted
#       directly.
#
# The per-cell fixtures force the per-cell path exactly as
# direct_class_emission_test does: an aggregate whose contracted bound is
# expression-valued but constant (`k in 1:(i+2-i)` == `1:2`), which declines
# the affine build (`:percell_acc` pinned).
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

# ---- fixtures ---------------------------------------------------------------

const _XQ_AX = [0.0, 1.0, 2.0, 3.0]
const _XQ_TA = [0.0, 10.0, 20.0, 30.0]
const _XQ_TB = [0.0, -100.0, -200.0, -300.0]

# Contracted bound `i+2-i`: evaluates to 2 for every cell but is syntactically
# expression-valued, so the equation takes the per-cell path (`:percell_acc`).
_xq_khi() = _op("-", _op("+", _v("i"), _i(2)), _v("i"))

function _xq_percell_eq(x::String, body, N::Int)
    lhs = ESM.OpExpr("faq", ESM.ASTExpr[]; output_idx=Any["i"],
        expr_body=_Didx(x, _v("i")), ranges=Dict("i" => [1, N]))
    rhs = ESM.OpExpr("faq", ESM.ASTExpr[]; output_idx=Any["i"],
        expr_body=body, ranges=Dict("i" => [1, N], "k" => Any[_i(1), _xq_khi()]),
        reduce="+")
    ESM.Equation(lhs, rhs)
end

# Twin per-cell INTERP equations: same shape (4-knot interp.linear), each
# equation against its OWN table — the cross-equation class-fragmentation
# source. Within one equation the spec is content-uniform, so the
# per-equation emitter alone mints NO lane table; only pooling across the
# equations (or the repair pass) can produce the class kernel.
function _xq_twin_interp_model(N)
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.UnknownVariable),
        "v" => ESM.ModelVariable(ESM.UnknownVariable))
    body(x, tbl) = _op("*",
        _op("fn", _const(tbl), _const(_XQ_AX), _idx(x, _v("i"));
            name="interp.linear"),
        _v("k"))
    ESM.Model(vars, [_xq_percell_eq("u", body("u", _XQ_TA), N),
                     _xq_percell_eq("v", body("v", _XQ_TB), N)])
end

# Twin per-cell PLAIN equations (no interp): the cross-equation class is pure
# state-slot variation — the merged kernel carries state tables, no lane spec.
function _xq_twin_plain_model(N)
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.UnknownVariable),
        "v" => ESM.ModelVariable(ESM.UnknownVariable))
    body(x) = _op("*", _op("*", _n(-0.5), _idx(x, _v("i"))), _v("k"))
    ESM.Model(vars, [_xq_percell_eq("u", body("u"), N),
                     _xq_percell_eq("v", body("v"), N)])
end

# Twin AFFINE-BOX equations: a Laplacian stencil (interior + boundary boxes)
# plus a nested const reduction Σ_{k=1..3} W[i,k]·k that the stencil
# vocabulary cannot model — the subtree-table rescue (LANE_EXPRTBL,
# `:affine_subtree_tbl`) materializes it as per-box value tables. Two states
# ⇒ box-kernel classes across equations AND across ghost patterns.
function _xq_afbox_model(N)
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.UnknownVariable),
        "v" => ESM.ModelVariable(ESM.UnknownVariable))
    lap(x) = _op("+", _idx(x, _op("-", _v("i"), _i(1))),
                      _op("*", _n(-2.0), _idx(x, _v("i"))),
                      _idx(x, _op("+", _v("i"), _i(1))))
    term = _op("*", _idx("W", _v("i"), _v("k")), _v("k"))
    agg() = ESM.OpExpr("faq", ESM.ASTExpr[]; expr_body=term,
        ranges=Dict{String,Any}("k" => Any[1, 3]), reduce="+")
    mkeq(x) = ESM.Equation(_ao1(_Didx(x, _v("i")), "i", 1, N),
                           _ao1(_op("+", lap(x), agg()), "i", 1, N))
    ESM.Model(vars, [mkeq("u"), mkeq("v")])
end
_xq_W(N) = Float64[sin(1.7i * k) + 0.05i for i in 1:N, k in 1:3]

_xq_ics(N) = merge(Dict("u[$k]" => 0.4 + 1.5 * (k / N) for k in 1:N),
                   Dict("v[$k]" => 0.9 + 1.1 * ((N - k) / N) for k in 1:N))
_xq_probe(n, k) = Float64[1.0 + 0.9 * sin(1.3i + 0.7k) for i in 1:n]

# ---- builders ---------------------------------------------------------------

# `compiler=:interpreter` is the per-cell scalar reference: no pooled emitter,
# no class merge, no kernels at all. `codegen=false` puts the primary
# emission's node budget at zero — a retained tuning threshold — so the class
# kernels stay on `kernel_section.kernels` and can be introspected.
function _xq_build(model, ics; codegen::Bool=true, compiler::Symbol=:native,
                   const_arrays=Dict{String,Any}())
    withenv("ESS_CODEGEN_NODE_BUDGET" => (codegen ? nothing : "0")) do
        ESM._reset_cascade_tally!()
        f, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics, const_arrays=const_arrays,
            compiler=compiler)
        (f=f, u0=u0, p=p, vm=vm, diag=diag, tally=copy(ESM._CASCADE_TALLY))
    end
end

_xq_du(f!, u, p, t) = (d = similar(u); fill!(d, 0.0); f!(d, u, p, t); d)
_xq_bitsame(a, b) = size(a) == size(b) && all(a .=== b)
_xq_repair(t) = get(t, :classmerge_round1_merge, 0) +
                get(t, :classmerge_round2_merge, 0)
_xq_directmerge(t) = get(t, :direct_classmerge_round1_merge, 0) +
                     get(t, :direct_classmerge_round2_merge, 0)

# Does any `:fn` node reachable from K carry a per-lane spec?
function _xq_has_lanespec(K)
    seen = IdDict{Any,Nothing}()
    visit(nd) = begin
        haskey(seen, nd) && return false
        seen[nd] = nothing
        if nd.kind === ESM._NK_OP && nd.op === :fn
            pl = nd.payload
            pl isa Tuple && length(pl) >= 2 && ESM._direct_is_lanespec(pl[2]) &&
                return true
        end
        any(visit, nd.children)
    end
    visit(K.spine) && return true
    any(visit, K.cse.recipes) && return true
    any(visit, K.cse.inv_recipes) && return true
    return any(_xq_has_lanespec, K.subs)
end
_xq_kernels(f!) = getfield(getfield(f!, :kernel_section), :kernels)

# ---- tests ------------------------------------------------------------------

@testset "cross-equation + affine-box direct class emission" begin

    @testset "the compiler gates the stage (white-box)" begin
        @test ESM._cross_eq_class_emit_enabled()
        # The interpreter stands the whole class-emission chain down at once:
        # this stage, the per-equation emitter beneath it, and the class merge.
        ESM._with_compiler_plan(ESM._compiler_plan(:interpreter)) do
            @test !ESM._cross_eq_class_emit_enabled()
            @test !ESM._direct_class_emit_enabled()
            @test ESM._oop_merge_disabled()
        end
    end

    @testset "(a) cross-equation classes: one kernel, zero repair — $name" for
            (name, mkmodel, want_lanespec) in (
            ("interp twins", _xq_twin_interp_model, true),
            ("plain twins", _xq_twin_plain_model, false))
        N = 6
        model = mkmodel(N)
        ics = _xq_ics(N)
        ron  = _xq_build(model, ics; codegen=false)                 # everything on
        rref = _xq_build(model, ics; compiler=:interpreter)         # the reference

        # The fixture really takes the per-cell path, once per equation. Under
        # `:native` those cells merge into access kernels (`:percell_acc`);
        # under `:interpreter` they stay plain scalar nodes
        # (`:percell_disabled`), which is the reference this file compares to.
        @test get(ron.tally, :percell_acc, 0) == 2
        @test get(rref.tally, :percell_disabled, 0) == 2
        for r in (ron, rref)
            @test get(r.tally, :affine, 0) == 0
        end

        # ON: the pooled scalarizer emitted ONE class kernel across both
        # equations; neither the direct kernel stage nor the repair pass had
        # anything left to do.
        @test ron.diag.n_acc_kernels == 1
        @test ron.diag.n_classmerge_in == ron.diag.n_acc_kernels
        @test _xq_repair(ron.tally) == 0
        @test _xq_directmerge(ron.tally) == 0
        @test get(ron.tally, :direct_class_kernel, 0) == (want_lanespec ? 1 : 0)
        @test count(_xq_has_lanespec, _xq_kernels(ron.f)) == (want_lanespec ? 1 : 0)

        # INTERPRETER: no class kernel of any provenance, and no merge.
        @test get(rref.tally, :direct_class_kernel, 0) == 0
        @test _xq_repair(rref.tally) == 0
        @test _xq_directmerge(rref.tally) == 0
        @test count(_xq_has_lanespec, _xq_kernels(rref.f)) == 0
    end

    @testset "(b) affine-box classes: direct stage emits, repair finds nothing" begin
        N = 8
        model = _xq_afbox_model(N)
        ics = _xq_ics(N)
        ca = Dict{String,Any}("W" => _xq_W(N))
        ron  = _xq_build(model, ics; codegen=false, const_arrays=ca)

        # The affine path owned both equations, and the subtree-table rescue
        # fired (the LANE_EXPRTBL per-box tables are really in play).
        @test get(ron.tally, :affine, 0) == 2
        @test get(ron.tally, :percell_acc, 0) == 0
        @test get(ron.tally, :affine_subtree_tbl, 0) >= 1

        # The assembled-kernel classes are emitted by the DIRECT stage, and
        # the repair pass that follows it found NOTHING: every merge in this
        # build is on a `direct_classmerge_*` key.
        @test _xq_repair(ron.tally) == 0
        @test _xq_directmerge(ron.tally) >= 1

        # The merge really shrank the list it was handed.
        @test ron.diag.n_acc_kernels < ron.diag.n_classmerge_in
    end

    @testset "(d) bit-identity vs the scalar reference — $name" for (name, mk) in (
            ("interp twins", N -> (_xq_twin_interp_model(N), Dict{String,Any}())),
            ("plain twins", N -> (_xq_twin_plain_model(N), Dict{String,Any}())),
            ("affine-box twins", N -> (_xq_afbox_model(N), Dict{String,Any}("W" => _xq_W(N)))))
        N = 7                                     # odd: asymmetric probes
        model, consts = mk(N)
        ics = _xq_ics(N)
        ron   = _xq_build(model, ics; const_arrays=consts)              # + codegen
        roni  = _xq_build(model, ics; const_arrays=consts, codegen=false)
        rref  = _xq_build(model, ics; const_arrays=consts, compiler=:interpreter)
        @test ron.u0 == roni.u0 == rref.u0
        for k in 1:3, t in (0.0, 0.7, 3.25)
            u = k == 1 ? copy(ron.u0) : _xq_probe(2N, k)
            dud = _xq_du(ron.f, u, ron.p, t)
            @test _xq_bitsame(dud, _xq_du(roni.f, u, roni.p, t))
            @test _xq_bitsame(dud, _xq_du(rref.f, u, rref.p, t))
        end

        # ForwardDiff Duals: values AND partials bit-identical through the
        # cross-equation / affine-box class kernels.
        Jn = ForwardDiff.jacobian((du, u) -> ron.f(du, u, ron.p, 0.4),
                                  zero(ron.u0), ron.u0)
        Jr = ForwardDiff.jacobian((du, u) -> rref.f(du, u, rref.p, 0.4),
                                  zero(rref.u0), rref.u0)
        @test _xq_bitsame(Jn, Jr)
    end

    @testset "(c) grid independence of the pooled emitter" begin
        N1, N2 = 8, 24
        A = _xq_build(_xq_twin_interp_model(N1), _xq_ics(N1); codegen=false)
        B = _xq_build(_xq_twin_interp_model(N2), _xq_ics(N2); codegen=false)

        # Structural counters identical at 3x the grid (mirror
        # grid_invariance_test: drop the one documented O(cells) field).
        drop(d) = (; [k => getfield(d, k) for k in keys(d)
                      if k !== :n_mat_array_cells]...)
        @test drop(A.diag) == drop(B.diag)
        @test A.diag.n_acc_kernels == 1

        # Cascade tally identical — in particular zero repair AND zero
        # direct-stage merges at both sizes (the pooled scalarizer emitted the
        # class outright), with the lane-spec kernel counted once.
        @test A.tally == B.tally
        @test _xq_repair(A.tally) == 0
        @test _xq_directmerge(A.tally) == 0
        @test get(A.tally, :direct_class_kernel, 0) == 1

        # Per-lane data — out slots + descriptor tables + lane-spec lane
        # counts — grows EXACTLY linearly (3x cells ⇒ 3x data).
        function lanes(K)
            n = Ref(0)
            seen = IdDict{Any,Nothing}()
            visit(nd) = begin
                haskey(seen, nd) && return
                seen[nd] = nothing
                if nd.kind === ESM._NK_OP && nd.op === :fn
                    pl = nd.payload
                    pl isa Tuple && length(pl) >= 2 &&
                        ESM._direct_is_lanespec(pl[2]) &&
                        (n[] += length(pl[2].specs))
                end
                foreach(visit, nd.children)
            end
            visit(K.spine)
            foreach(visit, K.cse.recipes)
            foreach(visit, K.cse.inv_recipes)
            return n[]
        end
        data(ks) = sum(length(K.cells.outs) + lanes(K) +
                       sum(length(d.arr) + length(d.conn) for d in K.acc; init=0)
                       for K in ks; init=0)
        dA, dB = data(_xq_kernels(A.f)), data(_xq_kernels(B.f))
        @test dA > 0
        @test dA * N2 == dB * N1
    end

    # ---- (e) repo fixture sweep: the repair pass finds nothing anywhere ----
    # Every .esm under tests/valid and tests/conformance that builds through
    # the tree-walk evaluator is built once and its cascade tally read. Models
    # that cannot build standalone (MTK-only surfaces, providers, missing
    # data) are skipped. Cross-COMPILER agreement over this corpus is the
    # conformance tier's job, not this file's; what this sweep owns is the
    # claim no fixture can make on its own — that across the whole corpus the
    # repair pass performs no merge, because every class was emitted directly.
    @testset "(e) fixture-corpus zero repair tallies" begin
        roots = [joinpath(TESTUTILS_REPO_ROOT, "tests", "valid"),
                 joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance")]
        esms = String[]
        for r in roots
            isdir(r) || continue
            for (dir, _dirs, files) in walkdir(r), f in files
                endswith(f, ".esm") && push!(esms, joinpath(dir, f))
            end
        end
        sort!(esms)
        @test length(esms) >= 100

        function corpus_build(file, name)
            withenv("ESS_CODEGEN_NODE_BUDGET" => "0") do
                ESM._reset_cascade_tally!()
                try
                    f!, u0, p, _t, _vm = ESM._build_evaluator(file; model_name=name)
                    return (f=f!, u0=u0, p=p, tally=copy(ESM._CASCADE_TALLY))
                catch e
                    corpus_is_resource_error(e) && rethrow()
                    return nothing
                end
            end
        end

        built = 0
        skipped = 0
        repair_total = 0
        direct_total = 0
        for path in esms
            file = try
                ESM.load_path(path)
            catch e
                corpus_is_resource_error(e) && rethrow()
                skipped += 1
                continue
            end
            file.models === nothing && (skipped += 1; continue)
            for name in sort!(collect(String.(keys(file.models))))
                ron = corpus_build(file, name)
                if ron === nothing
                    skipped += 1
                    continue
                end
                built += 1
                repair_total += _xq_repair(ron.tally)
                direct_total += _xq_directmerge(ron.tally)
            end
        end
        # The sweep is real (a corpus regression that stops fixtures building
        # would otherwise pass this vacuously) …
        @test built >= 40
        # … and on the whole corpus the repair pass had NOTHING to do: every
        # class was emitted directly (scalarizer pool, per-equation emitter,
        # or the assembled-kernel direct stage).
        @test repair_total == 0
    end
end
