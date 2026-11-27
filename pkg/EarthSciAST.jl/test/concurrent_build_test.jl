# Two builds on two tasks at once.
#
# A build keeps its scoped state — the state slot tables, the loop-variable
# registry and counter, the array-cell depth, the parameter-read sink, the plan
# and the record — on its own build context, so two builds running together
# cannot read each other's. Each concurrent build must equal its serial build
# bit for bit: the same `u0`, the same derivative at two points, the same
# layout, the same parameter classes and the same tier for every rule.
#
# The two documents are chosen to touch every piece of that state: a scalar
# reduction over a state array (a runtime contraction loop whose body gathers
# state through a slot table), an array equation (built per cell), a parameter
# read at build time by an `ic` fold (`:structural`), and a const-weighted
# reduction (a loop over a const gather). The builds overlap only on two or more
# threads, so a session with one thread runs this file again in a `julia -t 2`
# subprocess.

using Test
using EarthSciAST

include("testutils.jl")

_cb_sum(k, lo, hi, body) = Dict{String, Any}(
    "op" => "faq", "semiring" => "sum_product", "args" => Any[], "output_idx" => Any[],
    "ranges" => Dict{String, Any}(k => Any[lo, hi]), "expr" => body
)

# D(u[i]) = -r·u[i];  D(s) = Σ_k u[k]·x;  ic(s) = 2·s0.
function _cb_doc_state(N::Int)
    return Dict{String, Any}(
        "esm" => "2.0.0", "metadata" => Dict{String, Any}("name" => "CBState"),
        "models" => Dict{String, Any}(
            "A" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "u" => Dict{String, Any}("type" => "unknown", "shape" => Any["i"], "default" => 0.0),
                    "s" => Dict{String, Any}("type" => "unknown", "default" => 0.0),
                    "x" => Dict{String, Any}("type" => "parameter", "default" => 0.5),
                    "r" => Dict{String, Any}("type" => "parameter", "default" => 0.1),
                    "s0" => Dict{String, Any}("type" => "parameter", "default" => 3.0)
                ),
                "equations" => Any[
                    Dict{String, Any}(
                        "lhs" => Dict{String, Any}(
                            "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                            "ranges" => Dict{String, Any}("i" => Any[1, N]),
                            "expr" => jD(jidx("u", "i"))
                        ),
                        "rhs" => Dict{String, Any}(
                            "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                            "ranges" => Dict{String, Any}("i" => Any[1, N]),
                            "expr" => jop("*", jop("-", "r"), jidx("u", "i"))
                        )
                    ),
                    Dict{String, Any}(
                        "lhs" => jD("s"),
                        "rhs" => _cb_sum("k", 1, N, jop("*", jidx("u", "k"), "x"))
                    ),
                    Dict{String, Any}("lhs" => jop("ic", "s"), "rhs" => jop("*", "s0", 2.0)),
                ]
            )
        )
    )
end

# D(y) = k·Σ_m W[m]·y;  ic(y) = y0 + 1.
function _cb_doc_const(M::Int)
    W = Float64[(3m) % 11 for m in 1:M]
    return Dict{String, Any}(
        "esm" => "2.0.0", "metadata" => Dict{String, Any}("name" => "CBConst"),
        "models" => Dict{String, Any}(
            "B" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "y" => Dict{String, Any}("type" => "unknown", "default" => 0.0),
                    "k" => Dict{String, Any}("type" => "parameter", "default" => 1.5),
                    "y0" => Dict{String, Any}("type" => "parameter", "default" => 4.0)
                ),
                "equations" => Any[
                    Dict{String, Any}(
                        "lhs" => jD("y"),
                        "rhs" => jop(
                            "*", "k", _cb_sum(
                                "m", 1, M, jop(
                                    "*", jidx(
                                        Dict{String, Any}(
                                            "op" => "const", "args" => Any[], "value" => W
                                        ), "m"
                                    ), "y"
                                )
                            )
                        )
                    ),
                    Dict{String, Any}("lhs" => jop("ic", "y"), "rhs" => jop("+", "y0", 1.0)),
                ]
            )
        )
    )
end

_cb_bits(v::AbstractVector{Float64}) = reinterpret(UInt64, v)

# Everything the comparison holds a build to, as plain data.
function _cb_fingerprint(b)
    f!, u0, p, _t, vm, rep = b
    du1 = zeros(length(u0))
    f!(du1, u0, p, 0.3)
    u2 = u0 .+ 0.25 .* (1:length(u0))
    du2 = zeros(length(u0))
    f!(du2, u2, p, 1.7)
    return (
        u0 = collect(_cb_bits(u0)),
        du1 = collect(_cb_bits(du1)),
        du2 = collect(_cb_bits(du2)),
        layout = sort!([k => v for (k, v) in vm]),
        classes = sort!(collect(rep.products.param_classes)),
        tiers = [(r.rule, r.kind, r.tier) for r in rep.compiler_report.rules],
    )
end

function _cb_run()
    docs = (_cb_doc_state(24), _cb_doc_const(40))
    serial = map(d -> _cb_fingerprint(EarthSciAST.Internal.build(d)), docs)

    # The documents reach the state each piece of the context holds.
    @test serial[1].classes == ["A.r" => :numeric, "A.s0" => :structural, "A.x" => :numeric]
    @test serial[2].classes == ["B.k" => :numeric, "B.y0" => :structural]
    @test any(t -> t[1] == "A.s" && t[3] in (:scalar_loop_codegen, :scalar_loop), serial[1].tiers)
    @test any(t -> t[1] == "B.y" && t[3] in (:scalar_loop_codegen, :scalar_loop), serial[2].tiers)

    rounds = 25
    mismatches = 0
    for _ in 1:rounds
        tasks = [Threads.@spawn _cb_fingerprint(EarthSciAST.Internal.build(d)) for d in docs]
        got = fetch.(tasks)
        mismatches += count(i -> got[i] != serial[i], eachindex(docs))
    end
    @test mismatches == 0

    # Each document built twice at once against itself, too.
    for (i, d) in enumerate(docs)
        tasks = [Threads.@spawn _cb_fingerprint(EarthSciAST.Internal.build(d)) for _ in 1:4]
        @test all(==(serial[i]), fetch.(tasks))
    end
    return
end

if Threads.nthreads() >= 2
    @testset "concurrent builds" _cb_run()
else
    @testset "concurrent builds (julia -t 2 subprocess)" begin
        env = copy(ENV)
        env["JULIA_PROJECT"] = Base.active_project()
        args = if @isdefined _BATCH_TWO_THREAD_TESTS
            child = """
            using Test
            module ConcurrentBuildChecks end
            module CadenceRefreshChecks end
            @testset "two-thread build checks" begin
                Base.include(ConcurrentBuildChecks, ARGS[1])
                unset = [k => nothing for k in keys(ENV) if startswith(k, "ESS_")]
                withenv(unset..., "ESS_CR_CHILD" => "1", "ESS_THREADS_MIN_WORK" => "8") do
                    Base.include(CadenceRefreshChecks, ARGS[2])
                end
            end
            """
            ["-e", child, @__FILE__, joinpath(@__DIR__, "cadence_refresh_test.jl")]
        else
            [@__FILE__]
        end
        cmd = setenv(`$(Base.julia_cmd()) --startup-file=no -t 2 $args`, env)
        @test success(run(pipeline(ignorestatus(cmd); stdout = stdout, stderr = stderr)))
    end
end
