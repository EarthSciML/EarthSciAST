using EarthSciAST
using JSON3
using Reactant
using Test

function fragment_problem(; array = false, n = 4, stencil = false, version = "2.0.0")
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
        "esm" => version, "metadata" => Dict("name" => "Fragment test"),
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

function fragment_rk4(fragment, u, aux, p, t, forcing, cells, dt, stop)
    Reactant.@trace while t < stop
        k1 = fragment(u, aux, p, t, forcing, cells)
        k2 = fragment(u .+ (dt / 2) .* k1, aux, p, t + dt / 2, forcing, cells)
        k3 = fragment(u .+ (dt / 2) .* k2, aux, p, t + dt / 2, forcing, cells)
        k4 = fragment(u .+ dt .* k3, aux, p, t + dt, forcing, cells)
        u = u .+ (dt / 6) .* ((k1 .+ 2 .* k2) .+ (2 .* k3 .+ k4))
        t += dt
    end
    return u
end

function fragment_column_problem(n, levels)
    op(name, args...) = Dict("op" => name, "args" => Any[args...])
    ix(name, i, k) = op("index", name, i, k)
    D(v) = merge(op("D", v), Dict("wrt" => "t"))
    faq(body) = Dict(
        "op" => "faq", "args" => [], "output_idx" => ["i", "k"],
        "ranges" => Dict("i" => Dict("from" => "cell"), "k" => Dict("from" => "lev")), "expr" => body
    )
    shape = ["cell", "lev"]
    vars = Dict(
        "u" => Dict("type" => "unknown", "default" => 1.0, "shape" => shape),
        "data" => Dict("type" => "parameter", "shape" => shape)
    )
    # Clamping a nonlinear source index retains lane
    # independence. The vertical state stencil remains within each column.
    shifted = op("+", op("*", "i", "i"), 1, op("floor", op("/", op("-", "i"), 2)))
    source = op("min", shifted, n)
    expr = faq(op("+", ix("u", "i", op("-", "k", 1)), ix("data", source, "k")))
    doc = Dict(
        "esm" => "2.0.0", "metadata" => Dict("name" => "Column fragment test"),
        "index_sets" => Dict(
            "cell" => Dict("kind" => "interval", "size" => n),
            "lev" => Dict("kind" => "interval", "size" => levels)
        ),
        "models" => Dict("M" => Dict("variables" => vars, "equations" => [Dict("lhs" => faq(D(ix("u", "i", "k"))), "rhs" => expr)]))
    )
    data = [Float64(i + k) for i in 1:n, k in 1:levels]
    return esm_problem(doc, (0.0, 1.0); param_arrays = Dict("M.data" => data))
end

function fragment_rk4_inputs()
    prob = fragment_problem(; array = true)
    ir = operator_ir(prob; target = Lanes(:cells, ["cell"], 3))
    args = (
        ConcreteRArray([0.125, 1.25, 2.5]), ConcreteRArray(Float64[]),
        ConcreteRArray([2.0]), ConcreteRNumber(0.125),
        (ConcreteRArray([1.25, 2.5, 3.75, 5.0]),),
        ConcreteRArray(reshape(Int32[3, 1, 3], 1, 3)),
        ConcreteRNumber(0.125), ConcreteRNumber(0.375),
    )
    return emit_fragment(ir), args
end

function fragment_rk4_program()
    f, args = fragment_rk4_inputs()
    run = Reactant.@compile donated_args = :none fragment_rk4(f, args...)
    return f, args, run
end

# A lane model whose right-hand side references the template `sq` twice, with
# different arguments: `D(u[i]) = sq(u[i]) + sq(0.5 u[i] + data[i])`.
function template_problem(; n = 6)
    op(name, args...) = Dict{String, Any}("op" => name, "args" => Any[args...])
    ix(name) = op("index", name, "i")
    faq(expr) = merge(
        op("faq"), Dict(
            "output_idx" => ["i"], "ranges" => Dict("i" => Dict("from" => "cell")), "expr" => expr
        )
    )
    sq(w) = Dict{String, Any}(
        "op" => "apply_operator", "args" => Any[], "name" => "sq",
        "bindings" => Dict{String, Any}("w" => w)
    )
    vars = Dict{String, Any}(
        "u" => Dict{String, Any}("type" => "unknown", "default" => 1.0, "shape" => ["cell"]),
        "data" => Dict{String, Any}("type" => "parameter", "default" => collect(1.0:n), "shape" => ["cell"]),
    )
    rhs = faq(op("+", sq(ix("u")), sq(op("+", op("*", 0.5, ix("u")), ix("data")))))
    lhs = faq(merge(op("D", ix("u")), Dict("wrt" => "t")))
    doc = Dict(
        "esm" => "2.4.0", "metadata" => Dict("name" => "Template calls"),
        "index_sets" => Dict("cell" => Dict("kind" => "interval", "size" => n)),
        "models" => Dict(
            "M" => Dict(
                "variables" => vars, "equations" => [Dict("lhs" => lhs, "rhs" => rhs)],
                "operators" => Dict(
                    "sq" => Dict(
                        "params" => ["w"],
                        "body" => op("-", op("*", "w", "w"), op("*", 0.25, "w")),
                    )
                ),
            )
        ),
    )
    return esm_problem(doc, (0.0, 1.0))
end
one_call(fragment, u, aux, p, t) = fragment(u, aux, p, t, ())

if get(ENV, "ESM_REACTANT_FRAGMENT_CHILD", "") == "1"
    f, args, run = fragment_rk4_program()
    println(join(reinterpret(UInt64, Array(run(f, args...))), ","))
    exit()
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

    @testset "template references are called functions" begin
        prob = template_problem()
        ir = operator_ir(prob)
        f, g = emit_fragment(ir), emit_fragment(ir; calls = :inline)
        u = ConcreteRArray(collect(range(-0.5, 1.5; length = 6)))
        aux, p, t = ConcreteRArray(Float64[]), ConcreteRArray(Float64[]), ConcreteRNumber(0.0)
        hf = repr(Reactant.@code_hlo optimize = false one_call(f, u, aux, p, t))
        hg = repr(Reactant.@code_hlo optimize = false one_call(g, u, aux, p, t))
        # One private function for `sq`, called at both uses; none inline.
        @test count(r"func\.func private @[^(]*esm_tpl_sq", hf) == 1
        @test count(r"call @[^(]*esm_tpl_sq", hf) == 2
        @test !occursin("esm_tpl_", hg)
        @test !occursin("func.call", hg)
        uh = Array(u)
        expected = (uh .* uh .- 0.25 .* uh) .+ (w -> w * w - 0.25 * w).(0.5 .* uh .+ (1.0:6.0))
        rf = Reactant.@compile one_call(f, u, aux, p, t)
        rg = Reactant.@compile one_call(g, u, aux, p, t)
        @test Array(rf(f, u, aux, p, t)) ≈ expected rtol = 1.0e-14
        @test Array(rg(g, u, aux, p, t)) ≈ expected rtol = 1.0e-14
    end

    @testset "an RK4 leaf emits the operator once" begin
        f, args = fragment_rk4_inputs()
        h = repr(Reactant.@code_hlo optimize = false fragment_rk4(f, args...))
        @test count(r"func\.func private @[^(]*_fragment_body", h) == 1
        @test count(r"call @[^(]*_fragment_body", h) == 4
        g = emit_fragment(f.ir; calls = :inline)
        hg = repr(Reactant.@code_hlo optimize = false fragment_rk4(g, args...))
        @test !occursin("_fragment_body", hg)
        run_f = Reactant.@compile donated_args = :none fragment_rk4(f, args...)
        run_g = Reactant.@compile donated_args = :none fragment_rk4(g, args...)
        @test Array(run_f(f, args...)) ≈ Array(run_g(g, args...)) rtol = 1.0e-14
        @test_throws EarthSciAST.DirectEmitError emit_fragment(f.ir; calls = :sometimes)
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

        @test_throws EarthSciAST.SimulateError emit_fragment(ir; eltype = Float32)
        ir32 = operator_ir(fragment_problem(; version = "2.4.0"); unspecified_eltype = Float32)
        frag32 = emit_fragment(ir32; eltype = Float32)
        @test_throws EarthSciAST.SimulateError emit_fragment(ir32; eltype = Float64)
        u32, aux32 = ConcreteRArray(Float32[1]), ConcreteRArray(Float32[])
        run32 = Reactant.@compile frag32(u32, aux32, p, t, ())
        du32 = Array(run32(u32, aux32, p, t, ()))
        @test eltype(du32) === Float32
        @test du32 ≈ Float32[2.5]
    end

    @testset "external evaluation precision" begin
        fixture = joinpath(@__DIR__, "..", "..", "..", "..", "tests", "conformance", "precision_source", "rounding.esm")
        function witness()
            return JSON3.read(read(fixture, String), Dict{String, Any})
        end
        problem(doc) = esm_problem(doc, (0.0, 1.0))
        function refusal(doc)
            err = try
                operator_ir(problem(doc); unspecified_eltype = Float32)
                nothing
            catch e
                e
            end
            @test err isa EarthSciAST.SimulateError
            return err
        end
        prob = problem(witness())
        u64, aux64 = ConcreteRArray(zeros(2)), ConcreteRArray(Float64[])
        u32, aux32 = ConcreteRArray(zeros(Float32, 2)), ConcreteRArray(Float32[])
        p, t = ConcreteRArray([73.5]), ConcreteRNumber(0.0)

        frag64 = emit_fragment(operator_ir(prob))
        run64 = Reactant.@compile frag64(u64, aux64, p, t, ())
        @test Array(run64(u64, aux64, p, t, ())) == [1.0, 1.0]
        frag32 = emit_fragment(operator_ir(prob; unspecified_eltype = Float32))
        run32 = Reactant.@compile frag32(u32, aux32, p, t, ())
        @test Array(run32(u32, aux32, p, t, ())) == fill(prevfloat(1.0f0), 2)

        legacy = witness()
        legacy["esm"] = "2.3.0"
        @test refusal(legacy).code == "precision_choice_conflict"
        declared = witness()
        declared["domain"] = Dict("element_type" => "Float64")
        @test refusal(declared).code == "precision_choice_conflict"
        mixed = witness()
        mixed["models"]["M"]["variables"]["a"]["element_type"] = "Float64"
        err = refusal(mixed)
        @test err.code == "precision_choice_conflict"
        @test occursin("M.a", sprint(showerror, err))
        @test occursin("M.x", sprint(showerror, err))

        key = witness()
        key["models"]["M"]["equations"][1]["rhs"]["expr"] =
            _op("ifelse", _op("==", "a", 73.5), 1.0, 0.0)
        @test refusal(key).code == "key_precision_unspecified"

        fold = witness()
        fold["models"]["M"]["equations"][1]["rhs"]["expr"] =
            _op("+", 1.0e8, "a", -1.0e8, 1.0)
        frag = emit_fragment(operator_ir(problem(fold); unspecified_eltype = Float32))
        ones_p = ConcreteRArray([1.0])
        run = Reactant.@compile frag(u32, aux32, ones_p, t, ())
        @test Array(run(u32, aux32, ones_p, t, ())) == Float32[1, 1]

        # A declared-binary64 key compared exactly feeds the binary32 group
        # (esm-spec §11.3.3 P8). Binary32 spaces its integers 256 apart
        # here, so a comparison rounded to it would match the next id too.
        declared_key(rhs) = begin
            doc = witness()
            doc["models"]["M"]["variables"]["id"] = Dict(
                "type" => "parameter", "default" => 2260007000, "units" => "1",
                "element_type" => "Float64"
            )
            doc["models"]["M"]["equations"][1]["rhs"]["expr"] = rhs
            doc
        end
        quantity = witness()["models"]["M"]["equations"][1]["rhs"]["expr"]
        selected = _op("ifelse", _op("==", "id", 2260007000), quantity, 0.0)
        ir = operator_ir(problem(declared_key(selected)); unspecified_eltype = Float32)
        @test ir.working_eltype === Float32
        @test ir.binary64_keys == ["M.id"]
        frag = emit_fragment(ir)
        @test parameter_names(ir) == ["M.a", "M.id"]
        hit, miss = ConcreteRArray([73.5, 2260007000.0]), ConcreteRArray([73.5, 2260007001.0])
        run = Reactant.@compile frag(u32, aux32, hit, t, ())
        @test Array(run(u32, aux32, hit, t, ())) == fill(prevfloat(1.0f0), 2)
        @test Array(run(u32, aux32, miss, t, ())) == Float32[0, 0]
        # The key reaching binary32 arithmetic is a quantity, and mixes.
        err = refusal(declared_key(_op("+", selected, "id")))
        @test err.code == "precision_choice_conflict"
        @test occursin("M.id declares Float64", sprint(showerror, err))
        # A key compared with a computed operand cannot be compared in binary64.
        computed = _op("ifelse", _op("==", "id", _op("*", "a", 2.0)), quantity, 0.0)
        computed_ir = operator_ir(problem(declared_key(computed)); unspecified_eltype = Float32)
        computed_frag = emit_fragment(computed_ir)
        @test_throws EarthSciAST.DirectEmitError Reactant.@compile computed_frag(u32, aux32, hit, t, ())

        # A sum the build evaluates once in binary64 (a table of a
        # build-time-evaluable subexpression) cannot be rounded per operation
        # by a binary32 fragment, so the request is refused.
        table = witness()
        table["index_sets"]["k"] = Dict("kind" => "interval", "size" => 3)
        table["models"]["M"]["variables"]["W"] = Dict(
            "type" => "parameter", "units" => "s", "shape" => ["cells", "k"],
            "default" => [[1.0e8, 1.0, -1.0e8], [1.0e8, 3.0, -1.0e8]]
        )
        neighbours = _op("+", _ix("x", _op("-", "i", 1)), _ix("x", _op("+", "i", 1)))
        row = merge(
            _op("faq"), Dict(
                "expr" => _op("index", "W", "i", "kk"), "reduce" => "+", "output_idx" => [],
                "ranges" => Dict("kk" => Dict("from" => "k"))
            )
        )
        table["models"]["M"]["equations"][1]["rhs"]["expr"] = _op("+", neighbours, row)
        err = refusal(table)
        @test err.code == "float32_unsupported"
        @test occursin("build-time-evaluable", sprint(showerror, err))
    end

    @testset "four stage sites and runtime input changes" begin
        f, args, run = fragment_rk4_program()
        u, aux, p, t, forcing, cells, dt, stop = args
        stage = Reactant.@compile donated_args = :none f(u, aux, p, t, forcing, cells)
        initial, start = Array(u), Float64(t)
        # Reactant writes back loop carries. Reset state and time at each
        # invocation so every comparison actually takes the same steps.
        run_steps(q, time, fs, cs) =
            Array(run(f, ConcreteRArray(initial), aux, q, ConcreteRNumber(time), fs, cs, dt, stop))
        function host_steps(p, time, forcing, cells)
            h = Float64(dt)
            value = copy(initial)
            compute(v, time) = Array(stage(ConcreteRArray(v), aux, p, ConcreteRNumber(time), forcing, cells))
            while time < Float64(stop)
                k1 = compute(value, time)
                k2 = compute(value .+ h / 2 .* k1, time + h / 2)
                k3 = compute(value .+ h / 2 .* k2, time + h / 2)
                k4 = compute(value .+ h .* k3, time + h)
                value = value .+ h / 6 .* ((k1 .+ 2 .* k2) .+ (2 .* k3 .+ k4))
                time += h
            end
            return value
        end
        expected = host_steps(p, start, forcing, cells)
        first = run_steps(p, start, forcing, cells)
        @test first ≈ expected rtol = 1.0e-12
        @test first == run_steps(p, start, forcing, cells)
        for (changed, q, time, fs, cs) in (
                ("parameters", ConcreteRArray([3.0]), start, forcing, cells),
                ("time", p, 0.0, forcing, cells),
                ("forcing", p, start, (ConcreteRArray([2.0, 4.0, 6.0, 8.0]),), cells),
                ("cells", p, start, forcing, ConcreteRArray(reshape(Int32[1, 3, 1], 1, 3))),
            )
            @testset "changed $changed" begin
                got = run_steps(q, time, fs, cs)
                @test got ≈ host_steps(q, time, fs, cs) rtol = 1.0e-12
                @test got != first
            end
        end
    end

    @testset "column gathers and level batching" begin
        function column_run(levels, capacity)
            n = 8
            prob = fragment_column_problem(n, levels)
            prog = rhs_program(prob)
            whole = emit_fragment(operator_ir(prog))
            lane = emit_fragment(operator_ir(prog; target = Lanes(:columns, ["cell"], capacity)))
            tile = emit_fragment(
                operator_ir(prog; target = Tile(Decomposition(axes = ["cell" => nothing]); owned = ["cell" => 1:capacity], storage = ["cell" => 1:capacity]))
            )
            cell_ids = reverse(collect(1:capacity))
            state = reshape(collect(Float64, 1:(n * levels)), n, levels)
            forcing = (ConcreteRArray(2 .* vec(state)),)
            empty = ConcreteRArray(Float64[])
            t = ConcreteRNumber(0.0)
            u = ConcreteRArray(vec(state))
            ul = ConcreteRArray(vec(state[cell_ids, :]))
            ut = ConcreteRArray(vec(state[1:capacity, :]))
            cells = ConcreteRArray(reshape(Int32.(cell_ids), 1, capacity))
            fw = Reactant.@compile whole(u, empty, empty, t, forcing)
            fl = Reactant.@compile lane(ul, empty, empty, t, forcing, cells)
            ref = reshape(Array(fw(u, empty, empty, t, forcing)), n, levels)
            @test Array(fl(ul, empty, empty, t, forcing, cells)) ≈ vec(ref[cell_ids, :])
            hl = repr(Reactant.@code_hlo optimize = false lane(ul, empty, empty, t, forcing, cells))
            ht = repr(Reactant.@code_hlo optimize = false tile(ut, empty, empty, t, forcing))
            return count("stablehlo.", hl), count("stablehlo.", ht)
        end
        baseline = column_run(4, 3)
        @test column_run(4, 5) == baseline
        @test column_run(8, 3) == baseline
    end

    @testset "fragment metadata is a trace leaf" begin
        function key(fragment)
            seen = Reactant.OrderedIdDict()
            path = Any[]
            Reactant.make_tracer(seen, fragment, path, Reactant.TracedToTypes)
            return path
        end
        ir = operator_ir(fragment_problem())
        function with_payload(n)
            node = EarthSciAST._mknode(kind = EarthSciAST._NK_LITERAL, literal = 1.0)
            metadata = fill(node, n)
            return emit_fragment(OperatorIR(ir.f, ir.layout, ir.maps, ir.target, metadata, ir.params, ir.forcing))
        end
        small, large = with_payload(1_000), with_payload(1_000_000)
        @test only(key(small)) === small
        @test only(key(large)) === large
        # Both calls are warm. A recursive trace-key traversal would allocate
        # proportional to the payload and introduce one path entry per node.
        @test (@allocated key(large)) <= (@allocated key(small)) + 4096
    end

    if get(ENV, "ESM_TEST_REACTANT_REPRO", "0") == "1"
        @testset "fresh-process reproducibility" begin
            cmd = `$(Base.julia_cmd()) --project=$(dirname(Base.active_project())) $(@__FILE__)`
            probe = addenv(cmd, "ESM_REACTANT_FRAGMENT_CHILD" => "1")
            a = read(probe, String)
            b = read(probe, String)
            @test occursin(r"^\d+,\d+,\d+\s*$", a)
            @test a == b
        end
    end

    @testset "concurrent independent traces" begin
        f, args = fragment_rk4_inputs()
        g = emit_fragment(f.ir; fold = :reduce)
        # Reactant names each called function with a process-wide counter
        # (`##_fragment_body#142`), so traces are compared without it.
        trace(fragment) = replace(
            repr(Reactant.@code_hlo optimize = false fragment_rk4(fragment, args...)),
            r"(##[A-Za-z0-9_]+)#[0-9]+" => s"\1"
        )
        expected = (trace(f), trace(g))
        ready = Channel{Nothing}(2)
        go = Base.Event()
        function gated_trace(fragment)
            put!(ready, nothing)
            wait(go)
            return trace(fragment)
        end
        a = Threads.@spawn gated_trace(f)
        b = Threads.@spawn gated_trace(g)
        take!(ready)
        take!(ready)
        notify(go)
        @test fetch(a) == expected[1]
        @test fetch(b) == expected[2]
    end

    if get(ENV, "ESM_TEST_REACTANT_GPU", "0") == "1"
        @testset "per-device tile programs" begin
            platform = get(ENV, "EARTHSCI_JULIA_XLA_DEVICE", "gpu")
            devices = Reactant.addressable_devices(platform)
            @test length(devices) >= 4
            prob = fragment_problem(; array = true, n = 8)
            prog = rhs_program(prob)
            dec = Decomposition(axes = ["cell" => nothing])
            ranges = [1:2, 3:4, 5:6, 7:8]
            target = only(tile_classes(prog, dec, [(owned = ["cell" => r], storage = ["cell" => r]) for r in ranges]))
            ir = operator_ir(prog; target)
            tile = emit_fragment(ir)
            whole = emit_fragment(operator_ir(prog))
            state, data = collect(1.0:8.0), collect(11.0:18.0)
            params = parameter_vector(prog)
            function run_tile(device, r)
                u = ConcreteRArray(state[r]; device)
                z = ConcreteRArray(Float64[]; device)
                p = ConcreteRArray(params; device)
                t = ConcreteRNumber(0.5; device)
                (window,) = only(forcing_reach(ir, [first(r)]))
                fs = (ConcreteRArray(data[window]; device),)
                origin = ConcreteRArray(Int32[first(r)]; device)
                tile_step = Reactant.@compile tile(u, z, p, t, fs, origin)
                return Array(tile_step(u, z, p, t, fs, origin))
            end
            device = first(devices)
            u = ConcreteRArray(state; device)
            z = ConcreteRArray(Float64[]; device)
            p = ConcreteRArray(params; device)
            t = ConcreteRNumber(0.5; device)
            fs = (ConcreteRArray(data; device),)
            whole_step = Reactant.@compile whole(u, z, p, t, fs)
            reference = Array(whole_step(u, z, p, t, fs))
            result = map(run_tile, devices[1:4], ranges)
            @test reduce(vcat, result) ≈ reference rtol = 1.0e-12
        end
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
        # A selection builds a new program per call, which no class belongs to.
        err = try
            operator_ir(prob; select = RhsSelection(writes = ["M.u"]), target)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("select", err.msg)
        selected = EarthSciAST.select(prog; writes = ["M.u"])
        selected_target = only(tile_classes(selected, dec, input_boxes))
        @test operator_ir(selected; target = selected_target) isa EarthSciAST.OperatorIR
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

    @testset "PPM interior tiles share a program" begin
        root = joinpath(@__DIR__, "../../../../tests/conformance/range_restricted_rhs/fixtures/esd/problems")
        fixture = joinpath(root, "advection_1d_ppm_periodic.esm")
        prob = esm_problem(fixture, (0.0, 1.0); metaparameters = Dict("N" => 24))
        prog = rhs_program(prob)
        dec = Decomposition(axes = ["x" => 24])
        owned = [5:8, 13:16]
        stored = [2:11, 10:19]
        target = only(tile_classes(prog, dec, [(owned = ["x" => b], storage = ["x" => s]) for (b, s) in zip(owned, stored)]))
        whole = emit_fragment(operator_ir(prog))
        tile = emit_fragment(operator_ir(prog; target))
        state = [sin(i / 4) + i / 10 for i in 1:24]
        u, aux = ConcreteRArray(state), ConcreteRArray(Float64[])
        p, t = ConcreteRArray(parameter_vector(prog)), ConcreteRNumber(0.5)
        reference = Reactant.@compile whole(u, aux, p, t, ())
        expected = Array(reference(u, aux, p, t, ()))
        u1, origin1 = ConcreteRArray(state[stored[1]]), ConcreteRArray(Int32[5])
        step = Reactant.@compile tile(u1, aux, p, t, (), origin1)
        for (cells, storage) in zip(owned, stored)
            v = ConcreteRArray(state[storage])
            origin = ConcreteRArray(Int32[first(cells)])
            got = Array(step(v, aux, p, t, (), origin))
            want = [i in cells ? expected[i] : 0.0 for i in storage]
            @test got ≈ want rtol = 1.0e-12
        end
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

        outputs = KernelOutputs(spec; out_eltype = Float32)
        dec = Decomposition(axes = ["x" => nothing])
        boxes = [(owned = ["x" => i:i], storage = ["x" => i:i]) for i in 1:3]
        target = only(tile_classes(prob, dec, boxes; outputs))
        tiled = operator_ir(prob; target, outputs)
        @test only(ir_layout(tiled).out).shape == [1]
        ft = emit_fragment(tiled)
        ut = ConcreteRArray([100.0])
        origin = ConcreteRArray(Int32[1])
        run_tile = Reactant.@compile ft(ut, z, p, t, (), origin, dt)
        @test Array(only(run_tile(ut, z, p, t, (), origin, dt))) ≈ Float32[100.125]
        @test Array(only(run_tile(ConcreteRArray([300.0]), z, p, t, (), ConcreteRArray(Int32[3]), dt))) ≈ Float32[300.125]

        lane = operator_ir(prob; target = Lanes(:cells, ["x"], 2), outputs)
        @test only(ir_layout(lane).out).shape == [2]
        fl = emit_fragment(lane)
        ul = ConcreteRArray([300.0, 100.0])
        cells = ConcreteRArray(reshape(Int32[3, 1], 1, 2))
        run_lane = Reactant.@compile fl(ul, z, p, t, (), cells, dt)
        @test Array(only(run_lane(ul, z, p, t, (), cells, dt))) ≈ Float32[300.125, 100.125]
        gather = Reactant.@compile gather_lanes(lane, u, cells)
        @test Array(gather(lane, u, cells)) == [300.0, 100.0]

        reduced = operator_ir(prob; outputs = KernelOutputs(spec; out_eltype = Reactant.BFloat16))
        fb = emit_fragment(reduced)
        bf = Reactant.@compile fb(u, z, p, t, (), dt)
        @test Array(only(bf(u, z, p, t, (), dt))) == Reactant.BFloat16[100.125, 200.125, 300.125]
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
                g.vars, g.consts, g.columns
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

    @testset "faq fields inside a lane rule see the lane index" begin
        # The fragment lowerer gives a nested faq's bound indices their own
        # scope. Every field of the node must still be lane-rewritten, as the
        # in-place lane program does through `map_children`.
        ESA = EarthSciAST
        V, I = ESA.VarExpr, ESA.IntExpr
        node = ESA.OpExpr(
            "faq", ESA.ASTExpr[];
            output_idx = Any[], ranges = Dict{String, Any}("j" => Any[1, 2]),
            expr_body = ESA.OpExpr("*", ESA.ASTExpr[V("j"), V("i")]),
            filter = ESA.OpExpr("<=", ESA.ASTExpr[V("j"), V("i")]),
            key = ESA.OpExpr("+", ESA.ASTExpr[V("i"), V("j")])
        )
        function rewrite(fragment)
            spec = ESA._LaneSpec(
                :cells, ["cell"], 3, Dict("u" => ["cell"]), Dict("cell" => zeros(3)),
                ESA._LaneGather[], Set{String}(), Dict{String, Vector{String}}(),
                Dict{String, Int}(), Dict("cell" => 4), fragment, nothing, Set{String}(),
                String[], Set{String}()
            )
            scope = ESA._LaneScope(
                Dict("i" => "cell"), "i", Dict{String, UnitRange{Int}}(), Dict{String, Any}()
            )
            return ESA._lane_rewrite(spec, nothing, node, scope, "rule")
        end
        native, fragment = rewrite(false), rewrite(true)
        lane = ESA.OpExpr("index", ESA.ASTExpr[V("__lane_cell"), V("i")])
        @test repr(fragment.key) == repr(ESA.OpExpr("+", ESA.ASTExpr[lane, V("j")]))
        for f in (:expr_body, :filter, :key, :ranges, :args)
            @test repr(getfield(fragment, f)) == repr(getfield(native, f))
        end
    end

    @testset "lane subscripts follow the host integer evaluator" begin
        data = [10.0, 20.0, 30.0, 40.0]
        nbr = [2.0, 3.0, 4.0, 1.0]
        # A lane outside the domain reads the neighbour table past its axis.
        # That read leaves the array, so the lane reads 0.0, as an outer
        # read past an axis does, rather than a clamped neighbour.
        rhs = _op("+", _op("*", "rate", _ix("u", "i")), _ix("data", _ix("nbr", "i")))
        prob = cell_problem(["u" => rhs]; arrays = Dict("data" => (data, "cell"), "nbr" => (nbr, "cell")))
        prog = rhs_program(prob)
        cells = Int32[5 1 3]
        u = [1.0, 2.0, 3.0]
        fl = emit_fragment(operator_ir(prog; target = Lanes(:cells, ["cell"], 3)))
        p, t = ConcreteRArray(parameter_vector(prog)), ConcreteRNumber(0.5)
        args = (ConcreteRArray(u), ConcreteRArray(Float64[]), p, t, (), ConcreteRArray(cells))
        run = Reactant.@compile fl(args...)
        @test Array(run(args...)) ≈ [2.0, 4.0 + 20.0, 6.0 + 40.0]
        # Inside the domain the lane values are the native lane program's.
        inside = Int32[2 1 3]
        args = (ConcreteRArray(u), ConcreteRArray(Float64[]), p, t, (), ConcreteRArray(inside))
        @test Array(run(args...)) ≈ native_lanes(prog, inside, u)

        # A bare quotient must be exact on the host, which raises on any
        # other; a traced fragment cannot raise, so it refuses the quotient.
        half = _ix("data", _op("/", _op("*", 2, "i"), 2))
        prob = cell_problem(["u" => half]; arrays = Dict("data" => (data, "cell")))
        prog = rhs_program(prob)
        fl = emit_fragment(operator_ir(prog; target = Lanes(:cells, ["cell"], 3)))
        p = ConcreteRArray(parameter_vector(prog))
        args = (ConcreteRArray(u), ConcreteRArray(Float64[]), p, t, (), ConcreteRArray(cells))
        @test_throws EarthSciAST.DirectEmitError Reactant.@compile fl(args...)
    end

end
