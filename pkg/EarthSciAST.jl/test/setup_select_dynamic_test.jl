# Which array observeds the native build materializes once at setup
# (`_geometry_setup_vars`, tree_walk/setup_select.jl), for candidates that move
# with a state or with `t`, or that read an observed setup cannot evaluate:
#
#   * a join reduction (an `overlap`-gated `faq`) reading an observed that reads
#     the state stays out of setup, as does everything that reads it;
#   * an observed reading a setup table and `t` directly stays out of setup;
#   * a loop index named `t` is not a read of time: a reduction binding it is
#     still a build-once table;
#   * a join reduction reading an array observed that reads a computed scalar
#     observed (never in the setup environment) stays out of setup.

using Test
include("testutils.jl")

const _SD = EarthSciAST

_sd_op(o, a...; kw...) = Dict{String, Any}("op" => o, "args" => Any[a...], (String(k) => v for (k, v) in kw)...)
_sd_ix(a, s...) = _sd_op("index", a, s...)
_sd_faq(e, out, ranges; kw...) = Dict{String, Any}(
    "op" => "faq", "args" => Any[], "output_idx" => Any[out...],
    "ranges" => Dict{String, Any}(String(k) => Dict("from" => v) for (k, v) in ranges),
    "expr" => e, (String(k) => v for (k, v) in kw)...
)
_sd_arr(set) = Dict{String, Any}("type" => "unknown", "units" => "1", "shape" => [set])
_sd_par(shape...; default = 1.0) = Dict{String, Any}(
    "type" => "parameter", "units" => "1", "default" => default, "shape" => Any[shape...]
)

# A row sum over `y` of P, bound by `k`: a build-once nested parameter reduction.
_sd_rowsum(k) = _sd_faq(_sd_op("*", 2.0, _sd_faq(_sd_ix("P", "i", k), [], (k => "y",); reduce = "+")), ["i"], (:i => "x",))

# An `overlap`-gated reduction over cells `c` for records `r`, whose body nests
# a `faq` (so it is a setup join reduction) and multiplies by `f[c]`.
_sd_join(f) = _sd_faq(
    _sd_op(
        "*", _sd_ix(f, "c"),
        _sd_faq(_sd_ix("Q", "c", "k"), [], (:k => "y",); reduce = "+")
    ),
    ["r"], (:c => "x", :r => "recs");
    reduce = "+",
    join = Any[Dict("overlap" => Dict("src_env" => ["X", "Y"], "tgt_env" => ["Wb", "Sb", "Eb", "Nb"], "eps" => 0.0))]
)

function _sd_setup(equations, variables)
    vars = merge(
        Dict{String, Any}(
            "P" => _sd_par("x", "y"), "Q" => _sd_par("x", "y"),
            "X" => _sd_par("recs"), "Y" => _sd_par("recs"),
            "Wb" => _sd_par("x"), "Sb" => _sd_par("x"), "Eb" => _sd_par("x"), "Nb" => _sd_par("x"),
            "p" => Dict{String, Any}("type" => "parameter", "units" => "1", "default" => 1.0),
            "s" => Dict{String, Any}("type" => "unknown", "units" => "1", "shape" => ["x"], "default" => 0.5),
        ), variables
    )
    dlhs = _sd_faq(_sd_op("D", _sd_ix("s", "i"); wrt = "t"), ["i"], (:i => "x",))
    doc = Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "setup_select_dynamic"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => 3),
            "y" => Dict("kind" => "interval", "size" => 2),
            "recs" => Dict("kind" => "interval", "size" => 2),
        ),
        "models" => Dict(
            "M" => Dict(
                "variables" => vars,
                "equations" => Any[
                    equations...,
                    Dict("lhs" => dlhs, "rhs" => _sd_faq(_sd_op("-", _sd_ix("s", "i")), ["i"], (:i => "x",))),
                ],
            )
        ),
    )
    file = _SD.load_string(JSON3.write(doc))
    model = file.models["M"]
    g = _SD._DefGraph(model.equations)
    setup, _, _ = _SD._geometry_setup_vars(
        model, g, Set(["s"]), Set{String}(); index_sets = file.index_sets
    )
    return setup, _SD._dynamic_names(g, Set(["s"]))
end

@testset "setup selection: state, time and blocked reads" begin
    @testset "a join reduction reading a state-dependent observed stays out" begin
        setup, dynamic = _sd_setup(
            Any[
                Dict("lhs" => "C", "rhs" => _sd_rowsum("j")),
                Dict("lhs" => "Ws", "rhs" => _sd_faq(_sd_op("*", 2.0, _sd_ix("s", "i")), ["i"], (:i => "x",))),
                Dict("lhs" => "Nd", "rhs" => _sd_join("Ws")),
                Dict("lhs" => "Nc", "rhs" => _sd_join("C")),
            ],
            Dict("C" => _sd_arr("x"), "Ws" => _sd_arr("x"), "Nd" => _sd_arr("recs"), "Nc" => _sd_arr("recs")),
        )
        @test "Nd" in dynamic
        @test !("Nd" in setup)
        @test !("Ws" in setup)
        # The same gate over a build-once table is still a setup var.
        @test "C" in setup
        @test "Nc" in setup
    end

    @testset "an observed reading a setup table and `t` stays out" begin
        setup, dynamic = _sd_setup(
            Any[
                Dict("lhs" => "C", "rhs" => _sd_rowsum("j")),
                Dict("lhs" => "T", "rhs" => _sd_faq(_sd_op("*", _sd_ix("C", "i"), "t"), ["i"], (:i => "x",))),
                Dict("lhs" => "T2", "rhs" => _sd_faq(_sd_op("+", _sd_ix("T", "i"), _sd_ix("C", "i")), ["i"], (:i => "x",))),
            ],
            Dict("C" => _sd_arr("x"), "T" => _sd_arr("x"), "T2" => _sd_arr("x")),
        )
        @test "C" in setup
        @test "T" in dynamic && "T2" in dynamic
        @test !("T" in setup)
        @test !("T2" in setup)
    end

    @testset "a loop index named `t` is not a read of time" begin
        setup, dynamic = _sd_setup(
            Any[
                Dict("lhs" => "Ct", "rhs" => _sd_rowsum("t")),
                Dict(
                    "lhs" => "Nt", "rhs" => _sd_faq(
                        _sd_op("*", _sd_ix("Wb", "c"), _sd_faq(_sd_ix("Q", "c", "t"), [], (:t => "y",); reduce = "+")),
                        ["r"], (:c => "x", :r => "recs");
                        reduce = "+",
                        join = Any[Dict("overlap" => Dict("src_env" => ["X", "Y"], "tgt_env" => ["Wb", "Sb", "Eb", "Nb"], "eps" => 0.0))]
                    )
                ),
            ],
            Dict("Ct" => _sd_arr("x"), "Nt" => _sd_arr("recs")),
        )
        @test !("Ct" in dynamic) && !("Nt" in dynamic)
        @test "Ct" in setup
        @test "Nt" in setup
    end

    @testset "a join reduction reading a blocked observed stays out" begin
        setup, _ = _sd_setup(
            Any[
                Dict("lhs" => "k", "rhs" => _sd_op("*", 2.0, "p")),
                Dict("lhs" => "R", "rhs" => _sd_faq(_sd_op("*", _sd_ix("Wb", "i"), "k"), ["i"], (:i => "x",))),
                Dict("lhs" => "Nb2", "rhs" => _sd_join("R")),
            ],
            Dict(
                "k" => Dict{String, Any}("type" => "unknown", "units" => "1"),
                "R" => _sd_arr("x"), "Nb2" => _sd_arr("recs"),
            ),
        )
        @test !("R" in setup)
        @test !("Nb2" in setup)
    end
end
