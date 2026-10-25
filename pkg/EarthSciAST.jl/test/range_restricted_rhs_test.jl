# Range-restricted, operator-restricted right-hand sides (API_SPEC §5.8,
# issue #540): selection, halo, tiles and lanes on small documents built here.
# The manifest-driven suite is conformance_range_restricted_rhs_test.jl.

using Test
using EarthSciAST

const RRT = EarthSciAST

# A 2-D centered five-point stencil on an `nx × ny` grid, periodic in x by
# explicit wrap regions (cell 1 reads `u[nx, j]`, cell `nx` reads `u[1, j]`),
# with a zero ghost along y.
function _rrt_doc(nx::Int, ny::Int)
    u(i, j) = Dict("op" => "index", "args" => Any["u", i, j])
    plus(a, b) = Dict("op" => "+", "args" => Any[a, b])
    minus(a, b) = Dict("op" => "-", "args" => Any[a, b])
    lap(w, e) = Dict("op" => "+", "args" => Any[u(w, "j"), u(e, "j"),
                                                u("i", minus("j", 1)), u("i", plus("j", 1)),
                                                Dict("op" => "*", "args" => Any[-4, u("i", "j")])])
    ma = Dict("op" => "makearray", "args" => Any[],
              "regions" => Any[Any[Any[1, nx], Any[1, ny]], Any[Any[1, 1], Any[1, ny]],
                               Any[Any[nx, nx], Any[1, ny]]],
              "values" => Any[lap(minus("i", 1), plus("i", 1)), lap(nx, plus("i", 1)),
                              lap(minus("i", 1), 1)])
    faq(e) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
                  "ranges" => Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y")),
                  "expr" => e)
    lhs = faq(Dict("op" => "D", "args" => Any[u("i", "j")], "wrt" => "t"))
    rhs = faq(Dict("op" => "*", "args" => Any["k",
                   Dict("op" => "index", "args" => Any[ma, "i", "j"])]))
    return Dict{String,Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "rrt"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => nx),
                             "y" => Dict("kind" => "interval", "size" => ny)),
        "models" => Dict(
            "Diff" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x", "y"], "default" => 1.0),
                    "k" => Dict("type" => "parameter", "default" => 0.25)),
                "equations" => Any[Dict("lhs" => lhs, "rhs" => rhs)])))
end

_rrt_bits(x) = reinterpret(UInt64, x)

_rrt_allocated(du, x, ws, u, aux, p) = @allocated rhs!(du, x, ws, u, aux, p, 0.0)

@testset "range_restricted_rhs" begin
    nx, ny = 10, 6
    prob = esm_problem(_rrt_doc(nx, ny), (0.0, 1.0))
    prog = rhs_program(prob)
    L = tile_layout(prog)
    u = 0.5 .+ (1:L.n_u) ./ L.n_u
    G = fill(NaN, L.n_u)
    rhs!(G, prog, rhs_workspace(prog), u, Float64[], prob.p, 0.0)

    @testset "the whole-domain program is the Problem's right-hand side" begin
        du = similar(G)
        prob.f!(du, u, prob.p, 0.0)
        @test _rrt_bits.(du) == _rrt_bits.(G)
        @test [b.name for b in L.u] == ["Diff.u"]
        @test isempty(L.aux)
    end

    dec = Decomposition(axes = ["x" => (period = nx,), "y" => (period = nothing,)])

    @testset "halo" begin
        @test halo(prog, dec) == Dict(("Diff.u", "x") => (1, 1), ("Diff.u", "y") => (1, 1))
    end

    @testset "tiles partition G bitwise" begin
        seen = zeros(Int, L.n_u)
        for (xo, yo) in ((1:4, 1:3), (5:10, 1:3), (1:4, 4:6), (5:10, 4:6))
            xs, ys = (first(xo) - 1):(last(xo) + 1), (first(yo) - 1):(last(yo) + 1)
            tile = restrict(prog, dec; owned = ("x" => xo, "y" => yo),
                            storage = ("x" => xs, "y" => ys))
            T = tile_layout(tile)
            b = only(T.u)
            uS = fill(NaN, T.n_u)
            for c in CartesianIndices(Tuple(b.storage))
                gx, gy = c[1], c[2]
                1 <= gy <= ny || continue                 # dead halo stays NaN
                gx = mod1(gx, nx)                         # periodic image
                uS[RRT._tile_slot(b, (c[1], c[2]))] = u[(gy - 1) * nx + gx]
            end
            duS = fill(NaN, T.n_u)
            ws = rhs_workspace(tile)
            rhs!(duS, tile, ws, uS, Float64[], prob.p, 0.0)
            owned = Set{Int}()
            for c in CartesianIndices(Tuple(b.owned))
                s = RRT._tile_slot(b, (c[1], c[2]))
                push!(owned, s)
                g = (c[2] - 1) * nx + c[1]
                @test _rrt_bits(duS[s]) == _rrt_bits(G[g])
                seen[g] += 1
            end
            @test all(k -> k in owned || isnan(duS[k]), eachindex(duS))
            noaux = Float64[]
            _rrt_allocated(duS, tile, ws, uS, noaux, prob.p)
            @test _rrt_allocated(duS, tile, ws, uS, noaux, prob.p) == 0
        end
        @test all(==(1), seen)
    end

    @testset "refusals" begin
        err = try
            restrict(prog, dec; owned = ("x" => 3:5, "y" => 2:4), storage = ("x" => 3:6, "y" => 1:5))
        catch e
            e
        end
        @test err isa SimulateError && err.code == "range_halo_insufficient"
        @test occursin("Diff.u", err.msg) && occursin("'x'", err.msg)
        err = try
            restrict(prog, dec; owned = ("x" => 0:4, "y" => 1:6), storage = ("x" => -1:5, "y" => 0:7))
        catch e
            e
        end
        @test err isa SimulateError && err.code == "range_box_invalid"
        err = try
            halo(prog, Decomposition(axes = ["x" => (period = 7,)]))
        catch e
            e
        end
        @test err isa SimulateError && err.code == "range_box_invalid"
        # A cell lane reads its neighbours: refused by name.
        err = try
            lanes(prog, :cells, ["x", "y"])
        catch e
            e
        end
        @test err isa RRT.EarthSciASTError && err.code == "compiler_refused_rule"
        @test occursin("lane", sprint(showerror, err))
    end

    @testset "native only" begin
        iprob = esm_problem(_rrt_doc(nx, ny), (0.0, 1.0); compiler = :interpreter)
        iprog = rhs_program(iprob)
        du = fill(NaN, L.n_u)
        rhs!(du, iprog, rhs_workspace(iprog), u, Float64[], iprob.p, 0.0)
        @test _rrt_bits.(du) == _rrt_bits.(G)
        for f in (() -> halo(iprog, dec),
                  () -> restrict(iprog, dec; owned = ("x" => 1:4, "y" => 1:6),
                                 storage = ("x" => 0:5, "y" => 0:7)),
                  () -> lanes(iprog, :cells, ["x", "y"]))
            err = try
                f()
            catch e
                e
            end
            @test err isa SimulateError && err.code == "compiler_unavailable"
        end
    end

    @testset "selection" begin
        TO = TermOrigin
        sel = select(prog; terms = [TO(component = "Diff")])
        du = fill(NaN, L.n_u)
        rhs!(du, sel, rhs_workspace(sel), u, Float64[], prob.p, 0.0)
        @test _rrt_bits.(du) == _rrt_bits.(G)
        zero = select(prog; terms = [TO(component = "Nobody")])
        rhs!(du, zero, rhs_workspace(zero), u, Float64[], prob.p, 0.0)
        @test all(==(0.0), du)
        err = try
            select(prog; writes = String[], terms = :all)
        catch e
            e
        end
        @test err isa SimulateError && err.code == "range_selection_writes_incomplete"
        @test occursin("Diff.u", err.msg)
    end
end
