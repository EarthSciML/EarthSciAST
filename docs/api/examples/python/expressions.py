"""Build, parse, query and rewrite expressions."""

import earthsci_ast
from earthsci_ast import ExprNode
from earthsci_ast.errors import ParseError


# region: expressions ops=expr_node,free_variables,substitute
# An expression is a number, a variable name, or an operator node.
exchange = ExprNode(op="*", args=["k", ExprNode(op="-", args=["T_wall", "T_air"])])
assert earthsci_ast.free_variables(exchange) == {"k", "T_wall", "T_air"}

# Substitution replaces names with numbers or with other expressions.
fixed = earthsci_ast.substitute(exchange, {"k": 0.05, "T_wall": ExprNode(op="+", args=["T0", 10])})
assert fixed == ExprNode(
    op="*", args=[0.05, ExprNode(op="-", args=[ExprNode(op="+", args=["T0", 10]), "T_air"])]
)
assert earthsci_ast.free_variables(fixed) == {"T0", "T_air"}
# endregion


# region: parse_math ops=parse_math,print_math
# Math reads into the JSON form of an expression, under the names it uses:
# LaTeX with "markdown", Typst math with "typst". It is the inverse of print_math.
names = ["k", "T_wall", "T_air"]
latex = r"k \left(T_{\mathrm{wall}} - T_{\mathrm{air}}\right)"
read = earthsci_ast.parse_math(latex, names, "markdown")
assert read == {"op": "*", "args": ["k", {"op": "-", "args": ["T_wall", "T_air"]}]}
assert earthsci_ast.print_math(read, names, "markdown") == latex
print(earthsci_ast.print_math(read, names, "typst"))

# Text whose top is `=` reads as an equation.
eq = earthsci_ast.parse_math("(dif x)/(dif t) = -k x", ["x", "k"], "typst")
assert eq == {
    "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
    "rhs": {"op": "-", "args": [{"op": "*", "args": ["k", "x"]}]},
}
# endregion


# region: simplify ops=simplify
messy = ExprNode(op="+", args=[ExprNode(op="*", args=["x", 1]), 0])
assert earthsci_ast.simplify(messy) == "x"

folded = earthsci_ast.simplify(ExprNode(op="*", args=[2, 3, "x"]))
assert folded == ExprNode(op="*", args=["x", 6])
# endregion


# region: evaluate ops=evaluate
line = ExprNode(op="+", args=[ExprNode(op="*", args=[2, "x"]), 1])
assert earthsci_ast.evaluate(line, {"x": 3.0}) == 7.0
# endregion


# region: parse_math_error ops=parse_math
try:
    earthsci_ast.parse_math(r"k \left(T - ", ["k", "T"], "markdown")
except ParseError as exc:
    print("parse error:", exc)
    assert exc.code == "parse_error"
else:
    raise AssertionError("an unbalanced parenthesis should not parse")
# endregion
