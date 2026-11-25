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

/// An ESM expression given as a JSON value (a number, a name, or an
/// `(op: …, args: …)` node), as inline math: the arithmetic operators in their
/// usual notation and any other operator in the call form. A path block holds
/// expressions this way where the format has no math leaf for them, such as an
/// index set's `size`. Content (an expression the document already gives as
/// math) is returned as it is; a value that is no expression, as text.
#let show-expr(v) = {
  if type(v) == content { return v }
  // The expression as Typst math source, `none` when it is not one.
  let src(v, outer) = {
    if type(v) == str { return "italic(" + repr(v) + ")" }
    if type(v) == int or type(v) == float { return show-value(v) }
    if type(v) != dictionary or "op" not in v or type(v.op) != str { return none }
    let args = v.at("args", default: ())
    if type(args) != array { return none }
    let op = v.op
    let p = _prec.at(op, default: none)
    let parts(level) = args.map(a => src(a, level))
    if parts(0).any(x => x == none) { return none }
    let body = if op == "-" and args.len() == 1 {
      "-" + src(args.first(), 3)
    } else if op == "/" and args.len() == 2 {
      "(" + src(args.first(), 0) + ")/(" + src(args.last(), 0) + ")"
    } else if op == "^" and args.len() == 2 {
      src(args.first(), 4) + "^(" + src(args.last(), 0) + ")"
    } else if p != none and args.len() >= 2 {
      parts(p + 1).join(if op == "*" { " dot " } else { " " + op + " " })
    } else {
      "upright(" + repr(op) + ")(" + parts(0).join(", ") + ")"
    }
    // A fraction is grouped by its bar; anything else binding looser than
    // its place is parenthesized.
    if p != none and op != "/" and p < outer { "(" + body + ")" } else { body }
  }
  let s = src(v, 0)
  if s == none { raw(show-value(v)) } else { math.equation(eval(s, mode: "math")) }
}
