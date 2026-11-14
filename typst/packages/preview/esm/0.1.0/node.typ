// `esm.node("op", (fields), args…)` in math: the generic expression node
// (the escape form of the ESM math grammar). Imported by `lib.typ` as the
// module `esm`, so documents call it as `esm.node(…)`.

#import "values.typ": show-value

/// An operator the math notation has no surface for: the operator name upright,
/// its fields (when it has any) as a subscript, then its arguments in parentheses.
#let node(op, fields, ..args) = {
  let head = math.upright(op)
  if fields.len() > 0 {
    head = math.attach(head, br: text(0.8em, show-value(fields)))
  }
  $#head (#args.pos().join($, $))$
}
