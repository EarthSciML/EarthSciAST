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

# ── Array-einsum path (ess-runtime-contraction): out[i,j] = Σ_{k,l} body ──────
# The per-output-cell inner reduction compiles to ONE `_NK_CONTRACTION_LOOP`
# (contracted k,l symbolic, output i,j concrete) routed to the scalar-walk
# reference path, instead of unrolling ∏|k,l| terms per cell. Mirrors the
# cubed-sphere halo-tent shape.

# Weighted: out[i,j] = Σ_{k,l=1..M} W[i,j,k,l]·F[k,l] (INLINE const weight × const
# field — the const-gather-in-loop path). Integer-valued so grouped (nested-loop)
# and flat (unroll) sums are BIT-EQUAL.
function _cl_doc2d_weighted(M::Int)
    W = [ [ [ [ Float64((i+2j+3k+5l) % 7) for l in 1:M ] for k in 1:M ] for j in 1:2 ] for i in 1:2 ]
    F = [ [ Float64((2k+3l) % 5) for l in 1:M ] for k in 1:M ]
    agg = Dict{String,Any}("op"=>"aggregate","semiring"=>"sum_product","args"=>Any[],
        "output_idx"=>Any["i","j"],"ranges"=>Dict("i"=>Any[1,2],"j"=>Any[1,2],
                                                   "k"=>Any[1,M],"l"=>Any[1,M]),
        "expr"=>Dict("op"=>"*","args"=>Any[
            Dict("op"=>"index","args"=>Any[Dict("op"=>"const","args"=>Any[],"value"=>W),"i","j","k","l"]),
            Dict("op"=>"index","args"=>Any[Dict("op"=>"const","args"=>Any[],"value"=>F),"k","l"])]))
    Dict{String,Any}("esm"=>"0.8.0","metadata"=>Dict("name"=>"cl_einsum2d_w"),
      "models"=>Dict("R"=>Dict{String,Any}(
        "variables"=>Dict("out"=>Dict("type"=>"state","shape"=>Any["i","j"])),
        "equations"=>Any[Dict(
          "lhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["i","j"],
                      "ranges"=>Dict("i"=>Any[1,2],"j"=>Any[1,2]),
                      "expr"=>Dict("op"=>"D","args"=>Any[Dict("op"=>"index","args"=>Any["out","i","j"])],"wrt"=>"t")),
          "rhs"=>agg)])))
end
_cl_expected2d(M) = begin
    W(i,j,k,l)=Float64((i+2j+3k+5l)%7); F(k,l)=Float64((2k+3l)%5)
    [ sum(W(i,j,k,l)*F(k,l) for k in 1:M for l in 1:M) for i in 1:2, j in 1:2 ]
end

# Arithmetic: out[i,j] = Σ_{k,l=0..M} (k·l+1)·x[i,j] — tiny input for any M, so
# build size is measurable independent of the const-data size.
function _cl_doc2d_arith(M::Int)
    agg = Dict{String,Any}("op"=>"aggregate","semiring"=>"sum_product","args"=>Any[],
        "output_idx"=>Any["i","j"],"ranges"=>Dict("i"=>Any[1,2],"j"=>Any[1,2],
                                                   "k"=>Any[0,M],"l"=>Any[0,M]),
        "expr"=>Dict("op"=>"*","args"=>Any[
            Dict("op"=>"+","args"=>Any[Dict("op"=>"*","args"=>Any["k","l"]),1.0]),
            Dict("op"=>"index","args"=>Any["x","i","j"])]))
    Dict{String,Any}("esm"=>"0.8.0","metadata"=>Dict("name"=>"cl_einsum2d_a"),
      "models"=>Dict("R"=>Dict{String,Any}(
        "variables"=>Dict("x"=>Dict("type"=>"state","shape"=>Any["i","j"]),
                          "out"=>Dict("type"=>"state","shape"=>Any["i","j"])),
        "equations"=>Any[
          Dict("lhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["i","j"],
                 "ranges"=>Dict("i"=>Any[1,2],"j"=>Any[1,2]),
                 "expr"=>Dict("op"=>"D","args"=>Any[Dict("op"=>"index","args"=>Any["x","i","j"])],"wrt"=>"t")),
               "rhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["i","j"],
                 "ranges"=>Dict("i"=>Any[1,2],"j"=>Any[1,2]),"expr"=>0.0)),
          Dict("lhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["i","j"],
                 "ranges"=>Dict("i"=>Any[1,2],"j"=>Any[1,2]),
                 "expr"=>Dict("op"=>"D","args"=>Any[Dict("op"=>"index","args"=>Any["out","i","j"])],"wrt"=>"t")),
               "rhs"=>agg)])))
end

_cl_ics2d_w() = Dict("out[1,1]"=>0.0,"out[1,2]"=>0.0,"out[2,1]"=>0.0,"out[2,2]"=>0.0)
_cl_ics2d_a() = merge(_cl_ics2d_w(), Dict("x[1,1]"=>1.0,"x[1,2]"=>2.0,"x[2,1]"=>3.0,"x[2,2]"=>4.0))
_cl_build2d(doc, ics; loop::Bool, form=:inplace) =
    withenv("ESS_CONTRACTION_LOOP"=>(loop ? "1" : "0"),"ESS_CONTRACTION_LOOP_MIN"=>"8") do
        build_evaluator(doc; initial_conditions=ics, form=form)
    end
_cl_du2d(doc, ics; loop::Bool) = begin
    f!,u0,p,_,vm = _cl_build2d(doc, ics; loop=loop)
    du=similar(u0); f!(du,u0,p,0.0); (du, vm)
end

@testset "runtime contraction loop — 2-D array einsum (ess-runtime-contraction)" begin

    @testset "weighted einsum loop == unroll == exact (M=$M)" for M in (8, 12)
        dl, vml = _cl_du2d(_cl_doc2d_weighted(M), _cl_ics2d_w(); loop=true)
        du, vmu = _cl_du2d(_cl_doc2d_weighted(M), _cl_ics2d_w(); loop=false)
        exp = _cl_expected2d(M)
        for i in 1:2, j in 1:2
            key = "out[$i,$j]"
            @test dl[vml[key]] == du[vmu[key]]      # integer weights ⇒ bit-equal
            @test dl[vml[key]] == exp[i, j]
        end
    end

    @testset "arith einsum loop == unroll (M=20)" begin
        M = 20
        dl, vml = _cl_du2d(_cl_doc2d_arith(M), _cl_ics2d_a(); loop=true)
        du, vmu = _cl_du2d(_cl_doc2d_arith(M), _cl_ics2d_a(); loop=false)
        Sk = sum((k*l + 1) for k in 0:M for l in 0:M)
        for i in 1:2, j in 1:2
            key = "out[$i,$j]"; x0 = _cl_ics2d_a()["x[$i,$j]"]
            @test dl[vml[key]] == du[vmu[key]]
            @test dl[vml[key]] == x0 * Sk
        end
    end

    @testset "einsum loop preserves zero-alloc f!" begin
        f!, u0, p, _, vm = _cl_build2d(_cl_doc2d_arith(30), _cl_ics2d_a(); loop=true)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test (@allocated f!(du, u0, p, 0.0)) == 0
    end

    @testset "einsum :oop == :iip (loop)" begin
        du_iip, vmi = _cl_du2d(_cl_doc2d_arith(20), _cl_ics2d_a(); loop=true)
        fo, u0o, po, _, vmo = _cl_build2d(_cl_doc2d_arith(20), _cl_ics2d_a(); loop=true, form=:oop)
        duo = fo(u0o, po, 0.0)
        @test all(duo[vmo["out[$i,$j]"]] == du_iip[vmi["out[$i,$j]"]] for i in 1:2, j in 1:2)
    end

    @testset "einsum build size is ~flat in M (loop) vs ~M² (unroll)" begin
        _cl_build2d(_cl_doc2d_arith(8), _cl_ics2d_a(); loop=true)     # warm
        _cl_build2d(_cl_doc2d_arith(8), _cl_ics2d_a(); loop=false)
        tl(M) = @elapsed _cl_build2d(_cl_doc2d_arith(M), _cl_ics2d_a(); loop=true)
        tu(M) = @elapsed _cl_build2d(_cl_doc2d_arith(M), _cl_ics2d_a(); loop=false)
        big = 40
        @test min(tl(big), tl(big)) < min(tu(big), tu(big)) / 10   # ≥10× at M=40 (~1681 terms/cell)
    end

    # A contraction that indexes STATE at a contracted index (`src[k,l]`) has no
    # static per-k slot for the loop — the probe fails and the einsum takes the
    # existing affine/unroll path, unchanged. Confirm it does NOT loop and stays
    # correct even with the loop enabled (the realistic state-source shape).
    @testset "state-source contraction falls back to unroll, still correct" begin
        N = 4    # total contraction N² = 16 ≥ floor, so the gate/probe actually runs
        W = [ [ [ [ Float64((i+2j+3k+5l) % 7) for l in 1:N ] for k in 1:N ] for j in 1:2 ] for i in 1:2 ]
        agg = Dict{String,Any}("op"=>"aggregate","semiring"=>"sum_product","args"=>Any[],
            "output_idx"=>Any["i","j"],"ranges"=>Dict("i"=>Any[1,2],"j"=>Any[1,2],"k"=>Any[1,N],"l"=>Any[1,N]),
            "expr"=>Dict("op"=>"*","args"=>Any[
                Dict("op"=>"index","args"=>Any[Dict("op"=>"const","args"=>Any[],"value"=>W),"i","j","k","l"]),
                Dict("op"=>"index","args"=>Any["src","k","l"])]))
        doc = Dict{String,Any}("esm"=>"0.8.0","metadata"=>Dict("name"=>"cl_state_src"),
          "models"=>Dict("R"=>Dict{String,Any}(
            "variables"=>Dict("src"=>Dict("type"=>"state","shape"=>Any["k","l"]),
                              "out"=>Dict("type"=>"state","shape"=>Any["i","j"])),
            "equations"=>Any[
              Dict("lhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["k","l"],
                     "ranges"=>Dict("k"=>Any[1,N],"l"=>Any[1,N]),
                     "expr"=>Dict("op"=>"D","args"=>Any[Dict("op"=>"index","args"=>Any["src","k","l"])],"wrt"=>"t")),
                   "rhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["k","l"],
                     "ranges"=>Dict("k"=>Any[1,N],"l"=>Any[1,N]),"expr"=>0.0)),
              Dict("lhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["i","j"],
                     "ranges"=>Dict("i"=>Any[1,2],"j"=>Any[1,2]),
                     "expr"=>Dict("op"=>"D","args"=>Any[Dict("op"=>"index","args"=>Any["out","i","j"])],"wrt"=>"t")),
                   "rhs"=>agg)])))
        ics = Dict{String,Any}("out[1,1]"=>0.0,"out[1,2]"=>0.0,"out[2,1]"=>0.0,"out[2,2]"=>0.0)
        for k in 1:N, l in 1:N; ics["src[$k,$l]"] = Float64(k + l); end
        du(loop) = withenv("ESS_CONTRACTION_LOOP"=>(loop ? "1" : "0"),"ESS_CONTRACTION_LOOP_MIN"=>"8") do
            f!,u0,p,_,vm = build_evaluator(doc; initial_conditions=ics)
            d=similar(u0); f!(d,u0,p,0.0); (d,vm)
        end
        dl,vml = du(true); dr,vmr = du(false)
        Wf(i,j,k,l)=Float64((i+2j+3k+5l)%7)
        for i in 1:2, j in 1:2
            key="out[$i,$j]"
            @test dl[vml[key]] == dr[vmr[key]]     # loop-enabled == reference (no loop taken)
            @test dl[vml[key]] == sum(Wf(i,j,k,l)*(k+l) for k in 1:N for l in 1:N)
        end
    end
end
