using EarthSciAST
using Reactant
using Test

function fragment_problem(; array = false, n = 4, stencil = false)
    variable(kind, default; shape = nothing) = isnothing(shape) ?
        Dict{String, Any}("type" => kind, "default" => default) :
        Dict{String, Any}("type" => kind, "default" => default, "shape" => shape)
    op(name, args...) = Dict("op" => name, "args" => Any[args...])
    ix(name, i = "i") = op("index", name, i)
    D(name) = merge(op("D", name), Dict("wrt" => "t"))
    faq(expr) = merge(
        op("faq"), Dict(
            "output_idx" => ["i"], "ranges" => Dict("i" => Dict("from" => "cell")),
            "expr" => expr
        )
    )
    vars = Dict("u" => variable("unknown", 1.0), "rate" => variable("parameter", 2.0))
    lhs, rhs = D("u"), op("+", op("*", "rate", "u"), "t")
    if array
        vars["u"]["shape"] = ["cell"]
        vars["data"] = variable("parameter", collect(1.0:n); shape = ["cell"])
        lhs = faq(D(ix("u")))
        expr = op("+", op("*", "rate", ix("u")), ix("data"), "i", "t")
        if stencil
            expr = op("+", expr, ix("u", op("-", "i", 1)), ix("u", op("+", "i", 1)))
        end
        rhs = faq(expr)
    end
    doc = Dict(
        "esm" => "2.0.0", "metadata" => Dict("name" => "Fragment test"),
        "models" => Dict("M" => Dict("variables" => vars, "equations" => [Dict("lhs" => lhs, "rhs" => rhs)]))
    )
    if array
        doc["index_sets"] = Dict("cell" => Dict("kind" => "interval", "size" => n))
    end
    return esm_problem(doc, (0.0, 1.0); runtime_array_parameters = array)
end

# A model over `cell` (size `N`) whose states each get one equation
# `D(name[i]) = rhs`, with constant arrays `arrays` (name => (values, set)).
function cell_problem(eqs::Vector; N = 4, sets = Dict{String, Int}(), arrays = Dict())
    op(name, args...) = Dict("op" => name, "args" => Any[args...])
    faq(expr) = merge(
        op("faq"), Dict(
            "output_idx" => ["i"], "ranges" => Dict("i" => Dict("from" => "cell")),
            "expr" => expr
        )
    )
    vars = Dict{String, Any}("rate" => Dict{String, Any}("type" => "parameter", "default" => 2.0))
    equations = Any[]
    for (name, rhs) in eqs
        vars[name] = Dict{String, Any}("type" => "unknown", "default" => 1.0, "shape" => ["cell"])
        lhs = faq(merge(op("D", op("index", name, "i")), Dict("wrt" => "t")))
        push!(equations, Dict("lhs" => lhs, "rhs" => faq(rhs)))
    end
    for (name, (values, set)) in arrays
        vars[name] = Dict{String, Any}("type" => "parameter", "default" => values, "shape" => [set])
    end
    index_sets = Dict{String, Any}("cell" => Dict("kind" => "interval", "size" => N))
    for (name, n) in sets
        index_sets[name] = Dict("kind" => "interval", "size" => n)
    end
    doc = Dict(
        "esm" => "2.0.0", "metadata" => Dict("name" => "Fragment test"),
        "index_sets" => index_sets,
        "models" => Dict("M" => Dict("variables" => vars, "equations" => equations))
    )
    return esm_problem(doc, (0.0, 1.0))
end

_op(name, args...) = Dict("op" => name, "args" => Any[args...])
_ix(name, sub) = _op("index", name, sub)
_count_ops(mod) = count("stablehlo.", repr(mod))
balanced_sum(xs, lo = 1, hi = length(xs)) = lo == hi ? xs[lo] :
    balanced_sum(xs, lo, (lo + hi) ÷ 2) + balanced_sum(xs, (lo + hi) ÷ 2 + 1, hi)

# The native lane program's derivative at `cells`, the reference for a lane
# fragment.
function native_lanes(prog, cells::Matrix{Int32}, u)
    lp = lanes(prog, :cells, ["cell"])
    L = size(cells, 2)
    du = zeros(L)
    rhs!(
        du, lp, rhs_workspace(lp), u, Float64[], parameter_vector(prog), 0.5,
        default_forcing_set(lp), cells, L
    )
    return du
end

function fragment_steps(fragment, u, aux, p, t, maxiter)
    i = maxiter - maxiter
    Reactant.@trace while i < maxiter
        u = u .+ fragment(u, aux, p, t, ())
        i += one(i)
    end
    return u
end

@testset "StableHLO operator fragments" begin
    @testset "kernel output element types" begin
        spec = Dict("name" => "k", "outputs" => [])
        for T in (Float16, Float32, Float64)
            @test KernelOutputs(spec; out_eltype = T).out_eltype === T
        end
        @test KernelOutputs(spec).out_eltype === nothing
        @test_throws ArgumentError KernelOutputs(spec; out_eltype = BigFloat)
        @test_throws ArgumentError KernelOutputs(spec; out_eltype = Int32)
        @test_throws ArgumentError KernelOutputs(spec, BigFloat)
    end

    @testset "vector parameters and caller-owned loop" begin
        prob = fragment_problem()
        ir = operator_ir(prob)
        @test parameter_names(ir) == ["M.rate"]
        @test isempty(forcing_slots(ir))
        frag = emit_fragment(ir)
        u, aux = ConcreteRArray([1.0]), ConcreteRArray(Float64[])
        p, t = ConcreteRArray([2.0]), ConcreteRNumber(0.5)
        maxiter = ConcreteRNumber(2)
        run = Reactant.@compile fragment_steps(frag, u, aux, p, t, maxiter)
        @test Array(run(frag, u, aux, p, t, maxiter)) ≈ [11.0]
        @test Array(run(frag, ConcreteRArray([1.0]), aux, ConcreteRArray([1.0]), t, maxiter)) ≈ [5.5]

        frag32 = emit_fragment(ir; eltype = Float32)
        u32, aux32 = ConcreteRArray(Float32[1]), ConcreteRArray(Float32[])
        run32 = Reactant.@compile frag32(u32, aux32, p, t, ())
        du32 = Array(run32(u32, aux32, p, t, ()))
        @test eltype(du32) === Float32
        @test du32 ≈ Float32[2.5]
    end

    @testset "tiles and dynamic lane inputs" begin
        prob = fragment_problem(; array = true)
        prog = rhs_program(prob)
        p, t = ConcreteRArray(parameter_vector(prog)), ConcreteRNumber(0.5)
        aux = ConcreteRArray(Float64[])
        forcing = (ConcreteRArray([10.0, 20.0, 30.0, 40.0]),)
        dec = Decomposition(axes = ["cell" => nothing])
        tile = Tile(dec; owned = ["cell" => 2:3], storage = ["cell" => 1:4])
        tile_ir = operator_ir(prog; target = tile)
        @test halo(tile_ir) == halo(prog, dec)
        ft = emit_fragment(tile_ir)
        u = ConcreteRArray(ones(4))
        tile_run = Reactant.@compile ft(u, aux, p, t, forcing)
        @test Array(tile_run(u, aux, p, t, forcing)) ≈ [0.0, 24.5, 35.5, 0.0]
        @test forcing_reach(tile_ir) == [[2:3]]
        window = (ConcreteRArray([20.0, 30.0]),)
        compact_run = Reactant.@compile ft(u, aux, p, t, window)
        @test Array(compact_run(u, aux, p, t, window)) ≈ [0.0, 24.5, 35.5, 0.0]

        lane = operator_ir(prog; target = Lanes(:cells, ["cell"], 3))
        fl = emit_fragment(lane)
        lanes_u = ConcreteRArray([3.0, 1.0, 3.0])
        cells = ConcreteRArray(reshape(Int32[3, 1, 3], 1, 3))
        lane_run = Reactant.@compile fl(lanes_u, aux, p, t, forcing, cells)
        @test Array(lane_run(lanes_u, aux, p, t, forcing, cells)) ≈ [39.5, 13.5, 39.5]
        changed = ConcreteRArray(reshape(Int32[2, 4, 2], 1, 3))
        live = (ConcreteRArray([1.0, 2.0, 3.0, 4.0]),)
        @test Array(lane_run(lanes_u, aux, p, t, live, changed)) ≈ [10.5, 10.5, 10.5]

        full = ConcreteRArray([10.0, 20.0, 30.0, 40.0])
        gathered = Reactant.@compile gather_lanes(lane, full, cells)
        @test Array(gathered(lane, full, cells)) == [30.0, 10.0, 30.0]
        distinct = ConcreteRArray(reshape(Int32[4, 1, 2], 1, 3))
        scattered = Reactant.@compile scatter_lanes(lane, full, lanes_u, distinct)
        @test Array(scattered(lane, full, lanes_u, distinct)) == [1.0, 3.0, 30.0, 3.0]
    end

    @testset "reusable tile with traced origin and compact forcing" begin
        prob = fragment_problem(; array = true)
        prog = rhs_program(prob)
        dec = Decomposition(axes = ["cell" => nothing])
        input_boxes = [(owned = ["cell" => r], storage = ["cell" => r]) for r in (1:2, 3:4)]
        target = only(tile_classes(prog, dec, input_boxes))
        ir = operator_ir(prog; target)
        @test forcing_reach(ir, [1]) == [[1:2]]
        @test forcing_reach(ir, [3]) == [[3:4]]
        @test_throws ArgumentError forcing_reach(ir, [2])
        f = emit_fragment(ir)
        u, aux = ConcreteRArray([1.0, 2.0]), ConcreteRArray(Float64[])
        p, t = ConcreteRArray(parameter_vector(prog)), ConcreteRNumber(0.5)
        first_forcing = (ConcreteRArray([10.0, 20.0]),)
        first_origin = ConcreteRArray(Int32[1])
        run = Reactant.@compile f(u, aux, p, t, first_forcing, first_origin)
        @test Array(run(u, aux, p, t, first_forcing, first_origin)) ≈ [13.5, 26.5]
        second_forcing = (ConcreteRArray([30.0, 40.0]),)
        second_origin = ConcreteRArray(Int32[3])
        @test Array(run(u, aux, p, t, second_forcing, second_origin)) ≈ [35.5, 48.5]
    end

    @testset "boundary classes preserve stencil reach" begin
        prob = fragment_problem(; array = true, n = 8, stencil = true)
        prog = rhs_program(prob)
        dec = Decomposition(axes = ["cell" => nothing])
        owned = [1:2, 3:4, 5:6, 7:8]
        stored = [1:3, 2:5, 4:7, 6:8]
        classes = tile_classes(
            prog, dec, [(owned = ["cell" => b], storage = ["cell" => s]) for (b, s) in zip(owned, stored)]
        )
        @test length(classes) == 3
        inner = operator_ir(prog; target = classes[2])
        @test halo(inner) == Dict(("M.u", "cell") => (1, 1))
        @test forcing_reach(inner, [5]) == [[5:6]]
        frag = emit_fragment(inner)
        aux = ConcreteRArray(Float64[])
        p, t = ConcreteRArray(parameter_vector(prog)), ConcreteRNumber(0.5)
        u, forcing, origin = ConcreteRArray(collect(2.0:5.0)), (ConcreteRArray([8.0, 9.0]),), ConcreteRArray(Int32[3])
        step = Reactant.@compile frag(u, aux, p, t, forcing, origin)
        @test Array(step(u, aux, p, t, forcing, origin)) ≈ [0.0, 23.5, 29.5, 0.0]
        moved_u, moved_forcing, moved_origin = ConcreteRArray(collect(4.0:7.0)), (ConcreteRArray([10.0, 11.0]),), ConcreteRArray(Int32[5])
        @test Array(step(moved_u, aux, p, t, moved_forcing, moved_origin)) ≈ [0.0, 35.5, 41.5, 0.0]
    end

    @testset "standalone observed outputs" begin
        fixture = joinpath(@__DIR__, "../../../../tests/conformance/strip_and_expose/fixtures/geometry_step_map.esm")
        prob = esm_problem(fixture, (0.0, 1.0))
        spec = Dict(
            "name" => "geometry_source_value", "dt_params" => ["Geometry.dt"],
            "outputs" => [Dict("observed" => "Geometry.H_out_source")]
        )
        ir = operator_ir(prob; outputs = KernelOutputs(spec; out_eltype = Float32))
        @test only(ir_layout(ir).out).shape == [3]
        f = emit_fragment(ir)
        u, z = ConcreteRArray([100.0, 200.0, 300.0]), ConcreteRArray(Float64[])
        p = ConcreteRArray(parameter_vector(compile_kernels(prob, [spec])))
        t, dt = ConcreteRNumber(0.0), ConcreteRNumber(0.5)
        run = Reactant.@compile f(u, z, p, t, (), dt)
        @test Array(only(run(u, z, p, t, (), dt))) ≈ Float32[100.125, 200.125, 300.125]
    end


    @testset "lane gathers on bounded constant arrays" begin
        # A document cannot declare a constant array's boundary policy, so the
        # lane gather's source is replaced with a bounded copy that reads
        # `data[i + 1]`. The fragment must trace with no `:error` dimension.
        data = [10.0, 20.0, 30.0, 40.0]
        prob = cell_problem(
            ["u" => _op("+", _op("*", "rate", _ix("u", "i")), _ix("data", "i"))];
            arrays = Dict("data" => (data, "cell"))
        )
        prog = rhs_program(prob)
        p, t = ConcreteRArray(parameter_vector(prog)), ConcreteRNumber(0.5)
        aux = ConcreteRArray(Float64[])
        cells = Int32[4 1 2]
        u = [1.0, 2.0, 3.0]
        ESA = EarthSciAST
        for (policy, expected) in ((:periodic, [10.0, 20.0, 30.0]), (:clamp, [40.0, 20.0, 30.0]))
            ir = operator_ir(prog; target = Lanes(:cells, ["cell"], 3))
            g = only(ir.extra[1])
            sub = ESA.OpExpr("+", ESA.ASTExpr[ESA.VarExpr(first(only(g.vars))), ESA.IntExpr(1)])
            ir.extra[1][1] = ESA._LaneGather(
                g.buf, ESA.BoundedConstArray(copy(data), (policy,)), g.dims, g.name, [sub],
                g.vars, g.consts
            )
            # The host evaluator of the same read under the same policy.
            f!, u0, hp, _, vmap = ESA.Internal.build(
                Dict(
                    "esm" => "2.0.0", "metadata" => Dict("name" => "bounded"),
                    "index_sets" => Dict("cell" => Dict("kind" => "interval", "size" => 4)),
                    "models" => Dict(
                        "M" => Dict(
                            "variables" => Dict(
                                "y" => Dict("type" => "unknown", "default" => 0.0, "shape" => ["cell"]),
                                "data" => Dict("type" => "parameter", "default" => data, "shape" => ["cell"])
                            ),
                            "equations" => [
                                Dict(
                                    "lhs" => merge(
                                        _op("faq"), Dict(
                                            "output_idx" => ["i"], "ranges" => Dict("i" => Dict("from" => "cell")),
                                            "expr" => merge(_op("D", _ix("y", "i")), Dict("wrt" => "t"))
                                        )
                                    ),
                                    "rhs" => merge(
                                        _op("faq"), Dict(
                                            "output_idx" => ["i"], "ranges" => Dict("i" => Dict("from" => "cell")),
                                            "expr" => _ix("data", _op("+", "i", 1))
                                        )
                                    ),
                                ),
                            ]
                        )
                    )
                );
                const_array_boundaries = Dict("M.data" => [policy])
            )
            du = similar(u0)
            f!(du, u0, hp, 0.0)
            host = [du[vmap["M.y[$c]"]] for c in vec(cells)]
            @test host == expected
            fl = emit_fragment(ir)
            run = Reactant.@compile fl(ConcreteRArray(u), aux, p, t, (), ConcreteRArray(cells))
            out = Array(run(ConcreteRArray(u), aux, p, t, (), ConcreteRArray(cells)))
            @test out ≈ 2.0 .* u .+ host
        end
    end

    @testset "lane gathers on unbounded constant arrays" begin
        # The whole-domain build refuses an unguarded read past the edge, so a
        # lane gather that leaves the range is always one a guard discards. It
        # reads 0.0 there, as the native lane program does, and the value of
        # the array inside the range.
        data = [10.0, 20.0, 30.0, 40.0]
        rhs = _op(
            "+", _op("*", "rate", _ix("u", "i")),
            _op("ifelse", _op("<", "i", 4), _ix("data", _op("+", "i", 1)), 0.0)
        )
        prob = cell_problem(["u" => rhs]; arrays = Dict("data" => (data, "cell")))
        prog = rhs_program(prob)
        cells = Int32[4 1 3]
        u = [1.0, 2.0, 3.0]
        ref = native_lanes(prog, cells, u)
        @test ref ≈ [2.0, 24.0, 46.0]
        fl = emit_fragment(operator_ir(prog; target = Lanes(:cells, ["cell"], 3)))
        p, t = ConcreteRArray(parameter_vector(prog)), ConcreteRNumber(0.5)
        args = (ConcreteRArray(u), ConcreteRArray(Float64[]), p, t, (), ConcreteRArray(cells))
        run = Reactant.@compile fl(args...)
        @test Array(run(args...)) ≈ ref

        @test_throws EarthSciAST.TreeWalkError cell_problem(
            ["u" => _ix("data", _op("+", "i", 1))]; arrays = Dict("data" => (data, "cell"))
        )
    end

    @testset "constant folds stay on the host" begin
        # Σ_k w[k] * k over a long constant table reads the loop counter, so
        # the build keeps the loop and the emitter unrolls it. It folds to one
        # constant under both fold policies instead of one op per entry.
        K = 200
        w = collect(range(0.1, 2.0; length = K))
        sum_k = merge(
            _op("faq"), Dict(
                "output_idx" => [], "ranges" => Dict("k" => Dict("from" => "k")),
                "expr" => _op("*", _ix("w", "k"), "k")
            )
        )
        prob = cell_problem(
            ["u" => _op("*", _ix("u", "i"), sum_k)];
            sets = Dict("k" => K), arrays = Dict("w" => (w, "k"))
        )
        prog = rhs_program(prob)
        u0 = [1.0, 2.0, 3.0, 4.0]
        du = zeros(4)
        rhs!(du, prog, rhs_workspace(prog), u0, Float64[], parameter_vector(prog), 0.0, default_forcing_set(prog))
        ir = operator_ir(prog)
        u, aux = ConcreteRArray(u0), ConcreteRArray(Float64[])
        p, t = ConcreteRArray(parameter_vector(prog)), ConcreteRNumber(0.0)
        for fold in (:tree, :reduce)
            frag = emit_fragment(ir; fold)
            @test _count_ops(Reactant.@code_hlo optimize = false frag(u, aux, p, t, ())) < 60
            run = Reactant.@compile frag(u, aux, p, t, ())
            out = Array(run(u, aux, p, t, ()))
            @test out ≈ du rtol = 1.0e-13
            # A tree fold groups the host fold as it groups emitted terms: the
            # seed, then the terms, split in halves.
            fold === :tree && @test out == u0 .* balanced_sum([0.0; w .* (1:K)])
        end
    end

    @testset "lane scatter drops cells outside the domain" begin
        prob = cell_problem(["u" => _ix("u", "i"), "v" => _ix("v", "i")])
        prog = rhs_program(prob)
        lane = operator_ir(prog; target = Lanes(:cells, ["cell"], 3))
        full = ConcreteRArray(collect(1.0:8.0))
        updates = ConcreteRArray([-1.0, -2.0, -3.0, -4.0, -5.0, -6.0])
        cells = ConcreteRArray(reshape(Int32[2, 5, 0], 1, 3))
        scattered = Reactant.@compile scatter_lanes(lane, full, updates, cells)
        # Lane 1 writes cell 2 of u and v; cell 5 would land on v's first cell
        # and cell 0 on u's last, and both are dropped.
        @test Array(scattered(lane, full, updates, cells)) == [1.0, -1.0, 3.0, 4.0, 5.0, -4.0, 7.0, 8.0]
    end

end
