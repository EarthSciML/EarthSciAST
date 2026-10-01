# The compiled observed program (src/tree_walk/observed_program.jl).
#
# Under `compiler = :native` an observed read at output time —
# `observed_field(prob, name; u, t)`, an inline-test assertion, a field an
# output sink names — runs a program compiled once per problem and name through
# the right-hand side's array cascade, reading the state through the build's
# layout. `compiler = :interpreter` answers from the build-time cellwise
# evaluator, the oracle: every value read through the program must equal it bit
# for bit. The build of a program is independent of N.
using Test
using EarthSciAST
using OrdinaryDiffEqTsit5
using DiffEqCallbacks            # loads EarthSciASTDataOutputExt (the sink test)
using SciMLBase
using JSON3
include("testutils.jl")

const _OP = EarthSciAST

# Model `M` over `x ∈ 1…N`: a scalar state `c`, an array state `u`, a parameter
# `s`, and observeds of every shape the route takes —
#   h[i]  makearray (5 at i = 1, 7 elsewhere)         state-free, array
#   k[i]  = 2i                                         state-free, array
#   w[i]  = s·u[i]·c + sin(t) + k[i]                   state- and t-dependent
#   tot   = Σ_i w[i]                                   scalar over an array observed
#   q     = c·s·3                                      scalar, state-dependent
# `decay` sets the state equations' rates; `tests` are inline tests.
function _op_doc(N; decay = 0.0, tests = Any[])
    idx(a, i) = Dict("op" => "index", "args" => Any[a, i])
    over_x(body) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                        "ranges" => Dict("i" => Dict("from" => "x")), "expr" => body)
    return Dict{String,Any}("esm" => "1.1.0",
        "metadata" => Dict("name" => "observed_program"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => N)),
        "models" => Dict("M" => Dict{String,Any}(
            "variables" => Dict(
                "c" => Dict("type" => "unknown", "default" => 1.0),
                "u" => Dict("type" => "unknown", "shape" => Any["x"], "default" => 0.5),
                "s" => Dict("type" => "parameter", "default" => 1.5),
                "h" => Dict("type" => "unknown", "shape" => Any["x"]),
                "k" => Dict("type" => "unknown", "shape" => Any["x"]),
                "w" => Dict("type" => "unknown", "shape" => Any["x"]),
                "tot" => Dict("type" => "unknown"),
                "q" => Dict("type" => "unknown")),
            "equations" => Any[
                Dict("lhs" => Dict("op" => "D", "args" => Any["c"], "wrt" => "t"),
                     "rhs" => Dict("op" => "*", "args" => Any[-decay, "c"])),
                Dict("lhs" => Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                        "ranges" => Dict("i" => Dict("from" => "x")),
                        "expr" => Dict("op" => "D", "args" => Any[idx("u", "i")],
                                       "wrt" => "t")),
                     "rhs" => over_x(Dict("op" => "*",
                                          "args" => Any[-3decay, idx("u", "i")]))),
                Dict("lhs" => "h", "rhs" => Dict("op" => "makearray", "args" => Any[],
                    "regions" => Any[Any[Any[1, 1]], Any[Any[2, N]]],
                    "values" => Any[5.0, 7.0])),
                Dict("lhs" => "k", "rhs" => over_x(Dict("op" => "*", "args" => Any[2.0, "i"]))),
                Dict("lhs" => "w", "rhs" => over_x(Dict("op" => "+", "args" => Any[
                    Dict("op" => "*", "args" => Any["s", idx("u", "i"), "c"]),
                    Dict("op" => "sin", "args" => Any["t"]),
                    idx("k", "i")]))),
                Dict("lhs" => "tot", "rhs" => Dict("op" => "faq", "args" => Any[],
                    "output_idx" => Any[], "ranges" => Dict("i" => Dict("from" => "x")),
                    "expr" => idx("w", "i"))),
                Dict("lhs" => "q", "rhs" => Dict("op" => "*", "args" => Any["c", "s", 3.0]))],
            "tests" => tests)))
end

_op_bits(a, b) = length(a) == length(b) && all(a .=== b)
_op_rows(prob, name) = [r.tier for r in compiler_report(prob).rules
                        if r.kind === :observed && r.rule == name]

# Every RuntimeGeneratedFunction type reachable from `root` (the walk
# grid_invariance_test.jl uses on a right-hand side).
function _op_rgf_types(root)
    RGF = _OP.RuntimeGeneratedFunctions
    seen = IdDict{Any,Nothing}(); types = Set{Any}()
    stack = Any[root]
    while !isempty(stack)
        x = pop!(stack)
        T = typeof(x)
        (isbitstype(T) || x isa AbstractString || x isa Symbol || x isa Module ||
         x isa DataType) && continue
        if ismutable(x)
            haskey(seen, x) && continue
            seen[x] = nothing
        end
        if x isa RGF.RuntimeGeneratedFunction
            push!(types, T)
            continue
        end
        if x isa Array
            eltype(x) <: Number && continue
            for i in eachindex(x); isassigned(x, i) && push!(stack, x[i]); end
        elseif x isa AbstractDict
            continue
        else
            for i in 1:nfields(x); isdefined(x, i) && push!(stack, getfield(x, i)); end
        end
    end
    return types
end

# A sink that names two observed fields and records what it is handed.
mutable struct _OPSink
    times::Vector{Float64}
    names::Vector{String}
    records::Vector{Tuple{Float64,Vector{Float64},Dict{String,Array}}}
end
_OPSink(times, names) =
    _OPSink(times, names, Tuple{Float64,Vector{Float64},Dict{String,Array}}[])
_OP.sink_output_times(s::_OPSink) = s.times
_OP.sink_open!(::_OPSink) = nothing
function _OP.sink_write!(s::_OPSink, snap::_OP.StateSnapshot; selection = nothing)
    push!(s.records, (snap.t, Vector{Float64}(snap.state[1][1]),
                      Dict{String,Array}(k => copy(v) for (k, v) in snap.observed)))
    return nothing
end
_OP.sink_flush!(::_OPSink) = nothing
_OP.sink_close!(::_OPSink) = nothing
_OP.sink_observed_names(s::_OPSink) = s.names

@testset "the compiled observed program" begin

    @testset "a state-dependent observed is read at the given state and time" begin
        pn = esm_problem(_op_doc(5), (0.0, 1.0))
        pi_ = esm_problem(_op_doc(5), (0.0, 1.0); compiler = :interpreter)
        u = collect(range(0.3, 1.1; length = length(pn.u0)))
        c = u[pn.var_map["M.c"]]
        ui = [u[pn.var_map["M.u[$i]"]] for i in 1:5]
        for t in (0.0, 0.7)
            wn = observed_field(pn, "w"; u = u, t = t)
            @test _op_bits(wn, observed_field(pi_, "w"; u = u, t = t))
            @test wn ≈ [1.5 * ui[i] * c + sin(t) + 2i for i in 1:5]
            totn = observed_field(pn, "tot"; u = u, t = t)
            @test _op_bits(totn, observed_field(pi_, "tot"; u = u, t = t))
            @test totn[1] ≈ sum(wn)
        end
        qn = observed_field(pn, "q"; u = u)
        @test _op_bits(qn, observed_field(pi_, "q"; u = u))
        @test qn == [c * 1.5 * 3.0]
        # Without a state it is not a field of the build, and says so.
        err = try; observed_field(pn, "w"); nothing; catch e; e; end
        @test err isa _OP.SimulateError && occursin("u = ", sprint(showerror, err))
        # One row per name, naming the compiled route.
        for n in ("w", "tot", "q")
            @test _op_rows(pn, n) == [:output_compiled]
        end
        @test _op_rows(pi_, "w") == [:output_compiled_once]
        # A wrong-length state is refused rather than read past.
        @test_throws _OP.SimulateError observed_field(pn, "w"; u = u[1:2])
    end

    @testset "an array observed is compiled once and served at any state" begin
        pn = esm_problem(_op_doc(5), (0.0, 1.0))
        pi_ = esm_problem(_op_doc(5), (0.0, 1.0); compiler = :interpreter)
        @test observed_field(pn, "h") == [5.0, 7.0, 7.0, 7.0, 7.0]
        @test _op_bits(observed_field(pn, "h"), observed_field(pi_, "h"))
        @test _op_bits(observed_field(pn, "k"), observed_field(pi_, "k"))
        @test observed_field(pn, "k"; u = 2 .* pn.u0, t = 3.0) == [2.0, 4.0, 6.0, 8.0, 10.0]
        ctx = _OP._obs_ctx(pn)
        prog = ctx.programs["M.k"]
        observed_field(pn, "k"; u = pn.u0, t = 1.0)
        @test ctx.programs["M.k"] === prog           # built once, reused
        @test _op_rows(pn, "h") == [:output_compiled]
        @test _op_rows(pi_, "h") == [:output_percell]
    end

    @testset "the program's generated code is shared across N" begin
        progs = map((8, 64)) do N
            p = esm_problem(_op_doc(N), (0.0, 1.0))
            observed_field(p, "w"; u = p.u0, t = 0.5)
            observed_field(p, "tot"; u = p.u0, t = 0.5)
            _OP._obs_ctx(p).programs
        end
        for n in ("M.w", "M.tot")
            A, B = _op_rgf_types(progs[1][n]), _op_rgf_types(progs[2][n])
            @test !isempty(A)
            @test A == B
            @test length(progs[1][n].levels) == length(progs[2][n].levels)
        end
    end

    @testset "inline-test assertions read through the program" begin
        tests = Any[Dict("id" => "reads",
            "time_span" => Dict("start" => 0.0, "end" => 1.0),
            "tolerance" => Dict("rel" => 1e-9),
            "assertions" => Any[
                Dict("variable" => "w", "time" => 1.0, "coords" => Dict("x" => 2),
                     "expected" => 1.5 * 0.5 * 1.0 + sin(1.0) + 4.0),
                Dict("variable" => "q", "time" => 1.0, "expected" => 4.5),
                Dict("variable" => "tot", "time" => 1.0,
                     "expected" => sum(1.5 * 0.5 + sin(1.0) + 2i for i in 1:4)),
                Dict("variable" => "w", "time" => 0.0, "reduce" => "mean",
                     "expected" => 0.75 + 5.0)])]
        f = _OP.load_string(JSON3.write(_op_doc(4; tests = tests)))
        rn, nprog = _OP._counting_program_reads() do
            run_inline_tests(f)
        end
        ri = run_inline_tests(f; compiler = :interpreter)
        @test length(rn) == length(ri) == 4
        @test all(r -> r.status == _OP.PASS, rn)
        @test all(r -> r.status == _OP.PASS, ri)
        @test all(k -> rn[k].actual === ri[k].actual, 1:4)
        @test nprog == 4
    end

    @testset "an array state asserted by cell reads the layout, not its keys" begin
        pn = esm_problem(_op_doc(4; decay = 0.2), (0.0, 1.0))
        cells = _OP._state_cells(pn.var_map, "u", "M")
        @test cells == _OP._state_cells(Dict{String,Int}(pn.var_map), "u", "M")
        @test [c for (c, _) in cells] == [[1], [2], [3], [4]]
        u = collect(1.0:length(pn.u0))
        a1, s1 = _OP._state_scope(pn.var_map, u)
        a2, s2 = _OP._state_scope(Dict{String,Int}(pn.var_map), u)
        @test a1 == a2 && s1 == s2
    end

    @testset "observed fields a sink names ride its snapshot" begin
        sink = _OPSink([0.5, 1.0], ["M.w", "M.q"])
        pn = esm_problem(_op_doc(3; decay = 0.4), (0.0, 1.0); sinks = [sink])
        sol = solve(pn, Tsit5(); reltol = 1e-9, abstol = 1e-12)
        @test [r[1] for r in sink.records] == [0.5, 1.0]
        for (t, u, obs) in sink.records
            @test _op_bits(obs["M.w"], observed_field(pn, "M.w"; u = u, t = t))
            @test _op_bits(obs["M.q"], observed_field(pn, "M.q"; u = u, t = t))
        end
        @test sink.records[end][3]["M.q"][1] ≈ 4.5 * exp(-0.4) rtol = 1e-6
    end

    @testset "a remade parameter reaches the program and the sink" begin
        # `remake(prob; p)` shares the build, and so the program context whose
        # parameters are the build's; a read at a state, and a sink's record,
        # must see the remade problem's `p`.
        for compiler in (:native, :interpreter)
            sink = _OPSink([0.5, 1.0], ["M.w", "M.q"])
            p1 = esm_problem(_op_doc(3; decay = 0.4), (0.0, 1.0); sinks = [sink],
                             compiler = compiler)
            ref = esm_problem(_op_doc(3; decay = 0.4), (0.0, 1.0);
                              p = Dict("s" => 3.0), compiler = :interpreter)
            u = collect(range(0.3, 1.1; length = length(p1.u0)))
            c = u[p1.var_map["M.c"]]
            # Read the original first, so a context or memo shared with the
            # remade problem is already warm.
            @test observed_field(p1, "q"; u = u, t = 0.2) == [c * 1.5 * 3.0]
            p2 = remake(p1; p = Dict("s" => 3.0))
            for n in ("q", "w", "tot")
                v2 = observed_field(p2, n; u = u, t = 0.2)
                @test _op_bits(v2, observed_field(ref, n; u = u, t = 0.2))
            end
            @test observed_field(p2, "q"; u = u, t = 0.2) == [c * 3.0 * 3.0]
            # The problem it came from is unchanged.
            @test observed_field(p1, "q"; u = u, t = 0.2) == [c * 1.5 * 3.0]
            # A positional carrier, in the build's parameter order.
            pv = Float64[Float64(v) for v in values(p1.p)]
            pv[_OP.param_map(p1.p)["M.s"]] = 3.0
            p3 = remake(p1; p = pv)
            @test _op_bits(observed_field(p3, "w"; u = u, t = 0.2),
                           observed_field(ref, "w"; u = u, t = 0.2))
            solve(p2, Tsit5(); reltol = 1e-9, abstol = 1e-12)
            @test [r[1] for r in sink.records] == [0.5, 1.0]
            for (t, us, obs) in sink.records
                @test _op_bits(obs["M.q"], observed_field(ref, "M.q"; u = us, t = t))
                @test _op_bits(obs["M.w"], observed_field(ref, "M.w"; u = us, t = t))
            end
            @test sink.records[end][3]["M.q"][1] ≈ 9.0 * exp(-0.4) rtol = 1e-6
        end
    end

    @testset "an observed native cannot compile is refused by name" begin
        # With both code-generation budgets at zero (refusal boundaries under
        # `native`) every kernel the program needs is left to the per-cell
        # kernel runner; the document's own right-hand side has none to refuse.
        doc = _op_doc(3)
        doc["models"]["M"]["equations"] = doc["models"]["M"]["equations"][[1, 3, 4]]
        refused = withenv("ESS_CODEGEN_NODE_BUDGET" => "0",
                          "ESS_DUAL_CODEGEN_NODE_BUDGET" => "0") do
            pn = esm_problem(doc, (0.0, 1.0))
            try
                observed_field(pn, "h"); nothing
            catch e
                e
            end
        end
        @test refused isa _OP.TreeWalkError
        @test refused.code == _OP.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("refuses 'M.h'", refused.detail)
        pi_ = esm_problem(doc, (0.0, 1.0); compiler = :interpreter)
        @test observed_field(pi_, "h") == [5.0, 7.0, 7.0]
    end
end
