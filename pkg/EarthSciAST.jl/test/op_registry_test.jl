# Pinning tests for the operator registry (src/op_registry.jl) and the other
# Wave-1 shared foundations.
#
# The five per-pass op sets DERIVE from `_OP_TABLE`. Membership is behavior (fold/CSE/stencil/
# geometry-materialization/MTK-gap decisions with cross-language conformance
# consequences), so each derived set is pinned here against a literal copy of
# the pre-registry membership. A failure means the registry flags drifted:
# either revert the flag, or — for a DELIBERATE vocabulary change — update the
# literal below in the same commit, citing the motivating spec section.
# Containment invariants between the sets and the evaluator ladders are pinned
# separately by tree_walk_op_table_test.jl.

using Test
using EarthSciAST
using JSON3

const ESM = EarthSciAST

@testset "op registry pins" begin

    @testset "_WS4_FOLDABLE_ELEMENTWISE_OPS membership (pre-registry literal)" begin
        @test ESM._WS4_FOLDABLE_ELEMENTWISE_OPS == Set{String}(
            [
                "+", "-", "*", "/", "^", "neg", "pow",
                "sqrt", "abs", "sign",
                "exp", "log", "log10",
                "sin", "cos", "tan", "asin", "acos", "atan",
                "sinh", "cosh", "tanh",
                "max", "min", "floor", "ceil",
                "ifelse",
            ]
        )
        @test ESM._WS4_FOLDABLE_ELEMENTWISE_OPS isa Set{String}
    end

    @testset "_CSE_OPAQUE_OPS membership (pre-registry literal)" begin
        # What routes a rewrite-target op through
        # `_compile_op`'s `unlowered_operator` gate (instead of the guardless
        # `_cse_rebuild` generic-node path) is the GENERIC tier predicate
        # `_op_in_T` inside `_cse_hoistable` — a member of `_REWRITE_TARGET_OPS`
        # or an unregistered custom op is non-hoistable uniformly, by predicate,
        # not by a `cse=true` flag or an op-name list. `D`/`ic` KEEP `cse=true`
        # (they stay CSE barriers via their own `_compile_op` arms).
        @test ESM._CSE_OPAQUE_OPS == Set{String}(
            [
                "const", "enum", "D", "ic",
                "faq", "faq", "makearray", "broadcast", "reshape",
                "transpose", "concat", "index",
            ]
        )
        @test ESM._CSE_OPAQUE_OPS isa Set{String}
    end

    @testset "_STENCIL_ELEMENTWISE_OPS membership (pre-registry literal)" begin
        @test ESM._STENCIL_ELEMENTWISE_OPS == Set{String}(
            [
                "+", "*", "-", "neg", "/", "^", "pow",
                "<", "<=", ">", ">=", "==", "!=", "and", "or", "not", "ifelse",
                "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
                "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
                "exp", "log", "log10", "sqrt", "abs", "sign", "floor", "ceil",
                "min", "max", "pi", "π", "e", "Pre",
            ]
        )
        @test ESM._STENCIL_ELEMENTWISE_OPS isa Set{String}
    end

    @testset "_GEO_EVAL_OPS membership (pre-registry literal)" begin
        # `and` / `or` / `not` are members because a setup-time geometry body
        # may carry a CONTAINMENT PREDICATE — the canonical spelling is
        # `ifelse(and(cmp, cmp, …), …)`, which is what every projection-pushdown
        # binning aggregate writes — so without the three logical ops a
        # polygon-area binning body could not compile at all
        # (E_TREEWALK_GEOMETRY_SETUP: unsupported op 'and'). `_eval_node_op`'s
        # `:and` / `:or` / `:not` arms (tree_walk/compile.jl) evaluate them. See
        # CONFORMANCE_SPEC §5.5.7 "Cell-axis arrays".
        @test ESM._GEO_EVAL_OPS == Set{String}(
            [
                "+", "*", "-", "/", "^", "max", "min", "sqrt", "abs", "cos", "sin",
                "atan2",
                "ifelse", "floor", "ceil", ">", "<", ">=", "<=", "==", "!=",
                "and", "or", "not",
                "index", "true", "false", "faq", "faq",
            ]
        )
        @test ESM._GEO_EVAL_OPS isa Set{String}
        @test isconst(ESM, :_GEO_EVAL_OPS)
        @test isconst(ESM, :_REDUCE_PROJECTION_KINDS)
        @test ESM._REDUCE_PROJECTION_KINDS == ("min", "max", "sum", "prod")
    end

    @testset "MTK-ext _KNOWN_OPS source (pre-registry literal)" begin
        # The extension defines `const _KNOWN_OPS = EarthSciAST._ops_with(:mtk_known)`;
        # pin the accessor output here so the pin holds without loading MTK.
        @test ESM._ops_with(:mtk_known) == Set{String}(
            [
                "+", "-", "*", "/", "^",
                "exp", "log", "log10", "sin", "cos", "tan", "sinh", "cosh", "tanh",
                "asin", "acos", "atan", "sqrt", "abs",
                "min", "max",
                ">", "<", ">=", "<=", "==", "!=",
                "D",
                "faq", "faq", "makearray", "index", "broadcast",
                "reshape", "transpose",
                "concat", "Pre", "ifelse", "ic",
            ]
        )
        @test ESM._ops_with(:mtk_known) isa Set{String}
    end

    @testset "grad/div/laplacian were removed at esm 3.0.0 (§4.2)" begin
        # They are refused by name at load (`removed_op`), so they have no
        # registry row; spatial axes are harvested structurally from the
        # `dim`/`wrt` FIELDS (flatten.jl), not from an op-name set.
        for op in ("grad", "div", "laplacian")
            @test ESM._op_spec(op) === nothing
            @test op in ESM._REMOVED_OPS
            @test !(op in ESM._REWRITE_TARGET_OPS)
        end
        @test !(:spatial in ESM._OP_FLAG_NAMES)
        @test !(:dim_spatial in ESM._OP_FLAG_NAMES)
        @test_throws ArgumentError ESM._ops_with(:spatial)
        @test_throws ArgumentError ESM._ops_with(:dim_spatial)
        @test !isdefined(ESM, :_SPATIAL_OPS)
        @test !isdefined(ESM, :_DIM_SPATIAL_OPS)
    end

    @testset "_ARRAY_PRODUCER_OPS / _SELF_INDEXED_OPS membership (pre-registry literal)" begin
        # shape_promotion.jl's array rewrites: producers, and the
        # self-indexing nodes (producers + `index`) the leaf-indexing
        # rewrites never descend into.
        @test ESM._ARRAY_PRODUCER_OPS ==
            Set{String}(["faq", "faq", "makearray"])
        @test ESM._ARRAY_PRODUCER_OPS isa Set{String}
        @test ESM._SELF_INDEXED_OPS ==
            Set{String}(["faq", "faq", "makearray", "index"])
        @test ESM._SELF_INDEXED_OPS isa Set{String}
    end

    @testset "registry accessors" begin
        @test ESM._op_spec("sin") isa ESM._OpSpec
        @test ESM._op_spec("sin").scalar_fn === sin
        @test ESM._op_spec("no_such_op") === nothing
        @test_throws ArgumentError ESM._ops_with(:not_a_flag)
        # No duplicate rows (uniqueness is also asserted at load time).
        @test length(ESM._OP_TABLE) == length(ESM._OP_INDEX)
    end

    @testset "_BUILTIN_FUNCTION_NAMES membership (pre-registry literal)" begin
        # The reference checker's excused names, now derived from the
        # registry's `builtin_fn` flag (the :elementary rows + ifelse/Pre).
        # Mirrors Rust `is_builtin_function` (structural.rs) — a drift here is
        # a cross-binding divergence, not just a Julia one.
        @test ESM._BUILTIN_FUNCTION_NAMES == Set{String}(
            [
                "exp", "log", "log10", "sqrt", "abs", "sign",
                "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
                "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
                "min", "max", "floor", "ceil", "ifelse", "Pre",
            ]
        )
        @test ESM._BUILTIN_FUNCTION_NAMES isa Set{String}
    end

    @testset "units.jl dimensional-rule op classes (pre-registry literals)" begin
        # The five op-class sets `_DIMENSION_RULES` is populated from, now
        # derived from the registry's `dim_class` column. `_TRANSCENDENTAL_OPS`
        # additionally unions the spec-adjacent spellings ln/log2/expm1, which
        # deliberately have NO registry row (`_op_in_T` classifies unregistered
        # ops as open-namespace rewrite targets — a row would change that).
        @test ESM._TRANSCENDENTAL_OPS == Set{String}(
            [
                "exp", "log", "ln", "log10", "log2", "expm1",
                "tanh", "sinh", "cosh", "asinh", "acosh", "atanh",
            ]
        )
        # `sqrt` must never be transcendental: it halves its argument's
        # dimension (`_sqrt_rule`) rather than requiring a dimensionless one.
        @test !("sqrt" in ESM._TRANSCENDENTAL_OPS)
        @test ESM._CIRCULAR_OPS == Set{String}(["sin", "cos", "tan"])
        @test ESM._INVERSE_CIRCULAR_OPS ==
            Set{String}(["asin", "acos", "atan", "atan2"])
        @test ESM._COMPARISON_OPS ==
            Set{String}(["<", ">", "<=", ">=", "==", "!="])
        @test ESM._BOOLEAN_OPS == Set{String}(["and", "or", "not"])
        for s in (
                ESM._TRANSCENDENTAL_OPS, ESM._CIRCULAR_OPS,
                ESM._INVERSE_CIRCULAR_OPS, ESM._COMPARISON_OPS,
                ESM._BOOLEAN_OPS,
            )
            @test s isa Set{String}
        end
        # The spellings with no registry row stay OUT of the registry (their
        # rows would silently reclassify them for template lowering).
        for name in ("ln", "log2", "expm1", "=")
            @test ESM._op_spec(name) === nothing
        end
        @test_throws ArgumentError ESM._ops_with_dim_class(:not_a_class)
    end

    @testset "_UNARY_ELEMENTWISE_OPS: the mechanical unary ladder arms, in order" begin
        # Exactly the ops with a repetitive one-liner arm in `_eval_node_op` /
        # `_eval_acc_op`, in arm order. `atan` (1-or-2-ary), `neg`, and `not`
        # are deliberately absent (non-mechanical arms).
        expected = [
            ("sin", sin), ("cos", cos), ("tan", tan),
            ("asin", asin), ("acos", acos),
            ("sinh", sinh), ("cosh", cosh), ("tanh", tanh),
            ("asinh", asinh), ("acosh", acosh), ("atanh", atanh),
            ("exp", exp), ("log", log), ("log10", log10),
            ("sqrt", sqrt), ("abs", abs), ("sign", sign),
            ("floor", floor), ("ceil", ceil),
        ]
        table = ESM._UNARY_ELEMENTWISE_OPS
        @test [e.name for e in table] == [first(e) for e in expected]
        @test all(e.sym === Symbol(e.name) for e in table)
        @test [e.fn for e in table] == [last(e) for e in expected]
    end
end

@testset "operator shapes, normative arity and the reducer table" begin
    # The shaped rows are exactly the operators the generated ladders evaluate
    # and every back end must cover (the Reactant table is checked against this
    # set when the extension loads).
    @test ESM._SHAPED_OP_SYMS == Set{Symbol}(
        Symbol.(
            [
                "+", "*", "-", "neg", "/", "^", "pow", "atan2",
                "<", "<=", ">", ">=", "==", "!=", "and", "or", "not", "ifelse",
                "sin", "cos", "tan", "asin", "acos", "sinh", "cosh", "tanh",
                "asinh", "acosh", "atanh", "exp", "log", "log10", "sqrt", "abs",
                "sign", "floor", "ceil", "atan", "min", "max", "pi", "π", "e", "Pre",
            ]
        )
    )
    @test [r.sym for r in ESM._SHAPED_OPS][1:4] == [:+, :*, :-, :neg]
    for r in ESM._SHAPED_OPS
        @test r.spec.arity isa UnitRange{Int}
    end
    @test [s.name for s in ESM._OP_TABLE if s.lazy_from > 0] == ["and", "or", "ifelse"]
    @test ESM._op_spec("call") === nothing

    # Arity is normative: a node outside it is refused where the tree walk
    # compiles it, with one message.
    lit(x) = NumExpr(x)
    for (op, n) in (("-", 3), ("/", 3), ("and", 1), ("min", 1), ("sin", 2), ("ifelse", 2))
        err = try
            ESM._compile(OpExpr(op, ESM.ASTExpr[lit(1.0) for _ in 1:n]), Dict{String, Int}(), Set{Symbol}())
            nothing
        catch e
            e
        end
        @test err isa ESM.TreeWalkError && err.code == "E_TREEWALK_ARITY"
        @test occursin("$op expects", err.detail)
    end

    # Sets that derive from the registry outside the flag table's first nine.
    @test Set(ESM._SHAPE_REMAP_OPS) == Set(["reshape", "transpose", "concat"])
    @test Set(ESM._LIFT_WHOLE_ARRAY_OPS) == Set(["reshape", "transpose", "concat"])
    @test ESM._ARRAY_ELEMENT_OPS == Set(
        ["faq", "makearray", "index", "reshape", "transpose", "concat", "broadcast"]
    )
    @test ESM._DEPRECATED_DOCUMENT_OPS == Dict("neg" => ("-", 1), "pow" => ("^", 2))

    # The removed and deprecated spellings: one list each, which the document
    # formats share with the loader.
    @test ESM._REMOVED_OPS == (
        "arrayop", "fn", "table_lookup", "skolem", "rank", "intersect_polygon",
        "polygon_intersection_area", "argmin", "argmax", "aggregate",
        "grad", "div", "laplacian",
    )
    @test ESM.DocumentFormats.MExpr.REMOVED_OPS === ESM._REMOVED_OPS
    @test ESM.DocumentFormats.MExpr.DEPRECATED_OPS == ("neg", "pow")

    # The reducer table: the schema's `reduce` enum is its numeric rows; `or`
    # (bool_and_or) is not numeric; every reducer names a module function.
    @test Set(keys(ESM._OPLUS_IDENTITY)) == Set(["+", "*", "max", "min"])
    @test [r.sym for r in ESM._REDUCERS] == [:+, :*, :max, :min, :or]
    @test ESM._is_numeric_reducer("max") && !ESM._is_numeric_reducer("or")
    @test !ESM._is_numeric_reducer("bogus")
    @test ESM._oplus(:or, 0.0, 2.0) == 1.0
    @test ESM._oplus_numeric(:min, 3.0, 1.0) == 1.0
    @test_throws ESM.TreeWalkError ESM._oplus_numeric(:or, 0.0, 1.0)
    @test ESM._reducer_fnsym(:or) === :_or_combine
end

@testset "canonical emissible-field partition pins" begin
    # The former hand-maintained literal: forgetting a future OpExpr field
    # here would have silently DROPPED it from canonical JSON. The tuple is
    # now derived (fail-closed) from _EMISSIBLE_FIELDS/_CANONICAL_IGNORED_FIELDS;
    # this pins that the derivation reproduces the old literal exactly
    # (membership AND order — order feeds the E_CANONICAL_UNSUPPORTED_FIELD
    # message text).
    #
    # `expect_cadence` / `attrs` join the tail: `tests/conformance/canonical/
    # README.md` requires a node carrying either to raise
    # E_CANONICAL_UNSUPPORTED_FIELD, which only became reachable once the typed
    # IR stopped dropping them at parse.
    @test ESM._NON_EMISSIBLE_FIELDS == (
        :int_var, :lower, :upper, :output_idx, :expr_body, :reduce, :semiring,
        :ranges, :regions, :values, :shape, :perm, :axis,
        :join, :filter, :join_gates,
        :id, :distinct, :key,
        :expect_cadence, :attrs,
    )
    # The two annotations fail CLOSED rather than being silently dropped.
    for kw in (:expect_cadence => "const", :attrs => Dict{String, Any}("gamma" => 1.4))
        @test_throws CanonicalizeError ESM._emit_node_json(
            OpExpr(
                "+", EarthSciAST.ASTExpr[VarExpr("a"), VarExpr("b")];
                NamedTuple{(kw[1],)}((kw[2],))...
            )
        )
    end
    # `units` joins the closed emissible set at esm 1.2.0: a `const` node's
    # declared unit is meaning-bearing, so canonical JSON carries it and two
    # nodes differing only in it do not canonicalize alike (esm-spec §4.8.5).
    @test ESM._EMISSIBLE_FIELDS == (:op, :args, :wrt, :dim, :fn, :name, :value, :units)
    # `bindings` is tolerated-and-ignored (absent from the non-emissible
    # literal): a node carrying it still canonicalizes. `template_origin` is
    # load provenance, never on the wire (esm-spec §9.6.11).
    @test ESM._CANONICAL_IGNORED_FIELDS == (:bindings, :template_origin)
    # Fail-closed: the three tuples exactly partition fieldnames(OpExpr).
    @test sort(
        collect(
            (
                ESM._EMISSIBLE_FIELDS..., ESM._CANONICAL_IGNORED_FIELDS...,
                ESM._NON_EMISSIBLE_FIELDS...,
            )
        )
    ) ==
        sort(collect(fieldnames(OpExpr)))
    # Behavior spot-checks on the emitter itself (bypassing `canonicalize`'s
    # rewrites): ignored fields emit fine, non-emissible ones throw.
    @test ESM._emit_node_json(
        OpExpr(
            "+", EarthSciAST.ASTExpr[
                VarExpr("a"),
                VarExpr("b"),
            ];
            bindings = Dict{String, EarthSciAST.ASTExpr}("f" => VarExpr("u"))
        )
    ) ==
        ESM._emit_node_json(
        OpExpr(
            "+", EarthSciAST.ASTExpr[
                VarExpr("a"),
                VarExpr("b"),
            ]
        )
    )
    @test_throws CanonicalizeError ESM._emit_node_json(
        OpExpr("+", EarthSciAST.ASTExpr[VarExpr("a")]; shape = Any[2])
    )
end

@testset "Wave-1 foundation smoke checks" begin

    @testset "foreach_subexpr visits every child_exprs descendant" begin
        # An aggregate whose variables hide in expr_body / filter — the fields
        # a hand-rolled args-only walk misses.
        body = OpExpr("*", EarthSciAST.ASTExpr[VarExpr("w"), VarExpr("u")])
        agg = OpExpr(
            "faq", EarthSciAST.ASTExpr[];
            output_idx = Any["i"],
            ranges = Dict{String, Any}("i" => [1, 4]),
            expr_body = body,
            filter = OpExpr(
                ">", EarthSciAST.ASTExpr[
                    VarExpr("w"),
                    NumExpr(0.0),
                ]
            )
        )
        seen = String[]
        ESM.foreach_subexpr(agg) do e
            e isa VarExpr && push!(seen, e.name)
        end
        @test sort(seen) == ["u", "w", "w"]
        # Parent-before-children on a plain tree.
        order = []
        ESM.foreach_subexpr(e -> push!(order, e), body)
        @test order[1] === body
        @test length(order) == 3
    end

    @testset "json_walk combinators over Dict / JSON3 / Symbol keys" begin
        raw = JSON3.read("""{"op":"+","args":[{"op":"x","args":[]},3.5],"note":"n"}""")

        # _raw_get / _raw_haskey: Symbol-keyed JSON3.Object and String-keyed Dict.
        @test ESM._raw_get(raw, "op") == "+"
        @test ESM._raw_haskey(raw, "args")
        @test ESM._raw_get(Dict("op" => "-"), "op") == "-"
        @test ESM._raw_get(raw, "missing") === nothing

        # _walk_json: visits every node, key-aware pruning skips "op" values.
        names = String[]
        ESM._walk_json(raw) do key, n
            key == "op" && return false
            n isa AbstractString && push!(names, string(n))
            return true
        end
        @test names == ["n"]

        # _collect_json!: predicate collector, no pruning.
        nums = ESM._collect_json!(n -> n isa Real, Any[], raw)
        @test nums == Any[3.5]

        # _map_json: structure-preserving rewrite; replacement short-circuits,
        # untouched structure is rebuilt as OrderedDict{String,Any}/Vector{Any}
        # in document key order.
        out = ESM._map_json(raw) do key, n
            key == "note" && return "rewritten"
            n isa Real && return n + 1
            return ESM._JSON_DESCEND
        end
        @test out isa AbstractDict{String, Any}
        @test collect(keys(out)) == ["op", "args", "note"]
        @test out["note"] == "rewritten"
        @test out["args"][2] == 4.5
        @test out["args"][1]["op"] == "x"
        # Identity visitor normalizes without changing content.
        same = ESM._map_json((k, n) -> ESM._JSON_DESCEND, Dict("a" => Any[1, 2]))
        @test same == Dict("a" => Any[1, 2])
    end

    @testset "raw_substrates / raw_products give the ordered fields" begin
        subs = [ESM.StoichiometryEntry("B", 1.0), ESM.StoichiometryEntry("A", 2.0)]
        prods = [ESM.StoichiometryEntry("C", 1.0)]
        r = Reaction("r1", subs, prods, NumExpr(1.0))
        @test ESM.raw_substrates(r) === getfield(r, :substrates)
        @test ESM.raw_products(r) === getfield(r, :products)
        # Order preserved (the Dict view loses it).
        @test [e.species for e in ESM.raw_substrates(r)] == ["B", "A"]
        # get_products_dict serves the unordered Dict view.
        @test ESM.get_products_dict(r) == Dict("C" => 1.0)
        # Source/sink reactions keep the raw `nothing`.
        rsrc = Reaction("r2", nothing, prods, NumExpr(1.0))
        @test ESM.raw_substrates(rsrc) === nothing
    end
end

@testset "document-format keyword tables derive their literals" begin
    # The lexers' keyword and punctuation tables are inverses of each surface's
    # `KW_CHARS`, and the parser's function, comparison and reduction readings
    # are inverses of the printer's tables. Pin the derived values against the
    # literals they replace.
    DF = ESM.DocumentFormats
    L, Ty, P, Pr = DF.MLatex, DF.MTypst, DF.MParse, DF.MPrint
    K = DF.MToken
    @test L.CTRL_KW == Dict{String, K.Kw}(
        "ne" => K.KNe, "neq" => K.KNe, "le" => K.KLe, "leq" => K.KLe, "ge" => K.KGe, "geq" => K.KGe,
        "land" => K.KLand, "lor" => K.KLor, "lnot" => K.KLnot, "cdot" => K.KCdot, "times" => K.KTimes,
        "frac" => K.KFrac, "sqrt" => K.KSqrt, "exp" => K.KExp, "ln" => K.KLn, "log" => K.KLog,
        "sin" => K.KSin, "cos" => K.KCos, "tan" => K.KTan, "arcsin" => K.KAsin, "arccos" => K.KAcos,
        "arctan" => K.KAtan, "sinh" => K.KSinh, "cosh" => K.KCosh, "tanh" => K.KTanh, "min" => K.KMin,
        "max" => K.KMax, "lfloor" => K.KLfloor, "rfloor" => K.KRfloor, "lceil" => K.KLceil,
        "rceil" => K.KRceil, "partial" => K.KPdiff, "dot" => K.KDotacc, "sum" => K.KSum,
        "prod" => K.KProd, "in" => K.KInn, "substack" => K.KSubstack, "limits" => K.KLimitsL,
    )
    @test L.PUNCT == Dict{Char, K.Kw}(
        '+' => K.KPlus, '-' => K.KMinus, '=' => K.KEq, '<' => K.KLt, '>' => K.KGt, '/' => K.KSlash,
        '^' => K.KCaret, '_' => K.KUs, '(' => K.KLp, ')' => K.KRp, '{' => K.KLb, '}' => K.KRb, '[' => K.KLbk,
        ']' => K.KRbk, ',' => K.KComma, ';' => K.KSemi, ':' => K.KColon, '&' => K.KAmp, '.' => K.KSdot,
    )
    @test Ty.IDENT_KW == Dict{String, K.Kw}(
        "and" => K.KLand, "or" => K.KLor, "not" => K.KLnot, "dot" => K.KCdot, "times" => K.KTimes,
        "sqrt" => K.KSqrt, "exp" => K.KExp, "ln" => K.KLn, "log" => K.KLog, "sin" => K.KSin,
        "cos" => K.KCos, "tan" => K.KTan, "arcsin" => K.KAsin, "arccos" => K.KAcos, "arctan" => K.KAtan,
        "sinh" => K.KSinh, "cosh" => K.KCosh, "tanh" => K.KTanh, "min" => K.KMin, "max" => K.KMax,
        "abs" => K.KAbs, "floor" => K.KFloor, "ceil" => K.KCeil, "partial" => K.KPdiff, "dif" => K.KDif,
        "cases" => K.KCases, "vec" => K.KVec, "mat" => K.KMat, "sum" => K.KSum, "product" => K.KProd,
        "in" => K.KInn, "limits" => K.KLimits, "lr" => K.KLr,
    )
    @test Ty.PUNCT == Dict{Char, K.Kw}(
        '+' => K.KPlus, '-' => K.KMinus, '=' => K.KEq, '<' => K.KLt, '>' => K.KGt, '/' => K.KSlash,
        '^' => K.KCaret, '_' => K.KUs, ')' => K.KRp, '[' => K.KLbk, ']' => K.KRbk, ',' => K.KComma,
        ';' => K.KSemi, ':' => K.KColon, '&' => K.KAmp, '.' => K.KSdot, '\\' => K.KNl, '{' => K.KLset,
        '}' => K.KRset,
    )
    for (n, k) in Pr.FN_KW
        @test P.fn_of(k) == n
    end
    for (o, k) in Pr.CMP_KW
        @test P.cmp_of(k) == o
    end
    @test P.cmp_of(K.KPlus) === nothing
    for (r, k, _) in Pr.RED_TABLE
        @test P.red_of(k) === r
        @test Pr.redk_kw(r) == k
    end
    @test P.red_of(K.KPlus) === nothing
end
