# Building, reading from math and rewriting expressions.
using EarthSciAST

# region: expressions ops=parse_math,free_variables,substitute,simplify
# Read Typst math (or LaTeX, with :markdown) under the names it uses; the
# result is the expression's JSON form, which `expression_from_json` types.
names = ["k", "x", "y"]
expr = expression_from_json(parse_math("k x + y", names, :typst))
built = OpExpr("+", [OpExpr("*", [VarExpr("k"), VarExpr("x")]), VarExpr("y")])
@assert canonical_json(expr) == canonical_json(built)
# An expression shows as its Typst math.
@assert string(expr) == "k x + y"

@assert free_variables(expr) == Set(["k", "x", "y"])

# `substitute` takes a Dict{String,ASTExpr}: give the value type explicitly.
two_x = expression_from_json(parse_math("2 x", names, :typst))
replaced = substitute(expr, Dict{String, ASTExpr}("y" => two_x))
@assert string(replaced) == "k x + 2 x"
@assert free_variables(replaced) == Set(["k", "x"])

# Constant subexpressions fold away.
folded = simplify(expression_from_json(parse_math("x (1 + 1)", names, :typst)))
@assert string(folded) == "x dot 2"

# Text whose top is `=` reads as an equation, `lhs` and `rhs`.
eq = parse_math("(dif x)/(dif t) = -k x", names, :typst)
@assert string(expression_from_json(eq["rhs"])) == "-k x"
# endregion

# region: canonicalize ops=canonicalize,canonical_json
# The canonical form orders commutative arguments and drops identities, so two
# spellings of the same expression compare equal.
a = canonicalize(expression_from_json(parse_math("b + a + 0", ["a", "b"], :typst)))
b = canonicalize(expression_from_json(parse_math("a + b", ["a", "b"], :typst)))
@assert string(a) == string(b) == "a + b"
@assert canonical_json(a) == canonical_json(b) == """{"args":["a","b"],"op":"+"}"""
# endregion
