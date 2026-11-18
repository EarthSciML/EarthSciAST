# Pointwise lift (esm-spec §10.5) of a species whose spatial operator is written
# as an expression-template reference: the operator `makearray` then sits inside
# the template body, not in the merged equation. The lift's candidate search and
# its loop and axis decisions walk through the reference in its own frame
# (never expanding it, esm-spec §9.6.4 rule 2), and decide exactly what they
# decide on the expanded tree: the species is lifted onto the same grid, and the
# flattened system expands to the same equations and builds to the same
# right-hand side, bit for bit.

using Test
using EarthSciAST
const _PLR = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT (also lets this file run standalone)

_plr_fixture() = joinpath(
    TESTUTILS_REPO_ROOT, "tests", "conformance", "pointwise_lift", "fixtures",
    "lift_same_size_index_sets.esm"
)

# The fixture with Wind's operator moved into a template `adv(q, w)`: its body
# is the operator `makearray`, reading the species through the parameter `q`
# and the wind through `w`; the equation applies it to `_var` and `u`.
function _plr_referenced()
    doc = _PLR.JSON3.read(read(_plr_fixture(), String), Dict{String, Any})
    wind = doc["models"]["Wind"]
    eq = wind["equations"][1]
    ma = eq["rhs"]
    rename(x) = x isa AbstractString ? (x == "_var" ? "q" : x == "u" ? "w" : x) :
        x isa AbstractDict ? Dict{String, Any}(k => rename(v) for (k, v) in x) :
        x isa AbstractVector ? Any[rename(v) for v in x] : x
    wind["expression_templates"] = Dict{String, Any}(
        "adv" => Dict{String, Any}("params" => Any["q", "w"], "body" => rename(ma))
    )
    eq["rhs"] = Dict{String, Any}(
        "op" => "apply_expression_template", "args" => Any[], "name" => "adv",
        "bindings" => Dict{String, Any}("q" => "_var", "w" => "u")
    )
    return doc
end

_plr_eq(flat, name) = only(
    eq for eq in flat.equations
        if _PLR.differential_lhs_variable(eq.lhs) == name ||
        occursin(name, string(_PLR.serialize_expression(eq.lhs)))
)

@testset "pointwise lift through a template reference" begin
    plain = _PLR.flatten(_PLR.load_path(_plr_fixture()))
    mktempdir() do dir
        path = joinpath(dir, "lift_through_reference.esm")
        write(path, _PLR.JSON3.write(_plr_referenced()))
        ref = _PLR.flatten(_PLR.load_path(path))

        # The species is lifted, onto the grid the expanded operator names.
        @test plain.state_variables["Chem.c"].shape == ["x", "y"]
        @test ref.state_variables["Chem.c"].shape == ["x", "y"]

        # The reference survives flatten, read per cell as the operator
        # `makearray` it denotes is: `index(<reference>, i, j)` inside the
        # lifted `faq` over the same loops and index sets.
        lifted = _plr_eq(ref, "Chem.c")
        plain_eq = _plr_eq(plain, "Chem.c")
        @test lifted.rhs.op == "faq" && lifted.rhs.output_idx == plain_eq.rhs.output_idx
        @test Dict(k => v.from for (k, v) in lifted.rhs.ranges) ==
            Dict(k => v.from for (k, v) in plain_eq.rhs.ranges) ==
            Dict("i" => "x", "j" => "y")
        @test string(_PLR.serialize_expression(lifted.lhs)) ==
            string(_PLR.serialize_expression(plain_eq.lhs))
        terms = lifted.rhs.expr_body.args
        @test any(
            t -> t isa _PLR.OpExpr && t.op == "index" &&
                t.args[1] isa _PLR.OpExpr && t.args[1].op == "apply_expression_template" &&
                all(k -> t.args[k + 1] isa _PLR.VarExpr && t.args[k + 1].name == lifted.rhs.output_idx[k], 1:2),
            terms
        )

        # Same right-hand side, bit for bit, under both compilers.
        for compiler in (:native, :interpreter)
            fp, u0p, pp = _PLR.Internal.build(plain; compiler = compiler)
            fr, u0r, pr = _PLR.Internal.build(ref; compiler = compiler)
            @test u0p == u0r
            u = Float64[1.0 + 0.1 * k for k in eachindex(u0p)]
            dp, dr = similar(u0p), similar(u0r)
            fp(dp, u, pp, 0.0)
            fr(dr, u, pr, 0.0)
            @test dp == dr
        end
    end
end
