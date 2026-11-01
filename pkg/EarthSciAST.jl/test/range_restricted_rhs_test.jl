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
    lap(w, e) = Dict(
        "op" => "+", "args" => Any[
            u(w, "j"), u(e, "j"),
            u("i", minus("j", 1)), u("i", plus("j", 1)),
            Dict("op" => "*", "args" => Any[-4, u("i", "j")]),
        ]
    )
    ma = Dict(
        "op" => "makearray", "args" => Any[],
        "regions" => Any[
            Any[Any[1, nx], Any[1, ny]], Any[Any[1, 1], Any[1, ny]],
            Any[Any[nx, nx], Any[1, ny]],
        ],
        "values" => Any[
            lap(minus("i", 1), plus("i", 1)), lap(nx, plus("i", 1)),
            lap(minus("i", 1), 1),
        ]
    )
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y")),
        "expr" => e
    )
    lhs = faq(Dict("op" => "D", "args" => Any[u("i", "j")], "wrt" => "t"))
    rhs = faq(
        Dict(
            "op" => "*", "args" => Any[
                "k",
                Dict("op" => "index", "args" => Any[ma, "i", "j"]),
            ]
        )
    )
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "rrt"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => nx),
            "y" => Dict("kind" => "interval", "size" => ny)
        ),
        "models" => Dict(
            "Diff" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x", "y"], "default" => 1.0),
                    "k" => Dict("type" => "parameter", "default" => 0.25)
                ),
                "equations" => Any[Dict("lhs" => lhs, "rhs" => rhs)]
            )
        )
    )
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
    flux(c, w) = sub(
        Dict("op" => "*", "args" => Any[0.5, ix("u", c)]),
        Dict("op" => "*", "args" => Any[0.25, ix("u", w)])
    )
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict("i" => Dict("from" => "x")), "expr" => e
    )
    ma(regions, values) = Dict(
        "op" => "makearray", "args" => Any[], "regions" => regions,
        "values" => values
    )
    F = faq(flux("i", sub("i", 1)))
    du = faq(
        ix(
            ma(
                Any[Any[Any[1, nx - 1]], Any[Any[nx, nx]]],
                Any[sub(ix("F", add("i", 1)), ix("F", "i")), sub(ix("F", 1), ix("F", nx))]
            ),
            "i"
        )
    )
    lhs = faq(Dict("op" => "D", "args" => Any[ix("u", "i")], "wrt" => "t"))
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "rrt_flux"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => nx)),
        "models" => Dict(
            "Flux" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x"], "default" => 1.0),
                    "F" => Dict("type" => "unknown", "shape" => ["x"])
                ),
                "equations" => Any[
                    Dict("lhs" => "F", "rhs" => F),
                    Dict("lhs" => lhs, "rhs" => du),
                ]
            )
        )
    )
end

# A 1-D diffusion on `nx` cells (zero ghosts) plus `Σ_k W[i,k]·k` over a
# shaped parameter `W`: the sum reads only build-time data, so the affine tier
# evaluates it into a per-box table of values.
function _rrt_table_doc(nx::Int)
    u(i) = Dict("op" => "index", "args" => Any["u", i])
    add(a, b) = Dict("op" => "+", "args" => Any[a, b])
    sub(a, b) = Dict("op" => "-", "args" => Any[a, b])
    mul(a...) = Dict("op" => "*", "args" => Any[a...])
    agg = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any[],
        "ranges" => Dict("k" => Any[1, 3]),
        "expr" => mul(Dict("op" => "index", "args" => Any["W", "i", "k"]), "k")
    )
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict("i" => Dict("from" => "x")), "expr" => e
    )
    lhs = faq(Dict("op" => "D", "args" => Any[u("i")], "wrt" => "t"))
    rhs = faq(add(mul(0.25, add(u(sub("i", 1)), add(mul(-2, u("i")), u(add("i", 1))))), agg))
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "rrt_table"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => nx),
            "kk" => Dict("kind" => "interval", "size" => 3)
        ),
        "models" => Dict(
            "Tbl" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x"], "default" => 1.0),
                    "W" => Dict(
                        "type" => "parameter", "shape" => ["x", "kk"],
                        "default" => [
                            [sin(1.7 * i * k) + 0.05 * i for k in 1:3]
                                for i in 1:nx
                        ]
                    )
                ),
                "equations" => Any[Dict("lhs" => lhs, "rhs" => rhs)]
            )
        )
    )
end

# A 1-D document whose tile build takes every path that could cost the whole
# domain: clamped (not structurally affine) state and const subscripts, a
# shaped parameter with an inline default, one with a scalar default, and a
# const read out of range under a guard.
function _rrt_paths_doc(nx::Int)
    ix(v, a...) = Dict("op" => "index", "args" => Any[v, a...])
    op(o, a...) = Dict("op" => o, "args" => Any[a...])
    u(i) = ix("u", i)
    agg = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any[],
        "ranges" => Dict("k" => Any[1, 3]),
        "expr" => op("*", ix("W", "i", "k"), "k")
    )
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict("i" => Dict("from" => "x")), "expr" => e
    )
    lap = op(
        "+", u(op("max", op("-", "i", 1), 1)), op("*", -2, u("i")),
        u(op("min", op("+", "i", 1), nx))
    )
    rhs = faq(
        op(
            "+", op("*", 0.25, lap), agg, ix("c", op("max", "i", 2)), ix("S", "i"),
            op("ifelse", op("<", "i", nx), ix("g", op("+", "i", 1)), 0)
        )
    )
    lhs = faq(Dict("op" => "D", "args" => Any[u("i")], "wrt" => "t"))
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "rrt_paths"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => nx),
            "kk" => Dict("kind" => "interval", "size" => 3)
        ),
        "models" => Dict(
            "Paths" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x"], "default" => 1.0),
                    "W" => Dict(
                        "type" => "parameter", "shape" => ["x", "kk"],
                        "default" => [
                            [sin(1.7 * i * k) + 0.05 * i for k in 1:3]
                                for i in 1:nx
                        ]
                    ),
                    "c" => Dict(
                        "type" => "parameter", "shape" => ["x"],
                        "default" => [cos(0.3 * i) for i in 1:nx]
                    ),
                    "g" => Dict(
                        "type" => "parameter", "shape" => ["x"],
                        "default" => [0.01 * i for i in 1:nx]
                    ),
                    "S" => Dict("type" => "parameter", "shape" => ["x"], "default" => 2.0)
                ),
                "equations" => Any[Dict("lhs" => lhs, "rhs" => rhs)]
            )
        )
    )
end

# An outflow along x on an `nx × ny` grid as three equations, one per region
# (the faces `i = 1` and `i = nx` and the interior), over the observed flux
# `F[i,j] = u[i,j]/2 - u[i-1,j]/4` (a zero ghost at `i = 1`), which the build
# materializes into a buffer of its own; the face `i = nx` also reads two fixed
# cells, `u[1,1]·u[2,1]`. A tile that owns no cell of a face keeps that face's
# equation over no cells.
function _rrt_faces_doc(nx::Int, ny::Int)
    ix(v, i) = Dict("op" => "index", "args" => Any[v, i, "j"])
    fx(i) = Dict("op" => "index", "args" => Any["u", i, 1])
    op(o, a...) = Dict("op" => o, "args" => Any[a...])
    faq(lo, hi, e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Any[lo, hi], "j" => Any[1, ny]), "expr" => e
    )
    D(lo, hi) = faq(lo, hi, Dict("op" => "D", "args" => Any[ix("u", "i")], "wrt" => "t"))
    F = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y")),
        "expr" => op(
            "-", op("*", 0.5, ix("u", "i")),
            op("*", 0.25, ix("u", op("-", "i", 1)))
        )
    )
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "rrt_faces"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => nx),
            "y" => Dict("kind" => "interval", "size" => ny)
        ),
        "models" => Dict(
            "Faces" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x", "y"], "default" => 1.0),
                    "F" => Dict("type" => "unknown", "shape" => ["x", "y"])
                ),
                "equations" => Any[
                    Dict("lhs" => "F", "rhs" => F),
                    Dict(
                        "lhs" => D(1, 1),
                        "rhs" => faq(1, 1, op("-", ix("F", op("+", "i", 1)), op("*", 2, ix("F", "i"))))
                    ),
                    Dict(
                        "lhs" => D(2, nx - 1),
                        "rhs" => faq(2, nx - 1, op("-", ix("F", op("+", "i", 1)), ix("F", "i")))
                    ),
                    Dict(
                        "lhs" => D(nx, nx),
                        "rhs" => faq(nx, nx, op("-", op("*", fx(1), fx(2)), ix("F", "i")))
                    ),
                ]
            )
        )
    )
end

const _RRT_FIXTURES = joinpath(
    @__DIR__, "..", "..", "..", "tests", "conformance",
    "range_restricted_rhs", "fixtures"
)

# A whole-domain or tile program evaluated at a state that depends only on the
# slot, so two programs with one layout are fed the same state.
function _rrt_eval(x, p)
    L = tile_layout(x)
    u = 0.5 .+ (1:L.n_u) ./ (L.n_u + 1)
    aux = 0.25 .+ (1:L.n_aux) ./ (L.n_aux + 1)
    du = fill(NaN, L.n_u)
    rhs!(du, x, rhs_workspace(x), u, aux, p, 0.0, default_forcing_set(x))
    return du
end

_rrt_err(f) = try
    f()
    nothing
catch e
    e
end

_rrt_allocated(du, x, ws, u, aux, p, fs) = @allocated rhs!(du, x, ws, u, aux, p, 0.0, fs)

# The expressions of every generated function a program holds.
function _rrt_generated(x, acc = Set{String}(), seen = Set{UInt}())
    RGF = RRT.RuntimeGeneratedFunctions
    x isa RGF.RuntimeGeneratedFunction && (push!(acc, string(RGF.get_expression(x))); return acc)
    (x isa Module || x isa DataType || x isa String || x isa Symbol || isbits(x)) && return acc
    objectid(x) in seen && return acc
    push!(seen, objectid(x))
    if x isa AbstractArray || x isa Tuple || x isa AbstractDict || x isa AbstractSet
        foreach(v -> _rrt_generated(v, acc, seen), x isa AbstractDict ? values(x) : x)
        return acc
    end
    for f in fieldnames(typeof(x))
        isdefined(x, f) && _rrt_generated(getfield(x, f), acc, seen)
    end
    return acc
end

# How many numbers a program holds (its tables, its geometry, its constants).
function _rrt_data(x, n = Ref(0), seen = IdDict{Any, Nothing}())
    (x isa Module || x isa DataType || x isa String || x isa Symbol || isbits(x)) && return n[]
    haskey(seen, x) && return n[]
    seen[x] = nothing
    if x isa AbstractArray && eltype(x) <: Number
        n[] += length(x)
    elseif x isa AbstractArray || x isa Tuple || x isa AbstractDict || x isa AbstractSet
        foreach(v -> _rrt_data(v, n, seen), x isa AbstractDict ? values(x) : x)
    else
        for f in fieldnames(typeof(x))
            isdefined(x, f) && _rrt_data(getfield(x, f), n, seen)
        end
    end
    return n[]
end

# A tile of the program `prog` of a non-periodic 1-D document (or a 2-D one,
# `ny` cells along its uncut y), owned `o` with storage `st` along x, checked
# bitwise against `prog` at a state that depends only on the cell; returns the
# tile's generated code.
function _rrt_tile_code(prog, p, o, st; ny = nothing)
    n = tile_layout(prog).n_u
    nx = ny === nothing ? n : n ÷ ny
    g(c) = ny === nothing ? c[1] : (c[2] - 1) * nx + c[1]
    val(c) = 0.5 + g(c) / (n + 1)
    box(r) = ny === nothing ? ("x" => r,) : ("x" => r, "y" => 1:ny)
    tdec = Decomposition(
        axes = ny === nothing ? ["x" => (period = nothing,)] :
            ["x" => (period = nothing,), "y" => (period = nothing,)]
    )
    t = restrict(prog, tdec; owned = box(o), storage = box(st))
    b = only(tile_layout(t).u)
    uS = fill(NaN, tile_layout(t).n_u)
    for c in CartesianIndices(Tuple(b.storage))
        1 <= c[1] <= nx && (uS[RRT._tile_slot(b, Tuple(c))] = val(c))
    end
    duS = fill(NaN, length(uS))
    rhs!(duS, t, rhs_workspace(t), uS, Float64[], p, 0.0, default_forcing_set(t))
    uW = [val(Tuple(c)) for c in CartesianIndices(Tuple(only(tile_layout(prog).u).storage))]
    W = fill(NaN, n)
    rhs!(W, prog, rhs_workspace(prog), vec(uW), Float64[], p, 0.0, default_forcing_set(prog))
    @test all(
        c -> _rrt_bits(duS[RRT._tile_slot(b, Tuple(c))]) == _rrt_bits(W[g(c)]),
        CartesianIndices(Tuple(b.owned))
    )
    return _rrt_generated(t.f!)
end

@testset "range_restricted_rhs" begin
    nx, ny = 10, 6
    prob = esm_problem(_rrt_doc(nx, ny), (0.0, 1.0))
    prog = rhs_program(prob)
    L = tile_layout(prog)
    u = 0.5 .+ (1:L.n_u) ./ L.n_u
    G = fill(NaN, L.n_u)
    fs = default_forcing_set(prog)
    rhs!(G, prog, rhs_workspace(prog), u, Float64[], prob.p, 0.0, fs)

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
            tile = restrict(
                prog, dec; owned = ("x" => xo, "y" => yo),
                storage = ("x" => xs, "y" => ys)
            )
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
            rhs!(duS, tile, ws, uS, Float64[], prob.p, 0.0, fs)
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
            _rrt_allocated(duS, tile, ws, uS, noaux, prob.p, fs)
            @test _rrt_allocated(duS, tile, ws, uS, noaux, prob.p, fs) == 0
        end
        @test all(==(1), seen)
    end

    @testset "tiles share their code" begin
        # Tiles that own different region classes (the wrap columns at x = 1
        # and x = nx are owned by neither) and whose storage stays off the
        # seam emit the same code, and agree with the whole-domain program
        # bitwise. The whole-domain program keeps the optimizations a sharing
        # tile gives up: it emits what the Problem's own build emits.
        @test _rrt_generated(prog.f!) == _rrt_generated(prob.f!)
        codes = Set{String}[]
        for (xo, yo) in ((2:4, 1:3), (5:9, 4:6), (3:3, 2:5))
            xs, ys = (first(xo) - 1):(last(xo) + 1), (first(yo) - 1):(last(yo) + 1)
            tile = restrict(
                prog, dec; owned = ("x" => xo, "y" => yo),
                storage = ("x" => xs, "y" => ys)
            )
            push!(codes, _rrt_generated(tile.f!))
            b = only(tile_layout(tile).u)
            uS = fill(NaN, tile_layout(tile).n_u)
            for c in CartesianIndices(Tuple(b.storage))
                1 <= c[2] <= ny || continue
                uS[RRT._tile_slot(b, (c[1], c[2]))] = u[(c[2] - 1) * nx + c[1]]
            end
            duS = fill(NaN, length(uS))
            rhs!(
                duS, tile, rhs_workspace(tile), uS, Float64[], prob.p, 0.0,
                default_forcing_set(tile)
            )
            for c in CartesianIndices(Tuple(b.owned))
                @test _rrt_bits(duS[RRT._tile_slot(b, (c[1], c[2]))]) ==
                    _rrt_bits(G[(c[2] - 1) * nx + c[1]])
            end
        end
        @test !isempty(codes[1]) && all(==(codes[1]), codes)
        # Once decomposed, the program evaluates a new workspace through the
        # code its tiles share, to the same values, allocation-free.
        alt = RRT._decomposed_form(prog)
        @test alt isa RRT.TileProgram && _rrt_generated(alt.f!) == codes[1]
        ws2 = rhs_workspace(prog)
        du2 = fill(NaN, L.n_u)
        rhs!(du2, prog, ws2, u, Float64[], prob.p, 0.0, fs)
        @test _rrt_bits.(du2) == _rrt_bits.(G)
        noaux = Float64[]
        _rrt_allocated(du2, prog, ws2, u, noaux, prob.p, fs)
        @test _rrt_allocated(du2, prog, ws2, u, noaux, prob.p, fs) == 0
    end

    @testset "a tile emits a box it runs no cell of as every tile does" begin
        # Per-region equations (two faces and the interior) over a flux the
        # build materializes into its own buffer: the second tile owns no cell
        # of either face, so it keeps both face equations over no cells, and
        # reads the flux buffer there as the tile that owns a face does. Its
        # storage holds neither fixed cell `u[1,1]` nor `u[2,1]`, so both land
        # on one slot of its block, yet stay two reads, as in the first tile,
        # which stores them.
        fprob = esm_problem(_rrt_faces_doc(10, 4), (0.0, 1.0))
        fprog = rhs_program(fprob)
        codes = [
            _rrt_tile_code(fprog, fprob.p, o, st; ny = 4)
                for (o, st) in ((1:3, 0:4), (4:7, 3:8))
        ]
        @test all(==(codes[1]), codes)
    end

    @testset "a tile's build does not grow with the domain" begin
        # The per-box table of the tile's one owned box covers only the cells
        # it runs, so a tile of the same cells holds the same data at every
        # domain size, while the whole-domain program's grows with it; and it
        # emits the same code at every domain size.
        tdec = Decomposition(axes = ["x" => (period = nothing,)])
        whole, tile, codes = Int[], Int[], Set{String}[]
        for tx in (40, 400)
            tprob = esm_problem(_rrt_table_doc(tx), (0.0, 1.0))
            tprog = rhs_program(tprob)
            t = restrict(tprog, tdec; owned = ("x" => 11:14,), storage = ("x" => 10:15,))
            push!(codes, _rrt_tile_code(tprog, tprob.p, 11:14, 10:15))
            push!(whole, _rrt_data(tprog.f!))
            push!(tile, _rrt_data(t.f!))
        end
        @test whole[2] > whole[1] + 300
        @test tile[2] == tile[1]
        @test codes[2] == codes[1]
        # Every step of a tile's build that could cost the whole domain: box
        # checks of subscripts that are not structurally affine (a clamped
        # state and const subscript), a const read out of range under a
        # guard, and shaped parameters with an inline or a scalar default. A
        # tile reuses what its program's build worked out, so what its build
        # allocates grows by less than one number per added cell. A single
        # `@allocated` sample varies by a few KB from run to run, so each size
        # takes the smallest of several, and the sizes are far enough apart
        # that a fixed difference cannot pass for per-cell growth.
        alloc = Int[]
        for tx in (40, 4000)
            tprob = esm_problem(_rrt_paths_doc(tx), (0.0, 1.0))
            tprog = rhs_program(tprob)
            tx == 40 ? _rrt_tile_code(tprog, tprob.p, 11:14, 10:15) :
                restrict(tprog, tdec; owned = ("x" => 11:14,), storage = ("x" => 10:15,))
            push!(
                alloc, minimum(
                    @allocated(
                        restrict(
                            tprog, tdec; owned = ("x" => 11:14,),
                            storage = ("x" => 10:15,)
                        )
                    ) for _ in 1:5
                )
            )
        end
        @test alloc[2] - alloc[1] < 8 * (4000 - 40)
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
        rhs!(
            du, iprog, rhs_workspace(iprog), u, Float64[], iprob.p, 0.0,
            default_forcing_set(iprog)
        )
        @test _rrt_bits.(du) == _rrt_bits.(G)
        for f in (
                () -> halo(iprog, dec),
                () -> restrict(
                    iprog, dec; owned = ("x" => 1:4, "y" => 1:6),
                    storage = ("x" => 0:5, "y" => 0:7)
                ),
                () -> lanes(iprog, :cells, ["x", "y"]),
            )
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
        rhs!(du, sel, rhs_workspace(sel), u, Float64[], prob.p, 0.0, fs)
        @test _rrt_bits.(du) == _rrt_bits.(G)
        zero = select(prog; terms = [TO(component = "Nobody")])
        rhs!(du, zero, rhs_workspace(zero), u, Float64[], prob.p, 0.0, fs)
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
        lhs = RRT.OpExpr(
            "faq", RRT.ASTExpr[]; output_idx = Any["_mo0", "_mo1"],
            ranges = Dict{String, Any}("_mo0" => Any[1, nx], "_mo1" => Any[1, ny]),
            expr_body = RRT.OpExpr(
                "D", RRT.ASTExpr[
                    RRT.OpExpr(
                        "index",
                        RRT.ASTExpr[
                            RRT.VarExpr("w"), RRT.VarExpr("_mo0"),
                            RRT.VarExpr("_mo1"),
                        ]
                    ),
                ]; wrt = "t"
            )
        )
        body = RRT.OpExpr(
            "index", RRT.ASTExpr[
                RRT.VarExpr("u"), RRT.VarExpr("a"),
                RRT.VarExpr("b"),
            ]
        )
        rhs = RRT.OpExpr(
            "faq", RRT.ASTExpr[]; output_idx = Any["b", "a"],
            ranges = Dict{String, Any}("a" => Any[1, ny], "b" => Any[1, nx]),
            expr_body = body
        )
        clips = Dict{String, Any}("_mo0" => Any[3, 5], "_mo1" => Any[2, 2])
        out = RRT._clip_rhs_ranges(rhs, ["_mo0", "_mo1"], clips)
        @test out.ranges["b"] == Any[3, 5] && out.ranges["a"] == Any[2, 2]
        # A lower-rank right-hand side keeps the left-hand loops it names.
        low = RRT.OpExpr(
            "faq", RRT.ASTExpr[]; output_idx = Any["_mo1"],
            ranges = Dict{String, Any}("_mo1" => Any[1, ny]), expr_body = body
        )
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
        tile = restrict(
            prog, dec; owned = ("x" => 1:4, "y" => 1:6),
            storage = ("x" => 0:5, "y" => 0:7)
        )
        w1, w2 = rhs_workspace(tile), rhs_workspace(tile)
        @test w1.f! !== tile.f! && w2.f! !== w1.f!
        other = restrict(
            prog, dec; owned = ("x" => 5:10, "y" => 1:6),
            storage = ("x" => 4:11, "y" => 0:7)
        )
        T = tile_layout(tile)
        err = _rrt_err(
            () -> rhs!(
                zeros(T.n_u), tile, rhs_workspace(other), zeros(T.n_u),
                Float64[], prob.p, 0.0, default_forcing_set(tile)
            )
        )
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
            rhs!(
                du, lp, ws, state(8, LL.n_u, k), state(8, LL.n_aux, k), lprob.p, 0.0,
                default_forcing_set(lp), cells, 7
            )
            return du
        end
        ws0 = rhs_workspace(lp)
        nt = 4
        want = [_rrt_bits.(run!(ws0, k)) for k in 1:(40 + nt)]
        wss = [rhs_workspace(lp) for _ in 1:nt]
        @test wss[1].lbufs[1] !== ws0.lbufs[1] && wss[1].f! !== ws0.f!
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
        rhs!(
            BG, bprog, rhs_workspace(bprog), bu, Float64[], bprob.p, 0.0,
            default_forcing_set(bprog)
        )
        bdec = Decomposition(axes = ["x" => (period = bx,), "y" => (period = nothing,)])
        for (xo, xs) in ((1:4, 0:5), ((bx - 3):bx, (bx - 4):(bx + 1)), (1:2, -1:3))
            tile = restrict(
                bprog, bdec; owned = ("x" => xo, "y" => 1:ny),
                storage = ("x" => xs, "y" => 0:(ny + 1))
            )
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
            rhs!(
                duS, tile, rhs_workspace(tile), uS, Float64[], bprob.p, 0.0,
                default_forcing_set(tile)
            )
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
        rhs!(
            FG, fprog, rhs_workspace(fprog), fu, Float64[], fprob.p, 0.0,
            default_forcing_set(fprog)
        )
        fdec = Decomposition(axes = ["x" => (period = fx,)])
        @test halo(fprog, fdec) == Dict(("Flux.u", "x") => (1, 1))
        seen = zeros(Int, fx)
        for (xo, xs) in ((1:4, 0:5), (5:(fx - 4), 4:(fx - 3)), ((fx - 3):fx, (fx - 4):(fx + 1)))
            tile = restrict(fprog, fdec; owned = ("x" => xo,), storage = ("x" => xs,))
            @test length(tile.internal) <= length(xs)
            b = only(tile_layout(tile).u)
            uS = [fu[mod1(c, fx)] for c in xs]
            duS = fill(NaN, length(xs))
            rhs!(
                duS, tile, rhs_workspace(tile), uS, Float64[], fprob.p, 0.0,
                default_forcing_set(tile)
            )
            for c in xo
                seen[c] += _rrt_bits(duS[RRT._tile_slot(b, (c,))]) == _rrt_bits(FG[c])
            end
        end
        @test all(==(1), seen)
        # The last tile reads `F[1]`, and through it `u[1]`, past the seam.
        hi = restrict(
            fprog, fdec; owned = ("x" => (fx - 3):fx,),
            storage = ("x" => (fx - 4):(fx + 1),)
        )
        @test [(b.name, b.lo, b.hi) for b in RRT._layout_blocks(hi.internal)] ==
            [("Flux.u", [fx - 4], [fx]), ("__seam_1__Flux.u", [1], [1])]
    end
end
