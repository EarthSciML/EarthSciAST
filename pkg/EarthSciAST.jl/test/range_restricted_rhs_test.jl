# Range-restricted, operator-restricted right-hand sides (API_SPEC §5.8,
# issue #540): selection, halo, tiles and lanes on small documents built here.
# The manifest-driven suite is conformance_range_restricted_rhs_test.jl.

using Test
include("testutils.jl")
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
        "esm" => "2.0.0",
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
        "esm" => "2.0.0",
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
        "esm" => "2.0.0",
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
        "esm" => "2.0.0",
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
        "esm" => "2.0.0",
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

# A 1-D periodic three-point stencil on `nx` cells reached as a rule template
# (`D(q, wrt: x)` fires `Lper`, whose makearray body is read through its
# view): the boundary cells read across the wrap inside template bodies, under
# a condition so the reads stay in the body (no lane the caller makes) —
# `lap_lo` directly, `lap_hi` through a nested reference to `wrap_hi`.
function _rrt_tpl_seam_doc(nx::Int)
    pin(f, at) = Dict("op" => "index", "args" => Any[f, at])
    off(k) = k == 0 ? "i" : Dict("op" => (k > 0 ? "+" : "-"), "args" => Any["i", abs(k)])
    lap3(a, b, c) = Dict("op" => "+", "args" => Any[a, Dict("op" => "*", "args" => Any[-2, b]), c])
    ref(name) = Dict(
        "op" => "apply_operator", "args" => Any[], "name" => name,
        "bindings" => Dict("f" => "f")
    )
    elem(r, e) = Dict(
        "op" => "faq", "output_idx" => Any["i"], "args" => Any["f"],
        "ranges" => Dict("i" => r), "expr" => e
    )
    gt(a) = Dict("op" => ">", "args" => Any[a, 0.9])
    tpl = Dict(
        "lap_int" => Dict(
            "params" => ["f"],
            "body" => elem(Any[2, nx - 1], lap3(pin("f", off(-1)), pin("f", off(0)), pin("f", off(1))))
        ),
        "lap_lo" => Dict(
            "params" => ["f"],
            "body" => elem(
                Any[1, 1], Dict(
                    "op" => "ifelse", "args" => Any[
                        gt(pin("f", 1)), lap3(pin("f", nx), pin("f", 1), pin("f", 2)), pin("f", nx),
                    ]
                )
            )
        ),
        "wrap_hi" => Dict(
            "params" => ["f"],
            "body" => lap3(pin("f", nx - 1), pin("f", nx), pin("f", 1))
        ),
        "lap_hi" => Dict(
            "params" => ["f"],
            "body" => elem(
                Any[nx, nx], Dict(
                    "op" => "ifelse", "args" => Any[gt(pin("f", nx)), ref("wrap_hi"), pin("f", nx)]
                )
            )
        ),
        "Lper" => Dict(
            "params" => ["f"],
            "match" => Dict("op" => "D", "args" => ["f"], "wrt" => "x"),
            "body" => Dict(
                "op" => "makearray", "args" => Any[],
                "regions" => Any[Any[Any[2, nx - 1]], Any[Any[1, 1]], Any[Any[nx, nx]]],
                "values" => Any[ref("lap_int"), ref("lap_lo"), ref("lap_hi")]
            )
        ),
    )
    return Dict{String, Any}(
        "esm" => "2.0.0",
        "metadata" => Dict("name" => "rrt_tpl_seam"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => nx)),
        "models" => Dict(
            "T" => Dict(
                "operators" => tpl,
                "variables" => Dict(
                    "q" => Dict("type" => "unknown", "shape" => ["x"], "default" => 1.5),
                    "k" => Dict("type" => "parameter", "default" => 0.25)
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => Dict("op" => "D", "args" => ["q"], "wrt" => "t"),
                        "rhs" => Dict(
                            "op" => "*",
                            "args" => Any["k", Dict("op" => "D", "args" => ["q"], "wrt" => "x")]
                        )
                    ),
                ]
            )
        )
    )
end

# `_rrt_tpl_seam_doc` with the stencil applied to the OBSERVED
# `w[i] = q[i]·q[i] + 1/8` instead of the state: the rule binds the template's
# array parameter to `w`, so each boundary body reads `w` across the wrap (one
# directly, one through a nested reference).
function _rrt_tpl_seam_obs_doc(nx::Int)
    d = _rrt_tpl_seam_doc(nx)
    m = d["models"]["T"]
    q(i) = Dict("op" => "index", "args" => Any["q", i])
    m["variables"]["w"] = Dict("type" => "unknown", "shape" => ["x"])
    wdef = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict("i" => Dict("from" => "x")),
        "expr" => Dict("op" => "+", "args" => Any[Dict("op" => "*", "args" => Any[q("i"), q("i")]), 0.125])
    )
    m["equations"][1]["rhs"]["args"][2]["args"] = Any["w"]
    pushfirst!(m["equations"], Dict("lhs" => "w", "rhs" => wdef))
    d["metadata"]["name"] = "rrt_tpl_seam_obs"
    return d
end

# `_rrt_tpl_seam_doc` with no wrap: each boundary body reads only cells at its
# own end of the axis (`lap_lo` cells 1-3 directly, `lap_hi` cells
# `nx - 2:nx` through the nested `wrap_hi`), so a tile that owns an end
# cell reads its state array through the template's array parameter without
# crossing a seam, and shares its code with the other tiles.
function _rrt_tpl_edge_doc(nx::Int)
    d = _rrt_tpl_seam_doc(nx)
    tpl = d["models"]["T"]["operators"]
    pin(at) = Dict("op" => "index", "args" => Any["f", at])
    lap3(a, b, c) = Dict("op" => "+", "args" => Any[a, Dict("op" => "*", "args" => Any[-2, b]), c])
    lo_if = tpl["lap_lo"]["body"]["expr"]
    lo_if["args"][2] = lap3(pin(3), pin(1), pin(2))
    lo_if["args"][3] = pin(2)
    tpl["wrap_hi"]["body"] = lap3(pin(nx - 1), pin(nx), pin(nx - 2))
    tpl["lap_hi"]["body"]["expr"]["args"][3] = pin(nx - 1)
    d["metadata"]["name"] = "rrt_tpl_edge"
    return d
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
        # Decomposing a program does not change what its own workspaces run.
        @test rhs_workspace(prog).shared === prog.shared
        # A caller who wants the program and its tiles to run one compiled
        # right-hand side restricts it to its whole domain: the same code as
        # the tiles, the same values, allocation-free.
        dom = ("x" => 1:nx, "y" => 1:ny)
        whole = restrict(prog, dec; owned = dom, storage = dom)
        @test _rrt_generated(whole.f!) == codes[1]
        @test tile_layout(whole).n_u == L.n_u
        ws2 = rhs_workspace(whole)
        du2 = fill(NaN, L.n_u)
        rhs!(du2, whole, ws2, u, Float64[], prob.p, 0.0, fs)
        @test _rrt_bits.(du2) == _rrt_bits.(G)
        noaux = Float64[]
        _rrt_allocated(du2, whole, ws2, u, noaux, prob.p, fs)
        @test _rrt_allocated(du2, whole, ws2, u, noaux, prob.p, fs) == 0
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

    @testset "the program is built on the first rhs_program call, once" begin
        p2 = esm_problem(_rrt_doc(nx, ny), (0.0, 1.0))
        @test p2.build.seed isa RRT._ProgramSeed
        @test p2.build.program[] === nothing
        pr = rhs_program(p2)
        @test p2.build.program[] === pr
        @test rhs_program(p2) === pr
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
        err = caught(() -> select(no2; writes = ["Chem.O3"]))
        @test err isa SimulateError && occursin("Chem.O3", err.msg)
        # Kept contributions to a variable left out of `writes` still raise.
        emis = select(sp; writes = ["Chem.NO2", "Chem.O3"], terms = [TO(coupling = 0)])
        err = caught(() -> select(emis; writes = ["Chem.O3"]))
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
        err = caught(
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

    @testset "a template body read past the seam is a seam instance" begin
        tx = 12
        dir = mktempdir()
        fix = joinpath(dir, "rrt_tpl_seam.esm")
        open(io -> RRT.JSON3.write(io, _rrt_tpl_seam_doc(tx)), fix, "w")
        tprob = esm_problem(fix, (0.0, 1.0))
        tprog = rhs_program(tprob)
        # The expanded document: the same right-hand side, every reference
        # replaced by its expansion.
        xprob = esm_problem(RRT.Expand(RRT.load_path(fix)), (0.0, 1.0))
        xprog = rhs_program(xprob)
        TL = tile_layout(tprog)
        tdec = Decomposition(axes = ["x" => (period = tx,)])
        @test halo(tprog, tdec) == Dict(("T.q", "x") => (1, 1))
        # Two states, so each boundary takes both branches of its condition.
        for tu in (0.5 .+ sin.(1:TL.n_u), 1.5 .- sin.(1:TL.n_u))
            whole(prog) = (
                du = fill(NaN, TL.n_u); rhs!(
                    du, prog, rhs_workspace(prog), tu, Float64[], tprob.p, 0.0,
                    default_forcing_set(prog)
                ); du
            )
            TG = whole(tprog)
            @test all(isfinite, TG)
            @test _rrt_bits.(TG) == _rrt_bits.(whole(xprog))
            seen = zeros(Int, tx)
            for (xo, xs) in ((1:4, 0:5), (5:8, 4:9), (9:tx, 8:(tx + 1)))
                tile = restrict(tprog, tdec; owned = ("x" => xo,), storage = ("x" => xs,))
                T = tile_layout(tile)
                # Only a tile whose storage crosses the seam has a far block.
                @test length(RRT._layout_blocks(tile.internal)) == (xo == 5:8 ? 1 : 2)
                uS = fill(NaN, T.n_u)
                for b in T.u, c in CartesianIndices(Tuple(b.storage))
                    uS[RRT._tile_slot(b, Tuple(c))] = tu[mod1(c[1], tx)]
                end
                duS = fill(NaN, T.n_u)
                rhs!(
                    duS, tile, rhs_workspace(tile), uS, Float64[], tprob.p, 0.0,
                    default_forcing_set(tile)
                )
                b = first(T.u)
                for c in xo
                    seen[c] += _rrt_bits(duS[RRT._tile_slot(b, (c,))]) == _rrt_bits(TG[c])
                end
            end
            @test all(==(1), seen)
        end
    end

    @testset "a template body read of an observed past the seam is evaluated lazily" begin
        # The body's read of `w` past the seam is the observed's definition on
        # the far side, bound to the seam instance as an array expression and
        # evaluated at the cell the body reads (no buffer, no inlined body).
        tx = 12
        dir = mktempdir()
        fix = joinpath(dir, "rrt_tpl_seam_obs.esm")
        open(io -> RRT.JSON3.write(io, _rrt_tpl_seam_obs_doc(tx)), fix, "w")
        tprob = esm_problem(fix, (0.0, 1.0))
        tprog = rhs_program(tprob)
        xprob = esm_problem(RRT.Expand(RRT.load_path(fix)), (0.0, 1.0))
        xprog = rhs_program(xprob)
        TL = tile_layout(tprog)
        tdec = Decomposition(axes = ["x" => (period = tx,)])
        @test halo(tprog, tdec) == Dict(("T.q", "x") => (1, 1))
        for tu in (0.5 .+ sin.(1:TL.n_u), 1.5 .- sin.(1:TL.n_u))
            whole(prog) = (
                du = fill(NaN, TL.n_u); rhs!(
                    du, prog, rhs_workspace(prog), tu, Float64[], tprob.p, 0.0,
                    default_forcing_set(prog)
                ); du
            )
            TG = whole(tprog)
            @test all(isfinite, TG)
            @test _rrt_bits.(TG) == _rrt_bits.(whole(xprog))
            seen = zeros(Int, tx)
            for (xo, xs) in ((1:4, 0:5), (5:8, 4:9), (9:tx, 8:(tx + 1)))
                tile = restrict(tprog, tdec; owned = ("x" => xo,), storage = ("x" => xs,))
                T = tile_layout(tile)
                # The far side of `w` reads the far block of `q`.
                @test length(RRT._layout_blocks(tile.internal)) == (xo == 5:8 ? 1 : 2)
                uS = fill(NaN, T.n_u)
                for b in T.u, c in CartesianIndices(Tuple(b.storage))
                    uS[RRT._tile_slot(b, Tuple(c))] = tu[mod1(c[1], tx)]
                end
                duS = fill(NaN, T.n_u)
                rhs!(
                    duS, tile, rhs_workspace(tile), uS, Float64[], tprob.p, 0.0,
                    default_forcing_set(tile)
                )
                b = first(T.u)
                for c in xo
                    seen[c] += _rrt_bits(duS[RRT._tile_slot(b, (c,))]) == _rrt_bits(TG[c])
                end
            end
            @test all(==(1), seen)
        end
    end

    @testset "a template body read of an end cell in a tile that shares its code" begin
        # The state array is passed to the boundary bodies addressed through
        # the tile's own layout: the tile that owns cell `tx` reads the cells
        # it stores, and the boxes a tile owns no cell of (still evaluated
        # ahead of their empty loops) read nothing outside its storage.
        tx = 12
        dir = mktempdir()
        fix = joinpath(dir, "rrt_tpl_edge.esm")
        open(io -> RRT.JSON3.write(io, _rrt_tpl_edge_doc(tx)), fix, "w")
        tprob = esm_problem(fix, (0.0, 1.0))
        tprog = rhs_program(tprob)
        TL = tile_layout(tprog)
        tdec = Decomposition(axes = ["x" => (;)])
        @test halo(tprog, tdec) == Dict(("T.q", "x") => (2, 2))
        for tu in (0.5 .+ sin.(1:TL.n_u), 1.5 .- sin.(1:TL.n_u))
            TG = fill(NaN, TL.n_u)
            rhs!(
                TG, tprog, rhs_workspace(tprog), tu, Float64[], tprob.p, 0.0,
                default_forcing_set(tprog)
            )
            @test all(isfinite, TG)
            seen = zeros(Int, tx)
            for (xo, xs) in ((1:4, 1:6), (5:8, 3:10), (9:tx, 7:tx))
                tile = restrict(tprog, tdec; owned = ("x" => xo,), storage = ("x" => xs,))
                T = tile_layout(tile)
                b = only(T.u)
                uS = fill(NaN, T.n_u)
                for c in xs
                    uS[RRT._tile_slot(b, (c,))] = tu[c]
                end
                duS = fill(NaN, T.n_u)
                rhs!(
                    duS, tile, rhs_workspace(tile), uS, Float64[], tprob.p, 0.0,
                    default_forcing_set(tile)
                )
                for c in xo
                    seen[c] += _rrt_bits(duS[RRT._tile_slot(b, (c,))]) == _rrt_bits(TG[c])
                end
            end
            @test all(==(1), seen)
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

# U19: lanes each at their own time. Every lane equals the one-time call and
# the whole-domain program at its own time, bit for bit, whatever the other
# lanes' times: `t` read directly, through a 0-d observed, a 0-d observed of an
# observed and an array observed, all in one call.
@testset "lanes at their own times" begin
    ix(v, i) = Dict("op" => "index", "args" => Any[v, i])
    doc = Dict(
        "esm" => "2.0.0",
        "metadata" => Dict("name" => "lanetime", "authors" => ["test"]),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => 5)),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "units" => "1", "shape" => ["x"], "default" => 1.0),
                    "c" => Dict(
                        "type" => "parameter", "units" => "1", "shape" => ["x"],
                        "default" => [0.5, 1.5, 2.5, 3.5, 4.5]
                    ),
                    "k" => Dict("type" => "unknown", "units" => "1"),
                    "k0" => Dict("type" => "unknown", "units" => "1"),
                    "a" => Dict("type" => "unknown", "units" => "1", "shape" => ["x"])
                ),
                "equations" => Any[
                    Dict("lhs" => "k0", "rhs" => Dict("op" => "+", "args" => Any[1.0, Dict("op" => "sin", "args" => Any["t"])])),
                    Dict("lhs" => "k", "rhs" => Dict("op" => "*", "args" => Any[0.5, "k0"])),
                    # An array observed of `t` and of a 0-d observed of `t`.
                    Dict(
                        "lhs" => "a", "rhs" => Dict(
                            "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                            "ranges" => Dict("i" => Dict("from" => "x")),
                            "expr" => Dict("op" => "+", "args" => Any[Dict("op" => "*", "args" => Any[ix("c", "i"), "t"]), "k0"])
                        )
                    ),
                    Dict(
                        "lhs" => Dict(
                            "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                            "ranges" => Dict("i" => Dict("from" => "x")),
                            "expr" => Dict("op" => "D", "args" => Any[ix("u", "i")], "wrt" => "t")
                        ),
                        "rhs" => Dict(
                            "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                            "ranges" => Dict("i" => Dict("from" => "x")),
                            "expr" => Dict(
                                "op" => "+", "args" => Any[
                                    Dict("op" => "*", "args" => Any[-1.0, "k", ix("u", "i")]),
                                    ix("a", "i"),
                                ]
                            )
                        )
                    ),
                ]
            )
        )
    )
    path = joinpath(mktempdir(), "lanetime.esm")
    write(path, EarthSciAST.JSON3.write(doc))
    prob = esm_problem(path, (0.0, 1.0))
    lp = lanes(rhs_program(prob), :cells, ["x"]; chunk = 4)
    LL = lane_layout(lp)
    L = 4
    cells = Int32[4 1 3 2]
    u = [0.7, 1.3, 2.1, 0.0]
    ts = [0.3, 2.0, 7.25]
    fs = default_forcing_set(lp)
    ws = rhs_workspace(lp)
    du = fill(NaN, LL.n_u * L)
    rhs!(du, lp, ws, u, Float64[], prob.p, ts, fs, cells, 3)
    for l in 1:3
        one = fill(NaN, LL.n_u * L)
        rhs!(one, lp, ws, u, Float64[], prob.p, ts[l], fs, cells, 3)
        @test reinterpret(UInt64, du[l]) == reinterpret(UInt64, one[l])
    end
    # The whole-domain program at each lane's own time: one pass over a batch
    # at mixed times (0-d observeds of `t` are computed per lane).
    prog = rhs_program(prob)
    uw = [1.0, 2.1, 0.7, 1.3, 0.9]    # cells 4, 1, 3 hold u[4], u[1], u[3]
    uw[4], uw[1], uw[3] = u[1], u[2], u[3]
    for l in 1:3
        dw = fill(NaN, 5)
        rhs!(dw, prog, rhs_workspace(prog), uw, Float64[], prob.p, ts[l], default_forcing_set(prog))
        @test reinterpret(UInt64, du[l]) == reinterpret(UInt64, dw[cells[1, l]])
    end
    # Equal times: the one-time call.
    du2 = fill(NaN, LL.n_u * L)
    rhs!(du2, lp, ws, u, Float64[], prob.p, [2.0, 2.0, 2.0], fs, cells, 3)
    one = fill(NaN, LL.n_u * L)
    rhs!(one, lp, ws, u, Float64[], prob.p, 2.0, fs, cells, 3)
    @test reinterpret.(UInt64, du2[1:3]) == reinterpret.(UInt64, one[1:3])
    @test_throws DimensionMismatch rhs!(du2, lp, ws, u, Float64[], prob.p, [1.0], fs, cells, 3)
end

# The forms EarthSciIntegrator's derived documents write: a whole-array
# right-hand side `D(u) = faq{…}` and a `makearray` whose region value is an
# array `faq` (a Jacobian document's band field). Every lane equals the
# whole-domain program bit for bit.
@testset "lanes of whole-array faq right-hand sides" begin
    ix(v, i...) = Dict("op" => "index", "args" => Any[v, i...])
    whole(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y")), "expr" => e
    )
    doc = Dict(
        "esm" => "2.0.0",
        "metadata" => Dict("name" => "wholefaq", "authors" => ["test"]),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => 3),
            "y" => Dict("kind" => "interval", "size" => 4)
        ),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "units" => "1", "shape" => ["x", "y"], "default" => 1.0),
                    "v" => Dict("type" => "unknown", "units" => "1", "shape" => ["x", "y"], "default" => 2.0),
                    "c" => Dict("type" => "parameter", "units" => "1", "shape" => ["x"], "default" => [0.5, 1.5, 2.5])
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                        "rhs" => whole(
                            Dict(
                                "op" => "-", "args" => Any[
                                    Dict("op" => "*", "args" => Any[ix("c", "i"), ix("u", "i", "j"), "t"]),
                                    Dict("op" => "*", "args" => Any["j", ix("v", "i", "j")]),
                                ]
                            )
                        )
                    ),
                    Dict(
                        "lhs" => Dict("op" => "D", "args" => Any["v"], "wrt" => "t"),
                        "rhs" => Dict(
                            "op" => "makearray", "args" => Any[],
                            "regions" => Any[Any[Any[1, 3], Any[1, 4]]],
                            "values" => Any[whole(Dict("op" => "*", "args" => Any[ix("u", "i", "j"), ix("v", "i", "j")]))]
                        )
                    ),
                ]
            )
        )
    )
    path = joinpath(mktempdir(), "wholefaq.esm")
    write(path, EarthSciAST.JSON3.write(doc))
    prob = esm_problem(path, (0.0, 1.0))
    prog = rhs_program(prob)
    lp = lanes(prog, :cells, ["x", "y"]; chunk = 4)
    LL = lane_layout(lp)
    n = 12
    gu = [0.5 + ((k * 7919) % 101) / 37 for k in 1:(2n)]
    fs = default_forcing_set(prog)
    want = fill(NaN, 2n)
    rhs!(want, prog, rhs_workspace(prog), gu, Float64[], prob.p, 0.75, fs)
    offs = Dict(b.name => b.offset for b in LL.u)
    ws = rhs_workspace(lp)
    for batch in Iterators.partition(1:n, 4)
        L = 4
        u = zeros(LL.n_u * L)
        cells = ones(Int32, 2, L)
        for (l, c) in enumerate(batch)
            u[offs["M.u"] * L + l] = gu[c]
            u[offs["M.v"] * L + l] = gu[n + c]
            cells[1, l] = Int32((c - 1) % 3 + 1)
            cells[2, l] = Int32((c - 1) ÷ 3 + 1)
        end
        du = fill(NaN, LL.n_u * L)
        rhs!(du, lp, ws, u, Float64[], prob.p, 0.75, default_forcing_set(lp), cells, length(batch))
        for (l, c) in enumerate(batch)
            @test reinterpret(UInt64, du[offs["M.u"] * L + l]) == reinterpret(UInt64, want[c])
            @test reinterpret(UInt64, du[offs["M.v"] * L + l]) == reinterpret(UInt64, want[n + c])
        end
    end
end

# Every lane of `lanes(prob's program, kind, sets)` against the whole-domain
# program at the lane's cell, bit for bit, over every cell in batches of
# `batch` lanes plus one padding lane. `shapes` names each state's index sets,
# `ext` each set's extent. Returns the number of values compared and the
# number that differ. With `tsf`, lane `l` of a batch runs at time `tsf(l)`
# (a call with a time per lane) and is compared at that time. With
# `gathered`, the call reads its inputs from `gather_lane_inputs!`.
function _rrt_lanes_vs_whole(
        prob, kind, sets, shapes, ext; chunk = 4, batch = 3, t = 0.75, tsf = nothing,
        gathered = false
    )
    prog = rhs_program(prob)
    lp = lanes(prog, kind, sets; chunk = chunk)
    LL = lane_layout(lp)
    blocks = Dict(b.name => b for b in state_layout(prog))
    N = n_states(prog)
    gu = [0.5 + ((k * 7919) % 101) / 37 for k in 1:N]
    wants = Dict{Float64, Vector{Float64}}()
    want(tt) = get!(wants, tt) do
        w = fill(NaN, N)
        rhs!(w, prog, rhs_workspace(prog), gu, Float64[], prob.p, tt, default_forcing_set(prog))
        w
    end
    gslot(name, g) = blocks[name].offset + LinearIndices(Tuple(blocks[name].shape))[g...] - 1
    ws = rhs_workspace(lp)
    fs = default_forcing_set(lp)
    compared = differ = 0
    for bc in Iterators.partition(vec(collect(Iterators.product((1:ext[s] for s in sets)...))), batch)
        L = batch + 1
        cells = ones(Int32, length(sets), L)
        for (l, c) in enumerate(bc)
            cells[:, l] .= c
        end
        # The global index of element `nl` (over the non-lane sets) at cell `c`.
        function gidx(name, c, nl)
            k = 0
            return [s in sets ? c[findfirst(==(s), sets)] : nl[k += 1] for s in shapes[name]]
        end
        u = zeros(LL.n_u * L)
        for b in LL.u, (l, c) in enumerate(bc), (e, nl) in enumerate(CartesianIndices(Tuple(b.extents)))
            u[(b.offset + e - 1) * L + l] = gu[gslot(b.name, gidx(b.name, c, nl))]
        end
        du = fill(NaN, LL.n_u * L)
        tl = tsf === nothing ? t : [tsf(l) for l in eachindex(bc)]
        if gathered
            li = lane_inputs(lp, L)
            gather_lane_inputs!(li, lp, prob.p, t, fs, cells, length(bc))
            rhs!(du, lp, ws, u, Float64[], prob.p, tl, li, cells, length(bc))
        else
            rhs!(du, lp, ws, u, Float64[], prob.p, tl, fs, cells, length(bc))
        end
        for b in LL.u, (l, c) in enumerate(bc), (e, nl) in enumerate(CartesianIndices(Tuple(b.extents)))
            compared += 1
            got = du[(b.offset + e - 1) * L + l]
            w = want(tsf === nothing ? t : tsf(l))
            reinterpret(UInt64, got) == reinterpret(UInt64, w[gslot(b.name, gidx(b.name, c, nl))]) ||
                (differ += 1)
        end
    end
    return compared, differ
end

function _rrt_doc_of(name, sets, vars, eqs)
    doc = Dict(
        "esm" => "2.0.0",
        "metadata" => Dict("name" => name, "authors" => ["test"]),
        "index_sets" => Dict(s => Dict("kind" => "interval", "size" => n) for (s, n) in sets),
        "models" => Dict("M" => Dict("variables" => vars, "equations" => eqs))
    )
    path = joinpath(mktempdir(), "$name.esm")
    write(path, EarthSciAST.JSON3.write(doc))
    return esm_problem(path, (0.0, 1.0))
end

_rrt_lane_refusal(f) =
try
    f()
    nothing
catch e
    e isa RRT.EarthSciASTError && e.code == "compiler_refused_rule" &&
        occursin("lane", sprint(showerror, e)) ? :refused : e
end

# A lane spec for calling the lane rewrite directly: :cells lanes over `x` (3).
_rrt_lane_spec() = RRT._LaneSpec(
    :cells, ["x"], 4, Dict("u" => ["x"]), Dict("x" => zeros(4)), RRT._LaneGather[],
    Set{String}(["u"]), Dict{String, Vector{String}}(), Dict{String, Int}(), Dict("x" => 3), false,
    nothing, Set{String}(), String[], Set{String}()
)

# The renaming of an array faq's output indices to the subscripts it is read
# at, and where the faq sits in a `makearray` region (#780 review).
@testset "lanes read an array faq at exactly its own cells" begin
    ix(v, i...) = Dict("op" => "index", "args" => Any[v, i...])
    op(o, a...) = Dict("op" => o, "args" => Any[a...])
    faq(outs, ranges, e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any[outs...], "ranges" => ranges, "expr" => e
    )
    st(shape) = Dict("type" => "unknown", "units" => "1", "shape" => shape, "default" => 1.0)
    cpar = Dict("type" => "parameter", "units" => "1", "shape" => ["x"], "default" => [0.5, 1.5, 2.5])
    xy = Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y"))
    # `faq(D(u[a, b])) = index(faq{i, j}(body), a, b)`: the output indices are
    # renamed to `a`, `b`.
    eq_ab(body) = Dict(
        "lhs" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["a", "b"],
            "ranges" => Dict("a" => Dict("from" => "x"), "b" => Dict("from" => "y")),
            "expr" => Dict("op" => "D", "args" => Any[ix("u", "a", "b")], "wrt" => "t")
        ),
        "rhs" => ix(faq(["i", "j"], xy, body), "a", "b")
    )
    sets = Dict("x" => 3, "y" => 4)
    shapes = Dict("M.u" => ["x", "y"])

    # A nested faq rebinding the output index `i` keeps its own `i`.
    shadow = op(
        "-", op("*", ix("u", "i", "j"), "t"),
        op("*", "j", faq(String[], Dict("i" => Dict("from" => "x")), op("*", ix("c", "i"), "i")))
    )
    prob = _rrt_doc_of("lanecapture", sets, Dict("u" => st(["x", "y"]), "c" => cpar), Any[eq_ab(shadow)])
    compared, differ = _rrt_lanes_vs_whole(prob, :cells, ["x", "y"], shapes, sets)
    @test compared == 12 && differ == 0

    # A nested faq binding the subscript `b` (on the non-lane axis of a
    # :columns lane) where `k` is free would capture the renamed index:
    # refused.
    xz = Dict("i" => Dict("from" => "x"), "k" => Dict("from" => "z"))
    capture = Dict(
        "lhs" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["a", "b"],
            "ranges" => Dict("a" => Dict("from" => "x"), "b" => Dict("from" => "z")),
            "expr" => Dict("op" => "D", "args" => Any[ix("u", "a", "b")], "wrt" => "t")
        ),
        "rhs" => ix(
            faq(
                ["i", "k"], xz, op(
                    "*", ix("u", "i", "k"),
                    faq(String[], Dict("b" => Dict("from" => "z")), op("*", ix("cz", "b"), "k"))
                )
            ), "a", "b"
        )
    )
    czpar = Dict("type" => "parameter", "units" => "1", "shape" => ["z"], "default" => [0.5, 1.5, 2.5, 3.5, 4.5])
    prob = _rrt_doc_of(
        "lanecapture2", Dict("x" => 3, "z" => 5), Dict("u" => st(["x", "z"]), "cz" => czpar), Any[capture]
    )
    @test _rrt_lane_refusal(() -> lanes(rhs_program(prob), :columns, ["x"]; chunk = 4)) === :refused

    # An array faq carrying `args` is refused.
    withargs = merge(faq(["i", "j"], xy, op("*", -1.0, ix("u", "i", "j"))), Dict("args" => Any["u"]))
    prob = _rrt_doc_of(
        "laneargs", sets, Dict("u" => st(["x", "y"])), Any[
            Dict("lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"), "rhs" => withargs),
        ]
    )
    @test _rrt_lane_refusal(() -> lanes(rhs_program(prob), :cells, ["x", "y"]; chunk = 4)) === :refused

    # An array faq carrying `join` or `distinct` is refused. No whole-domain
    # program reads one this way (it is a value-invention producer), so the
    # lane rewrite is called directly.
    let ESA = EarthSciAST, V = EarthSciAST.VarExpr
        spec = _rrt_lane_spec()
        scope = ESA._LaneScope(
            Dict("l" => "x"), "l", Dict{String, UnitRange{Int}}(), Dict{String, Any}("l" => Dict("from" => "x"))
        )
        for extra in ((; distinct = true), (; join = Any[Dict("on" => Any["i"])]))
            F = ESA.OpExpr(
                "faq", ESA.ASTExpr[]; output_idx = Any["i"],
                ranges = Dict{String, Any}("i" => Dict("from" => "x")),
                expr_body = ESA.OpExpr("index", ESA.ASTExpr[V("u"), V("i")]), extra...
            )
            read = ESA.OpExpr("index", ESA.ASTExpr[F, V("l")])
            @test _rrt_lane_refusal(
                () -> ESA._lane_rewrite(spec, (; arrays = Dict{String, Any}()), read, scope, "rule")
            ) === :refused
        end
    end

    # A bare read on a non-lane axis whose subscript runs over a range that
    # does not start at 1 is refused (a read by position).
    lhs_b(name, brange) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["a", "b"],
        "ranges" => Dict("a" => Dict("from" => "x"), "b" => brange),
        "expr" => Dict("op" => "D", "args" => Any[ix(name, "a", "b")], "wrt" => "t")
    )
    xk25 = Dict("i" => Dict("from" => "x"), "k" => Any[2, 5])
    prob = _rrt_doc_of(
        "laneoffset", Dict("x" => 3, "z" => 5), Dict("u" => st(["x", "z"])), Any[
            Dict("lhs" => lhs_b("u", Any[1, 1]), "rhs" => op("*", -1.0, ix("u", "a", "b"))),
            Dict(
                "lhs" => lhs_b("u", Any[2, 5]),
                "rhs" => ix(faq(["i", "k"], xk25, op("*", "k", ix("u", "i", "k"))), "a", "b")
            ),
        ]
    )
    @test _rrt_lane_refusal(() -> lanes(rhs_program(prob), :columns, ["x"]; chunk = 4)) === :refused

    # A makearray band whose value fits its region on a non-lane axis that
    # starts above 1: read at the absolute subscript, as the whole domain does.
    band(klo, khi) = Dict(
        "lhs" => Dict("op" => "D", "args" => Any["v"], "wrt" => "t"),
        "rhs" => Dict(
            "op" => "makearray", "args" => Any[],
            "regions" => Any[Any[Any[1, 3], Any[1, 5]], Any[Any[1, 3], Any[2, 5]]],
            "values" => Any[
                faq(["i", "k"], xz, op("*", -1.0, ix("v", "i", "k"))),
                faq(
                    ["i", "k"], Dict("i" => Dict("from" => "x"), "k" => Any[klo, khi]),
                    op("*", ix("u", "i", "k"), "k", "t")
                ),
            ]
        )
    )
    deq_u = Dict(
        "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
        "rhs" => faq(["i", "k"], xz, op("-", ix("v", "i", "k"), ix("u", "i", "k")))
    )
    zsets = Dict("x" => 3, "z" => 5)
    zvars = Dict("u" => st(["x", "z"]), "v" => st(["x", "z"]))
    prob = _rrt_doc_of("laneband", zsets, zvars, Any[deq_u, band(2, 5)])
    compared, differ = _rrt_lanes_vs_whole(
        prob, :columns, ["x"], Dict("M.u" => ["x", "z"], "M.v" => ["x", "z"]), zsets; batch = 2
    )
    @test compared == 30 && differ == 0
    # The same value placed one off its region is refused.
    prob = _rrt_doc_of("laneband2", zsets, zvars, Any[deq_u, band(1, 4)])
    @test _rrt_lane_refusal(() -> lanes(rhs_program(prob), :columns, ["x"]; chunk = 4)) === :refused
end

# A time per lane in every position a 0-d observed of `t` can be read (#781
# review): a right-hand side that is no faq, states of different shapes in
# :columns lanes, a band field and a contraction. Each lane equals the
# whole-domain program at its own time, bit for bit.
@testset "lanes at their own times read 0-d observeds of t anywhere" begin
    ix(v, i...) = Dict("op" => "index", "args" => Any[v, i...])
    op(o, a...) = Dict("op" => o, "args" => Any[a...])
    faq(outs, ranges, e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any[outs...], "ranges" => ranges, "expr" => e
    )
    st(shape) = Dict("type" => "unknown", "units" => "1", "shape" => shape, "default" => 1.0)
    obs(shape = nothing) = shape === nothing ? Dict("type" => "unknown", "units" => "1") :
        Dict("type" => "unknown", "units" => "1", "shape" => shape)
    faqd(name, idx, ranges, body) = Dict(
        "lhs" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any[idx...], "ranges" => ranges,
            "expr" => Dict("op" => "D", "args" => Any[ix(name, idx...)], "wrt" => "t")
        ),
        "rhs" => body
    )
    tsf(l) = (0.3, 2.0, 7.25)[l]
    k_eqs = Any[
        Dict("lhs" => "k0", "rhs" => op("+", 1.0, op("sin", "t"))),
        Dict("lhs" => "k", "rhs" => op("*", 0.5, "k0")),
    ]
    k_vars = Dict("k0" => obs(), "k" => obs())

    # A: `faq(D(u[i])) = -k·c[i]·u[i]`, a right-hand side that is no faq,
    # with a pre-gathered read of `c`; also through the pre-gathered call.
    xr = Dict("i" => Dict("from" => "x"))
    cpar = Dict("type" => "parameter", "units" => "1", "shape" => ["x"], "default" => [0.5, 1.5, 2.5, 3.5, 4.5])
    prob = _rrt_doc_of(
        "lanetA", Dict("x" => 5), merge(k_vars, Dict("u" => st(["x"]), "c" => cpar)),
        vcat(k_eqs, Any[faqd("u", ["i"], xr, op("*", -1.0, "k", ix("c", "i"), ix("u", "i")))])
    )
    for f in (nothing, tsf), g in (false, true)
        compared, differ = _rrt_lanes_vs_whole(
            prob, :cells, ["x"], Dict("M.u" => ["x"]), Dict("x" => 5); tsf = f, gathered = g
        )
        @test compared == 5 && differ == 0
    end
    # Padding lanes take the first lane's time, in both calls.
    lp = lanes(rhs_program(prob), :cells, ["x"]; chunk = 4)
    ws = rhs_workspace(lp)
    du = fill(NaN, 4)
    rhs!(du, lp, ws, [0.7, 1.3, 2.1, 0.0], Float64[], prob.p, [0.3, 2.0, 7.25], default_forcing_set(lp), Int32[4 1 3 2], 3)
    @test ws.lbufs[end] == [0.3, 2.0, 7.25, 0.3]
    @test isnan(du[4])
    li = lane_inputs(lp, 4)
    gather_lane_inputs!(li, lp, prob.p, 0.0, default_forcing_set(lp), Int32[4 1 3 2], 3)
    ws = rhs_workspace(lp)
    rhs!(du, lp, ws, [0.7, 1.3, 2.1, 0.0], Float64[], prob.p, [7.25, 2.0, 0.3], li, Int32[4 1 3 2], 3)
    @test ws.lbufs[end] == [7.25, 2.0, 0.3, 7.25]
    @test_throws DimensionMismatch rhs!(
        du, lp, ws, [0.7, 1.3, 2.1, 0.0], Float64[], prob.p, [0.3, 2.0], li, Int32[4 1 3 2], 3
    )
    # At most L times.
    @test_throws DimensionMismatch rhs!(
        du, lp, ws, [0.7, 1.3, 2.1, 0.0], Float64[], prob.p, [0.3, 2.0, 7.25, 1.0, 2.0],
        default_forcing_set(lp), Int32[4 1 3 2], 3
    )

    # B: states of different shapes in :columns lanes over x, a band field
    # (makearray of an array faq) and a contraction, all reading `k`.
    xz = Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "z"))
    xy = Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y"))
    sets = Dict("x" => 3, "y" => 4, "z" => 2)
    prob = _rrt_doc_of(
        "lanetB", sets, merge(k_vars, Dict("a" => st(["x", "z"]), "b" => st(["x", "y"]))),
        vcat(
            k_eqs, Any[
                faqd("a", ["i", "j"], xz, faq(["i", "j"], xz, op("*", -1.0, "k", ix("a", "i", "j")))),
                Dict(
                    "lhs" => Dict("op" => "D", "args" => Any["b"], "wrt" => "t"),
                    "rhs" => Dict(
                        "op" => "makearray", "args" => Any[],
                        "regions" => Any[Any[Any[1, 3], Any[1, 4]], Any[Any[1, 3], Any[2, 4]]],
                        "values" => Any[
                            faq(["i", "j"], xy, op("*", -2.0, "k", ix("b", "i", "j"))),
                            faq(
                                ["i", "j"], Dict("i" => Dict("from" => "x"), "j" => Any[2, 4]),
                                op(
                                    "+", op("*", "k", ix("b", "i", "j")),
                                    faq(String[], Dict("m" => Dict("from" => "z")), op("*", "k", ix("a", "i", "m")))
                                )
                            ),
                        ]
                    )
                ),
            ]
        )
    )
    shapes = Dict("M.a" => ["x", "z"], "M.b" => ["x", "y"])
    for f in (nothing, tsf), g in (false, true)
        compared, differ = _rrt_lanes_vs_whole(prob, :columns, ["x"], shapes, sets; tsf = f, gathered = g)
        @test compared == 18 && differ == 0
    end
end

# `t` reaching the right-hand side through an observed with no lane set (#781
# review): it is evaluated once per call, so the build and the one-time call
# are unchanged, a call at equal times equals the one-time call, and a call at
# mixed times is refused naming the observed.
@testset "lane observeds of t with no lane set" begin
    ix(v, i...) = Dict("op" => "index", "args" => Any[v, i...])
    op(o, a...) = Dict("op" => o, "args" => Any[a...])
    faq(outs, ranges, e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any[outs...], "ranges" => ranges, "expr" => e
    )
    xr = Dict("i" => Dict("from" => "x"))
    wr = Dict("w" => Dict("from" => "w"))
    faqd(body) = Dict(
        "lhs" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["i"], "ranges" => xr,
            "expr" => Dict("op" => "D", "args" => Any[ix("u", "i")], "wrt" => "t")
        ),
        "rhs" => faq(["i"], xr, body)
    )
    f_eq = Dict("lhs" => "f", "rhs" => faq(["w"], wr, op("*", "w", "t")))
    vars = Dict(
        "u" => Dict("type" => "unknown", "units" => "1", "shape" => ["x"], "default" => 1.0),
        "f" => Dict("type" => "unknown", "units" => "1", "shape" => ["w"]),
        "k" => Dict("type" => "unknown", "units" => "1")
    )
    sets = Dict("x" => 5, "w" => 3)
    docs = [
        # Read directly, contracted over w.
        _rrt_doc_of(
            "lanesh1", sets, vars, Any[
                f_eq, Dict("lhs" => "k", "rhs" => op("sin", "t")),
                faqd(faq(String[], wr, op("*", ix("f", "w"), ix("u", "i")))),
            ]
        ),
        # Read through a 0-d observed.
        _rrt_doc_of(
            "lanesh2", sets, vars, Any[
                f_eq, Dict("lhs" => "k", "rhs" => faq(String[], wr, ix("f", "w"))),
                faqd(op("*", "k", ix("u", "i"))),
            ]
        ),
    ]
    cells = Int32[4 1 3 2]
    u = [0.7, 1.3, 2.1, 0.0]
    for prob in docs
        @test _rrt_lanes_vs_whole(prob, :cells, ["x"], Dict("M.u" => ["x"]), sets)[2] == 0
        lp = lanes(rhs_program(prob), :cells, ["x"]; chunk = 4)
        ws = rhs_workspace(lp)
        fs = default_forcing_set(lp)
        one = fill(NaN, 4)
        rhs!(one, lp, ws, u, Float64[], prob.p, 2.0, fs, cells, 3)
        same = fill(NaN, 4)
        rhs!(same, lp, ws, u, Float64[], prob.p, [2.0, 2.0, 2.0], fs, cells, 3)
        @test reinterpret.(UInt64, same[1:3]) == reinterpret.(UInt64, one[1:3])
        err = try
            rhs!(same, lp, ws, u, Float64[], prob.p, [0.3, 2.0, 7.25], fs, cells, 3)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("'M.f'", err.msg)
        # The pre-gathered call: the same at equal times, the same refusal.
        li = lane_inputs(lp, 4)
        gather_lane_inputs!(li, lp, prob.p, 2.0, fs, cells, 3)
        gsame = fill(NaN, 4)
        rhs!(gsame, lp, ws, u, Float64[], prob.p, [2.0, 2.0, 2.0], li, cells, 3)
        @test reinterpret.(UInt64, gsame[1:3]) == reinterpret.(UInt64, one[1:3])
        err = try
            rhs!(gsame, lp, ws, u, Float64[], prob.p, [0.3, 2.0, 7.25], li, cells, 3)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("'M.f'", err.msg)
    end
end

_rrt_lane_allocated(du, lp, ws, u, aux, p, t, x, cells, n) =
    @allocated rhs!(du, lp, ws, u, aux, p, t, x, cells, n)
_rrt_gather_allocated(li, lp, p, fs, cells, n) =
    @allocated gather_lane_inputs!(li, lp, p, 0.25, fs, cells, n)

# A lane call is straight-line work over its lanes: it allocates nothing, it
# computes a value derived from forcing data alone (a whole-domain contraction
# of a forcing array) once per forcing set rather than on every call or chunk,
# and it still recomputes it for a new forcing set. The document is the
# conformance suite's `lanes_forcing_contraction`.
@testset "lane calls: no allocation, forcing-only values once per forcing set" begin
    path = joinpath(
        @__DIR__, "..", "..", "..", "tests", "conformance", "range_restricted_rhs",
        "fixtures", "lanes_forcing_contraction.esm"
    )
    prob = esm_problem(path, (0.0, 1.0); compiler = :native)
    prog = rhs_program(prob)
    lp = lanes(prog, :cells, ["lon", "lat", "lev"]; chunk = 4)
    LL = lane_layout(lp)
    L = 6                                   # two chunks of 4, the second padded
    cells = Int32[
        3 6 1 2 5 4
        2 5 1 3 4 1
        1 1 2 1 3 1
    ]
    n = 6
    u = [0.5 + 0.1 * l for l in 1:(LL.n_u * L)]
    fs = default_forcing_set(lp)
    ws = rhs_workspace(lp)
    du = fill(NaN, LL.n_u * L)
    # The whole-domain values at each lane's cell.
    function whole(fs_whole)
        W = tile_layout(prog)
        b = only(W.u)
        uw = fill(1.0, W.n_u)
        for l in 1:n
            uw[RRT._tile_slot(b, Tuple(Int.(cells[:, l])))] = u[l]
        end
        dw = fill(NaN, W.n_u)
        rhs!(dw, prog, rhs_workspace(prog), uw, Float64[], prob.p, 0.25, fs_whole)
        return [dw[RRT._tile_slot(b, Tuple(Int.(cells[:, l])))] for l in 1:n]
    end
    bits(x) = reinterpret(UInt64, x)
    rhs!(du, lp, ws, u, Float64[], prob.p, 0.25, fs, cells, n)
    ref = whole(default_forcing_set(prog))
    @test bits.(du[1:n]) == bits.(ref)
    # Steady state: nothing allocated, at a new time and at the same one.
    noaux = Float64[]
    _rrt_lane_allocated(du, lp, ws, u, noaux, prob.p, 0.5, fs, cells, n)
    @test _rrt_lane_allocated(du, lp, ws, u, noaux, prob.p, 0.75, fs, cells, n) == 0
    @test _rrt_lane_allocated(du, lp, ws, u, noaux, prob.p, 0.75, fs, cells, n) == 0
    li = lane_inputs(lp, L)
    _rrt_gather_allocated(li, lp, prob.p, fs, cells, n)
    _rrt_lane_allocated(du, lp, ws, u, noaux, prob.p, 0.25, li, cells, n)
    @test _rrt_gather_allocated(li, lp, prob.p, fs, cells, n) == 0
    @test _rrt_lane_allocated(du, lp, ws, u, noaux, prob.p, 0.5, li, cells, n) == 0
    @test bits.(du[1:n]) == bits.(ref)
    # The forcing-only contraction E is not recomputed by a call under the
    # same forcing set: scribble over the workspace's copy of F (which only
    # E reads; the pre-gathered reads of F come from the set itself) and the
    # lanes still hold the values of the set's F.
    kF = findfirst(s -> s.name == "Emis.F", forcing_slots(lp))
    saved = copy(ws.fbufs[kF])
    ws.fbufs[kF] .= 1.0e6
    rhs!(du, lp, ws, u, Float64[], prob.p, 0.9, fs, cells, n)
    @test bits.(du[1:n]) == bits.(ref)
    ws.fbufs[kF] .= saved
    # A new forcing set: E is recomputed from it.
    F2 = [1.0 + 0.5 * s for s in 1:40]
    fs2 = replace_forcing(fs, kF, F2)
    rhs!(du, lp, ws, u, Float64[], prob.p, 0.25, fs2, cells, n)
    ref2 = whole(replace_forcing(default_forcing_set(prog), kF, F2))
    @test bits.(du[1:n]) == bits.(ref2)
    @test bits.(ref2) != bits.(ref)
    # A cell outside its lane set's range is refused.
    bad = copy(cells)
    bad[2, 3] = 6
    @test_throws ArgumentError rhs!(du, lp, ws, u, Float64[], prob.p, 0.25, fs, bad, n)
    @test_throws ArgumentError gather_lane_inputs!(li, lp, prob.p, 0.25, fs, bad, n)
end
