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
#       stage (its tallies carry exactly the merges the repair pass performed
#       under the kill switch) and the repair pass finds NOTHING.
#   (c) GRID INDEPENDENCE: for a multi-equation fixture the kernel count,
#       every structural diag counter, and the cascade tally are identical at
#       N and 3N; per-lane data grows exactly 3x.
#   (d) BIT-IDENTITY: du is `===` per element (NaN/-0.0 count) against the
#       kill-switch oracle (ESS_CROSS_EQ_CLASS_EMIT_DISABLE=1), the
#       per-equation-emitter-only oracle (ESS_DIRECT_CLASS_EMIT_DISABLE=1),
#       the fully split build (ESS_KERNEL_CLASS_MERGE_DISABLE=1), and the
#       per-cell scalar reference (ESS_STENCIL_DISABLE=1) — both emitters,
#       codegen on and off, and through ForwardDiff Duals — plus a sweep of
#       the repo fixture corpus (tests/valid + tests/conformance).
#   (e) COMPAT: under each disable switch the system behaves exactly as
#       before this landed (per-equation emission + repair-only merging).
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
    lhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"],
        expr_body=_Didx(x, _v("i")), ranges=Dict("i" => [1, N]))
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"],
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
    agg() = ESM.OpExpr("aggregate", ESM.ASTExpr[]; expr_body=term,
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

# `crosseq=false` → ESS_CROSS_EQ_CLASS_EMIT_DISABLE=1 (per-equation emission +
# repair-only merging — the kill-switch oracle). `direct=false` →
# ESS_DIRECT_CLASS_EMIT_DISABLE=1 (content-keyed assemble-then-merge; stands
# the cross-eq stage down too). `merge=false` → the umbrella switch (fully
# split, no class kernels of any provenance). `stencil=false` → the per-cell
# scalar reference.
function _xq_build(model, ics; crosseq::Bool=true, direct::Bool=true,
                   merge::Bool=true, codegen::Bool=true, stencil::Bool=true,
                   form::Symbol=:inplace, const_arrays=Dict{String,Any}())
    withenv("ESS_CROSS_EQ_CLASS_EMIT_DISABLE" => (crosseq ? nothing : "1"),
            "ESS_DIRECT_CLASS_EMIT_DISABLE" => (direct ? nothing : "1"),
            "ESS_KERNEL_CLASS_MERGE_DISABLE" => (merge ? nothing : "1"),
            "ESS_CODEGEN_DISABLE" => (codegen ? nothing : "1"),
            "ESS_STENCIL_DISABLE" => (stencil ? nothing : "1")) do
        ESM._reset_cascade_tally!()
        f, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics, form=form, const_arrays=const_arrays)
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

    @testset "kill switches gate the stage (white-box)" begin
        @test ESM._cross_eq_class_emit_enabled()
        withenv("ESS_CROSS_EQ_CLASS_EMIT_DISABLE" => "1") do
            @test !ESM._cross_eq_class_emit_enabled()
        end
        # Standing down the per-equation emitter (or any class-merge umbrella
        # switch) stands the cross-eq stage down too — a build with direct
        # emission off must behave exactly as before this landed.
        withenv("ESS_DIRECT_CLASS_EMIT_DISABLE" => "1") do
            @test !ESM._cross_eq_class_emit_enabled()
        end
        withenv("ESS_KERNEL_CLASS_MERGE_DISABLE" => "1") do
            @test !ESM._cross_eq_class_emit_enabled()
        end
        withenv("ESS_OOP_MERGE_DISABLE" => "1") do
            @test !ESM._cross_eq_class_emit_enabled()
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
        roff = _xq_build(model, ics; crosseq=false, codegen=false)  # kill switch
        rdo  = _xq_build(model, ics; direct=false, codegen=false)   # pre-direct oracle
        rspl = _xq_build(model, ics; merge=false, codegen=false)    # fully split

        # Every setting really takes the per-cell path, once per equation.
        for r in (ron, roff, rdo, rspl)
            @test get(r.tally, :percell_acc, 0) == 2
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

        # KILL SWITCH: per-equation emission splits per equation
        # (n_classmerge_in == 2) and only the REPAIR pass gets back to one
        # kernel — exactly the pre-change pipeline.
        @test roff.diag.n_acc_kernels == 1
        @test roff.diag.n_classmerge_in == 2
        @test _xq_repair(roff.tally) >= 1
        @test _xq_directmerge(roff.tally) == 0

        # DIRECT OFF: the cross-eq stage stands down with it — identical
        # posture to the kill switch (content-keyed per-equation compile,
        # repair-only merging).
        @test rdo.diag.n_acc_kernels == 1
        @test rdo.diag.n_classmerge_in == 2
        @test _xq_repair(rdo.tally) >= 1
        @test _xq_directmerge(rdo.tally) == 0
        @test get(rdo.tally, :direct_class_kernel, 0) == 0

        # MERGE OFF: fully split — one kernel per equation, no lane-batched
        # class kernel of any provenance.
        @test rspl.diag.n_acc_kernels == 2
        @test _xq_repair(rspl.tally) == 0
        @test _xq_directmerge(rspl.tally) == 0
        @test count(_xq_has_lanespec, _xq_kernels(rspl.f)) == 0
    end

    @testset "(b) affine-box classes: direct stage emits, repair finds nothing" begin
        N = 8
        model = _xq_afbox_model(N)
        ics = _xq_ics(N)
        ca = Dict{String,Any}("W" => _xq_W(N))
        ron  = _xq_build(model, ics; codegen=false, const_arrays=ca)
        roff = _xq_build(model, ics; crosseq=false, codegen=false, const_arrays=ca)
        rspl = _xq_build(model, ics; merge=false, codegen=false, const_arrays=ca)

        # The affine path owned both equations, and the subtree-table rescue
        # fired (the LANE_EXPRTBL per-box tables are really in play).
        for r in (ron, roff, rspl)
            @test get(r.tally, :affine, 0) == 2
            @test get(r.tally, :percell_acc, 0) == 0
            @test get(r.tally, :affine_subtree_tbl, 0) >= 1
        end

        # ON: the assembled-kernel classes are emitted by the DIRECT stage —
        # it performed exactly the merges the repair pass performs under the
        # kill switch (the work MOVED, tally for tally) — and the repair pass
        # found NOTHING.
        @test _xq_repair(ron.tally) == 0
        @test _xq_directmerge(ron.tally) >= 1
        @test get(ron.tally, :direct_classmerge_round1_merge, 0) ==
              get(roff.tally, :classmerge_round1_merge, 0)
        @test get(ron.tally, :direct_classmerge_round2_merge, 0) ==
              get(roff.tally, :classmerge_round2_merge, 0)
        @test _xq_directmerge(roff.tally) == 0

        # Same final kernel list size either way; both smaller than unmerged.
        @test ron.diag.n_acc_kernels == roff.diag.n_acc_kernels
        @test ron.diag.n_classmerge_in == roff.diag.n_classmerge_in ==
              rspl.diag.n_acc_kernels
        @test ron.diag.n_acc_kernels < rspl.diag.n_acc_kernels
    end

    @testset "(d) bit-identity vs all oracles — $name" for (name, mk) in (
            ("interp twins", N -> (_xq_twin_interp_model(N), Dict{String,Any}())),
            ("plain twins", N -> (_xq_twin_plain_model(N), Dict{String,Any}())),
            ("affine-box twins", N -> (_xq_afbox_model(N), Dict{String,Any}("W" => _xq_W(N)))))
        N = 7                                     # odd: asymmetric probes
        model, consts = mk(N)
        ics = _xq_ics(N)
        ron   = _xq_build(model, ics; const_arrays=consts)              # + codegen
        roni  = _xq_build(model, ics; const_arrays=consts, codegen=false)
        roff  = _xq_build(model, ics; const_arrays=consts, crosseq=false)
        rdo   = _xq_build(model, ics; const_arrays=consts, direct=false)
        rspl  = _xq_build(model, ics; const_arrays=consts, merge=false)
        rref  = _xq_build(model, ics; const_arrays=consts, stencil=false)
        @test ron.u0 == roni.u0 == roff.u0 == rdo.u0 == rspl.u0 == rref.u0
        for k in 1:3, t in (0.0, 0.7, 3.25)
            u = k == 1 ? copy(ron.u0) : _xq_probe(2N, k)
            dud = _xq_du(ron.f, u, ron.p, t)
            @test _xq_bitsame(dud, _xq_du(roni.f, u, roni.p, t))
            @test _xq_bitsame(dud, _xq_du(roff.f, u, roff.p, t))
            @test _xq_bitsame(dud, _xq_du(rdo.f, u, rdo.p, t))
            @test _xq_bitsame(dud, _xq_du(rspl.f, u, rspl.p, t))
            @test _xq_bitsame(dud, _xq_du(rref.f, u, rref.p, t))
        end

        # :oop emitter, same identities (+ ≡ the in-place values).
        odef = _xq_build(model, ics; const_arrays=consts, form=:oop)
        ooff = _xq_build(model, ics; const_arrays=consts, crosseq=false, form=:oop)
        ospl = _xq_build(model, ics; const_arrays=consts, merge=false, form=:oop)
        for k in 1:2, t in (0.0, 0.7)
            u = k == 1 ? copy(odef.u0) : _xq_probe(2N, k)
            duo = odef.f(u, odef.p, t)
            @test _xq_bitsame(duo, ooff.f(u, ooff.p, t))
            @test _xq_bitsame(duo, ospl.f(u, ospl.p, t))
            @test _xq_bitsame(duo, _xq_du(ron.f, u, ron.p, t))
        end

        # ForwardDiff Duals: values AND partials bit-identical through the
        # cross-equation / affine-box class kernels.
        Jn = ForwardDiff.jacobian((du, u) -> ron.f(du, u, ron.p, 0.4),
                                  zero(ron.u0), ron.u0)
        Jo = ForwardDiff.jacobian((du, u) -> roff.f(du, u, roff.p, 0.4),
                                  zero(roff.u0), roff.u0)
        Js = ForwardDiff.jacobian((du, u) -> rspl.f(du, u, rspl.p, 0.4),
                                  zero(rspl.u0), rspl.u0)
        @test _xq_bitsame(Jn, Jo)
        @test _xq_bitsame(Jn, Js)
        # The :oop emitter compares against ITS OWN kill-switch oracles.
        # (Deliberately NOT against the in-place Jacobian: the two emitters'
        # Dual partial accumulation differs by `-0.0` vs `0.0` signed zeros on
        # some fixtures — a pre-existing cross-emitter artifact, identical
        # with the stage on and off, and not this change's to pin.)
        Joop  = ForwardDiff.jacobian(u -> odef.f(u, odef.p, 0.4), odef.u0)
        Joopo = ForwardDiff.jacobian(u -> ooff.f(u, ooff.p, 0.4), ooff.u0)
        Joops = ForwardDiff.jacobian(u -> ospl.f(u, ospl.p, 0.4), ospl.u0)
        @test _xq_bitsame(Joop, Joopo)
        @test _xq_bitsame(Joop, Joops)
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

    # ---- (d, corpus) repo fixture sweep: bit-identity + zero repair ---------
    # Every .esm under tests/valid and tests/conformance that builds through
    # the tree-walk evaluator is built with the stage ON and with the kill
    # switch, and the two RHS evaluations must agree === per element. Models
    # that cannot build standalone (MTK-only surfaces, providers, missing
    # data) are skipped SYMMETRICALLY — an asymmetric build/eval failure is a
    # test failure, since the switch may not change what builds.
    @testset "(d) fixture-corpus differential + zero repair tallies" begin
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

        function corpus_build(file, name; crosseq::Bool)
            withenv("ESS_CROSS_EQ_CLASS_EMIT_DISABLE" => (crosseq ? nothing : "1"),
                    "ESS_CODEGEN_DISABLE" => "1") do
                ESM._reset_cascade_tally!()
                try
                    f!, u0, p, _t, _vm = ESM.build_evaluator(file; model_name=name)
                    return (f=f!, u0=u0, p=p, tally=copy(ESM._CASCADE_TALLY))
                catch
                    return nothing
                end
            end
        end
        function du_or_nothing(f!, u0, p, t)
            du = zeros(length(u0))
            try
                f!(du, u0, p, t)
            catch
                return nothing
            end
            return du
        end

        built = 0
        skipped = 0
        repair_total = 0
        direct_total = 0
        for path in esms
            file = try
                ESM.load_path(path)
            catch
                skipped += 1
                continue
            end
            file.models === nothing && (skipped += 1; continue)
            for name in sort!(collect(String.(keys(file.models))))
                ron = corpus_build(file, name; crosseq=true)
                rof = corpus_build(file, name; crosseq=false)
                # The switch must not change WHAT builds.
                @test (ron === nothing) == (rof === nothing)
                if ron === nothing || rof === nothing
                    skipped += 1
                    continue
                end
                built += 1
                @test _xq_bitsame(ron.u0, rof.u0)
                repair_total += _xq_repair(ron.tally)
                direct_total += _xq_directmerge(ron.tally)
                for t in (0.0, 0.7)
                    a = du_or_nothing(ron.f, ron.u0, ron.p, t)
                    b = du_or_nothing(rof.f, rof.u0, rof.p, t)
                    # The switch must not change WHAT evaluates, either.
                    @test (a === nothing) == (b === nothing)
                    (a === nothing || b === nothing) && continue
                    @test _xq_bitsame(a, b)
                end
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
