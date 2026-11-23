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

function fragment_steps(fragment, u, aux, p, t, maxiter)
    i = maxiter - maxiter
    Reactant.@trace while i < maxiter
        u = u .+ fragment(u, aux, p, t, ())
        i += one(i)
    end
    return u
end

@testset "StableHLO operator fragments" begin
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
        ir = operator_ir(prob; outputs = KernelSpec(spec; out_eltype = Float32))
        @test only(ir_layout(ir).out).shape == [3]
        f = emit_fragment(ir)
        u, z = ConcreteRArray([100.0, 200.0, 300.0]), ConcreteRArray(Float64[])
        p = ConcreteRArray(parameter_vector(compile_kernels(prob, [spec])))
        t, dt = ConcreteRNumber(0.0), ConcreteRNumber(0.5)
        run = Reactant.@compile f(u, z, p, t, (), dt)
        @test Array(only(run(u, z, p, t, (), dt))) ≈ Float32[100.125, 200.125, 300.125]
    end

end
