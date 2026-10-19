"""Build, parse, query and rewrite expressions."""

import earthsci_ast
from earthsci_ast import Equation, ExprNode


# region: expressions ops=expr_node,parse_expression,free_variables,substitute,to_ascii
# An expression is a number, a variable name, or an operator node.
exchange = ExprNode(op="*", args=["k", ExprNode(op="-", args=["T_wall", "T_air"])])
assert earthsci_ast.free_variables(exchange) == {"k", "T_wall", "T_air"}

# Text parses to the same tree that to_ascii prints.
parsed = earthsci_ast.parse_expression("k * (T_wall - T_air)")
assert earthsci_ast.to_ascii(parsed) == earthsci_ast.to_ascii(exchange)

# Substitution replaces names with numbers or with other expressions.
fixed = earthsci_ast.substitute(exchange, {"k": 0.05, "T_wall": ExprNode(op="+", args=["T0", 10])})
assert earthsci_ast.to_ascii(fixed) == "0.05 * (T0 + 10 - T_air)"
assert earthsci_ast.free_variables(fixed) == {"T0", "T_air"}
# endregion


# region: parse_equation ops=parse_equation
eq = earthsci_ast.parse_equation("D(x, t) = -k * x")
assert isinstance(eq, Equation)
assert earthsci_ast.to_ascii(eq) == "D(x)/Dt = -k * x"
# endregion


# region: simplify ops=simplify
messy = ExprNode(op="+", args=[ExprNode(op="*", args=["x", 1]), 0])
assert earthsci_ast.simplify(messy) == "x"

folded = earthsci_ast.simplify(ExprNode(op="*", args=[2, 3, "x"]))
assert earthsci_ast.to_ascii(folded) == "x * 6"
# endregion


# region: evaluate ops=evaluate
line = ExprNode(op="+", args=[ExprNode(op="*", args=[2, "x"]), 1])
assert earthsci_ast.evaluate(line, {"x": 3.0}) == 7.0
# endregion


# region: expression_parse_error ops=expression_parse_error
try:
    earthsci_ast.parse_expression("k * (T_wall - ")
except earthsci_ast.ExpressionParseError as exc:
    print("parse error:", exc)
else:
    raise AssertionError("an unbalanced parenthesis should not parse")
# endregion
