// esm: typesetting for ESM model documents written in the ESM Typst source format.
//
// A document starts with
//
//   #import "@preview/esm:0.1.0": *
//   #show: esm-document.with(esm: "2.1.0", name: "Decay")
//
// and uses the functions below. Every function only typesets: what a document
// means is read from its text by the ESM readers, not computed here.

#import "values.typ": show-value, show-pairs
#import "node.typ" as esm
// Reactions are written in typsium's `#ce[…]`, re-exported here.
#import "@preview/typsium:0.3.2": ce

#let _kind-names = (var: "variable", param: "parameter", species: "species")

/// The document: its front matter (the named arguments) as a title and a table.
#let esm-document(..front, body) = {
  let meta = front.named()
  let name = meta.at("name", default: none)
  set document(title: name) if type(name) == str
  set heading(numbering: none)
  // Display equations are numbered, so a label after one (`$ … $ <eq-loss>`)
  // can be referenced from the prose (`@eq-loss`).
  set math.equation(numbering: "(1)")
  if name != none {
    align(center, text(1.6em, weight: "bold", show-value(name)))
  }
  let rest = meta.pairs().filter(((k, _)) => k != "name")
  if rest.len() > 0 {
    align(center, text(0.85em, show-pairs(rest)))
  }
  body
}

/// A component's description.
#let description(body) = block(inset: (left: 1em), emph(body))

/// The start of a model section.
#let model(name) = heading(level: 1, [#smallcaps[Model] #name])

/// The start of a reaction-system section.
#let reaction-system(name) = heading(level: 1, [#smallcaps[Reaction system] #name])

#let _decl(kind, name, attrs) = block(
  breakable: false,
  grid(
    columns: (auto, 1fr),
    column-gutter: 1em,
    row-gutter: 0.4em,
    [#name], text(fill: luma(90), _kind-names.at(kind)),
    ..attrs.pairs().map(((k, v)) => (none, [#raw(k): #show-value(v)])).flatten(),
  ),
)

/// A variable declaration: the name in math, then its attributes.
#let var(name, ..attrs) = _decl("var", name, attrs.named())

/// A parameter declaration.
#let param(name, ..attrs) = _decl("param", name, attrs.named())

/// A species declaration.
#let species(name, ..attrs) = _decl("species", name, attrs.named())

/// A path block's value: objects and arrays as nested key and item rows, an
/// expression (math, `$…$`) as typeset math, any other value as JSON.
#let _block-value(v) = {
  let rows(pairs) = grid(
    columns: 2,
    column-gutter: 0.6em,
    row-gutter: 0.45em,
    ..pairs.map(((k, x)) => (raw(k), _block-value(x))).flatten(),
  )
  if type(v) == content { v }
  else if type(v) == dictionary {
    if v.len() == 0 { raw("{}") } else { rows(v.pairs().map(((k, x)) => (k + ":", x))) }
  } else if type(v) == array {
    if v.len() == 0 { raw("[]") } else { rows(v.map(x => ("-", x))) }
  } else { raw(json.encode(v)) }
}

/// A field of the document with no surface of its own, keyed by its JSON path.
#let esm-block(path, value) = block(
  width: 100%,
  inset: 0.6em,
  stroke: 0.5pt + luma(180),
  radius: 2pt,
  [#text(fill: luma(90), raw(path)) \ #_block-value(value)],
)

#let _labelled(name, body, attrs) = block(
  breakable: false,
  grid(
    columns: (auto, 1fr),
    column-gutter: 1em,
    row-gutter: 0.4em,
    text(fill: luma(90), name), body,
    ..attrs.pairs().map(((k, v)) => (none, [#raw(k): #show-value(v)])).flatten(),
  ),
)

/// A reaction with fields besides its equation: the `#ce[…]` line, then the fields.
#let reaction(..attrs, body) = _labelled("reaction", body, attrs.named())

/// An initialization equation.
#let initialization(body) = _labelled("initialization", body, (:))

/// A constraint equation.
#let constraints(body) = _labelled("constraint", body, (:))

/// An expression template with fields besides its definition.
#let template(..attrs, body) = _labelled("template", body, attrs.named())

/// A rewrite rule: `lhs ⇒ rhs`, then its fields.
#let rule(name, lhs, rhs, ..attrs) = _labelled(
  [rule #raw(name)],
  $#lhs arrow.r.double #rhs$,
  attrs.named(),
)

/// A subsystem included by reference.
#let subsystem(name, ..attrs) = _labelled("subsystem", strong(name), attrs.named())

/// An analysis with one plot: its fields.
#let plot(..attrs) = _labelled("plot", none, attrs.named())
