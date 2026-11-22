# Structural time derivatives inside template bodies, resolved by flatten step
# 3a without expanding (esm-spec §9.6.4 rule 3, "Time derivatives";
# esm-libraries-spec §4.7.5 step 3a; CONFORMANCE_SPEC §5.60). The byte goldens
# (after `Expand`, and with references kept) are pinned by
# flatten_wire_conformance_test.jl; this file checks the registry entries the
# step writes and what the build does with them.

using Test
using EarthSciAST
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _TTD_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "flatten_wire", "fixtures")

_ttd_flat(name) = EarthSciAST.flatten(EarthSciAST.load_path(joinpath(_TTD_DIR, "$name.esm")))

_ttd_params(reg, n) = String[String(p) for p in reg[n]["params"]]

# The equation defining `lhs` in `flat`.
_ttd_rhs(flat, lhs) = only(e.rhs for e in flat.equations if e.lhs isa EarthSciAST.VarExpr && e.lhs.name == lhs)

function _ttd_has_D(e)
    found = false
    EarthSciAST.foreach_subexpr(e) do x
        x isa EarthSciAST.OpExpr && x.op == "D" && (found = true)
    end
    return found
end

function _ttd_refused(file, compiler)
    try
        EarthSciAST.esm_problem(file, (0.0, 1.0); compiler = compiler)
        return nothing
    catch e
        e isa EarthSciAST.EarthSciASTError || rethrow()
        return sprint(showerror, e)
    end
end

@testset "time derivatives in template bodies resolve without expanding" begin
    flat = _ttd_flat("template_time_derivative")
    reg = flat.template_registry
    # A parameter under `D` becomes `p_dt`, appended to `params` after the
    # body's free name `c`, which flatten made a parameter (esm-spec §10.7).
    @test _ttd_params(reg, "rate") == ["p", "c", "p_dt"]
    # `D` of a reference is a reference to the derivative entry `<S>.ddt`.
    @test _ttd_params(reg, "sq.ddt") == ["q", "q_dt"]
    @test _ttd_params(reg, "sq") == ["q"]
    @test _ttd_params(reg, "nested") == ["s", "s_dt"]
    # A body with no `D` of its own gains `g_dt` through the reference it holds.
    @test _ttd_params(reg, "cube_rate") == ["g", "g_dt"]
    # `wrt` bound to "t": structural in that instance only.
    @test _ttd_params(reg, "dwrt.variant1") == ["f", "v", "f_dt"]
    @test _ttd_params(reg, "dwrt.variant2") == ["f", "v"]
    # Each new entry follows its template.
    ks = collect(keys(reg))
    @test findfirst(==("sq.ddt"), ks) == findfirst(==("sq"), ks) + 1

    # References survive, carrying the derivative bindings.
    r1 = _ttd_rhs(flat, "M.r1")
    @test r1.op == "apply_operator" && r1.name == "rate"
    @test r1.bindings["p_dt"] isa EarthSciAST.OpExpr   # a's tendency
    r6 = _ttd_rhs(flat, "M.r6")
    @test r6.op == "apply_operator" && r6.name == "sq.ddt"
    @test Set(keys(r6.bindings)) == Set(["q", "q_dt"])
    r7 = _ttd_rhs(flat, "M.r7")
    @test r7.name == "cube_rate" && haskey(r7.bindings, "g_dt")

    # No `D` stays on a right-hand side or in a reached body.
    @test !any(e -> _ttd_has_D(e.rhs), flat.equations)
    for n in ("rate", "sq.ddt", "nested", "cube_rate", "dwrt.variant1")
        @test !_ttd_has_D(EarthSciAST.expression_from_json(reg[n]["body"]))
    end

    # The build compiles the references and gives the expansion's numbers:
    # r1 = c·(-k·a), r3 = 2(a-b)·b, r6 = 2(-k·a)·a.
    file = EarthSciAST.load_path(joinpath(_TTD_DIR, "template_time_derivative.esm"))
    for compiler in (:interpreter, :native)
        @test _ttd_refused(file, compiler) === nothing
    end
end

@testset "a time derivative the table cannot answer is refused by the build gate" begin
    flat = _ttd_flat("template_time_derivative_unanswered")
    reg = flat.template_registry
    # One reference to `rate` resolves, the other cannot bind `p_dt`: the
    # resolved body takes the name, the unresolved one is `rate.unresolved`.
    @test _ttd_params(reg, "rate") == ["p", "p_dt"]
    @test _ttd_params(reg, "rate.unresolved") == ["p"]
    @test _ttd_has_D(EarthSciAST.expression_from_json(reg["rate.unresolved"]["body"]))
    @test _ttd_rhs(flat, "M.r1").name == "rate"
    @test _ttd_rhs(flat, "M.r2").name == "rate.unresolved"
    # `D(p^2)`: `^` is outside the table, so the `D` stays in `pw`'s body.
    @test _ttd_params(reg, "pw") == ["p"]
    @test _ttd_has_D(EarthSciAST.expression_from_json(reg["pw"]["body"]))
    file = EarthSciAST.load_path(joinpath(_TTD_DIR, "template_time_derivative_unanswered.esm"))
    for compiler in (:interpreter, :native)
        msg = _ttd_refused(file, compiler)
        @test msg !== nothing && occursin("unlowered_operator", msg)
    end
end

@testset "p_dt avoids the template's names" begin
    doc = Dict(
        "esm" => "1.3.0", "metadata" => Dict("name" => "dt_fresh"),
        "models" => Dict(
            "M" => Dict(
                "operators" => Dict(
                    "f" => Dict(
                        "params" => ["p", "p_dt"],
                        "body" => Dict("op" => "*", "args" => ["p_dt", Dict("op" => "D", "args" => ["p"])]),
                    ),
                ),
                "variables" => Dict(
                    "a" => Dict("type" => "unknown", "default" => 1.0),
                    "y" => Dict("type" => "unknown"),
                ),
                "equations" => [
                    Dict("lhs" => Dict("op" => "D", "args" => ["a"], "wrt" => "t"), "rhs" => Dict("op" => "-", "args" => ["a"])),
                    Dict(
                        "lhs" => "y",
                        "rhs" => Dict(
                            "op" => "apply_operator", "args" => [], "name" => "f",
                            "bindings" => Dict("p" => "a", "p_dt" => 2.0)
                        )
                    ),
                ],
            )
        ),
    )
    flat = EarthSciAST.flatten(EarthSciAST.load_string(JSON3.write(doc)))
    @test _ttd_params(flat.template_registry, "f") == ["p", "p_dt", "p_dt_"]
    y = _ttd_rhs(flat, "M.y")
    @test Set(keys(y.bindings)) == Set(["p", "p_dt", "p_dt_"])
    x = EarthSciAST.expand_flattened_refs(flat)
    canon(v) = EarthSciAST._canonical_compact(JSON3.read(JSON3.write(v)))
    @test canon(EarthSciAST.serialize_expression(_ttd_rhs(x, "M.y"))) ==
        canon(Dict("op" => "*", "args" => [2.0, Dict("op" => "-", "args" => ["M.a"])]))
end
