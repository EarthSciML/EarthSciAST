"""
An equation as math: `lhs = rhs` is the math of the expression
`==(lhs, rhs)`.

Port of `formal/Esm/Document/Source/Equation.lean` (Rust
`document::source::equation`).
"""
module SEquation

using ..DJson

"""`Source.eqExpr`: the expression an equation is printed as."""
eq_expr(e) = JObj(Kvs(["args" => JArr(Any[e.lhs, e.rhs]), "op" => "=="]))

"""`Source.eqSides`: the equation sides of a parsed `==` node, or `nothing`."""
function eq_sides(j)
    j isa JObj || return nothing
    kvs = j.kvs
    length(kvs) == 2 || return nothing
    (a, xs), (o, op) = kvs[1], kvs[2]
    (a == "args" && o == "op" && op == "==" && xs isa JArr) || return nothing
    length(xs.xs) == 2 || return nothing
    return xs.xs[1], xs.xs[2]
end

end # module SEquation
