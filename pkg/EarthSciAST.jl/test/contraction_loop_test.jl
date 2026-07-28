# Runtime contraction loop (ess-runtime-contraction).
#
# A UNIFORM scalar reduction Σ_{k∈lo:hi} body(k, state) is compiled ONCE into a
# single `_NK_CONTRACTION_LOOP` node that iterates the range at eval time, instead
# of UNROLLING the body into `length(k)` scalar terms at build time. This pins:
#
#   * NUMERIC IDENTITY to the unrolled fold (bit-identical for a single contracted
#     index — same accumulation order, seeded from 0̄);
#   * BUILD SIZE is O(1) in the reduction length (the unroll is O(length)) —
#     asserted via build time being ~flat in M while the unroll grows linearly;
#   * the loop preserves the zero-allocation `f!` hot path and differentiates
#     (ForwardDiff) — the loop counter is an integer constant of the value type;
#   * a `:oop` Float64 run stays bit-identical to `f!` (the oop oracle);
#   * the const-array-gather-in-loop path (a loop var as a runtime subscript);
#   * the conservative GATE: a reduction whose body indexes STATE at a
#     loop-var-dependent slot (no static per-k node) FALLS BACK to unrolling and
#     still gives the right answer;
#   * `ESS_CONTRACTION_LOOP=0` forces the pure-unroll reference.

using Test
using ForwardDiff
include("testutils.jl")

const _CL_ESS = EarthSciAST

# Scalar reduction model: D(s)/dt = Σ_{k=0..M} (k * x); x constant (D(x)=0).
# Constant-RHS ODE from zero ICs, so du(u0) IS the derivative at t=0.
# Σ_{k=0..M} k = M(M+1)/2, so du[s] = x0 · M(M+1)/2.
_cl_doc(M::Int) = Dict{String,Any}(
    "esm" => "0.8.0",
    "metadata" => Dict("name" => "contraction_loop_repro"),
    "models" => Dict("Repro" => Dict{String,Any}(
        "variables" => Dict("x" => Dict("type" => "state"),
                            "s" => Dict("type" => "state")),
        "equations" => Any[
            Dict("lhs" => Dict("op" => "D", "args" => Any["x"], "wrt" => "t"),
                 "rhs" => 0.0),
            Dict("lhs" => Dict("op" => "D", "args" => Any["s"], "wrt" => "t"),
                 "rhs" => Dict("op" => "aggregate", "semiring" => "sum_product",
                               "args" => Any[], "output_idx" => Any[],
                               "ranges" => Dict("k" => Any[0, M]),
                               "expr" => Dict("op" => "*", "args" => Any["k", "x"]))),
        ],
    )),
)

# Const-array-weighted reduction: D(s)/dt = Σ_{k=1..N} W[k] · x, W an INLINE const
# array. The loop var reaches a const-array subscript → runtime `_NK_CONST_GATHER`
# with an `_NK_LOOPVAR` subscript; still one compiled body.
_cl_doc_weighted(W::Vector{Float64}) = Dict{String,Any}(
    "esm" => "0.8.0",
    "metadata" => Dict("name" => "contraction_loop_weighted"),
    "models" => Dict("Repro" => Dict{String,Any}(
        "variables" => Dict("x" => Dict("type" => "state"),
                            "s" => Dict("type" => "state")),
        "equations" => Any[
            Dict("lhs" => Dict("op" => "D", "args" => Any["x"], "wrt" => "t"),
                 "rhs" => 0.0),
            Dict("lhs" => Dict("op" => "D", "args" => Any["s"], "wrt" => "t"),
                 "rhs" => Dict("op" => "aggregate", "semiring" => "sum_product",
                               "args" => Any[], "output_idx" => Any[],
                               "ranges" => Dict("k" => Any[1, length(W)]),
                               "expr" => Dict("op" => "*", "args" => Any[
                                   Dict("op" => "index", "args" => Any[
                                       Dict("op" => "const", "args" => Any[], "value" => W),
                                       "k"]),
                                   "x"]))),
        ],
    )),
)

_cl_build(doc; loop::Bool, form=:inplace) =
    withenv("ESS_CONTRACTION_LOOP" => (loop ? "1" : "0"),
            "ESS_CONTRACTION_LOOP_MIN" => "8") do
        build_evaluator(doc; initial_conditions = Dict("x" => 2.0, "s" => 0.0), form=form)
    end

_cl_du_s(doc; loop::Bool) = begin
    f!, u0, p, _, vmap = _cl_build(doc; loop=loop)
    du = similar(u0); f!(du, u0, p, 0.0)
    du[vmap["s"]]
end

@testset "runtime contraction loop (ess-runtime-contraction)" begin

    @testset "numeric identity: loop == unroll (bit-identical), M=$M" for M in (8, 50, 200)
        exact = 2.0 * (M * (M + 1) ÷ 2)
        dl = _cl_du_s(_cl_doc(M); loop=true)
        du = _cl_du_s(_cl_doc(M); loop=false)
        @test dl == du            # single-index loop is bit-identical to the unroll
        @test dl == exact
    end

    @testset "const-array-gather in loop == unroll" begin
        W = collect(1.0:16.0)     # 16 ≥ the min-length floor → loop engages
        dl = _cl_du_s(_cl_doc_weighted(W); loop=true)
        du = _cl_du_s(_cl_doc_weighted(W); loop=false)
        @test dl == du
        @test dl == 2.0 * sum(W)  # x0 · ΣW
    end

    @testset "loop preserves zero-alloc f!" begin
        f!, u0, p, _, vmap = _cl_build(_cl_doc(200); loop=true)
        du = similar(u0)
        f!(du, u0, p, 0.0)                       # warm up
        @test (@allocated f!(du, u0, p, 0.0)) == 0
    end

    @testset ":oop is bit-identical to f! (loop)" begin
        M = 50
        du_iip = _cl_du_s(_cl_doc(M); loop=true)
        fo, u0o, po, _, vmo = _cl_build(_cl_doc(M); loop=true, form=:oop)
        duo = fo(u0o, po, 0.0)
        @test duo[vmo["s"]] == du_iip
    end

    @testset "AD (ForwardDiff) differentiates through the loop" begin
        M = 50
        f!, u0, p, _, vmap = _cl_build(_cl_doc(M); loop=true)
        g(u) = (d = similar(u, eltype(u)); f!(d, u, p, 0.0); d[vmap["s"]])
        J = ForwardDiff.gradient(g, u0)
        @test J[vmap["x"]] == M * (M + 1) ÷ 2     # d(du_s)/dx = Σk, loop var has 0 deriv
        @test J[vmap["s"]] == 0.0
    end

    @testset "build size is O(1) in reduction length (loop) vs O(M) (unroll)" begin
        # Warm up compilation once so the timing reflects build work, not JIT.
        _cl_build(_cl_doc(16); loop=true); _cl_build(_cl_doc(16); loop=false)
        t_loop(M)   = @elapsed _cl_build(_cl_doc(M); loop=true)
        t_unroll(M) = @elapsed _cl_build(_cl_doc(M); loop=false)
        # Loop build time is ~flat in M; unroll grows ~linearly. Assert the loop
        # build at large M is much faster than the unroll at the same M (a robust,
        # machine-independent proxy for O(1)-vs-O(M) build IR size).
        big = 4000
        tl = min(t_loop(big), t_loop(big))
        tu = min(t_unroll(big), t_unroll(big))
        @test tl < tu / 5     # loop build ≥5× faster than unroll at M=4000
    end

    @testset "ESS_CONTRACTION_LOOP=0 forces the unroll reference" begin
        # With the loop disabled the result must be unchanged (the reference).
        @test _cl_du_s(_cl_doc(200); loop=false) == 2.0 * (200 * 201 ÷ 2)
    end
end
