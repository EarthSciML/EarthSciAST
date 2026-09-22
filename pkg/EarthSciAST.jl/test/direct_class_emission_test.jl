# DIRECT CLASS EMISSION (acc_merge.jl `_direct_class_emit_enabled` /
# `_direct_merge_fn_payload`): the per-cell scalarizer emits lane-batched class
# kernels DIRECTLY — the grouping signature keys an interp spec's SHAPE instead
# of its content, and a group whose same-shape specs vary mints an
# `_Interp*LaneSpec` per-lane table at merge time — so the kernel count is
# grid-independent BY CONSTRUCTION, and the post-hoc kernel-class merge
# (oop_merge.jl) becomes a residual REPAIR pass with nothing to do on kernels
# this emitter produced.
#
# What must hold, and is asserted here:
#   1. THE GATE — the emitter runs under `:native` and stands down under
#      `:interpreter`, which turns the class merge off with it: a build with no
#      class merge must carry NO lane-batched class kernels of either
#      provenance. The shape-vs-content signature and the merge's own
#      spec-mismatch guard are pinned directly, below the build.
#   2. ZERO RESIDUAL MERGES — on the per-cell-path fixtures the direct build's
#      cascade tally shows the class kernel came from the EMITTER
#      (`:direct_class_kernel`) and the repair pass performed no merge
#      (`:classmerge_round1_merge` / `:classmerge_round2_merge` absent,
#      `n_classmerge_in == n_acc_kernels` — the emitter left the repair pass
#      nothing, which is the whole point of emitting directly).
#   3. BIT-IDENTITY — du is `===` per element (NaN/-0.0 count; never ≈)
#      against the per-cell scalar reference (`compiler=:interpreter`), across
#      interp lane classes (linear/bilinear/searchsorted), a guarded (ifelse)
#      class, with the kernels emitted AND left on the per-cell runner, and
#      under ForwardDiff Duals (Jacobian bit-compare).
#   4. THE INVARIANT TIER SURVIVES — a class whose interp query chain is
#      loop-INVARIANT keeps a REAL invariant tier under direct emission (CSE
#      runs after the merge, so only the lane-varying `:fn` node is pinned
#      cell-varying — `_acc_fn_pay_lane_varying`).
#   5. GRID INDEPENDENCE of the direct path, by the grid_invariance_test
#      methodology: at N=8 vs N=24 every structural diag counter, per-kernel
#      structural signature, and the cascade tally are IDENTICAL, and the
#      per-lane data (out slots + descriptor tables + lane-spec lane counts)
#      grows exactly 3x.
#
# The fixtures force the PER-CELL path (the scalarizer under test) with an
# aggregate whose contracted bound is expression-valued but constant
# (`k in 1:(i+2-i)` == `1:2` for every cell): syntactically non-const bounds
# decline the affine build, and the cascade tally pins `:percell_acc`.
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

# ---- fixtures ---------------------------------------------------------------

const _DCE_AX  = [0.0, 1.0, 2.0, 3.0]
const _DCE_TA  = [0.0, 10.0, 20.0, 30.0]
const _DCE_TB  = [0.0, -100.0, -200.0, -300.0]
const _DCE_BAX = [0.0, 1.0, 2.0]
const _DCE_BTA = Any[Any[1.0, 1.5, 2.0], Any[1.1, 1.6, 2.1], Any[1.2, 1.7, 2.2]]
const _DCE_BTB = Any[Any[-9.0, 3.0, -1.0], Any[2.5, -4.0, 0.5], Any[-0.25, 8.0, -6.0]]
const _DCE_SSA = [0.5, 1.5, 2.5, 3.5]
const _DCE_SSB = [1.0, 2.0, 2.0, 3.0]     # duplicates: the fiddly boundary case

_dce_constarr(v) = OpExpr("const", ESM.ASTExpr[]; value=v)
# Contracted bound `i+2-i`: evaluates to 2 for every cell but is syntactically
# expression-valued, so `_is_const_int_range` is false and the equation takes
# the per-cell path (`:percell_acc`) with a 2-term `_NK_CONTRACTION` per cell.
_dce_khi() = _op("-", _op("+", _v("i"), _i(2)), _v("i"))

# One equation over `u[1:N]` whose RHS body is `index(makearray(regions →
# vals), i) * k` summed over the pseudo-contracted k. Region 1 = cells
# 1:N÷2, region 2 = the rest — each region's `vals` entry carries its OWN
# interp table, the class-fragmentation source under content keying.
function _dce_percell_model(vals::Vector{ESM.ASTExpr}, N::Int)
    mk = OpExpr("makearray", ESM.ASTExpr[];
        regions=[[[1, N ÷ 2]], [[N ÷ 2 + 1, N]]], values=vals)
    lhs = OpExpr("faq", ESM.ASTExpr[]; output_idx=Any["i"],
        expr_body=_Didx("u", _v("i")), ranges=Dict("i" => [1, N]))
    rhs = OpExpr("faq", ESM.ASTExpr[]; output_idx=Any["i"],
        expr_body=_op("*", _op("index", mk, _v("i")), _v("k")),
        ranges=Dict("i" => [1, N], "k" => Any[_i(1), _dce_khi()]), reduce="+")
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.UnknownVariable),
        "g" => ESM.ModelVariable(ESM.ParameterVariable; default=3.0),
        "h" => ESM.ModelVariable(ESM.ParameterVariable; default=7.0))
    ESM.Model(vars, [ESM.Equation(lhs, rhs)])
end

_dce_linear(tbl)  = _op("fn", _dce_constarr(tbl), _dce_constarr(_DCE_AX),
                        _idx("u", _v("i")); name="interp.linear")
_dce_bilin(tbl)   = _op("fn", _dce_constarr(tbl), _dce_constarr(_DCE_BAX),
                        _dce_constarr(_DCE_BAX), _idx("u", _v("i")),
                        _idx("u", _v("i")); name="interp.bilinear")
_dce_search(xs)   = _op("fn", _idx("u", _v("i")), _dce_constarr(xs);
                        name="interp.searchsorted")
_dce_guarded(tbl) = _op("ifelse", _op(">", _idx("u", _v("i")), _n(1.0)),
                        _dce_linear(tbl), _n(-1.0))
# Loop-INVARIANT interp query (g/h): the invariant-tier fixture (§4 above).
_dce_invq(tbl) = _op("*", _op("fn", _dce_constarr(tbl), _dce_constarr(_DCE_AX),
                              _op("/", _v("g"), _v("h")); name="interp.linear"),
                     _idx("u", _v("i")))

_dce_model(mk, N) = _dce_percell_model(ESM.ASTExpr[mk(1), mk(2)], N)
_dce_linear_model(N) = _dce_model(r -> _dce_linear(r == 1 ? _DCE_TA : _DCE_TB), N)
_dce_bilinear_model(N) = _dce_model(r -> _dce_bilin(r == 1 ? _DCE_BTA : _DCE_BTB), N)
_dce_search_model(N) = _dce_model(r -> _dce_search(r == 1 ? _DCE_SSA : _DCE_SSB), N)
_dce_guard_model(N) = _dce_model(r -> _dce_guarded(r == 1 ? _DCE_TA : _DCE_TB), N)
_dce_inv_model(N) = _dce_model(r -> _dce_invq(r == 1 ? _DCE_TA : _DCE_TB), N)

# ICs / probe states inside every fixture's axis span ([0, 2] ⊂ all axes),
# straddling the guard threshold 1.0 so both branches are live.
_dce_ics(N) = Dict("u[$k]" => 0.4 + 1.5 * (k / N) for k in 1:N)
_dce_probe(n, k) = Float64[1.0 + 0.9 * sin(1.3i + 0.7k) for i in 1:n]

# ---- builders ---------------------------------------------------------------

# `compiler=:interpreter` is the per-cell scalar reference: no emitter, no
# class merge, no kernels at all. `codegen=false` puts the primary emission's
# node budget at zero — a retained tuning threshold — so the class kernels stay
# on `kernel_section.kernels` and can be introspected.
function _dce_build(model, ics; codegen::Bool=true, compiler::Symbol=:native)
    withenv("ESS_CODEGEN_NODE_BUDGET" => (codegen ? nothing : "0")) do
        ESM._reset_cascade_tally!()
        f, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics, compiler=compiler)
        (f=f, u0=u0, p=p, vm=vm, diag=diag, tally=copy(ESM._CASCADE_TALLY))
    end
end

_dce_du(f!, u, p, t) = (d = similar(u); fill!(d, 0.0); f!(d, u, p, t); d)
_dce_bitsame(a, b) = size(a) == size(b) && all(a .=== b)

# Does any `:fn` node reachable from K carry a per-lane spec? (Spines are DAGs
# post-CSE; the visited set keeps the walk linear.)
function _dce_has_lanespec(K)
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
    return any(_dce_has_lanespec, K.subs)
end

_dce_kernels(f!) = getfield(getfield(f!, :kernel_section), :kernels)

# ---- tests ------------------------------------------------------------------

@testset "direct class emission (per-cell scalarizer → class kernels)" begin

    @testset "the compiler gates the emitter (white-box)" begin
        @test ESM._direct_class_emit_enabled()
        # The interpreter turns the emitter off, and the class merge with it —
        # a build with no class merge must carry no lane-batched class kernel.
        ESM._with_compiler_plan(ESM._compiler_plan(:interpreter)) do
            @test !ESM._direct_class_emit_enabled()
            @test ESM._oop_merge_disabled()
        end

        # Signature: non-direct = byte-for-byte the content key (2-arg ≡
        # 3-arg false); direct = shape key (same-shape different-content
        # specs SHARE a signature that content keying splits).
        fnnode(tbl) = ESM._mknode(kind=ESM._NK_OP, op=:fn,
            payload=("interp.linear",
                     ESM._build_interp_spec("interp.linear", Any[tbl, _DCE_AX])),
            children=ESM._Node[ESM._mknode(kind=ESM._NK_STATE, idx=1)])
        sig(n, args...) = String(take!(ESM._struct_sig!(IOBuffer(), n, args...)))
        nA, nB = fnnode(_DCE_TA), fnnode(_DCE_TB)
        @test sig(nA) == sig(nA, false)          # 2-arg ≡ explicit false
        @test sig(nA, false) != sig(nB, false)   # content key splits
        @test sig(nA, true) == sig(nB, true)     # shape key shares

        # Merge: the 3-arg form keeps the loud spec-mismatch guard; the
        # direct (4-arg) form mints the per-lane spec table in cell order
        # with `_outs_cells` addressing.
        @test_throws ESM.TreeWalkError ESM._acc_merge_nodes(
            ESM._Node[nA, nB], 2, ESM._AccDesc[])
        merged = ESM._acc_merge_nodes(ESM._Node[nA, nB], 2, ESM._AccDesc[], true)
        @test merged.kind === ESM._NK_OP && merged.op === :fn
        h = merged.payload[2]
        @test h isa ESM._InterpLinearLaneSpec
        @test (h.s1, h.s2, h.s3, h.off) == (1, 0, 0, 1)
        @test [s.table for s in h.specs] == [_DCE_TA, _DCE_TB]
        # Content-equal specs still ride ONE scalar payload (no gratuitous
        # lane table), exactly the pre-direct behavior.
        merged_eq = ESM._acc_merge_nodes(ESM._Node[fnnode(_DCE_TA), fnnode(copy(_DCE_TA))],
                                         2, ESM._AccDesc[], true)
        @test merged_eq.payload[2] isa ESM._InterpLinearSpec
    end

    @testset "zero residual merges + tallies — $name" for (name, model) in (
            ("interp.linear", _dce_linear_model(6)),
            ("interp.bilinear", _dce_bilinear_model(6)),
            ("interp.searchsorted", _dce_search_model(6)),
            ("guarded interp.linear", _dce_guard_model(6)))
        ics = _dce_ics(6)
        rdef = _dce_build(model, ics; codegen=false)

        # The fixture really takes the per-cell path.
        @test get(rdef.tally, :percell_acc, 0) == 1
        @test get(rdef.tally, :affine, 0) == 0

        # DIRECT: one class kernel straight out of the emitter; the repair
        # pass found NOTHING to do (the zero-residual-merges pin).
        @test rdef.diag.n_acc_kernels == 1
        @test rdef.diag.n_classmerge_in == rdef.diag.n_acc_kernels
        @test get(rdef.tally, :direct_class_kernel, 0) == 1
        @test get(rdef.tally, :classmerge_round1_merge, 0) == 0
        @test get(rdef.tally, :classmerge_round2_merge, 0) == 0
        @test count(_dce_has_lanespec, _dce_kernels(rdef.f)) == 1

        # INTERPRETER: no class kernel of either provenance, and no access
        # kernel at all — the equation stays on the per-cell scalar walker.
        rref = _dce_build(model, ics; compiler=:interpreter)
        @test get(rref.tally, :direct_class_kernel, 0) == 0
        @test count(_dce_has_lanespec, _dce_kernels(rref.f)) == 0
    end

    @testset "bit-identity vs the scalar reference — $name" for
            (name, mkmodel) in (
            ("interp.linear", _dce_linear_model),
            ("interp.bilinear", _dce_bilinear_model),
            ("interp.searchsorted", _dce_search_model),
            ("guarded interp.linear", _dce_guard_model),
            ("invariant-query interp.linear", _dce_inv_model))
        N = 7                                     # odd: unequal region sizes
        model = mkmodel(N)
        ics = _dce_ics(N)
        rdef = _dce_build(model, ics)                       # direct + codegen
        rdefi = _dce_build(model, ics; codegen=false)       # direct, interpreted
        rref = _dce_build(model, ics; compiler=:interpreter) # per-cell scalar walk
        @test rdef.u0 == rref.u0
        for k in 1:4, t in (0.0, 0.7, 3.25)
            u = k == 1 ? copy(rdef.u0) : _dce_probe(N, k)
            dud = _dce_du(rdef.f, u, rdef.p, t)
            @test _dce_bitsame(dud, _dce_du(rdefi.f, u, rdefi.p, t))
            @test _dce_bitsame(dud, _dce_du(rref.f, u, rref.p, t))
        end

        # ForwardDiff Duals: values AND partials bit-identical through the
        # direct class kernel, emitted and interpreted.
        Jd = ForwardDiff.jacobian((du, u) -> rdef.f(du, u, rdef.p, 0.4),
                                  zero(rdef.u0), rdef.u0)
        Jr = ForwardDiff.jacobian((du, u) -> rref.f(du, u, rref.p, 0.4),
                                  zero(rref.u0), rref.u0)
        @test _dce_bitsame(Jd, Jr)
    end

    @testset "direct emission KEEPS a real invariant tier" begin
        # The class's `g/h` interp query chain is loop-invariant. Direct
        # emission runs `_build_acc_cse` AFTER the merge: only the lane-spec
        # `:fn` node is pinned cell-varying (`_acc_fn_pay_lane_varying`), so
        # the chain keeps a REAL inv slot, evaluated once per call rather than
        # once per lane. (A post-hoc merge cannot: its members' inv recipes
        # carry content-DIFFERENT specs, so `_oop_inv_nodes_identical` declines
        # and the whole tier folds into the cell tier. Same bits either way,
        # which is why the counter is what this pins.)
        N = 6
        ics = _dce_ics(N)
        rdef = _dce_build(_dce_inv_model(N), ics; codegen=false)
        rref = _dce_build(_dce_inv_model(N), ics; compiler=:interpreter)
        @test rdef.diag.n_acc_kernels == 1
        @test rdef.diag.n_acc_inv_slots >= 1     # kept by construction
        for t in (0.0, 0.42)
            @test _dce_bitsame(_dce_du(rdef.f, rdef.u0, rdef.p, t),
                               _dce_du(rref.f, rref.u0, rref.p, t))
        end
    end

    @testset "direct path is grid-independent (grid_invariance methodology)" begin
        N1, N2 = 8, 24
        A = _dce_build(_dce_linear_model(N1), _dce_ics(N1); codegen=false)
        B = _dce_build(_dce_linear_model(N2), _dce_ics(N2); codegen=false)

        # Structural counters: identical at 3x the grid (n_mat_array_cells is
        # the one documented O(cells) diag field; this fixture materializes
        # nothing, but mirror grid_invariance_test and drop it anyway).
        drop(d) = (; [k => getfield(d, k) for k in keys(d)
                      if k !== :n_mat_array_cells]...)
        @test drop(A.diag) == drop(B.diag)
        @test A.diag.n_acc_kernels == 1

        # Cascade tally identical — in particular ONE direct class kernel and
        # ZERO repair merges at BOTH sizes.
        @test A.tally == B.tally
        @test get(A.tally, :direct_class_kernel, 0) == 1
        @test get(A.tally, :classmerge_round1_merge, 0) == 0
        @test get(A.tally, :classmerge_round2_merge, 0) == 0

        # Per-kernel structural signature (spine/recipe shapes, descriptor
        # kinds, bound) identical; descriptor/lane VALUES excluded.
        shape!(out, nd) = (push!(out, (nd.kind, nd.op));
                           foreach(c -> shape!(out, c), nd.children); out)
        ksig(K) = repr((; shape = shape!(Tuple{UInt8,Symbol}[], K.spine),
                        acc_kinds = UInt8[d.kind for d in K.acc],
                        cell_recipes = [shape!(Tuple{UInt8,Symbol}[], r)
                                        for r in K.cse.recipes],
                        inv_recipes = [shape!(Tuple{UInt8,Symbol}[], r)
                                       for r in K.cse.inv_recipes],
                        n_subs = length(K.subs),
                        bound = nameof(typeof(K.bound))))
        @test sort!(map(ksig, _dce_kernels(A.f))) ==
              sort!(map(ksig, _dce_kernels(B.f)))

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
        dA, dB = data(_dce_kernels(A.f)), data(_dce_kernels(B.f))
        @test dA > 0
        @test dA * N2 == dB * N1
    end
end
