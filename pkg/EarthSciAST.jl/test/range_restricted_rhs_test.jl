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

# A 1-D periodic flux form on `nx` cells: the observed `F[i] = u[i]/2 - u[i-1]/4`
# (a zero ghost at `i = 1`) and `D(u[i]) = F[i+1] - F[i]`, wrapping by an
# explicit region at `i = nx`, so a tile across the seam reads `F` (and through
# it `u`) past the seam.
function _rrt_flux_doc(nx::Int)
    ix(v, i) = Dict("op" => "index", "args" => Any[v, i])
    sub(a, b) = Dict("op" => "-", "args" => Any[a, b])
    add(a, b) = Dict("op" => "+", "args" => Any[a, b])
    flux(c, w) = sub(Dict("op" => "*", "args" => Any[0.5, ix("u", c)]),
                     Dict("op" => "*", "args" => Any[0.25, ix("u", w)]))
    faq(e) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                  "ranges" => Dict("i" => Dict("from" => "x")), "expr" => e)
    ma(regions, values) = Dict("op" => "makearray", "args" => Any[], "regions" => regions,
                               "values" => values)
    F = faq(flux("i", sub("i", 1)))
    du = faq(ix(ma(Any[Any[Any[1, nx - 1]], Any[Any[nx, nx]]],
                   Any[sub(ix("F", add("i", 1)), ix("F", "i")), sub(ix("F", 1), ix("F", nx))]),
                "i"))
    lhs = faq(Dict("op" => "D", "args" => Any[ix("u", "i")], "wrt" => "t"))
    return Dict{String,Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "rrt_flux"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => nx)),
        "models" => Dict("Flux" => Dict(
            "variables" => Dict(
                "u" => Dict("type" => "unknown", "shape" => ["x"], "default" => 1.0),
                "F" => Dict("type" => "unknown", "shape" => ["x"])),
            "equations" => Any[Dict("lhs" => "F", "rhs" => F),
                               Dict("lhs" => lhs, "rhs" => du)])))
end

const _RRT_FIXTURES = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance",
                               "range_restricted_rhs", "fixtures")

# A whole-domain or tile program evaluated at a state that depends only on the
# slot, so two programs with one layout are fed the same state.
function _rrt_eval(x, p)
    L = tile_layout(x)
    u = 0.5 .+ (1:L.n_u) ./ (L.n_u + 1)
    aux = 0.25 .+ (1:L.n_aux) ./ (L.n_aux + 1)
    du = fill(NaN, L.n_u)
    rhs!(du, x, rhs_workspace(x), u, aux, p, 0.0)
    return du
end

_rrt_err(f) = try
    f()
    nothing
catch e
    e
end

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

    @testset "the program seed is built on the first rhs_program call" begin
        p2 = esm_problem(_rrt_doc(nx, ny), (0.0, 1.0))
        r = p2.inspection.program_seed
        @test r isa RRT._ProgramSeedRecipe
        @test r.memo[] === nothing
        @test !any(f -> getfield(r, f) isa RRT.FlattenedSystem, fieldnames(typeof(r)))
        pr = rhs_program(p2)
        @test r.memo[] !== nothing && r.memo[].flat isa RRT.FlattenedSystem
        @test rhs_program(p2).seed === pr.seed
        @test _rrt_bits.(_rrt_eval(pr, p2.p)) == _rrt_bits.(_rrt_eval(prog, prob.p))
    end

    @testset "rhs ranges clip by position when the index names differ" begin
        lhs = RRT.OpExpr("faq", RRT.ASTExpr[]; output_idx = Any["_mo0", "_mo1"],
                         ranges = Dict{String,Any}("_mo0" => Any[1, nx], "_mo1" => Any[1, ny]),
                         expr_body = RRT.OpExpr("D", RRT.ASTExpr[RRT.OpExpr("index",
                             RRT.ASTExpr[RRT.VarExpr("w"), RRT.VarExpr("_mo0"),
                                         RRT.VarExpr("_mo1")])]; wrt = "t"))
        body = RRT.OpExpr("index", RRT.ASTExpr[RRT.VarExpr("u"), RRT.VarExpr("a"),
                                                RRT.VarExpr("b")])
        rhs = RRT.OpExpr("faq", RRT.ASTExpr[]; output_idx = Any["b", "a"],
                         ranges = Dict{String,Any}("a" => Any[1, ny], "b" => Any[1, nx]),
                         expr_body = body)
        clips = Dict{String,Any}("_mo0" => Any[3, 5], "_mo1" => Any[2, 2])
        out = RRT._clip_rhs_ranges(rhs, ["_mo0", "_mo1"], clips)
        @test out.ranges["b"] == Any[3, 5] && out.ranges["a"] == Any[2, 2]
        # A lower-rank right-hand side keeps the left-hand loops it names.
        low = RRT.OpExpr("faq", RRT.ASTExpr[]; output_idx = Any["_mo1"],
                         ranges = Dict{String,Any}("_mo1" => Any[1, ny]), expr_body = body)
        out = RRT._clip_rhs_ranges(low, ["_mo0", "_mo1"], clips)
        @test out.ranges["_mo1"] == Any[2, 2]
    end

    @testset "a selection of a selection composes" begin
        TO = TermOrigin
        sprob = esm_problem(joinpath(_RRT_FIXTURES, "selection_two_operator.esm"), (0.0, 1.0))
        sp = rhs_program(sprob)
        chem = select(sp; terms = [TO(component = "Chem")])
        both = select(sp; terms = [TO(component = "Chem"), TO(component = "Adv")])
        adv = select(sp; terms = [TO(component = "Adv")])
        # terms intersect: {Chem, Adv} ∩ {Chem} is Chem, Adv ∩ Chem is nothing.
        @test _rrt_bits.(_rrt_eval(select(both; terms = [TO(component = "Chem")]), sprob.p)) ==
              _rrt_bits.(_rrt_eval(chem, sprob.p))
        @test all(==(0.0), _rrt_eval(select(adv; terms = [TO(component = "Chem")]), sprob.p))
        @test _rrt_bits.(_rrt_eval(select(adv; terms = :all), sprob.p)) ==
              _rrt_bits.(_rrt_eval(adv, sprob.p))
        # writes = :all is the program's own writes.
        no2 = select(sp; writes = ["Chem.NO2"], terms = [TO(coupling = 0)])
        @test [b.name for b in tile_layout(no2).aux] == ["Chem.O3"]
        @test [b.name for b in tile_layout(select(no2)).u] == ["Chem.NO2"]
        @test _rrt_bits.(_rrt_eval(select(no2), sprob.p)) ==
              _rrt_bits.(_rrt_eval(no2, sprob.p))
        # A variable the program only reads cannot be written.
        err = _rrt_err(() -> select(no2; writes = ["Chem.O3"]))
        @test err isa SimulateError && occursin("Chem.O3", err.msg)
        # Kept contributions to a variable left out of `writes` still raise.
        emis = select(sp; writes = ["Chem.NO2", "Chem.O3"], terms = [TO(coupling = 0)])
        err = _rrt_err(() -> select(emis; writes = ["Chem.O3"]))
        @test err isa SimulateError && err.code == "range_selection_writes_incomplete"
        @test occursin("Chem.NO2", err.msg)
    end

    @testset "workspaces share nothing mutable" begin
        tile = restrict(prog, dec; owned = ("x" => 1:4, "y" => 1:6),
                        storage = ("x" => 0:5, "y" => 0:7))
        w1, w2 = rhs_workspace(tile), rhs_workspace(tile)
        @test w1.f! === tile.f! && w2.f! !== w1.f!
        other = restrict(prog, dec; owned = ("x" => 5:10, "y" => 1:6),
                         storage = ("x" => 4:11, "y" => 0:7))
        T = tile_layout(tile)
        err = _rrt_err(() -> rhs!(zeros(T.n_u), tile, rhs_workspace(other), zeros(T.n_u),
                                  Float64[], prob.p, 0.0))
        @test err isa ArgumentError

        # Lanes: concurrent calls through one workspace per task agree bitwise
        # with one caller's.
        lprob = esm_problem(joinpath(_RRT_FIXTURES, "lanes_column.esm"), (0.0, 1.0))
        lp = lanes(rhs_program(lprob), :columns, ["lon", "lat"]; chunk = 4)
        LL = lane_layout(lp)
        all_cells = Int32[Int32(c[d]) for d in 1:2, c in vec(collect(Iterators.product(1:5, 1:4)))]
        batches = [all_cells[:, circshift(1:20, k)[1:8]] for k in 0:7]
        state(L, nper, k) = [0.5 + 0.001 * k + j / (nper * L + 1) for j in 1:(nper * L)]
        function run!(ws, k)
            cells = batches[mod1(k, length(batches))]
            du = fill(NaN, LL.n_u * 8)
            rhs!(du, lp, ws, state(8, LL.n_u, k), state(8, LL.n_aux, k), lprob.p, 0.0,
                 nothing, cells, 7)
            return du
        end
        ws0 = rhs_workspace(lp)
        nt = 4
        want = [_rrt_bits.(run!(ws0, k)) for k in 1:(40 + nt)]
        wss = [rhs_workspace(lp) for _ in 1:nt]
        @test wss[1].index_bufs[1] !== ws0.index_bufs[1] && wss[1].f! !== ws0.f!
        got = Vector{Any}(undef, nt)
        @sync for w in 1:nt
            Threads.@spawn begin
                got[w] = [_rrt_bits.(run!(wss[w], k + w)) for k in 1:40]
            end
        end
        @test all(w -> all(k -> got[w][k] == want[k + w], 1:40), 1:nt)
    end

    @testset "a tile across the periodic seam stores only its storage" begin
        bx = 64
        bprob = esm_problem(_rrt_doc(bx, ny), (0.0, 1.0))
        bprog = rhs_program(bprob)
        BL = tile_layout(bprog)
        bu = 0.5 .+ (1:BL.n_u) ./ BL.n_u
        BG = fill(NaN, BL.n_u)
        rhs!(BG, bprog, rhs_workspace(bprog), bu, Float64[], bprob.p, 0.0)
        bdec = Decomposition(axes = ["x" => (period = bx,), "y" => (period = nothing,)])
        for (xo, xs) in ((1:4, 0:5), (bx - 3:bx, (bx - 4):(bx + 1)), (1:2, -1:3))
            tile = restrict(bprog, bdec; owned = ("x" => xo, "y" => 1:ny),
                            storage = ("x" => xs, "y" => 0:(ny + 1)))
            # One slot per in-domain storage cell: the cells past the seam are
            # a block of their own, not the rest of the axis.
            @test length(tile.internal) == length(xs) * ny
            T = tile_layout(tile)
            b = only(T.u)
            uS = fill(NaN, T.n_u)
            for c in CartesianIndices(Tuple(b.storage))
                1 <= c[2] <= ny || continue
                uS[RRT._tile_slot(b, (c[1], c[2]))] = bu[(c[2] - 1) * bx + mod1(c[1], bx)]
            end
            duS = fill(NaN, T.n_u)
            rhs!(duS, tile, rhs_workspace(tile), uS, Float64[], bprob.p, 0.0)
            ok = true
            for c in CartesianIndices(Tuple(b.owned))
                ok &= _rrt_bits(duS[RRT._tile_slot(b, (c[1], c[2]))]) ==
                      _rrt_bits(BG[(c[2] - 1) * bx + c[1]])
            end
            @test ok
        end
    end

    @testset "an observed read past the seam is evaluated there" begin
        fx = 40
        fprob = esm_problem(_rrt_flux_doc(fx), (0.0, 1.0))
        fprog = rhs_program(fprob)
        FL = tile_layout(fprog)
        fu = 0.5 .+ (1:FL.n_u) ./ (FL.n_u + 7)
        FG = fill(NaN, FL.n_u)
        rhs!(FG, fprog, rhs_workspace(fprog), fu, Float64[], fprob.p, 0.0)
        fdec = Decomposition(axes = ["x" => (period = fx,)])
        @test halo(fprog, fdec) == Dict(("Flux.u", "x") => (1, 1))
        seen = zeros(Int, fx)
        for (xo, xs) in ((1:4, 0:5), (5:(fx - 4), 4:(fx - 3)), ((fx - 3):fx, (fx - 4):(fx + 1)))
            tile = restrict(fprog, fdec; owned = ("x" => xo,), storage = ("x" => xs,))
            @test length(tile.internal) <= length(xs)
            b = only(tile_layout(tile).u)
            uS = [fu[mod1(c, fx)] for c in xs]
            duS = fill(NaN, length(xs))
            rhs!(duS, tile, rhs_workspace(tile), uS, Float64[], fprob.p, 0.0)
            for c in xo
                seen[c] += _rrt_bits(duS[RRT._tile_slot(b, (c,))]) == _rrt_bits(FG[c])
            end
        end
        @test all(==(1), seen)
        # The last tile reads `F[1]`, and through it `u[1]`, past the seam.
        hi = restrict(fprog, fdec; owned = ("x" => (fx - 3):fx,),
                      storage = ("x" => (fx - 4):(fx + 1),))
        @test [(b.name, b.lo, b.hi) for b in RRT._layout_blocks(hi.internal)] ==
              [("Flux.u", [fx - 4], [fx]), ("__seam_1__Flux.u", [1], [1])]
    end
end
