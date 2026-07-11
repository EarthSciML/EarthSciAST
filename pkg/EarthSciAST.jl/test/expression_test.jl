using Test
using EarthSciAST
using JSON3

@testset "EarthSciAST.Expression Operations" begin

    @testset "substitute function" begin
        # Unit-level behaviors not expressible as fixture cases:
        # object-identity preservation, wrt/dim passthrough.
        num = NumExpr(3.14)
        bindings = Dict{String,EarthSciAST.ASTExpr}("x" => NumExpr(2.0))
        @test substitute(num, bindings) === num

        var_x = VarExpr("x")
        @test substitute(var_x, bindings) === bindings["x"]

        var_y = VarExpr("y")
        @test substitute(var_y, bindings) === var_y

        diff_expr = OpExpr("D", EarthSciAST.ASTExpr[var_x], wrt="t", dim="time")
        result = substitute(diff_expr, bindings)
        @test result.wrt == "t"
        @test result.dim == "time"
    end

    @testset "substitute fixtures" begin
        # Fixture-driven cases shared with Rust (pkg/earthsci-ast-rs/tests/substitution.rs)
        # and Python (pkg/earthsci-ast-py/tests/test_substitute.py). A new fixture case
        # lights up all three bindings at once.
        fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "substitution")
        fixture_files = ["simple_var_replace.json", "nested_substitution.json", "scoped_reference.json"]

        for filename in fixture_files
            filepath = joinpath(fixtures_dir, filename)
            @testset "$filename" begin
                @test isfile(filepath)
                cases = JSON3.read(read(filepath, String))
                @test cases isa JSON3.Array
                @test !isempty(cases)

                for (i, case) in enumerate(cases)
                    label = haskey(case, :description) ? String(case[:description]) : "case $i"
                    @testset "$label" begin
                        input_expr = EarthSciAST.parse_expression(case[:input])
                        bindings = Dict{String,EarthSciAST.ASTExpr}(
                            string(k) => EarthSciAST.parse_expression(v)
                            for (k, v) in pairs(case[:bindings])
                        )
                        expected = EarthSciAST.parse_expression(case[:expected])
                        result = substitute(input_expr, bindings)
                        # ASTExpr structs have no `==` method, so compare via the
                        # canonical JSON-serialized form.
                        @test EarthSciAST.serialize_expression(result) ==
                              EarthSciAST.serialize_expression(expected)
                    end
                end
            end
        end
    end

    @testset "free_variables function" begin
        # Test NumExpr (no variables)
        num = NumExpr(3.14)
        @test free_variables(num) == Set{String}()

        # Test VarExpr (single variable)
        var_x = VarExpr("x")
        @test free_variables(var_x) == Set(["x"])

        # Test OpExpr with multiple variables
        sum_expr = OpExpr("+", EarthSciAST.ASTExpr[VarExpr("x"), VarExpr("y")])
        @test free_variables(sum_expr) == Set(["x", "y"])

        # Test nested expressions
        nested = OpExpr("*", EarthSciAST.ASTExpr[OpExpr("+", EarthSciAST.ASTExpr[VarExpr("x"), NumExpr(1.0)]), VarExpr("y")])
        @test free_variables(nested) == Set(["x", "y"])

        # Test OpExpr with wrt field
        diff_expr = OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t")
        @test free_variables(diff_expr) == Set(["x", "t"])

        # Test expression with repeated variables
        repeated = OpExpr("+", EarthSciAST.ASTExpr[VarExpr("x"), VarExpr("x"), VarExpr("y")])
        @test free_variables(repeated) == Set(["x", "y"])
    end

    @testset "contains function" begin
        # Test NumExpr (contains no variables)
        num = NumExpr(3.14)
        @test !EarthSciAST.contains(num, "x")

        # Test VarExpr
        var_x = VarExpr("x")
        @test EarthSciAST.contains(var_x, "x")
        @test !EarthSciAST.contains(var_x, "y")

        # Test OpExpr
        sum_expr = OpExpr("+", EarthSciAST.ASTExpr[VarExpr("x"), VarExpr("y")])
        @test EarthSciAST.contains(sum_expr, "x")
        @test EarthSciAST.contains(sum_expr, "y")
        @test !EarthSciAST.contains(sum_expr, "z")

        # Test nested expressions
        nested = OpExpr("*", EarthSciAST.ASTExpr[OpExpr("+", EarthSciAST.ASTExpr[VarExpr("x"), NumExpr(1.0)]), VarExpr("y")])
        @test EarthSciAST.contains(nested, "x")
        @test EarthSciAST.contains(nested, "y")
        @test !EarthSciAST.contains(nested, "z")

        # Test OpExpr with wrt field
        diff_expr = OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t")
        @test EarthSciAST.contains(diff_expr, "x")
        @test EarthSciAST.contains(diff_expr, "t")
        @test !EarthSciAST.contains(diff_expr, "y")
    end

    # Numerical evaluation lives in `tree_walk.jl` (the official ESS Julia
    # runner). Op-by-op evaluator coverage is in `tree_walk_test.jl`; this
    # file only exercises the structural operations that remain in
    # `expression.jl` (substitute / free_variables / contains / simplify).

    @testset "simplify function" begin
        # Test NumExpr and VarExpr (already simplified)
        num = NumExpr(3.14)
        @test simplify(num) === num
        var = VarExpr("x")
        @test simplify(var) === var

        # Test constant folding
        @test simplify(OpExpr("+", EarthSciAST.ASTExpr[NumExpr(2.0), NumExpr(3.0)])) == NumExpr(5.0)
        @test simplify(OpExpr("*", EarthSciAST.ASTExpr[NumExpr(2.0), NumExpr(3.0)])) == NumExpr(6.0)

        # Test additive identity: x + 0 = x
        var_x = VarExpr("x")
        @test simplify(OpExpr("+", EarthSciAST.ASTExpr[var_x, NumExpr(0.0)])) === var_x
        @test simplify(OpExpr("+", EarthSciAST.ASTExpr[NumExpr(0.0), var_x])) === var_x

        # Test additive identity with all zeros
        @test simplify(OpExpr("+", EarthSciAST.ASTExpr[NumExpr(0.0), NumExpr(0.0)])) == NumExpr(0.0)

        # Test multiplicative identity: x * 1 = x
        @test simplify(OpExpr("*", EarthSciAST.ASTExpr[var_x, NumExpr(1.0)])) === var_x
        @test simplify(OpExpr("*", EarthSciAST.ASTExpr[NumExpr(1.0), var_x])) === var_x

        # Test multiplicative zero: x * 0 = 0
        @test simplify(OpExpr("*", EarthSciAST.ASTExpr[var_x, NumExpr(0.0)])) == NumExpr(0.0)
        @test simplify(OpExpr("*", EarthSciAST.ASTExpr[NumExpr(0.0), var_x])) == NumExpr(0.0)

        # Test multiplicative identity with all ones
        @test simplify(OpExpr("*", EarthSciAST.ASTExpr[NumExpr(1.0), NumExpr(1.0)])) == NumExpr(1.0)

        # Test exponentiation rules
        @test simplify(OpExpr("^", EarthSciAST.ASTExpr[var_x, NumExpr(0.0)])) == NumExpr(1.0)
        @test simplify(OpExpr("^", EarthSciAST.ASTExpr[var_x, NumExpr(1.0)])) === var_x
        @test simplify(OpExpr("^", EarthSciAST.ASTExpr[NumExpr(0.0), NumExpr(2.0)])) == NumExpr(0.0)
        @test simplify(OpExpr("^", EarthSciAST.ASTExpr[NumExpr(1.0), var_x])) == NumExpr(1.0)

        # Test subtraction: x - 0 = x
        @test simplify(OpExpr("-", EarthSciAST.ASTExpr[var_x, NumExpr(0.0)])) === var_x

        # Test division: x / 1 = x, 0 / x = 0
        @test simplify(OpExpr("/", EarthSciAST.ASTExpr[var_x, NumExpr(1.0)])) === var_x
        @test simplify(OpExpr("/", EarthSciAST.ASTExpr[NumExpr(0.0), var_x])) == NumExpr(0.0)

        # Test recursive simplification
        nested = OpExpr("*", EarthSciAST.ASTExpr[OpExpr("+", EarthSciAST.ASTExpr[NumExpr(1.0), NumExpr(2.0)]), var_x])
        simplified = simplify(nested)
        @test simplified isa OpExpr
        @test simplified.op == "*"
        @test simplified.args[1] == NumExpr(3.0)
        @test simplified.args[2] === var_x

        # Test n-ary operations
        n_ary_add = OpExpr("+", EarthSciAST.ASTExpr[var_x, NumExpr(0.0), VarExpr("y"), NumExpr(0.0)])
        simplified = simplify(n_ary_add)
        @test simplified isa OpExpr
        @test simplified.op == "+"
        @test length(simplified.args) == 2
        @test var_x in simplified.args
        @test VarExpr("y") in simplified.args
    end

    @testset "substitute edge cases" begin
        # Substitution semantics (see CONFORMANCE_SPEC.md §2.2.3):
        # - single-pass (non-transitive): bindings are not re-applied to their
        #   own replacements, so circular/self-referential bindings terminate
        # - recursive over AST structure: arbitrary nesting is supported up to
        #   native stack limits
        # - OpExpr nodes with empty args are valid inputs and preserved
        # - null/missing inputs have no Julia equivalent: ASTExpr is a typed union

        # --- Circular references: single-pass, no cycle detection needed ---
        # Mirrors Python test_substitute_circular_reference_detection
        # (test_substitute.py:295). With bindings {x => y, y => x}, substituting
        # `x` yields `y` — the replacement `y` is NOT re-resolved.
        var_x = VarExpr("x")
        var_y = VarExpr("y")
        circular_bindings = Dict{String,EarthSciAST.ASTExpr}(
            "x" => var_y,
            "y" => var_x,
        )
        @test substitute(var_x, circular_bindings) === var_y
        @test substitute(var_y, circular_bindings) === var_x

        # Self-referential binding {x => x} must terminate with x unchanged.
        self_bindings = Dict{String,EarthSciAST.ASTExpr}("x" => var_x)
        @test substitute(var_x, self_bindings) === var_x

        # Mutual reference within a compound expression: each var rewritten once.
        sum_xy = OpExpr("+", EarthSciAST.ASTExpr[var_x, var_y])
        result = substitute(sum_xy, circular_bindings)
        @test result isa OpExpr
        @test result.args[1] === var_y
        @test result.args[2] === var_x

        # Self-reference inside a nested replacement: inner x NOT re-substituted.
        inner_x_plus_one = OpExpr("+", EarthSciAST.ASTExpr[var_x, NumExpr(1.0)])
        nested_self = Dict{String,EarthSciAST.ASTExpr}("x" => inner_x_plus_one)
        nested_result = substitute(var_x, nested_self)
        @test nested_result isa OpExpr
        @test nested_result.op == "+"
        @test nested_result.args[1] === var_x  # NOT recursed into
        @test nested_result.args[2] == NumExpr(1.0)

        # --- Deep nesting: recursive, bounded only by Julia's stack ---
        # Mirrors Python test_substitute_deep_nesting (test_substitute.py:310);
        # Python uses depth 5, we use a stronger bound.
        depth = 200
        deep_expr = var_x
        for i in 0:(depth - 1)
            deep_expr = OpExpr("+", EarthSciAST.ASTExpr[deep_expr, VarExpr("v$i")])
        end
        deep_bindings = Dict{String,EarthSciAST.ASTExpr}("x" => NumExpr(1.0))
        deep_result = substitute(deep_expr, deep_bindings)

        # Walk the left spine down to the innermost x; it should be replaced.
        cursor = deep_result
        for _ in 1:depth
            @test cursor isa OpExpr
            @test cursor.op == "+"
            @test length(cursor.args) == 2
            cursor = cursor.args[1]
        end
        @test cursor == NumExpr(1.0)

        # --- Empty OpExpr args: structurally valid, preserved ---
        # Closest analogue to Python's {"op": "+"} (missing args) — an OpExpr
        # with empty args is valid and substitution returns an equivalent node.
        empty_op = OpExpr("+", EarthSciAST.ASTExpr[])
        any_bindings = Dict{String,EarthSciAST.ASTExpr}("x" => NumExpr(42.0))
        empty_result = substitute(empty_op, any_bindings)
        @test empty_result isa OpExpr
        @test empty_result.op == "+"
        @test isempty(empty_result.args)

        # --- Empty bindings: identity on compound expressions ---
        compound = OpExpr(
            "*",
            EarthSciAST.ASTExpr[
                var_x,
                OpExpr("+", EarthSciAST.ASTExpr[var_y, NumExpr(1.0)]),
            ];
            wrt="t",
            dim="time",
        )
        empty_bindings = Dict{String,EarthSciAST.ASTExpr}()
        id_result = substitute(compound, empty_bindings)
        @test id_result isa OpExpr
        @test id_result.op == "*"
        @test id_result.wrt == "t"
        @test id_result.dim == "time"
        @test id_result.args[1] === var_x

        # --- Metadata preservation through substitution ---
        d_expr = OpExpr("D", EarthSciAST.ASTExpr[var_x]; wrt="t", dim="time")
        num_bindings = Dict{String,EarthSciAST.ASTExpr}("x" => NumExpr(3.14))
        d_result = substitute(d_expr, num_bindings)
        @test d_result.op == "D"
        @test d_result.wrt == "t"
        @test d_result.dim == "time"
        @test d_result.args[1] == NumExpr(3.14)
    end

    @testset "Integration tests" begin
        # Test substitute + simplify
        expr = OpExpr("*", EarthSciAST.ASTExpr[OpExpr("+", EarthSciAST.ASTExpr[VarExpr("x"), NumExpr(0.0)]), VarExpr("y")])
        bindings = Dict{String,EarthSciAST.ASTExpr}("y" => NumExpr(1.0))
        substituted = substitute(expr, bindings)
        simplified = simplify(substituted)
        @test simplified === VarExpr("x")

        # Free-variable analysis composes with the official tree-walk
        # evaluator: every free variable must be in `bindings` for
        # `evaluate_expr` to succeed.
        expr = OpExpr("+", EarthSciAST.ASTExpr[OpExpr("*", EarthSciAST.ASTExpr[VarExpr("x"), VarExpr("y")]), NumExpr(1.0)])
        vars = free_variables(expr)
        @test vars == Set(["x", "y"])

        eval_bindings = Dict("x" => 2.0, "y" => 3.0)
        @test EarthSciAST.evaluate_expr(expr, eval_bindings) == 7.0

        partial_bindings = Dict("x" => 2.0)  # missing "y"
        @test_throws UnboundVariableError EarthSciAST.evaluate_expr(expr, partial_bindings)
    end

    @testset "shared traversal covers nested aggregate fields (child_exprs)" begin
        E = EarthSciAST
        # aggregate whose body/filter/bounds/table-axes/key carry variables
        # invisible to an args-only traversal.
        agg = OpExpr("aggregate", E.ASTExpr[];
            output_idx=Any["i"],
            ranges=Dict{String,Any}(
                "i" => E.IndexSetRef("cells"),
                "j" => Any[IntExpr(1), VarExpr("n_upper")]),
            expr_body=OpExpr("*", E.ASTExpr[
                OpExpr("index", E.ASTExpr[VarExpr("A"), VarExpr("i")]),
                VarExpr("w")]),
            filter=OpExpr(">", E.ASTExpr[VarExpr("thresh"), NumExpr(0.0)]),
            key=VarExpr("keyvar"))
        outer = OpExpr("+", E.ASTExpr[VarExpr("base"), agg])

        @testset "free_variables sees nested bodies, subtracts binders" begin
            fv = free_variables(outer)
            @test "A" in fv && "w" in fv && "thresh" in fv
            @test "base" in fv
            @test "n_upper" in fv          # expression-valued dense range bound
            @test "keyvar" in fv           # value-invention key expression
            @test !("i" in fv)             # loop index bound by the aggregate
            @test !("j" in fv)
        end

        @testset "contains sees nested bodies" begin
            @test EarthSciAST.contains(outer, "A")
            @test EarthSciAST.contains(outer, "w")
            @test EarthSciAST.contains(outer, "thresh")
            @test EarthSciAST.contains(outer, "n_upper")
            @test EarthSciAST.contains(outer, "keyvar")
            @test !EarthSciAST.contains(outer, "zzz")
            # containment (not free-ness): binder symbols still "appear".
            @test EarthSciAST.contains(outer, "i")
            # contains is now Base.contains — no shadowing function.
            @test EarthSciAST.contains === Base.contains
            @test Base.contains(agg, "A")
        end

        @testset "substitute rewrites key and range-bound expressions" begin
            bindings = Dict{String,E.ASTExpr}(
                "w" => NumExpr(2.0), "n_upper" => IntExpr(10),
                "keyvar" => VarExpr("keyvar2"))
            r = substitute(agg, bindings)
            @test r.expr_body.args[2] == NumExpr(2.0)
            @test r.ranges["j"][2] == IntExpr(10)
            @test r.key == VarExpr("keyvar2")
            # untouched fields preserved (reconstruct-backed rewrite)
            @test r.output_idx == Any["i"]
            @test r.ranges["i"] isa E.IndexSetRef
        end

        @testset "integral int_var is a binder for free_variables" begin
            integ = OpExpr("integrate", E.ASTExpr[];
                int_var="s",
                lower=NumExpr(0.0), upper=VarExpr("T"),
                expr_body=OpExpr("*", E.ASTExpr[VarExpr("s"), VarExpr("k")]))
            fv = free_variables(integ)
            @test fv == Set(["T", "k"])
            @test EarthSciAST.contains(integ, "s")  # containment still true
        end

        @testset "table_lookup axis inputs traversed" begin
            tl = OpExpr("table_lookup", E.ASTExpr[]; table="fuel",
                table_axes=Dict{String,E.ASTExpr}(
                    "code" => OpExpr("+", E.ASTExpr[VarExpr("fm"), IntExpr(1)])))
            @test free_variables(tl) == Set(["fm"])
            @test EarthSciAST.contains(tl, "fm")
        end
    end

    @testset "UnboundVariableError uses showerror" begin
        err = UnboundVariableError("x", "variable 'x' is unbound")
        @test sprint(showerror, err) == "UnboundVariableError: variable 'x' is unbound"
    end
end