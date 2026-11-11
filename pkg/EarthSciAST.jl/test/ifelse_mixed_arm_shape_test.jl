# esm-spec §4.3.4: a variable declared WITHOUT a `shape` whose definition is
# elementwise down to an `ifelse` with one array arm and one scalar arm has the
# array arm's shape whichever arm the condition takes. Its shape is decided at
# build from the operands: a gather from a const table is a scalar operand, and
# an unshaped data-fed parameter has the shape of its data. The Rust binding
# pins the same documents and values (PR #692).

using Test
using EarthSciAST

const E_IMA = EarthSciAST

_ima_op(o, a...) = Dict{String, Any}("op" => o, "args" => Any[a...])
_ima_cellwise(lhs, rhs) = Dict{String, Any}(
    "lhs" => lhs, "rhs" => Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict{String, Any}("i" => Dict{String, Any}("from" => "cell")),
        "expr" => rhs
    )
)
_ima_index_set() = Dict{String, Any}("cell" => Dict{String, Any}("kind" => "interval", "size" => 3))

# The reseact form: `X = ifelse(lev < 2, F / D, 0.0)` with `F: [cell]` and
# `D = index(const [31, 28, 31], 2)`, either arm order, read per cell by a
# state or not read at all.
function _ima_gathered_doc(; lev, reversed::Bool, read::Bool)
    fd = _ima_op("/", "F", "D")
    x = reversed ? _ima_op("ifelse", _ima_op(">=", "lev", 2.0), 0.0, fd) :
        _ima_op("ifelse", _ima_op("<", "lev", 2.0), fd, 0.0)
    table = Dict{String, Any}("op" => "const", "args" => Any[], "value" => [31.0, 28.0, 31.0])
    dq = Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict{String, Any}("i" => Dict{String, Any}("from" => "cell")),
        "expr" => Dict{String, Any}("op" => "D", "args" => Any[_ima_op("index", "q", "i")], "wrt" => "t")
    )
    q_rhs = read ? _ima_op("index", "X", "i") : _ima_op("*", -1.0, _ima_op("index", "q", "i"))
    rhs = Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict{String, Any}("i" => Dict{String, Any}("from" => "cell")), "expr" => q_rhs
    )
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict{String, Any}("name" => "ifelse_gathered_scalar"),
        "index_sets" => _ima_index_set(),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "lev" => Dict{String, Any}("type" => "parameter", "default" => lev),
                    "F" => Dict{String, Any}(
                        "type" => "parameter", "shape" => Any["cell"], "default" => [28.0, 56.0, 84.0]
                    ),
                    "D" => Dict{String, Any}("type" => "unknown"),
                    "X" => Dict{String, Any}("type" => "unknown"),
                    "q" => Dict{String, Any}("type" => "unknown", "shape" => Any["cell"], "default" => 0.0),
                ),
                "equations" => Any[
                    Dict{String, Any}("lhs" => "X", "rhs" => x),
                    Dict{String, Any}("lhs" => "D", "rhs" => _ima_op("index", table, 2)),
                    Dict{String, Any}("lhs" => dq, "rhs" => rhs),
                ]
            )
        )
    )
end

# The shared document `ifelse_data_fed_unshaped.esm`: `F` is a data-fed
# parameter declared with NO `shape`; the runtime supplies its data.
function _ima_data_fed_doc(; f_shape = nothing)
    f = Dict{String, Any}(
        "type" => "parameter", "units" => "1", "default" => 1.0,
        "update" => Dict{String, Any}(
            "kind" => "data", "source" => "src",
            "from" => Dict{String, Any}("file_variable" => "F")
        )
    )
    f_shape === nothing || (f["shape"] = f_shape)
    vars = Dict{String, Any}(
        "F" => f,
        "lev_on" => Dict{String, Any}("type" => "parameter", "units" => "1", "default" => 1.0),
        "lev_off" => Dict{String, Any}("type" => "parameter", "units" => "1", "default" => 3.0),
    )
    eqs = Any[]
    f2 = _ima_op("*", "F", 2.0)
    for (suffix, lev, reversed) in (
            ("on", "lev_on", false), ("off", "lev_off", false),
            ("rev_on", "lev_on", true), ("rev_off", "lev_off", true),
        )
        vars["X_$suffix"] = Dict{String, Any}("type" => "unknown", "units" => "1")
        vars["R_$suffix"] = Dict{String, Any}("type" => "unknown", "units" => "1", "shape" => Any["cell"])
        x = reversed ? _ima_op("ifelse", _ima_op(">=", lev, 2.0), 0.25, f2) :
            _ima_op("ifelse", _ima_op("<", lev, 2.0), f2, 0.25)
        push!(eqs, Dict{String, Any}("lhs" => "X_$suffix", "rhs" => x))
        push!(eqs, _ima_cellwise("R_$suffix", _ima_op("index", "X_$suffix", "i")))
    end
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict{String, Any}("name" => "ifelse_data_fed_unshaped"),
        "index_sets" => _ima_index_set(),
        "data_sources" => Dict{String, Any}(
            "src" => Dict{String, Any}(
                "kind" => "static",
                "source" => Dict{String, Any}("url_template" => "file:///nonexistent/f.nc")
            )
        ),
        "models" => Dict{String, Any}("IfelseDataFed" => Dict{String, Any}("variables" => vars, "equations" => eqs))
    )
end

# A const provider of `F`'s data.
struct _IMAProvider
    data::Vector{Float64}
end
E_IMA.provider_refresh_times(::_IMAProvider) = Float64[]
E_IMA.provider_sample(p::_IMAProvider, ::Real; selection = nothing) =
    Dict{String, Any}("IfelseDataFed.F" => copy(p.data))

const _IMA_F = [1.5, -2.0, 0.75]

@testset "ifelse with one array arm and one scalar arm (esm-spec §4.3.4)" begin
    @testset "a gather from a const table is a scalar operand" begin
        for compiler in (:native, :interpreter), reversed in (false, true),
                read in (true, false), lev in (1.0, 3.0)
            prob = E_IMA.esm_problem(
                _ima_gathered_doc(; lev, reversed, read), (0.0, 1.0); compiler = compiler
            )
            want = lev < 2 ? [1.0, 2.0, 3.0] : [0.0, 0.0, 0.0]
            @test E_IMA.observed_field(prob, "M.X"; u = zeros(3), t = 0.0) == want
            du = similar(prob.u0)
            prob.f!(du, prob.u0, prob.p, 0.0)
            @test du == (read ? want : [-0.0, -0.0, -0.0])
        end
    end

    # The data takes the parameter's shape at build: never a refusal ("one
    # value") and never the declared default or a silent 0.0.
    want = Dict(
        "on" => [3.0, -4.0, 1.5], "off" => [0.25, 0.25, 0.25],
        "rev_on" => [3.0, -4.0, 1.5], "rev_off" => [0.25, 0.25, 0.25],
    )
    routes = Any[
        (:native, (; const_arrays = Dict{String, Any}("IfelseDataFed.F" => copy(_IMA_F)))),
        (:interpreter, (; const_arrays = Dict{String, Any}("IfelseDataFed.F" => copy(_IMA_F)))),
        (:native, (; providers = Dict{String, Any}("IfelseDataFed.F" => _IMAProvider(_IMA_F)))),
        (:interpreter, (; providers = Dict{String, Any}("IfelseDataFed.F" => _IMAProvider(_IMA_F)))),
        (:native, (; param_arrays = Dict{String, Any}("IfelseDataFed.F" => copy(_IMA_F)))),
    ]
    @testset "an unshaped data-fed parameter takes its data's shape ($compiler, $(only(keys(kw))))" for (compiler, kw) in routes
        prob = E_IMA.esm_problem(_ima_data_fed_doc(), (0.0, 1.0); compiler = compiler, kw...)
        for (suffix, v) in want
            @test E_IMA.observed_field(prob, "IfelseDataFed.X_$suffix") == v
            @test E_IMA.observed_field(prob, "IfelseDataFed.R_$suffix") == v
        end
    end

    @testset "`shape: []` with array data is refused" begin
        for compiler in (:native, :interpreter)
            doc = _ima_data_fed_doc(; f_shape = Any[])
            @test_throws E_IMA.TreeWalkError E_IMA.esm_problem(
                deepcopy(doc), (0.0, 1.0); compiler = compiler,
                const_arrays = Dict{String, Any}("IfelseDataFed.F" => copy(_IMA_F))
            )
            @test_throws DimensionMismatch E_IMA.esm_problem(
                deepcopy(doc), (0.0, 1.0); compiler = compiler,
                providers = Dict{String, Any}("IfelseDataFed.F" => _IMAProvider(_IMA_F))
            )
        end
    end

    # A build entry that does not adopt shapes refuses the array rather than
    # reading a scalar the data never gave.
    @testset "the bare build refuses array data for an unshaped parameter" begin
        file = E_IMA.load_document(_ima_data_fed_doc())
        @test_throws E_IMA.TreeWalkError E_IMA._build_evaluator(
            file; const_arrays = Dict{String, Any}("F" => copy(_IMA_F))
        )
    end
end
