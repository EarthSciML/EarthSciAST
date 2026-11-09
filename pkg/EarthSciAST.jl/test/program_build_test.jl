# `esm_problem(…; program_build = true)`: the Problem's right-hand side is its
# whole-model program, lowered once, and `rhs_program` returns that program.
# Its evaluations are the ones a program built the default way gives.

using Test
using Random
using EarthSciAST

_pbt_idx(v, ix...) = Dict("op" => "index", "args" => Any[v, ix...])
_pbt_op(op, args...) = Dict("op" => op, "args" => Any[args...])

# A 2-D diffusion `u` forced by a gridded `F` (a live buffer), and a 0-d `y`
# driven by one cell of `F` and a parameter.
function _pbt_doc(nx::Int, ny::Int)
    u(i, j) = _pbt_idx("u", i, j)
    lap = _pbt_op(
        "+", u(_pbt_op("-", "i", 1), "j"), u(_pbt_op("+", "i", 1), "j"),
        u("i", _pbt_op("-", "j", 1)), u("i", _pbt_op("+", "j", 1)),
        _pbt_op("*", -4, u("i", "j"))
    )
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y")),
        "expr" => e
    )
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "pbt"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => nx),
            "y" => Dict("kind" => "interval", "size" => ny)
        ),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x", "y"], "default" => 1.0),
                    "y" => Dict("type" => "unknown", "default" => 0.5),
                    "F" => Dict("type" => "parameter", "shape" => ["x", "y"]),
                    "k" => Dict("type" => "parameter", "default" => 0.25)
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => faq(Dict("op" => "D", "args" => Any[u("i", "j")], "wrt" => "t")),
                        "rhs" => faq(
                            _pbt_op(
                                "+", _pbt_op("*", "k", lap),
                                _pbt_op("*", _pbt_idx("F", "i", "j"), _pbt_op("exp", _pbt_op("*", -1, "t")))
                            )
                        )
                    ),
                    Dict(
                        "lhs" => _pbt_op("D", "y"),
                        "rhs" => _pbt_op("-", _pbt_op("*", "k", _pbt_idx("F", 2, 3)), "y")
                    ),
                ]
            )
        )
    )
end

_pbt_bits(x) = reinterpret(UInt64, x)

@testset "program_build" begin
    nx, ny = 7, 5
    F = reshape(collect(range(0.5, 2.0; length = nx * ny)), nx, ny)
    for c in (:native, :interpreter)
        @testset "$c" begin
            base = esm_problem(
                _pbt_doc(nx, ny), (0.0, 1.0); compiler = c,
                param_arrays = Dict("M.F" => copy(F))
            )
            shared = esm_problem(
                _pbt_doc(nx, ny), (0.0, 1.0); compiler = c,
                param_arrays = Dict("M.F" => copy(F)), program_build = true
            )
            prog0 = rhs_program(base)
            prog = rhs_program(shared)
            # The Problem holds its program: no second build.
            @test rhs_program(shared) === prog
            @test shared.f! === prog.f!

            @test shared.u0 == base.u0
            @test Dict(shared.var_map) == Dict(base.var_map)
            @test n_states(prog) == n_states(prog0)
            @test state_layout(prog) == state_layout(prog0)
            @test tile_layout(prog).n_aux == tile_layout(prog0).n_aux
            @test [s.name for s in parameters(prog)] == [s.name for s in parameters(prog0)]
            @test [(s.name, s.kind, s.shape) for s in forcing_slots(prog)] ==
                [(s.name, s.kind, s.shape) for s in forcing_slots(prog0)]

            rng = Xoshiro(7)
            n = n_states(prog)
            aux = zeros(tile_layout(prog).n_aux)
            ws, ws0 = rhs_workspace(prog), rhs_workspace(prog0)
            fs, fs0 = default_forcing_set(prog), default_forcing_set(prog0)
            pv, pv0 = parameter_vector(prog), parameter_vector(prog0)
            @test pv == pv0
            for t in (0.0, 0.3)
                u = 0.5 .+ rand(rng, n)
                du, du0 = zeros(n), zeros(n)
                rhs!(du, prog, ws, u, aux, pv, t, fs)
                rhs!(du0, prog0, ws0, u, aux, pv0, t, fs0)
                @test _pbt_bits.(du) == _pbt_bits.(du0)
                # The Problem's own `f!` evaluates the same right-hand side.
                dp, dp0 = zeros(n), zeros(n)
                shared.f!(dp, u, shared.p, t)
                base.f!(dp0, u, base.p, t)
                @test _pbt_bits.(dp) == _pbt_bits.(dp0)
            end
            if c === :native
                u = 0.5 .+ rand(rng, n)
                du = zeros(n)
                rhs!(du, prog, ws, u, aux, pv, 0.1, fs)
                @test (@allocated rhs!(du, prog, ws, u, aux, pv, 0.1, fs)) == 0
            end
            # A derived program still builds from the shared one's seed.
            sel = select(prog)
            sel0 = select(prog0)
            u = 0.5 .+ rand(rng, n)
            du, du0 = zeros(n), zeros(n)
            rhs!(du, sel, rhs_workspace(sel), u, aux, pv, 0.2, default_forcing_set(sel))
            rhs!(du0, sel0, rhs_workspace(sel0), u, aux, pv0, 0.2, default_forcing_set(sel0))
            @test _pbt_bits.(du) == _pbt_bits.(du0)
        end
    end
end
