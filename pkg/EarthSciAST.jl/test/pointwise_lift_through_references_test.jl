# Pointwise lift (esm-spec §10.5) of a species whose spatial operator is written
# as an expression-template reference: the operator `makearray` then sits inside
# the template body, not in the merged equation. The lift's candidate search and
# its loop and axis decisions walk through the reference in its own frame
# (never expanding it, esm-spec §9.6.4 rule 2), and must decide exactly what
# they decide on the expanded document: each case below is written once with
# the reference and once with its expansion (`_substitute`, the expansion's own
# substitution) written in place, and the two must lift the species onto the
# same grid, over the same loops, and build to the same right-hand side, bit
# for bit.

using Test
using EarthSciAST
const _PLR = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT (also lets this file run standalone)

_plr_fixture() = joinpath(
    TESTUTILS_REPO_ROOT, "tests", "conformance", "pointwise_lift", "fixtures",
    "lift_same_size_index_sets.esm"
)

_plr_load() = _PLR.JSON3.read(read(_plr_fixture(), String), Dict{String, Any})

_plr_rename(x, m) = x isa AbstractString ? get(m, x, x) :
    x isa AbstractDict ? Dict{String, Any}(k => _plr_rename(v, m) for (k, v) in x) :
    x isa AbstractVector ? Any[_plr_rename(v, m) for v in x] : x

# The fixture's Wind operator as the template `adv(params…)` whose body is
# `body(makearray)`, applied with `bindings`; and the same document with the
# reference expanded in place.
function _plr_pair(; params, body, bindings)
    ref = _plr_load()
    ma = ref["models"]["Wind"]["equations"][1]["rhs"]
    tbody = body(ma)
    ref["models"]["Wind"]["expression_templates"] = Dict{String, Any}(
        "adv" => Dict{String, Any}("params" => Any[params...], "body" => tbody)
    )
    ref["models"]["Wind"]["equations"][1]["rhs"] = Dict{String, Any}(
        "op" => "apply_expression_template", "args" => Any[], "name" => "adv",
        "bindings" => Dict{String, Any}(bindings)
    )
    inline = _plr_load()
    inline["models"]["Wind"]["equations"][1]["rhs"] =
        _PLR._substitute(tbody, Dict{String, Any}(bindings))
    return ref, inline
end

_plr_eq(flat, name) = only(
    eq for eq in flat.equations
        if occursin(name, string(_PLR.serialize_expression(eq.lhs)))
)

function _plr_flatten(dir, tag, doc)
    path = joinpath(dir, "$tag.esm")
    write(path, _PLR.JSON3.write(doc))
    return _PLR.flatten(_PLR.load_path(path))
end

function _plr_rhs(flat, compiler)
    f, u0, p = _PLR.Internal.build(flat; compiler = compiler)
    u = Float64[1.0 + 0.1 * k for k in eachindex(u0)]
    du = similar(u0)
    f(du, u, p, 0.0)
    return du
end

# The reference document and its expansion lift `Chem.c` identically.
function _plr_check(dir, tag, ref, inline; compilers = (:native, :interpreter))
    fr = _plr_flatten(dir, "$(tag)_ref", ref)
    fi = _plr_flatten(dir, "$(tag)_inline", inline)
    @test fr.state_variables["Chem.c"].shape == fi.state_variables["Chem.c"].shape == ["x", "y"]
    er, ei = _plr_eq(fr, "Chem.c"), _plr_eq(fi, "Chem.c")
    @test string(_PLR.serialize_expression(er.lhs)) == string(_PLR.serialize_expression(ei.lhs))
    @test er.rhs.op == ei.rhs.op == "faq"
    @test er.rhs.output_idx == ei.rhs.output_idx
    @test Dict(k => v.from for (k, v) in er.rhs.ranges) == Dict(k => v.from for (k, v) in ei.rhs.ranges)
    # The reference survives, read per cell at the lift's loops.
    @test any(
        t -> t isa _PLR.OpExpr && t.op == "index" && t.args[1] isa _PLR.OpExpr &&
            t.args[1].op == "apply_expression_template" &&
            [a.name for a in t.args[2:end]] == er.rhs.output_idx,
        er.rhs.expr_body.args
    )
    for c in compilers
        @test _plr_rhs(fr, c) == _plr_rhs(fi, c)
    end
    return fr, fi
end

@testset "pointwise lift through a template reference" begin
    mktempdir() do dir
        @testset "the operator makearray inside a template body" begin
            ref, inline = _plr_pair(
                params = ["q", "w"],
                body = ma -> _plr_rename(ma, Dict("_var" => "q", "u" => "w")),
                bindings = ["q" => "_var", "w" => "u"]
            )
            _plr_check(dir, "plain", ref, inline)
        end

        @testset "the conformance fixture" begin
            # tests/conformance/pointwise_lift/fixtures/lift_operator_reference.esm
            # is the case above, as a file every binding can read.
            fix = joinpath(dirname(_plr_fixture()), "lift_operator_reference.esm")
            fr = _PLR.flatten(_PLR.load_path(fix))
            fi = _PLR.flatten(_PLR.load_path(_plr_fixture()))
            @test fr.state_variables["Chem.c"].shape == ["x", "y"]
            @test fr.lifted_shapes == fi.lifted_shapes
            @test _plr_rhs(fr, :native) == _plr_rhs(fi, :native)
        end

        @testset "a parameter in structural positions (output_idx, ranges)" begin
            # `L` names the faq's first loop: expansion substitutes it in
            # `output_idx` and in the `ranges` key's twin in the body.
            ref, inline = _plr_pair(
                params = ["q", "w", "L"],
                body = ma -> _plr_rename(ma, Dict("_var" => "q", "u" => "w", "i" => "L")),
                bindings = ["q" => "_var", "w" => "u", "L" => "m"]
            )
            # `ranges` keys are not substitution sites: give the body's range
            # the bound name, as an author writing for this binding would.
            for d in (ref["models"]["Wind"]["expression_templates"]["adv"]["body"],)
                f = d["values"][1]
                f["ranges"] = Dict{String, Any}("m" => f["ranges"]["i"], "j" => f["ranges"]["j"])
            end
            f = inline["models"]["Wind"]["equations"][1]["rhs"]["values"][1]
            f["ranges"] = Dict{String, Any}("m" => f["ranges"]["i"], "j" => f["ranges"]["j"])
            fr, fi = _plr_check(dir, "structural", ref, inline)
            @test _plr_eq(fr, "Chem.c").rhs.output_idx == ["m", "j"]
        end

        @testset "a parameter named like a loop index of the body" begin
            # Parameter `i` bound to `m`: expansion replaces every `i` in the
            # body, the faq's own loop among them, so the lift's loops are
            # `m, j` on both documents.
            ref, inline = _plr_pair(
                params = ["q", "w", "i"],
                body = ma -> _plr_rename(ma, Dict("_var" => "q", "u" => "w")),
                bindings = ["q" => "_var", "w" => "u", "i" => "m"]
            )
            for f in (
                    ref["models"]["Wind"]["expression_templates"]["adv"]["body"]["values"][1],
                    inline["models"]["Wind"]["equations"][1]["rhs"]["values"][1],
                )
                haskey(f["ranges"], "i") && (f["ranges"] = Dict{String, Any}("m" => f["ranges"]["i"], "j" => f["ranges"]["j"]))
            end
            fr, _ = _plr_check(dir, "shadow", ref, inline)
            @test _plr_eq(fr, "Chem.c").rhs.output_idx == ["m", "j"]
        end

        @testset "the body's makearray binds other loop names than the lift's" begin
            # The inline operator's `output_idx` is set to the lift's loops; the
            # referenced one keeps its own (`a`, `b`), read positionally at the
            # lift's loops by `index(<reference>, i, j)`: the same cells.
            ref, inline = _plr_pair(
                params = ["q", "w"],
                body = ma -> merge(
                    _plr_rename(ma, Dict("_var" => "q", "u" => "w")),
                    Dict{String, Any}("output_idx" => Any["a", "b"])
                ),
                bindings = ["q" => "_var", "w" => "u"]
            )
            _plr_check(dir, "binder", ref, inline)
        end
    end

    @testset "a reference with a missing binding is refused" begin
        # Load refuses it (esm-spec §9.6.9, `_validate_apply_ref`), so a flattened
        # system never carries one; the lift's walk refuses it too, with the
        # same code, rather than reading the unbound parameter as a free name.
        ref, _ = _plr_pair(
            params = ["q", "w"],
            body = ma -> _plr_rename(ma, Dict("_var" => "q", "u" => "w")),
            bindings = ["q" => "_var"]
        )
        err(f) = try
            f(); nothing
        catch e
            e
        end
        mktempdir() do dir
            path = joinpath(dir, "missing.esm")
            write(path, _PLR.JSON3.write(ref))
            e1 = err(() -> _PLR.flatten(_PLR.load_path(path)))
            @test e1 isa _PLR.ExpressionTemplateError
            reg = ref["models"]["Wind"]["expression_templates"]
            bad = _PLR.OpExpr(
                "apply_expression_template", _PLR.ASTExpr[];
                name = "adv", bindings = Dict{String, _PLR.ASTExpr}("q" => _PLR.VarExpr("c"))
            )
            e2 = err(() -> _PLR._collect_makearrays!(Tuple{_PLR.OpExpr, Any}[], bad, _PLR._RefWalk(reg)))
            @test e2 isa _PLR.ExpressionTemplateError
            e1 isa _PLR.ExpressionTemplateError && e2 isa _PLR.ExpressionTemplateError &&
                @test _PLR.error_code(e1) == _PLR.error_code(e2)
        end
    end
end
