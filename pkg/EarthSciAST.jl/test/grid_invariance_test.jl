# GRID-INDEPENDENCE of the compiled IR (build-level pin). The document is O(1)
# in the grid; the IR must be too. An affine-stencilizable model compiles to a
# FIXED set of access kernels — interior box + boundary regions, a contraction
# kernel, the scalar prelude — whose STRUCTURE (kernel count, per-kernel spine
# node counts and shapes, descriptor-table widths, CSE recipe counts, scalar
# rhs entries, prelude slot counts, the cascade classification tally) is a
# fact of the DOCUMENT, not of the grid. Only per-lane DATA may grow with N —
# out-slot/lane tables, materialized-buffer cells, the covered-cell totals —
# and those at most LINEARLY.
#
# Pinned by building ONE model at two grid sizes (N=8 vs N=24, a 3x step; the
# stencil boundary decomposition needs a minimum extent of ~6 per axis) and
# asserting:
#   * every diag counter except the buffer-cell count `n_mat_array_cells` is
#     IDENTICAL — including the hard-zero `_VecNode`-overlay fields;
#   * the residual kernel lists (introspected via `kernel_section.kernels`
#     under ESS_CODEGEN_DISABLE=1, where nothing is emitted and the list is
#     complete — the oop_merge/xcse idiom) have EQUAL per-kernel structural
#     signatures: spine (kind, op) preorder, spine/recipe node counts,
#     descriptor count + kinds, sub-kernel count, bound type. Descriptor
#     VALUES (a boundary wrap delta embeds N) are deliberately excluded;
#   * the always-on `_CASCADE_TALLY` is identical at both sizes, and both
#     array equations landed on `:affine` — a size-dependent fallback to
#     `:percell_acc` would silently trade O(1) IR for O(N);
#   * the per-lane data total (covered cells + descriptor arr/conn tables)
#     grows EXACTLY linearly (3x cells at 3x grid).
#
# The model exercises the three structural tiers at once: an affine stencil
# with ghost-boundary regions (g/h loop-invariant → an inv slot), a constant-
# bound column contraction (fixed depth K=3 — a physical column has a fixed
# level count; the GRID axis is i), and a scalar observed chain (rate → flux,
# two named prelude slots) feeding a scalar state equation.
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

# D(u[i]) = (g/h)·(u[i-1] − 2u[i] + u[i+1])      — stencil, boundary regions
# D(y[i]) = Σ_{k=1:3} u[i]·k                     — constant-bound contraction
# rate = g·h;  flux = rate + sin(rate)           — scalar observed chain
# D(x)  = −flux·x                                — scalar rhs entry
function _gi_model(N)
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.UnknownVariable),
        "y" => ESM.ModelVariable(ESM.UnknownVariable),
        "x" => ESM.ModelVariable(ESM.UnknownVariable; default=1.0),
        "g" => ESM.ModelVariable(ESM.ParameterVariable; default=3.0),
        "h" => ESM.ModelVariable(ESM.ParameterVariable; default=7.0),
        # esm 1.0.0 §6.3: `rate` / `flux` are `unknown`s DEFINED by the
        # bare-variable-LHS equations below; there is no `observed` type.
        "rate" => ESM.ModelVariable(ESM.UnknownVariable),
        "flux" => ESM.ModelVariable(ESM.UnknownVariable))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    stencil = _op("*", _op("/", _v("g"), _v("h")), lap)
    colsum = ESM.OpExpr("arrayop", ESM.ASTExpr[];
        output_idx=Any["i"], expr_body=_op("*", _idx("u", _v("i")), _v("k")),
        ranges=Dict("i" => [1, N], "k" => [1, 3]), reduce="+")
    ESM.Model(vars, [
        ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(stencil, "i", 1, N)),
        ESM.Equation(_ao1(_Didx("y", _v("i")), "i", 1, N), colsum),
        ESM.Equation(_v("rate"), _op("*", _v("g"), _v("h"))),
        ESM.Equation(_v("flux"), _op("+", _v("rate"), _op("sin", _v("rate")))),
        ESM.Equation(_D("x"), _op("*", _op("neg", _v("flux")), _v("x")))])
end

# Build under ESS_CODEGEN_DISABLE=1 so `kernel_section.kernels` holds EVERY
# kernel (n_emitted == 0, asserted below) — the codegen tier only relocates
# runners, never changes the kernel IR under it. Tally reset/copy brackets the
# build, the scan_prefix idiom.
function _gi_build(N)
    ics = Dict{String,Float64}("x" => 1.0)
    for k in 1:N
        ics["u[$k]"] = sin(0.3k) + 0.1k
        ics["y[$k]"] = 0.0
    end
    withenv("ESS_CODEGEN_DISABLE" => "1") do
        ESM._reset_cascade_tally!()
        f, u0, p, _t, vm, diag = ESM._build_evaluator_impl(_gi_model(N);
            initial_conditions=ics)
        (f=f, u0=u0, p=p, vm=vm, diag=diag, tally=copy(ESM._CASCADE_TALLY),
         kernels=getfield(getfield(f, :kernel_section), :kernels),
         n_emitted=getfield(getfield(f, :kernel_section), :n_emitted))
    end
end

# ---- Structural signature of one kernel: everything that must NOT scale ----
_gi_nodes(nd::ESM._Node) = 1 + sum(_gi_nodes(c) for c in nd.children; init=0)
function _gi_shape!(out, nd::ESM._Node)
    push!(out, (nd.kind, nd.op))
    for c in nd.children
        _gi_shape!(out, c)
    end
    return out
end
# Descriptor VALUES stay out: a boundary kernel's wrap delta embeds N by
# construction (access_kernel_foundation_test's `-1 + N1`); its KIND and the
# table WIDTH (descriptor count) are the structural facts.
function _gi_sig(K::ESM._AccKernel)
    (; shape = _gi_shape!(Tuple{UInt8,Symbol}[], K.spine),
       n_spine = _gi_nodes(K.spine),
       n_acc = length(K.acc),
       acc_kinds = UInt8[d.kind for d in K.acc],
       cell_recipe_nodes = Int[_gi_nodes(r) for r in K.cse.recipes],
       inv_recipe_nodes = Int[_gi_nodes(r) for r in K.cse.inv_recipes],
       n_subs = length(K.subs),
       bound = nameof(typeof(K.bound)))
end
# Sorted-by-repr so the comparison pins the kernel SET, not an incidental
# build order (the order IS deterministic today; the pin should not depend
# on that staying true).
_gi_sigs(kernels) = sort!([repr(_gi_sig(K)) for K in kernels])

# ---- Per-lane data: the ONLY thing allowed to grow (and only linearly) ----
_gi_cells(K::ESM._AccKernel) = ESM._is_outs(K.cells) ?
    length(K.cells.outs) : prod(length.(K.cells.ranges))
_gi_data(kernels) = sum(_gi_cells(K) + sum(length(d.arr) + length(d.conn)
                                           for d in K.acc; init=0)
                        for K in kernels; init=0)

# Diag minus the buffer-cell count — the one field documented as O(cells)
# (`n_mat_array_cells = n_total - n_states`); every other counter is a count
# of STRUCTURES (kernels, slots, entries, folds), grid-free by design.
_gi_invariant(d) = (; [k => getfield(d, k) for k in keys(d)
                       if k !== :n_mat_array_cells]...)

@testset "compiled IR size is independent of the grid (build-level)" begin
    N1, N2 = 8, 24
    A = _gi_build(N1)
    B = _gi_build(N2)

    # The build is real at both sizes (and the kernel lists are complete).
    @test A.n_emitted == 0 && B.n_emitted == 0
    for r in (A, B)
        du = zero(r.u0); r.f(du, r.u0, r.p, 0.0)
        @test all(isfinite, du)
    end

    @testset "diag counters are grid-free" begin
        @test _gi_invariant(A.diag) == _gi_invariant(B.diag)
        # The tiers all FIRED — an invariantly-zero diag would pass the
        # equality vacuously.
        @test A.diag.n_acc_kernels >= 2      # stencil boxes + contraction
        @test A.diag.n_acc_inv_slots >= 1    # g/h hoisted
        @test A.diag.n_scalar_entries == 1   # D(x) alone; no per-cell spill
        @test A.diag.n_obs_slots == 2        # rate, flux
        @test A.diag.n_scan_folds == 0
    end

    @testset "per-kernel structural signatures are identical" begin
        @test length(A.kernels) == length(B.kernels)
        @test _gi_sigs(A.kernels) == _gi_sigs(B.kernels)
    end

    @testset "classification tally is identical (no size-dependent fallback)" begin
        @test A.tally == B.tally
        @test get(A.tally, :affine, 0) == 2              # both array equations
        @test get(A.tally, :percell_acc, 0) == 0         # no O(N) spill
        @test get(A.tally, :percell_disabled, 0) == 0
    end

    @testset "per-lane data grows exactly linearly" begin
        # Each array equation covers its N output cells exactly once, so the
        # kernel-partition total is 2N: a 3x grid is exactly 3x data.
        @test _gi_data(A.kernels) * N2 == _gi_data(B.kernels) * N1
        @test length(B.u0) - 1 == 3 * (length(A.u0) - 1)  # 2N states + x
    end
end
