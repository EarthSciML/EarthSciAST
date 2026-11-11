# An interpolation template whose query is an inlined observed chain, under
# strict `compiler = :native` and the interpreter.
#
# The shape is a single-column shortwave scheme's cloud-table read: a suffix
# integral written as a `makearray` (a reverse-window `faq` on the layers, 0 at
# the top interface), a pointwise observed of it, and `bilinear` read at that
# observed per interface. Inlined, the query is a sub-tree reached from every
# use of the template's `y` (the template writes it at each clamp and bracket,
# about 180 times once its counts are unrolled), and the integral is a
# `makearray` read at the interface index. Two things are pinned:
#
#   * native builds it (the interface index is symbolic on the compile-once
#     and whole-array contraction tiers, so the `makearray` region and the
#     window filter are chosen at run time) and gives the interpreter's bits;
#   * an observed nothing reads, built from the template observed, is
#     evaluated per cell by the interpreter (and by the inline-test reader when
#     no compiled program carries it) without walking the shared query once
#     per use.

module TemplateNestedObservedTests

using Test
using JSON3
using EarthSciAST
const EA = EarthSciAST
import OrdinaryDiffEqTsit5   # the solver `run_inline_tests` picks

const REPO = normpath(joinpath(@__DIR__, "..", "..", ".."))

_op(o, a...; kw...) = Dict{String, Any}(
    "op" => o, "args" => Any[a...], (String(k) => v for (k, v) in kw)...
)
_ix(a, s...) = _op("index", a, s...)
_const(v) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => v)
_faq(out, ranges, e; kw...) = Dict{String, Any}(
    "op" => "faq", "args" => Any[], "output_idx" => Any[out...],
    "ranges" => ranges, "expr" => e, (String(k) => v for (k, v) in kw)...
)

# `n` layers, `n + 1` interfaces. `q` is the layer state, `W` its suffix sum on
# the interfaces, `alw` a clamped log of it, `R` the bilinear table read at
# (`mu`, `alw[kn]`), `dR` the per-layer increment of `R` (read by the state's
# right-hand side) and `xr` a multiple of `dR` that nothing reads.
function nested_doc(n::Int; tests::Bool = false)
    lev = Dict("from" => "lev")
    nodes = Dict("from" => "lev_nodes")
    var(shape = nothing; d = nothing) = (
        v = Dict{String, Any}("type" => "unknown");
        shape === nothing || (v["shape"] = Any[shape...]);
        d === nothing || (v["default"] = d); v
    )
    suffix = _faq(
        ("k",), Dict("k" => Any[1, n], "j" => Any[1, n]),
        _op("*", _ix("q", "j"), _ix(_const(Float64[0.5 + 0.01 * j for j in 1:n]), "j"));
        reduce = "+", filter = _op(">=", "j", "k")
    )
    W = Dict{String, Any}(
        "op" => "makearray", "args" => Any[],
        "regions" => Any[Any[Any[1, n]], Any[Any[n + 1, n + 1]]],
        "values" => Any[suffix, 0.0]
    )
    tab = Any[
        Any[0.0, 69.0, 90.0, 94.0, 96.0], Any[0.0, 58.0, 80.0, 90.0, 92.0],
        Any[0.0, 40.0, 70.0, 82.0, 85.0], Any[0.0, 15.0, 60.0, 78.0, 80.0],
    ]
    look = Dict{String, Any}(
        "op" => "apply_expression_template", "args" => Any[], "name" => "bilinear",
        "bindings" => Dict{String, Any}(
            "table" => _const(tab), "axis_x" => _const([0.0, 0.2, 0.5, 1.0]),
            "axis_y" => _const([0.0, 1.0, 2.0, 3.0, 4.0]),
            "x" => "mu", "y" => _ix("alw", "kn"), "nx" => 4, "ny" => 5,
        )
    )
    vars = Dict{String, Any}(
        "q" => var(("lev",); d = 0.02),
        "mu" => var(), "W" => var(("lev_nodes",)), "alw" => var(("lev_nodes",)),
        "R" => var(("lev_nodes",)), "dR" => var(("lev",)), "xr" => var(("lev",)),
    )
    eqs = Any[
        Dict("lhs" => "mu", "rhs" => _op("+", 0.45, _op("*", 0.4, _op("sin", "t")))),
        Dict("lhs" => "W", "rhs" => W),
        # Written elementwise over the shaped `W` (no `faq`), as a scheme
        # writes it: the build folds such an observed into its readers, which
        # is what puts the `makearray` inside the template's query.
        Dict(
            "lhs" => "alw",
            "rhs" => _op("min", _op("log10", _op("+", _op("/", "W", _op("*", "mu", 0.01)), 1.0)), 3.999),
        ),
        Dict("lhs" => "R", "rhs" => _faq(("kn",), Dict("kn" => nodes), _op("/", look, 100.0))),
        Dict(
            "lhs" => "dR", "rhs" => _faq(
                ("k",), Dict("k" => lev),
                _op("-", _ix("R", "k"), _ix("R", _op("+", "k", 1)))
            )
        ),
        Dict("lhs" => "xr", "rhs" => _op("/", "dR", 0.01)),
        Dict(
            "lhs" => _faq(("k",), Dict("k" => lev), _op("D", _ix("q", "k"); wrt = "t")),
            "rhs" => _faq(("k",), Dict("k" => lev), _op("-", _ix("dR", "k"), _op("*", 0.1, _ix("q", "k")))),
        ),
    ]
    model = Dict{String, Any}(
        "variables" => vars, "equations" => eqs,
        "expression_template_imports" => Any[
            Dict{String, Any}("ref" => joinpath(REPO, "lib", "interp.esm"), "only" => Any["bilinear"]),
        ],
    )
    if tests
        # The values are not pinned here (the two compilers are compared to
        # each other below); a wide tolerance keeps every row a PASS.
        model["tolerance"] = Dict("abs" => 1.0e6)
        model["tests"] = Any[
            Dict(
                "id" => "fields_t0", "time_span" => Dict("start" => 0.0, "end" => 0.5),
                "assertions" => Any[
                    Dict("variable" => v, "time" => tt, "reduce" => r, "expected" => 0.0)
                        for v in ("R", "xr") for r in ("max", "mean") for tt in (0.0, 0.5)
                ],
            ),
        ]
    end
    return Dict{String, Any}(
        "esm" => "2.0.0", "metadata" => Dict("name" => "template_nested_observed"),
        "index_sets" => Dict(
            "lev" => Dict("kind" => "interval", "size" => n),
            "lev_nodes" => Dict("kind" => "interval", "size" => n + 1),
        ),
        "models" => Dict("Column" => model)
    )
end

function rhs_at(doc, compiler; times = (0.0, 0.4, 1.3))
    f!, u0, p, _, vm = EA._build_evaluator(doc; compiler = compiler)
    out = Dict{String, Vector{Float64}}()
    for t in times
        du = similar(u0)
        fill!(du, NaN)
        f!(du, u0, p, t)
        for (k, v) in vm
            push!(get!(() -> Float64[], out, k), du[v])
        end
    end
    return out
end

same_bits(a, b) = keys(a) == keys(b) && all(all(a[k] .=== b[k]) for k in keys(a))

@testset "template read at an inlined makearray observed chain" begin
    n = 16
    doc = nested_doc(n)

    @testset "native builds it and gives the interpreter's bits" begin
        dn = rhs_at(doc, :native)
        di = rhs_at(doc, :interpreter)
        @test same_bits(dn, di)
        @test all(isfinite, reduce(vcat, values(dn)))
    end

    # A symbolic-subscript `makearray` read and a filtered `faq` read, each on
    # its own: the compile-once observed reader against the per-cell walk.
    @testset "observed fields: native = interpreter" begin
        probs = Dict(c => EA.esm_problem(doc, (0.0, 1.0); compiler = c) for c in (:native, :interpreter))
        for name in ("Column.W", "Column.alw", "Column.R", "Column.xr")
            vals = Dict(
                c => vec(EA.observed_field(prob, name; u = prob.u0, t = 0.7))
                    for (c, prob) in probs
            )
            @test all(vals[:native] .=== vals[:interpreter])
            @test all(isfinite, vals[:native])
        end
    end

    # Every row passes under both compilers, each in bounded time, and the two
    # read the same bits.
    @testset "inline tests: both compilers, same bits" begin
        dir = mktempdir()
        path = joinpath(dir, "template_nested_observed.esm")
        write(path, JSON3.write(nested_doc(n; tests = true)))
        rows = Dict{Symbol, Any}()
        for c in (:native, :interpreter)
            t = @elapsed rows[c] = run_inline_tests(path; compiler = c)
            @test !isempty(rows[c])
            @test all(r -> r.status == EA.PASS, rows[c])
            # Generous: the shared-query walk this guards against does not finish.
            @test t < 300
        end
        @test length(rows[:native]) == length(rows[:interpreter])
        for (a, b) in zip(rows[:native], rows[:interpreter])
            @test a.actual !== nothing && a.actual === b.actual
        end
    end
end

end # module
