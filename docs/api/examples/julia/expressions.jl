# Building, parsing and rewriting expressions.
using EarthSciAST

# region: expressions ops=parse_expression,parse_equation,free_variables,substitute,simplify
# Parse from text, or build the tree directly.
expr = parse_expression("k * x + y")
built = OpExpr("+", [OpExpr("*", [VarExpr("k"), VarExpr("x")]), VarExpr("y")])
@assert to_ascii(expr) == to_ascii(built) == "k * x + y"

@assert free_variables(expr) == Set(["k", "x", "y"])

# `substitute` takes a Dict{String,ASTExpr}: give the value type explicitly.
replaced = substitute(expr, Dict{String, ASTExpr}("y" => parse_expression("2 * x")))
@assert to_ascii(replaced) == "k * x + 2 * x"
@assert free_variables(replaced) == Set(["k", "x"])

# Constant subexpressions fold away.
@assert to_ascii(simplify(parse_expression("x * (1 + 1)"))) == "x * 2"

# An equation parses the same way, with D(x, t) for a time derivative.
eq = parse_equation("D(x, t) = -k * x")
@assert eq isa Equation
@assert to_unicode(eq) == "∂x/∂t = −k·x"
# endregion

# region: canonicalize ops=canonicalize,canonical_json
# The canonical form orders commutative arguments and drops identities, so two
# spellings of the same expression compare equal.
a = canonicalize(parse_expression("b + a + 0"))
b = canonicalize(parse_expression("a + b"))
@assert to_ascii(a) == to_ascii(b) == "a + b"
@assert canonical_json(a) == canonical_json(b) == """{"args":["a","b"],"op":"+"}"""
# endregion
