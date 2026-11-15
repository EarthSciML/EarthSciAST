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
