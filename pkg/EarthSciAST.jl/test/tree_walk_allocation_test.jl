# Allocation tests for the tree-walk PDE RHS (ess-9cc).
#
# The codebase's FIRST allocation test. It pins the hard property that the
# in-place RHS `f!(du, u, p, t)` built by `build_evaluator` allocates NOTHING per
# call in steady state — at two+ grid sizes, so the property is N-independent
# (no per-cell allocation hiding behind a small absolute number). This guards the
# zero-allocation discipline of the vectorized array-kernel runner (ess-dhq +
# ess-9cc): `@views`/gather slices, preallocated per-node scratch buffers, fused
# in-place broadcasts, in-place semiring folds, and an explicit `du` scatter
# (never `du[slots] .= …`, whose `dotview` allocates a SubArray).
#
# Reuses the `zero_alloc_harness.jl` helpers — `built_rhs_alloc_bytes(model;…)`
# and `rhs_alloc_bytes(f!,du,u0,p,t)` — which any future evaluator work can call.

using Test
using EarthSciAST

include("testutils.jl")  # builder quartet + zero_alloc_harness.jl

const ESM = EarthSciAST

# D(y[i]) = Σ_{k=1..M} A[i,k]·x[k] (sum_product) — exercises the VK_REDUCE axis
# fold + CONSTVEC (A[i,k]) + GATHER (x[k]).
function _contraction_model(M)
    vars = Dict("y" => ModelVariable(StateVariable),
                "x" => ModelVariable(StateVariable))
    body = _op("*", _idx("A", _v("i"), _v("k")), _idx("x", _v("k")))
    rhs = OpExpr("arrayop", ESM.Expr[]; output_idx=Any["i"], expr_body=body,
                 ranges=Dict("i" => [1, 2], "k" => [1, M]), reduce="+")
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("y", _v("i")), "i", 1, 2), rhs)])
end

# 1-D periodic centered-advection document: discretizes to an arrayop whose RHS
# is (u[i+1]-u[i-1])/(2·dx) — exercises PARAM (dx) + the `/` and `-` OP arms in a
# REALISTIC parse→discretize→build_evaluator pipeline.
function _advection_esm(n)
    dx = 1.0 / n
    Dict{String,Any}(
        "esm" => "0.4.0",
        "metadata" => Dict{String,Any}("name" => "advection_1d_alloc"),
        "grids" => Dict{String,Any}("gx" => Dict{String,Any}(
            "family" => "cartesian",
            "dimensions" => Any[Dict{String,Any}(
                "name" => "i", "size" => n, "periodic" => true, "spacing" => "uniform")])),
        "rules" => Any[Dict{String,Any}(
            "name" => "centered_grad",
            "pattern" => Dict{String,Any}("op" => "grad", "args" => Any["\$u"], "dim" => "\$x"),
            "replacement" => Dict{String,Any}("op" => "/", "args" => Any[
                Dict{String,Any}("op" => "-", "args" => Any[
                    Dict{String,Any}("op" => "index", "args" => Any[
                        "\$u", Dict{String,Any}("op" => "+", "args" => Any["\$x", 1])]),
                    Dict{String,Any}("op" => "index", "args" => Any[
                        "\$u", Dict{String,Any}("op" => "-", "args" => Any["\$x", 1])])]),
                Dict{String,Any}("op" => "*", "args" => Any[2, "dx"])]))],
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "grid" => "gx",
            "variables" => Dict{String,Any}(
                "u" => Dict{String,Any}("type" => "state", "default" => 0.0,
                    "units" => "1", "shape" => Any["i"], "location" => "cell_center"),
                "dx" => Dict{String,Any}("type" => "parameter", "default" => dx, "units" => "1")),
            "equations" => Any[Dict{String,Any}(
                "lhs" => Dict{String,Any}("op" => "D", "args" => Any["u"], "wrt" => "t"),
                "rhs" => Dict{String,Any}("op" => "grad", "args" => Any["u"], "dim" => "i"))])))
end


# Closed-function (`interp.*`) leaves on the array RHS (ess-wrh). Each is a single
# arrayop `D(u[i]) = interp.<op>(<const table/axis>, …, u[i])` — the const table &
# axis ride on the fn handler (lowered to a typed `_Interp*Spec` at build time);
# the per-cell query `u[i]` merges to a GATHER. These exercise the de-boxed
# whole-array `_eval_vec_interp_*` kernels: the only Float64 arrays are the
# preallocated buffers, so a steady-state `f!` call must allocate 0 bytes even
# though the RHS contains a table lookup. This coverage gap is exactly why the
# per-lane `Float64`→`Any` box went unnoticed before ess-wrh.
_interp_linear_model(N) = ESM.Model(
    Dict("u" => ModelVariable(StateVariable)),
    [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                  _ao1(_op("fn", _const([10.0, 20.0, 40.0, 80.0, 160.0]),
                           _const([0.0, 1.0, 2.0, 3.0, 4.0]),
                           _idx("u", _v("i")); name="interp.linear"), "i", 1, N))])

_interp_searchsorted_model(N) = ESM.Model(
    Dict("u" => ModelVariable(StateVariable)),
    [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                  _ao1(_op("fn", _idx("u", _v("i")),
                           _const([1.0, 2.0, 3.0, 4.0, 5.0]);
                           name="interp.searchsorted"), "i", 1, N))])

# Bilinear: x-query is the per-cell state `u[i]` (→ GATHER); y-query is a broadcast
# parameter (→ PARAM). Both children stay non-constant, so the leaf runs the
# whole-array kernel rather than folding.
_interp_bilinear_model(N) = ESM.Model(
    Dict("u" => ModelVariable(StateVariable),
         "cz" => ModelVariable(ParameterVariable; default=0.5)),
    [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                  _ao1(_op("fn",
                           _const(Any[Any[1.0, 1.5, 2.0], Any[1.1, 1.6, 2.1], Any[1.2, 1.7, 2.2]]),
                           _const([10.0, 100.0, 1000.0]), _const([0.1, 0.5, 1.0]),
                           _idx("u", _v("i")), _v("cz"); name="interp.bilinear"), "i", 1, N))])

# Live forcing gather (ess-14f.3): D(u[i]) = forcing[i] + u[i]. `forcing` is a
# refreshable buffer bound BY REFERENCE via `param_arrays` and read through the
# new `_VK_PGATHER` kernel — the zero-alloc dual of a frozen const-array gather.
# Pins that a discrete-cadence forcing read stays allocation-free and
# N-independent: the only Float64 arrays are the captured flat buffer and the
# preallocated gather `slots`/`buf`, none allocated per call.
_forcing_gather_model(N) = ESM.Model(
    Dict("u" => ModelVariable(StateVariable)),
    [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                  _ao1(_op("+", _idx("forcing", _v("i")), _idx("u", _v("i"))), "i", 1, N))])

@testset "tree_walk PDE RHS is allocation-free (ess-9cc)" begin

    @testset "vectorized stencil RHS: 0 bytes, N-independent" begin
        # Two+ grid sizes — the steady-state allocation must be EXACTLY 0 at every
        # size (a per-cell leak would grow the byte count with N).
        for N in (64, 256, 1024)
            ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
            @test built_rhs_alloc_bytes(_stencil_model(N); initial_conditions=ics) == 0
        end
    end

    @testset "vectorized reduction (sum_product) RHS: 0 bytes" begin
        for M in (3, 16, 64)
            A = reshape(collect(1.0:(2.0 * M)), 2, M)
            ics = Dict{String,Float64}("y[1]" => 0.0, "y[2]" => 0.0)
            for k in 1:M
                ics["x[$k]"] = 0.5k
            end
            @test built_rhs_alloc_bytes(_contraction_model(M);
                initial_conditions=ics, const_arrays=Dict("A" => A)) == 0
        end
    end

    @testset "vectorized interp.linear RHS: 0 bytes, N-independent (ess-wrh)" begin
        # Query lands strictly inside the axis so the blend (not a clamp) runs.
        for N in (32, 128)
            ics = Dict("u[$k]" => 0.5 + 3.0 * (k - 1) / N for k in 1:N)
            @test built_rhs_alloc_bytes(_interp_linear_model(N); initial_conditions=ics) == 0
        end
    end

    @testset "vectorized interp.searchsorted RHS: 0 bytes, N-independent (ess-wrh)" begin
        for N in (32, 128)
            ics = Dict("u[$k]" => 1.0 + 4.0 * (k - 1) / N for k in 1:N)
            @test built_rhs_alloc_bytes(_interp_searchsorted_model(N); initial_conditions=ics) == 0
        end
    end

    @testset "vectorized interp.bilinear RHS: 0 bytes, N-independent (ess-wrh)" begin
        for N in (32, 128)
            ics = Dict("u[$k]" => 10.0 + 990.0 * (k - 1) / N for k in 1:N)
            @test built_rhs_alloc_bytes(_interp_bilinear_model(N); initial_conditions=ics) == 0
        end
    end

    @testset "vectorized forcing gather (param_arrays) RHS: 0 bytes, N-independent (ess-14f.3)" begin
        # Two+ grid sizes — the per-RHS allocation must be EXACTLY 0 at every size
        # (a per-cell leak in the live forcing read would grow with N). Mirrors the
        # stencil/reduction cases but exercises the `_VK_PGATHER` kernel.
        for N in (64, 256, 1024)
            ics = Dict("u[$k]" => 0.1k for k in 1:N)
            forcing = collect(1.0:Float64(N))
            @test built_rhs_alloc_bytes(_forcing_gather_model(N);
                initial_conditions=ics, param_arrays=Dict("forcing" => forcing)) == 0
        end
    end

    @testset "scalar contraction :+ fold is allocation-free (line fix)" begin
        # Directly pin the scalar `_eval_contraction` `:+` arm (the old
        # `@tullio s = …` site, ~80 B/reduced cell): a hand-built
        # `_NK_CONTRACTION` node summed via `_eval_node` must be 0-alloc and
        # equal to the seeded fold, bit-identical to the prior Tullio sum.
        u = collect(1.0:6.0)
        p = (;)
        kids = ESM._Node[ESM._mknode(kind=ESM._NK_STATE, idx=k) for k in 1:6]
        cnode = ESM._mknode(kind=ESM._NK_CONTRACTION, op=:+, literal=0.0, children=kids)
        ESM._eval_node(cnode, u, p, 0.0)             # warmup/compile
        @test ESM._eval_node(cnode, u, p, 0.0) == sum(u)
        @test (@allocated ESM._eval_node(cnode, u, p, 0.0)) == 0
    end
end
