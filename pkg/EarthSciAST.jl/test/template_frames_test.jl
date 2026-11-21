# Template instances and frames (templates/frames.jl): reading a template
# reference through the template's own body, without expanding it
# (esm-spec §9.6.4 rule 2).
#
#   * a prepared body names each parameter by a sentinel, and each name it
#     reads from its caller by an implicit-parameter sentinel; names the body
#     binds itself stay;
#   * a reference carries its implicit parameters as bindings
#     (`_tpl_augment`), nested references inside bodies included, so the names
#     an expression reads (`free_variables`) are those of its expansion;
#   * one frame per template instance: two uses with the same bindings share
#     one, different bindings do not, and a parameter in a structural
#     position is substituted into that instance's body;
#   * a walk through the frames visits each instance body once, so a 64-deep
#     doubling chain stays linear;
#   * the dependency graph and range selection read through references this
#     way.

using Test
using EarthSciAST
using EarthSciAST: OpExpr, VarExpr, NumExpr, ASTExpr, expression_from_json, free_variables

const _FR = EarthSciAST

_fr_ref(name, b) = Dict{String, Any}(
    "op" => "apply_expression_template", "args" => Any[], "name" => name,
    "bindings" => Dict{String, Any}(b)
)
_fr_op(o, a...; kw...) = Dict{String, Any}("op" => o, "args" => Any[a...], (String(k) => v for (k, v) in kw)...)

function _fr_registry()
    return Dict{String, Any}(
        # reads its parameter `x`, the global `k` and the caller's index `i`
        "scale" => Dict{String, Any}(
            "params" => Any["x"],
            "body" => _fr_op("*", "k", _fr_op("index", "x", "i")),
        ),
        # binds `j` itself; reads `scale` with a compound binding
        "colsum" => Dict{String, Any}(
            "params" => Any["q"],
            "body" => Dict{String, Any}(
                "op" => "faq", "args" => Any[], "output_idx" => Any[],
                "ranges" => Dict{String, Any}("j" => Any[1, 3]),
                "expr" => _fr_ref("scale", Dict("x" => _fr_op("+", "q", "j"))),
            ),
        ),
        # `s` names an index set (a structural position) and is read nowhere else
        "over" => Dict{String, Any}(
            "params" => Any["s", "y"],
            "body" => Dict{String, Any}(
                "op" => "faq", "args" => Any[], "output_idx" => Any["m"],
                "ranges" => Dict{String, Any}("m" => Dict{String, Any}("from" => "s")),
                "expr" => _fr_op("index", "y", "m"),
            ),
        ),
    )
end

_fr_names(e::ASTExpr) = sort!(collect(free_variables(e)))

@testset "template frames" begin
    tt = _FR._TplTable(_fr_registry())

    @testset "prepared bodies" begin
        d = _FR._tpl_def(tt, "scale")
        @test isempty(d.structural)
        @test d.closed.free == ["i", "k"]
        b = d.closed.body
        @test _fr_names(b) == sort!(["\0arg\0x", "\0free\0i", "\0free\0k"])
        # A name the body binds stays; the nested reference carries the names
        # its body reads from `colsum`'s scope as implicit bindings.
        c = _FR._tpl_def(tt, "colsum")
        @test c.closed.free == ["i", "k"]
        inner = c.closed.body.expr_body
        @test _FR._tpl_is_call(inner)
        @test inner.bindings["\0free\0k"] == VarExpr("\0free\0k")
        @test inner.bindings["\0free\0i"] == VarExpr("\0free\0i")
        @test inner.bindings["x"].args[2] == VarExpr("j")      # bound by colsum's faq
        # A parameter in a structural position is substituted per instance.
        @test _FR._tpl_def(tt, "over").structural == ["s"]
    end

    @testset "augmented references read what the expansion reads" begin
        e = expression_from_json(_fr_ref("colsum", Dict("q" => "w")))
        a = _FR._tpl_augment(tt, e)
        @test _fr_names(a) == ["i", "k", "w"]
        @test _fr_names(a) == _fr_names(_FR._expand_expr_refs(e, _fr_registry()))
        # Under a binder of the caller's, the caller's own `i` is not free.
        f = expression_from_json(
            Dict{String, Any}(
                "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                "ranges" => Dict{String, Any}("i" => Any[1, 2]),
                "expr" => _fr_ref("scale", Dict("x" => "w")),
            )
        )
        @test _fr_names(_FR._tpl_augment(tt, f)) == ["k", "w"]
    end

    @testset "one frame per instance" begin
        r1 = _FR._tpl_augment(tt, expression_from_json(_fr_ref("scale", Dict("x" => "a"))))
        r2 = _FR._tpl_augment(tt, expression_from_json(_fr_ref("scale", Dict("x" => "a"))))
        r3 = _FR._tpl_augment(tt, expression_from_json(_fr_ref("scale", Dict("x" => "b"))))
        f1 = _FR._tpl_frame(tt, r1, nothing)
        @test _FR._tpl_frame(tt, r2, nothing) === f1
        @test _FR._tpl_frame(tt, r3, nothing) !== f1
        @test f1.body === _FR._tpl_def(tt, "scale").closed.body   # the body is not copied
        x, xf = _FR._tpl_leaf(VarExpr("\0arg\0x"), f1)
        @test x == VarExpr("a") && xf === nothing
        # A nested reference's frame reads its bindings in the outer frame.
        c = _FR._tpl_frame(tt, _FR._tpl_augment(tt, expression_from_json(_fr_ref("colsum", Dict("q" => "w")))), nothing)
        n = _FR._tpl_frame(tt, c.body.expr_body, c)
        @test n.parent === c
        q, qf = _FR._tpl_leaf(VarExpr("\0free\0k"), n)
        @test q == VarExpr("k") && qf === nothing
        # Structural parameters: one instance body per value.
        o1 = _FR._tpl_frame(tt, expression_from_json(_fr_ref("over", Dict("s" => "lon", "y" => "u"))), nothing)
        o2 = _FR._tpl_frame(tt, expression_from_json(_fr_ref("over", Dict("s" => "lat", "y" => "u"))), nothing)
        @test o1.body.ranges["m"].from == "lon"
        @test o2.body.ranges["m"].from == "lat"
        # Bindings that do not cover the parameters are refused as load refuses them.
        bad = expression_from_json(_fr_ref("scale", Dict("y" => "a")))
        err = try
            _FR._tpl_frame(tt, bad, nothing); nothing
        catch e
            e
        end
        @test err isa EarthSciAST.ExpressionTemplateError
    end

    @testset "a walk visits each instance once" begin
        depth = EarthSciAST.MAX_TEMPLATE_EXPANSION_DEPTH
        reg = Dict{String, Any}()
        for k in 1:(depth - 1)
            nxt = _fr_ref("c$(k + 1)", Dict("v" => "v"))
            reg["c$k"] = Dict{String, Any}("params" => Any["v"], "body" => _fr_op("+", nxt, nxt))
        end
        reg["c$depth"] = Dict{String, Any}("params" => Any["v"], "body" => _fr_op("*", "v", "g"))
        ct = _FR._TplTable(reg)
        top = _FR._tpl_augment(ct, expression_from_json(_fr_ref("c1", Dict("v" => "z"))))
        @test _fr_names(top) == ["g", "z"]
        visits = Ref(0)
        _FR._tpl_foreach_node((n, fr) -> (visits[] += 1), ct, top)
        @test visits[] < 10 * depth
        @test length(ct.frames) == depth
    end

    @testset "the dependency graph reads through nested references" begin
        doc = Dict{String, Any}(
            "esm" => "0.9.0", "metadata" => Dict{String, Any}("name" => "frames_graph"),
            "models" => Dict{String, Any}(
                "M" => Dict{String, Any}(
                    "expression_templates" => Dict{String, Any}(
                        "inner" => Dict{String, Any}("params" => Any["x"], "body" => _fr_op("*", "k", "x")),
                        "outer" => Dict{String, Any}(
                            "params" => Any["y"],
                            "body" => _fr_op("+", _fr_ref("inner", Dict("x" => "y")), "c"),
                        ),
                    ),
                    "variables" => Dict{String, Any}(
                        "k" => Dict{String, Any}("type" => "parameter", "default" => 0.5),
                        "c" => Dict{String, Any}("type" => "parameter", "default" => 0.1),
                        "y" => Dict{String, Any}("type" => "unknown", "default" => 1.0),
                        "z" => Dict{String, Any}("type" => "unknown", "default" => 2.0),
                    ),
                    "equations" => Any[
                        Dict{String, Any}(
                            "lhs" => _fr_op("D", "y"; wrt = "t"),
                            "rhs" => _fr_ref("outer", Dict("y" => "z")),
                        ),
                        Dict{String, Any}("lhs" => _fr_op("D", "z"; wrt = "t"), "rhs" => _fr_op("-", "z")),
                    ],
                )
            ),
        )
        file = EarthSciAST.load_string(IOBuffer(EarthSciAST.JSON3.write(doc)))
        @test file.component_templates !== nothing
        g = EarthSciAST.expression_graph(file)
        into_y = Set(e.source.name for e in g.edges if e.target.name == "M.y")
        @test into_y == Set(["M.k", "M.c", "M.z"])
        # The caller's document still carries its references.
        @test file.models["M"].equations[1].rhs isa OpExpr
        @test file.models["M"].equations[1].rhs.op == "apply_expression_template"
    end

    @testset "range selection reads through references" begin
        # `D(y)` reads the observed `w` only inside a template body: the
        # selection keeps `w`.
        doc = Dict{String, Any}(
            "esm" => "0.9.0", "metadata" => Dict{String, Any}("name" => "frames_select"),
            "models" => Dict{String, Any}(
                "M" => Dict{String, Any}(
                    "expression_templates" => Dict{String, Any}(
                        "damp" => Dict{String, Any}("params" => Any["x"], "body" => _fr_op("*", "w", "x")),
                    ),
                    "variables" => Dict{String, Any}(
                        "w" => Dict{String, Any}("type" => "unknown"),
                        "y" => Dict{String, Any}("type" => "unknown", "default" => 1.0),
                        "z" => Dict{String, Any}("type" => "unknown", "default" => 2.0),
                    ),
                    "equations" => Any[
                        Dict{String, Any}("lhs" => _fr_op("D", "y"; wrt = "t"), "rhs" => _fr_ref("damp", Dict("x" => "y"))),
                        Dict{String, Any}("lhs" => _fr_op("D", "z"; wrt = "t"), "rhs" => _fr_op("-", "z")),
                        Dict{String, Any}("lhs" => "w", "rhs" => _fr_op("*", 2, "z")),
                    ],
                )
            ),
        )
        flat = EarthSciAST.flatten(EarthSciAST.load_string(IOBuffer(EarthSciAST.JSON3.write(doc))))
        @test any(eq -> occursin("apply_expression_template", string(EarthSciAST.serialize_expression(eq.rhs))), flat.equations)
        # `w` is live only through the reference in `D(y)`'s rule.
        @test haskey(flat.observed_variables, "M.w")
        flat2, W, R = EarthSciAST._select_flat(flat, ["M.y", "M.z"], :all)
        @test haskey(flat2.observed_variables, "M.w")
    end
end
