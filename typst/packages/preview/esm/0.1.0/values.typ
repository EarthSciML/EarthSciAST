// Display of the values a document carries as named arguments (front matter,
// declaration attributes, path blocks): the ESM JSON values in Typst syntax.

/// A value as text: strings as they are, `none` as `null`, arrays and
/// dictionaries in a compact JSON-like spelling.
#let show-value(v) = {
  if type(v) == str { v }
  else if v == none { "null" }
  else if type(v) == bool { if v { "true" } else { "false" } }
  else if type(v) == int { str(v) }
  // `repr` keeps a float as it was written (`1.8e-12`); `str` spells it out
  // in full (`0.0000000000018`).
  else if type(v) == float { repr(v) }
  else if type(v) == array { "[" + v.map(show-value).join(", ") + "]" }
  else if type(v) == dictionary {
    "{" + v.pairs().map(((k, x)) => k + ": " + show-value(x)).join(", ") + "}"
  } else { repr(v) }
}

/// Named values as a two-column grid of keys and values.
#let show-pairs(pairs) = grid(
  columns: 2,
  column-gutter: 1em,
  row-gutter: 0.5em,
  ..pairs.map(((k, v)) => (text(fill: luma(90), raw(k)), show-value(v))).flatten(),
)

// Binding strength of the arithmetic operators, for parenthesizing operands.
#let _prec = ("+": 1, "-": 1, "*": 2, "/": 2, "^": 3)
// The binding strength of a piece that never needs parentheses: a name, a
// nonnegative number, a call.
#let _atom = 5

/// An ESM expression given as a JSON value (a number, a name, or an
/// `(op: …, args: …)` node), as inline math: the arithmetic operators in their
/// usual notation and any other operator in the call form. A path block holds
/// expressions this way where the format has no math leaf for them, such as an
/// index set's `size`. Content (an expression the document already gives as
/// math) is returned as it is; a value that is no expression, as text.
#let show-expr(v) = {
  if type(v) == content { return v }
  // The expression as Typst math source and how strongly it binds, as
  // `(source, strength)`, or `none` when it is not one. Each node is built
  // once; its parent parenthesizes it where it binds looser than its place.
  let src(v) = {
    if type(v) == str { return ("italic(" + repr(v) + ")", _atom) }
    if type(v) == int or type(v) == float {
      let s = show-value(v)
      // An exponent (`1e-12`) or a non-finite float would read as letters and
      // operators in math, so it is set as one upright piece of text.
      if s.contains(regex("[a-zA-Z]")) { s = repr(s) }
      // A negative number binds like a unary minus.
      return (s, if v < 0 { 1 } else { _atom })
    }
    if type(v) != dictionary or "op" not in v or type(v.op) != str { return none }
    let args = v.at("args", default: ())
    if type(args) != array { return none }
    let kids = args.map(src)
    if kids.any(x => x == none) { return none }
    // A child's source, parenthesized when it binds looser than `need`.
    let at(kid, need) = if kid.last() < need { "(" + kid.first() + ")" } else { kid.first() }
    let op = v.op
    let p = _prec.at(op, default: none)
    if op == "-" and kids.len() == 1 {
      ("-" + at(kids.first(), 3), 1)
    } else if op == "/" and kids.len() == 2 {
      // Grouped by its bar, so it needs parentheses only as a power's base.
      ("(" + kids.first().first() + ")/(" + kids.last().first() + ")", 3)
    } else if op == "^" and kids.len() == 2 {
      (at(kids.first(), 4) + "^(" + kids.last().first() + ")", 3)
    } else if p != none and kids.len() >= 2 {
      // Left-associative: the first operand may bind as loosely as the operator.
      let ops = kids.enumerate().map(((i, k)) => at(k, if i == 0 { p } else { p + 1 }))
      (ops.join(if op == "*" { " dot " } else { " " + op + " " }), p)
    } else {
      ("upright(" + repr(op) + ")(" + kids.map(k => k.first()).join(", ") + ")", _atom)
    }
  }
  let s = src(v)
  if s == none { raw(show-value(v)) } else { math.equation(eval(s.first(), mode: "math")) }
}
