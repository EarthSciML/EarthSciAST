using Test
using EarthSciSerialization

@testset "Display Tests" begin

    @testset "Utility Functions" begin
        # Test to_superscript
        @test EarthSciSerialization.to_superscript("1") == "¹"
        @test EarthSciSerialization.to_superscript("23") == "²³"
        @test EarthSciSerialization.to_superscript("-1") == "⁻¹"
        @test EarthSciSerialization.to_superscript("+2") == "⁺²"

        # Test has_element_pattern
        @test EarthSciSerialization.has_element_pattern("H2O") == true
        @test EarthSciSerialization.has_element_pattern("CO2") == true
        @test EarthSciSerialization.has_element_pattern("NH3") == true
        @test EarthSciSerialization.has_element_pattern("xyz") == false
        @test EarthSciSerialization.has_element_pattern("temp") == false
        @test EarthSciSerialization.has_element_pattern("H") == true
        @test EarthSciSerialization.has_element_pattern("He") == true

        # Non-ASCII names must not throw StringIndexError
        @test EarthSciSerialization.has_element_pattern("α2") == false
        @test EarthSciSerialization.has_element_pattern("αH2O") == true
        @test EarthSciSerialization.has_element_pattern("θ") == false
    end

    @testset "Chemical Formula Formatting" begin
        # Test format_chemical_subscripts for unicode
        @test EarthSciSerialization.format_chemical_subscripts("H2O", :unicode) == "H₂O"
        @test EarthSciSerialization.format_chemical_subscripts("CO2", :unicode) == "CO₂"
        @test EarthSciSerialization.format_chemical_subscripts("CH4", :unicode) == "CH₄"
        @test EarthSciSerialization.format_chemical_subscripts("CaCO3", :unicode) == "CaCO₃"
        @test EarthSciSerialization.format_chemical_subscripts("temp", :unicode) == "temp"  # Non-chemical variable unchanged

        # Test format_chemical_subscripts for latex
        @test EarthSciSerialization.format_chemical_subscripts("H2O", :latex) == "\\mathrm{H_{2}O}"
        @test EarthSciSerialization.format_chemical_subscripts("CO2", :latex) == "\\mathrm{CO_{2}}"
        @test EarthSciSerialization.format_chemical_subscripts("NH3", :latex) == "\\mathrm{NH_{3}}"
        @test EarthSciSerialization.format_chemical_subscripts("temp", :latex) == "\\mathrm{temp}"  # Non-chemical multi-char var → upright

        # Test format_chemical_subscripts for ascii
        @test EarthSciSerialization.format_chemical_subscripts("H2O", :ascii) == "H2O"   # No subscripts in ASCII
        @test EarthSciSerialization.format_chemical_subscripts("CO2", :ascii) == "CO2"   # No subscripts in ASCII
        @test EarthSciSerialization.format_chemical_subscripts("NH3", :ascii) == "NH3"   # No subscripts in ASCII
        @test EarthSciSerialization.format_chemical_subscripts("temp", :ascii) == "temp" # Non-chemical variable unchanged

        # Non-ASCII names must not throw and pass through / subscript correctly
        @test EarthSciSerialization.format_chemical_subscripts("α2", :unicode) == "α2"
        @test EarthSciSerialization.format_chemical_subscripts("αH2O", :unicode) == "αH₂O"
        @test EarthSciSerialization.format_chemical_subscripts("α2", :ascii) == "α2"
    end

    @testset "Number Formatting" begin
        # Test format_number for unicode with small numbers
        @test EarthSciSerialization.format_number(3.14, :unicode) == "3.14"
        @test EarthSciSerialization.format_number(1.0, :unicode) == "1"  # Julia formats 1.0 as "1"
        @test EarthSciSerialization.format_number(-2.5, :unicode) == "-2.5"
        @test EarthSciSerialization.format_number(0, :unicode) == "0"

        # Test format_number for latex with small numbers
        @test EarthSciSerialization.format_number(3.14, :latex) == "3.14"
        @test EarthSciSerialization.format_number(1.0, :latex) == "1"  # Julia formats 1.0 as "1"
        @test EarthSciSerialization.format_number(-2.5, :latex) == "-2.5"
    end

    @testset "Operator Precedence" begin
        # Test get_operator_precedence - check actual values in the implementation
        @test EarthSciSerialization.get_operator_precedence("+") == 4
        @test EarthSciSerialization.get_operator_precedence("-") == 4
        @test EarthSciSerialization.get_operator_precedence("*") == 5
        @test EarthSciSerialization.get_operator_precedence("/") == 5
        @test EarthSciSerialization.get_operator_precedence("^") == 7
        @test EarthSciSerialization.get_operator_precedence("pow") == 8  # Based on error output
        @test EarthSciSerialization.get_operator_precedence("sin") == 8
        @test EarthSciSerialization.get_operator_precedence("unknown") == 8  # Unknown operators get default precedence
    end

    @testset "Parentheses Logic" begin
        # Create test expressions
        add_expr = OpExpr("+", EarthSciSerialization.Expr[NumExpr(1.0), VarExpr("x")])
        mul_expr = OpExpr("*", EarthSciSerialization.Expr[VarExpr("y"), VarExpr("z")])

        # Test needs_parentheses
        @test EarthSciSerialization.needs_parentheses("*", add_expr, false) == true   # (1 + x) * ...
        @test EarthSciSerialization.needs_parentheses("+", mul_expr, false) == false  # y*z + ...
        @test EarthSciSerialization.needs_parentheses("-", add_expr, true) == true    # ... - (1 + x)
        @test EarthSciSerialization.needs_parentheses("*", mul_expr, false) == false  # y*z * ...
    end

    @testset "Expression Formatting" begin
        # Test NumExpr formatting
        num_expr = NumExpr(3.14)
        @test EarthSciSerialization.format_expression_unicode(num_expr) == "3.14"
        @test EarthSciSerialization.format_expression_latex(num_expr) == "3.14"

        # Test VarExpr formatting
        var_expr = VarExpr("x")
        @test EarthSciSerialization.format_expression_unicode(var_expr) == "x"
        @test EarthSciSerialization.format_expression_latex(var_expr) == "x"

        # Test chemical VarExpr formatting
        chem_var = VarExpr("H2O")
        @test EarthSciSerialization.format_expression_unicode(chem_var) == "H₂O"
        @test EarthSciSerialization.format_expression_latex(chem_var) == "\\mathrm{H_{2}O}"

        # Test basic OpExpr formatting
        add_expr = OpExpr("+", EarthSciSerialization.Expr[NumExpr(1.0), VarExpr("x")])
        @test EarthSciSerialization.format_expression_unicode(add_expr) == "1 + x"  # Julia formats 1.0 as "1"
        @test EarthSciSerialization.format_expression_latex(add_expr) == "1 + x"  # Julia formats 1.0 as "1"
    end

    @testset "Show Methods" begin
        # Test Expr show methods
        num_expr = NumExpr(2.5)

        # Test plain text output
        io = IOBuffer()
        show(io, "text/plain", num_expr)
        @test String(take!(io)) == "2.5"

        # Test LaTeX output
        show(io, "text/latex", num_expr)
        @test String(take!(io)) == "2.5"

        # Test ASCII output
        show(io, "text/ascii", num_expr)
        @test String(take!(io)) == "2.5"

        # Test more complex expressions with ASCII MIME type
        mul_expr = OpExpr("*", EarthSciSerialization.Expr[VarExpr("x"), NumExpr(2.0)])
        show(io, "text/ascii", mul_expr)
        @test String(take!(io)) == "x * 2"

        pow_expr = OpExpr("^", EarthSciSerialization.Expr[VarExpr("x"), NumExpr(2.0)])
        show(io, "text/ascii", pow_expr)
        @test String(take!(io)) == "x^2"

        # Test chemical formula in ASCII (no subscripts)
        chem_var = VarExpr("H2O")
        show(io, "text/ascii", chem_var)
        @test String(take!(io)) == "H2O"  # Plain ASCII, no Unicode subscripts
    end

    @testset "Equation Display" begin
        # Test Equation show method
        lhs = OpExpr("D", EarthSciSerialization.Expr[VarExpr("x")], wrt="t")
        rhs = OpExpr("*", EarthSciSerialization.Expr[NumExpr(2.0), VarExpr("x")])
        eq = Equation(lhs, rhs)

        io = IOBuffer()
        show(io, eq)
        output = String(take!(io))
        # Just test that show produces some output that looks like an equation
        @test Base.contains(output, "x")
        @test Base.contains(output, "=")
        @test length(output) > 0
    end

    @testset "EsmFile Display" begin
        metadata = Metadata("test_model", description="Test model")
        esm_file = EsmFile("0.1.0", metadata)

        # 2-arg show: compact one-liner (used in reprs and collections)
        io = IOBuffer()
        show(io, esm_file)
        output = String(take!(io))
        @test Base.contains(output, "test_model")
        @test Base.contains(output, "0.1.0")
        @test !Base.contains(output, "\n")

        # 3-arg text/plain show: multi-line structured summary
        show(io, MIME("text/plain"), esm_file)
        plain = String(take!(io))
        @test Base.contains(plain, "ESM v0.1.0: test_model")
        @test Base.contains(plain, "Description: Test model")
    end

    @testset "Model and ReactionSystem Display" begin
        variables = Dict(
            "x" => ModelVariable(StateVariable, default=1.0),
            "k" => ModelVariable(ParameterVariable, default=0.5),
        )
        equations = [Equation(
            OpExpr("D", EarthSciSerialization.Expr[VarExpr("x")], wrt="t"),
            OpExpr("*", EarthSciSerialization.Expr[VarExpr("k"), VarExpr("x")]),
        )]
        model = Model(variables, equations)

        # 2-arg show: compact, single line — safe inside collections
        io = IOBuffer()
        show(io, model)
        compact = String(take!(io))
        @test compact == "Model(2 variables, 1 equations)"
        @test !Base.contains(compact, "\n")

        # 3-arg text/plain show: full multi-line listing
        show(io, MIME("text/plain"), model)
        plain = String(take!(io))
        @test Base.contains(plain, "Model:")
        @test Base.contains(plain, "Variables (2):")
        @test Base.contains(plain, "Equations (1):")

        rs = ReactionSystem(
            [Species("A"), Species("B")],
            [Reaction("r1",
                      [EarthSciSerialization.StoichiometryEntry("A", 1)],
                      [EarthSciSerialization.StoichiometryEntry("B", 1)],
                      VarExpr("k"))];
            parameters=[Parameter("k", 0.1)],
        )

        show(io, rs)
        rs_compact = String(take!(io))
        @test rs_compact == "ReactionSystem(2 species, 1 reactions)"
        @test !Base.contains(rs_compact, "\n")

        show(io, MIME("text/plain"), rs)
        rs_plain = String(take!(io))
        @test Base.contains(rs_plain, "ReactionSystem:")
        @test Base.contains(rs_plain, "Species (2):")
        @test Base.contains(rs_plain, "Reactions (1):")
    end

    @testset "min/max render as function calls for any arity" begin
        E = EarthSciSerialization.Expr
        two = OpExpr("max", E[VarExpr("a"), VarExpr("b")])
        three = OpExpr("min", E[VarExpr("a"), VarExpr("b"), VarExpr("c")])
        @test EarthSciSerialization.format_expression_unicode(two) == "max(a, b)"
        @test EarthSciSerialization.format_expression_ascii(two) == "max(a, b)"
        @test EarthSciSerialization.format_expression_latex(two) == "\\max(a, b)"
        @test EarthSciSerialization.format_expression_unicode(three) == "min(a, b, c)"
    end

    @testset "to_ascii dispatch" begin
        @test to_ascii(nothing) == "nothing"
        @test to_ascii(2.5) == "2.5"
        @test to_ascii("H2O") == "H2O"
        eq = Equation(VarExpr("y"), OpExpr("+", EarthSciSerialization.Expr[VarExpr("x"), NumExpr(1.0)]))
        @test to_ascii(eq) == "y = x + 1"
        @test_throws ArgumentError to_ascii(:a_symbol)
    end

end