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
#
# THREADED TIER, and why this file pins the SERIAL path explicitly.
# The codegen tier can run a section's cell axis as static chunks through
# Polyester (`_run_cg_section_threaded!`, codegen_kernel.jl). That dispatch is
# NOT free: handing a closure over `du`/`u`/`p`/`tabs` to Polyester's batch
# runner costs a fixed ~96 B per call (48 B closure + 48 B
# `ManualMemory.Reference`; both non-isbits, so Polyester boxes them). The cost
# is per DISPATCH, not per cell — it does not grow with N — but it is not 0.
#
# The tier arms itself when Polyester is loaded, and Polyester arrives as a
# TRANSITIVE dependency of the SciML stack (ModelingToolkit / OrdinaryDiffEq /
# Catalyst). So whether these measurements see the serial or the threaded path
# depends on which OTHER test files ran first in the same process — this file
# alone loads no SciML package and measures the serial path, while the full
# `runtests.jl` has MTK loaded by the time it gets here and measures the
# threaded one. That is a property of the process, not of the kernels.
#
# The zero-allocation DISCIPLINE this file exists to guard (`@views`/gather
# slices, preallocated scratch, fused in-place broadcasts, in-place semiring
# folds, explicit `du` scatter) is a property of the kernels themselves, so the
# testsets below pin the serial path and keep asserting EXACTLY 0 — via
# `ESS_THREADS_MIN_CELLS`, which `_sec_prep_threads!` reads ONCE per section
# and caches (unlike `ESS_THREADS_DISABLE`/`ESS_CG_THREADS_DISABLE`, which
# `_cg_threads_available()` re-reads on EVERY call and whose `get(ENV, …)`
# itself allocates a 32 B String per call once the variable is set — a kill
# switch cannot be used to measure zero allocation).
#
# The threaded dispatch is then covered on its own terms by the final testset:
# its cost must stay CONSTANT in N, which is the real invariant (a per-cell
# leak on the chunked path would grow with the grid).

using Test
using EarthSciAST

include("testutils.jl")  # builder quartet + zero_alloc_harness.jl

const ESM = EarthSciAST

# D(y[i]) = Σ_{k=1..M} A[i,k]·x[k] (sum_product) — exercises the VK_REDUCE axis
# fold + CONSTVEC (A[i,k]) + GATHER (x[k]).
function _contraction_model(M)
    vars = Dict("y" => ModelVariable(UnknownVariable),
                "x" => ModelVariable(UnknownVariable))
    body = _op("*", _idx("A", _v("i"), _v("k")), _idx("x", _v("k")))
    rhs = OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"], expr_body=body,
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
                "u" => Dict{String,Any}("type" => "unknown", "default" => 0.0,
                    "units" => "1", "shape" => Any["i"], "location" => "cell_center"),
                "dx" => Dict{String,Any}("type" => "parameter", "default" => dx, "units" => "1")),
            "equations" => Any[Dict{String,Any}(
                "lhs" => Dict{String,Any}("op" => "D", "args" => Any["u"], "wrt" => "t"),
                "rhs" => Dict{String,Any}("op" => "grad", "args" => Any["u"], "dim" => "i"))])))
end


# Closed-function (`interp.*`) leaves on the array RHS (ess-wrh). Each is a single
# arrayop `D(u[i]) = interp.<op>(<const table/axis>, …, u[i])` — the const table &
# axis ride on the fn payload (lowered to a typed `_Interp*Spec` at build time);
# the per-cell query `u[i]` merges to a GATHER. These exercise the de-boxed
# whole-array interp path (`_eval_acc_op`'s `:fn` arm): the only Float64 arrays are the
# preallocated buffers, so a steady-state `f!` call must allocate 0 bytes even
# though the RHS contains a table lookup. This coverage gap is exactly why the
# per-lane `Float64`→`Any` box went unnoticed before ess-wrh.
_interp_linear_model(N) = ESM.Model(
    Dict("u" => ModelVariable(UnknownVariable)),
    [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                  _ao1(_op("fn", _const([10.0, 20.0, 40.0, 80.0, 160.0]),
                           _const([0.0, 1.0, 2.0, 3.0, 4.0]),
                           _idx("u", _v("i")); name="interp.linear"), "i", 1, N))])

_interp_searchsorted_model(N) = ESM.Model(
    Dict("u" => ModelVariable(UnknownVariable)),
    [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                  _ao1(_op("fn", _idx("u", _v("i")),
                           _const([1.0, 2.0, 3.0, 4.0, 5.0]);
                           name="interp.searchsorted"), "i", 1, N))])

# Bilinear: x-query is the per-cell state `u[i]` (→ GATHER); y-query is a broadcast
# parameter (→ PARAM). Both children stay non-constant, so the leaf runs the
# whole-array kernel rather than folding.
_interp_bilinear_model(N) = ESM.Model(
    Dict("u" => ModelVariable(UnknownVariable),
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
    Dict("u" => ModelVariable(UnknownVariable)),
    [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                  _ao1(_op("+", _idx("forcing", _v("i")), _idx("u", _v("i"))), "i", 1, N))])

# Scalar (non-arrayop) `interp.*` observeds on the RHS (perf-interp-alloc). Each
# is a plain scalar equation `D(z) = interp.<op>(<const table/axis>, …, <state>)`,
# so the RHS compiles to a scalar `_Node` tree walked by `_eval_node_op`'s `:fn`
# arm — the FastJX-box hot path. The const table/axis are validated + coerced to
# typed `_Interp*Spec` ONCE at build time and read via a concrete-tuple `isa`
# match, so a steady-state `f!` call allocates 0 bytes (the fix moved all
# per-call, value-independent work — the fresh axis `Vector`, the monotonicity
# re-walk, the `Vector{Any}` splice, the `_fn_const_arg_spec` scan, the boxed
# `evaluate_closed_function` dispatch — to build time).
# Scalar CSE over a LIVE forcing buffer (ess-qic): `F[1]*k` occurs three times
# across two scalar equations, so it is now hoisted into the CSE prelude — whose
# slot is filled by a live `_NK_PARAM_GATHER` read. Before ess-qic the gather's
# un-canonicalizable payload made `_cse_key` decline, so this shape never reached
# the prelude at all; pin that hoisting it keeps `f!` at 0 bytes (the prelude
# scratch is preallocated at build; the gather is a bare indexed load into the
# aliased flat buffer).
#   D(x) = sin(F[1]*k) + cos(F[1]*k);   D(y) = F[1]*k
function _cse_forcing_scalar_model()
    vars = Dict("x" => ModelVariable(UnknownVariable; default=1.0),
                "y" => ModelVariable(UnknownVariable; default=1.0),
                "k" => ModelVariable(ParameterVariable; default=2.0))
    fk = _op("*", _idx("F", _i(1)), _v("k"))
    ESM.Model(vars, [
        ESM.Equation(_D("x"), _op("+", _op("sin", fk), _op("cos", fk))),
        ESM.Equation(_D("y"), fk)])
end

function _scalar_interp_linear_model()
    axis = _const([0.0, 1.0, 2.0, 3.0]); tab = _const([10.0, 20.0, 30.0, 40.0])
    vars = Dict("x" => ModelVariable(UnknownVariable; default=1.5),
                "z" => ModelVariable(UnknownVariable; default=0.0))
    body = _op("fn", tab, axis, _v("x"); name="interp.linear")
    ESM.Model(vars, [ESM.Equation(_D("z"), body)])
end
function _scalar_interp_searchsorted_model()
    xs = _const([1.0, 2.0, 3.0, 4.0, 5.0])
    vars = Dict("x" => ModelVariable(UnknownVariable; default=2.5),
                "z" => ModelVariable(UnknownVariable; default=0.0))
    body = _op("fn", _v("x"), xs; name="interp.searchsorted")
    ESM.Model(vars, [ESM.Equation(_D("z"), body)])
end
function _scalar_interp_bilinear_model()
    tab = _const([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]])
    ax  = _const([0.0, 1.0, 2.0]); ay = _const([0.0, 10.0, 20.0])
    vars = Dict("x" => ModelVariable(UnknownVariable; default=0.5),
                "y" => ModelVariable(UnknownVariable; default=5.0),
                "z" => ModelVariable(UnknownVariable; default=0.0))
    body = _op("fn", tab, ax, ay, _v("x"), _v("y"); name="interp.bilinear")
    ESM.Model(vars, [ESM.Equation(_D("z"), body)])
end

# Bytes a scalar `_NK_CONTRACTION` `:+` fold over `n` states allocates per call,
# plus the folded value. Measured INSIDE a function — the discipline
# `rhs_alloc_bytes` follows, and the way the RHS actually calls the walker. At
# `@testset` scope the enclosing block's bindings box the returned `Float64` on
# Julia < 1.12 (a flat 16 B, the same at n=6 and n=6000), which measures the
# probe rather than the fold.
function _contract_fold_alloc(n; warmup::Int=3, samples::Int=5)
    u = collect(1.0:n)
    p = (;)
    kids = ESM._Node[ESM._mknode(kind=ESM._NK_STATE, idx=k) for k in 1:n]
    cnode = ESM._mknode(kind=ESM._NK_CONTRACTION, op=:+, literal=0.0, children=kids)
    for _ in 1:warmup
        ESM._eval_node(cnode, u, p, 0.0)
    end
    best = typemax(Int)
    for _ in 1:samples
        best = min(best, @allocated ESM._eval_node(cnode, u, p, 0.0))
    end
    return (best, ESM._eval_node(cnode, u, p, 0.0), sum(u))
end

# Force the SERIAL path for every exact-zero measurement below, so the numbers
# are a property of the kernels rather than of whichever packages a previously
# included test file happened to load. `_sec_prep_threads!` reads this once per
# section and caches the verdict, so it costs no per-call allocation of its own
# (see the header note).
const _SERIAL_PIN = ("ESS_THREADS_MIN_CELLS" => string(typemax(Int)),)

withenv(_SERIAL_PIN...) do
@testset "tree_walk PDE RHS is allocation-free (ess-9cc)" begin

    @testset "scalar interp.* observed RHS: 0 bytes (perf-interp-alloc)" begin
        # The FastJX box hot path: a scalar `interp.linear` observed. Must be
        # allocation-free after the build-time-spec fix.
        @test built_rhs_alloc_bytes(_scalar_interp_linear_model()) == 0
        @test built_rhs_alloc_bytes(_scalar_interp_searchsorted_model()) == 0
        @test built_rhs_alloc_bytes(_scalar_interp_bilinear_model()) == 0
    end


    @testset "vectorized stencil RHS: 0 bytes, N-independent" begin
        # Two+ grid sizes — the steady-state allocation must be EXACTLY 0 at
        # every size (a per-cell leak would grow the byte count with N).
        for N in (64, 256, 1024, 2500)
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

    @testset "CSE'd scalar forcing gather RHS: 0 bytes (ess-qic)" begin
        # The CSE prelude now hoists expressions built over a live forcing buffer.
        # The hoisted slot is filled from a `_NK_PARAM_GATHER` read every call, so the
        # zero-allocation discipline has to hold through the prelude too.
        @test built_rhs_alloc_bytes(_cse_forcing_scalar_model();
            param_arrays=Dict("F" => [5.0, 6.0])) == 0
    end

    @testset "scalar contraction :+ fold is allocation-free (line fix)" begin
        # Directly pin the scalar `_eval_contraction` `:+` arm (the old
        # `@tullio s = …` site, ~80 B/reduced cell): a hand-built
        # `_NK_CONTRACTION` node summed via `_eval_node` must be 0-alloc and
        # equal to the seeded fold, bit-identical to the prior Tullio sum.
        # Two lengths, so the property is fold-length-independent the way the
        # rest of this file is grid-size-independent.
        for n in (6, 600)
            bytes, got, want = _contract_fold_alloc(n)
            @test got == want
            @test bytes == 0
        end
    end
end
end  # withenv(_SERIAL_PIN...)

# The chunked cell axis on its own terms. Only reachable when the threaded tier
# is actually armed (Polyester loaded — usually transitively via the SciML
# stack — and `nthreads() > 1`), so it is skipped in a bare `julia --project`
# run of this file and exercised in the full suite.
#
# The dispatch costs a FIXED ~96 B per call (see the header). What must hold is
# that the cost is per dispatch and not per CELL: a real leak in a chunked
# kernel would scale with the grid. So this pins N-INDEPENDENCE plus a small
# absolute ceiling, which is the same property the serial testsets pin with
# `== 0` — just at the constant the batch runner actually costs.
@testset "threaded cell axis: per-dispatch cost is constant in N (ess-9cc)" begin
    if !EarthSciAST._threads_available()
        @info "skipping threaded-tier allocation test: threaded tier not armed " *
              "(needs Polyester loaded and nthreads() > 1; " *
              "nthreads=$(Threads.nthreads()), " *
              "polyester=$(EarthSciAST._polyester_loaded()))"
    else
        # Small min-cells so every N below genuinely chunks; read once per
        # section and cached, so it adds no per-call allocation.
        withenv("ESS_THREADS_MIN_CELLS" => "256") do
            bytes = map((1024, 4096, 16384)) do N
                ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
                built_rhs_alloc_bytes(_stencil_model(N); initial_conditions=ics)
            end
            # Grid grows 16x; the per-call cost must not move at all.
            @test allequal(bytes)
            # And it must stay a small constant, not creep toward per-cell.
            @test all(<=(256), bytes)

            fbytes = map((1024, 16384)) do N
                ics = Dict("u[$k]" => 0.1k for k in 1:N)
                built_rhs_alloc_bytes(_forcing_gather_model(N);
                    initial_conditions=ics,
                    param_arrays=Dict("forcing" => collect(1.0:Float64(N))))
            end
            @test allequal(fbytes)
            @test all(<=(256), fbytes)
        end
    end
end
