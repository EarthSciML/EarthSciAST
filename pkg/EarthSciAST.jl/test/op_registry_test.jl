# Pinning tests for the operator registry (src/op_registry.jl) and the other
# Wave-1 shared foundations.
#
# The five per-pass op sets used to be hand-maintained literal `const` Sets;
# they now DERIVE from `_OP_TABLE`. Membership is behavior (fold/CSE/stencil/
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
        @test ESM._WS4_FOLDABLE_ELEMENTWISE_OPS == Set{String}([
            "+", "-", "*", "/", "^", "neg", "pow",
            "sqrt", "abs", "sign",
            "exp", "log", "log10",
            "sin", "cos", "tan", "asin", "acos", "atan",
            "sinh", "cosh", "tanh",
            "max", "min", "floor", "ceil",
        ])
        @test ESM._WS4_FOLDABLE_ELEMENTWISE_OPS isa Set{String}
    end

    @testset "_CSE_OPAQUE_OPS membership (pre-registry literal)" begin
        # `fn` was dropped from this set (ess-obs): a closed-function call is a
        # pure scalar function of its scalar args, so CSE may hoist it AND share
        # subexpressions beneath it. Keeping it opaque made every `interp.*` /
        # `datetime.*` call a sharing barrier, which is what let an inlined
        # observed chain under an `interp.*` lookup be re-walked per occurrence.
        # grad/div/laplacian KEEP `cse=true` (esm-spec §4.2): a rewrite-target
        # op is a NON-hoistable CSE barrier, so CSE-opacity is what routes it
        # through `_compile_op` and its `unlowered_operator` rejection gate
        # (tree_walk/compile.jl §340) instead of the guardless `_cse_rebuild`
        # generic-node path. Their `known`/`spatial`/`dim_spatial` PRIVILEGE
        # flags were dropped; this membership is rejection-routing, not privilege.
        @test ESM._CSE_OPAQUE_OPS == Set{String}([
            "const", "enum", "call", "D", "ic", "grad", "div", "laplacian",
            "arrayop", "aggregate", "makearray", "broadcast", "reshape",
            "transpose", "concat", "index",
        ])
        @test ESM._CSE_OPAQUE_OPS isa Set{String}
        @test !("fn" in ESM._CSE_OPAQUE_OPS)
    end

    @testset "_STENCIL_ELEMENTWISE_OPS membership (pre-registry literal)" begin
        @test ESM._STENCIL_ELEMENTWISE_OPS == Set{String}([
            "+", "*", "-", "neg", "/", "^", "pow",
            "<", "<=", ">", ">=", "==", "!=", "and", "or", "not", "ifelse",
            "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
            "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
            "exp", "log", "log10", "sqrt", "abs", "sign", "floor", "ceil",
            "min", "max", "pi", "π", "e", "Pre",
        ])
        @test ESM._STENCIL_ELEMENTWISE_OPS isa Set{String}
    end

    @testset "_GEO_EVAL_OPS membership (pre-registry literal)" begin
        @test ESM._GEO_EVAL_OPS == Set{String}([
            "+", "*", "-", "/", "^", "max", "min", "sqrt", "abs", "cos", "sin",
            "atan2",
            "ifelse", "floor", "ceil", ">", "<", ">=", "<=", "==", "!=",
            "index", "intersect_polygon", "polygon_intersection_area", "skolem",
            "true", "false", "aggregate", "arrayop",
        ])
        @test ESM._GEO_EVAL_OPS isa Set{String}
        # Previously a plain (non-const) global — a bug-adjacent oversight.
        @test isconst(ESM, :_GEO_EVAL_OPS)
        @test isconst(ESM, :_REDUCE_PROJECTION_KINDS)
        @test ESM._REDUCE_PROJECTION_KINDS == ("min", "max", "sum", "prod")
    end

    @testset "MTK-ext _KNOWN_OPS source (pre-registry literal)" begin
        # The extension defines `const _KNOWN_OPS = EarthSciAST._ops_with(:mtk_known)`;
        # pin the accessor output here so the pin holds without loading MTK.
        @test ESM._ops_with(:mtk_known) == Set{String}([
            "+", "-", "*", "/", "^",
            "exp", "log", "log10", "sin", "cos", "tan", "sinh", "cosh", "tanh",
            "asin", "acos", "atan", "sqrt", "abs",
            "min", "max",
            ">", "<", ">=", "<=", "==", "!=",
            "D",  # grad/div/laplacian dropped (§4.2): unregistered user-op tier
            "arrayop", "aggregate", "makearray", "index", "broadcast",
            "reshape", "transpose",
            "concat", "Pre", "ifelse", "call", "fn", "ic",
        ])
        @test ESM._ops_with(:mtk_known) isa Set{String}
    end

    @testset "grad/div/laplacian are demoted to unprivileged rewrite targets (§4.2)" begin
        # esm-spec §4.2: the spatial-calculus sugar carries NO dimensional /
        # spatial / coordinate privilege. The former `known`/`spatial`/
        # `dim_spatial` flags were dropped — dimension is UNDETERMINABLE until
        # lowered (§4.8.3/§4.8.4, units.jl has no rule), and spatial axes are
        # harvested structurally from the `dim`/`wrt` FIELDS (flatten.jl), not
        # from an op-name set. They retain ONLY `cse=true`: the non-hoistable
        # rewrite-target-barrier routing that makes the `unlowered_operator`
        # gate fire (pinned by the _CSE_OPAQUE_OPS pin above and by
        # tree_walk_test.jl) — rejection handling, not privilege.
        for op in ("grad", "div", "laplacian")
            @test !(op in ESM._ops_with(:mtk_known))   # no MTK "known" privilege
            @test op in ESM._CSE_OPAQUE_OPS            # rejection-gate routing only
        end
        # The `spatial` / `dim_spatial` registry flags were removed entirely,
        # and there is no `_SPATIAL_OPS` / `_DIM_SPATIAL_OPS` op-name set.
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
              Set{String}(["aggregate", "arrayop", "makearray"])
        @test ESM._ARRAY_PRODUCER_OPS isa Set{String}
        @test ESM._SELF_INDEXED_OPS ==
              Set{String}(["aggregate", "arrayop", "makearray", "index"])
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
        # validate.jl's reference-checker excused names, now derived from the
        # registry's `builtin_fn` flag (the :elementary rows + ifelse/Pre).
        # Mirrors Rust `is_builtin_function` (structural.rs) — a drift here is
        # a cross-binding divergence, not just a Julia one.
        @test ESM._BUILTIN_FUNCTION_NAMES == Set{String}([
            "exp", "log", "log10", "sqrt", "abs", "sign",
            "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
            "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
            "min", "max", "floor", "ceil", "ifelse", "Pre",
        ])
        @test ESM._BUILTIN_FUNCTION_NAMES isa Set{String}
    end

    @testset "units.jl dimensional-rule op classes (pre-registry literals)" begin
        # The five op-class sets `_DIMENSION_RULES` is populated from, now
        # derived from the registry's `dim_class` column. `_TRANSCENDENTAL_OPS`
        # additionally unions the spec-adjacent spellings ln/log2/expm1, which
        # deliberately have NO registry row (`_op_in_T` classifies unregistered
        # ops as open-namespace rewrite targets — a row would change that).
        @test ESM._TRANSCENDENTAL_OPS == Set{String}([
            "exp", "log", "ln", "log10", "log2", "expm1",
            "tanh", "sinh", "cosh", "asinh", "acosh", "atanh",
        ])
        # `sqrt` must never be transcendental: it halves its argument's
        # dimension (`_sqrt_rule`) rather than requiring a dimensionless one.
        @test !("sqrt" in ESM._TRANSCENDENTAL_OPS)
        @test ESM._CIRCULAR_OPS == Set{String}(["sin", "cos", "tan"])
        @test ESM._INVERSE_CIRCULAR_OPS ==
              Set{String}(["asin", "acos", "atan", "atan2"])
        @test ESM._COMPARISON_OPS ==
              Set{String}(["<", ">", "<=", ">=", "==", "!="])
        @test ESM._BOOLEAN_OPS == Set{String}(["and", "or", "not"])
        for s in (ESM._TRANSCENDENTAL_OPS, ESM._CIRCULAR_OPS,
                  ESM._INVERSE_CIRCULAR_OPS, ESM._COMPARISON_OPS,
                  ESM._BOOLEAN_OPS)
            @test s isa Set{String}
        end
        # The spellings with no registry row stay OUT of the registry (their
        # rows would silently reclassify them for template lowering).
        for name in ("ln", "log2", "expm1")
            @test ESM._op_spec(name) === nothing
        end
        @test_throws ArgumentError ESM._ops_with_dim_class(:not_a_class)
    end

    @testset "display precedence / separator lookups (pre-registry literals)" begin
        # Display output is contract-pinned (RENDERING_CONTRACT + the display
        # goldens), so these two lookups are pinned literal-for-literal. Both
        # derive from the registry (`display_prec` / `infix_sep`) plus the
        # derivation-site wire alias "=" ↦ the "==" row's values ("=" has no
        # registry row for the same `_op_in_T` reason as above).
        @test ESM._DISPLAY_OP_PRECEDENCE == Dict{String,Int}(
            "or" => 1,
            "and" => 2,
            "==" => 3, "=" => 3, "!=" => 3,
            "<" => 3, ">" => 3, "<=" => 3, ">=" => 3,
            "+" => 4, "-" => 4,
            "*" => 5, "/" => 5,
            "not" => 6,
            "^" => 7,
        )
        @test ESM._INFIX_SEPARATORS == Dict(
            "-"   => (ascii = " - ",   unicode = " − ", latex = " - "),
            "*"   => (ascii = " * ",   unicode = "·",   latex = " \\cdot "),
            ">="  => (ascii = " >= ",  unicode = " ≥ ", latex = " \\geq "),
            "<="  => (ascii = " <= ",  unicode = " ≤ ", latex = " \\leq "),
            "=="  => (ascii = " == ",  unicode = " = ", latex = " = "),
            "="   => (ascii = " == ",  unicode = " = ", latex = " = "),
            "!="  => (ascii = " != ",  unicode = " ≠ ", latex = " \\neq "),
            "and" => (ascii = " and ", unicode = " ∧ ", latex = " \\land "),
            "or"  => (ascii = " or ",  unicode = " ∨ ", latex = " \\lor "),
        )
        @test ESM._op_spec("=") === nothing
        # Anything without an explicit infix precedence binds atom-tight.
        @test ESM._DISPLAY_FUNCTION_PRECEDENCE == 8
        @test ESM.get_operator_precedence("sin") == 8
        @test ESM.is_function_call_op("sin")
        @test !ESM.is_function_call_op("=")
    end

    @testset "_UNARY_ELEMENTWISE_OPS: the mechanical unary ladder arms, in order" begin
        # Exactly the ops with a repetitive one-liner arm in `_eval_node_op` /
        # `_eval_vec_op`, in arm order. `atan` (1-or-2-ary), `neg`, and `not`
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

@testset "canonical emissible-field partition pins" begin
    # The former hand-maintained literal: forgetting a future OpExpr field
    # here would have silently DROPPED it from canonical JSON. The tuple is
    # now derived (fail-closed) from _EMISSIBLE_FIELDS/_CANONICAL_IGNORED_FIELDS;
    # this pins that the derivation reproduces the old literal exactly
    # (membership AND order — order feeds the E_CANONICAL_UNSUPPORTED_FIELD
    # message text).
    @test ESM._NON_EMISSIBLE_FIELDS == (
        :int_var, :lower, :upper, :output_idx, :expr_body, :reduce, :semiring,
        :ranges, :regions, :values, :shape, :perm, :axis,
        :table, :table_axes, :output,
        :join, :filter, :join_gates,
        :id, :manifold, :distinct, :key, :label,
    )
    @test ESM._EMISSIBLE_FIELDS == (:op, :args, :wrt, :dim, :fn, :name, :value)
    # `arg`/`bindings` were historically tolerated-and-ignored (absent from the
    # non-emissible literal): a node carrying them still canonicalizes.
    @test ESM._CANONICAL_IGNORED_FIELDS == (:arg, :bindings)
    # Fail-closed: the three tuples exactly partition fieldnames(OpExpr).
    @test sort(collect((ESM._EMISSIBLE_FIELDS..., ESM._CANONICAL_IGNORED_FIELDS...,
                        ESM._NON_EMISSIBLE_FIELDS...))) ==
          sort(collect(fieldnames(OpExpr)))
    # Behavior spot-checks on the emitter itself (bypassing `canonicalize`'s
    # rewrites): ignored fields emit fine, non-emissible ones throw.
    @test ESM._emit_node_json(OpExpr("+", EarthSciAST.ASTExpr[VarExpr("a"),
                                                           VarExpr("b")];
                                     arg="i")) ==
          ESM._emit_node_json(OpExpr("+", EarthSciAST.ASTExpr[VarExpr("a"),
                                                           VarExpr("b")]))
    @test_throws CanonicalizeError ESM._emit_node_json(
        OpExpr("+", EarthSciAST.ASTExpr[VarExpr("a")]; shape=Any[2]))
end

@testset "Wave-1 foundation smoke checks" begin

    @testset "foreach_subexpr visits every child_exprs descendant" begin
        # An aggregate whose variables hide in expr_body / filter — the fields
        # a hand-rolled args-only walk misses.
        body = OpExpr("*", EarthSciAST.ASTExpr[VarExpr("w"), VarExpr("u")])
        agg = OpExpr("aggregate", EarthSciAST.ASTExpr[];
                     output_idx=Any["i"],
                     ranges=Dict{String,Any}("i" => [1, 4]),
                     expr_body=body,
                     filter=OpExpr(">", EarthSciAST.ASTExpr[VarExpr("w"),
                                                         NumExpr(0.0)]))
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
        @test out isa AbstractDict{String,Any}
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
