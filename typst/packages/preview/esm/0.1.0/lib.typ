// esm: typesetting for ESM model documents written in the ESM Typst source format.
//
// A document starts with
//
//   #import "@preview/esm:0.1.0": *
//   #show: esm-document.with(esm: "2.1.0", name: "Decay")
//
// and uses the functions below. Every function only typesets: what a document
// means is read from its text by the ESM readers, not computed here.

#import "values.typ": show-value, show-pairs, show-expr
#import "node.typ" as esm
// Reactions are written in typsium's `#ce[…]`, re-exported here.
#import "@preview/typsium:0.3.2": ce

#let _kind-names = (var: "variable", param: "parameter", species: "species")
#let _muted = luma(90)
#let _faint = luma(200)

// The figure kinds of the constructs a document can reference by label.
#let _template-kind = "esm-template"
#let _rule-kind = "esm-rule"
#let _reference-kind = "esm-reference"

// ---------------------------------------------------------------------------
// References

/// The citation key of a reference: its first author's surname and its year
/// (`grell2005`), or `ref<n>` when the citation shows neither. A document cites
/// a reference by this key (`@grell2005`); keys a document shares get `a`, `b`, …
#let _reference-keys(refs) = {
  let base = refs.enumerate().map(((i, r)) => {
    let c = if type(r) == dictionary { r.at("citation", default: "") } else { "" }
    if type(c) != str { c = "" }
    let surname = lower(c.split(",").first()).replace(regex("[^a-z]"), "")
    let year = c.find(regex("\b(1[5-9]|20)\d\d\b"))
    if surname == "" or year == none { "ref" + str(i + 1) } else { surname + year }
  })
  base.enumerate().map(((i, k)) => {
    if base.filter(x => x == k).len() == 1 { k }
    else { k + "abcdefghijklmnopqrstuvwxyz".at(base.slice(0, i).filter(x => x == k).len()) }
  })
}

/// The front matter's `references`, as a numbered list. Each entry is a figure
/// labelled with its key, so prose cites it as `@key`.
#let _references(refs) = {
  heading(level: 1, numbering: none, [References])
  for (r, key) in refs.zip(_reference-keys(refs)) {
    let body = if type(r) == dictionary {
      let c = r.at("citation", default: none)
      let doi = r.at("doi", default: none)
      let url = r.at("url", default: none)
      let rest = r.pairs().filter(((k, _)) => k not in ("citation", "doi", "url"))
      [#if c != none { show-value(c) }]
      if doi != none { [ #link("https://doi.org/" + doi)[doi:#doi]] }
      if url != none { [ #link(url)] }
      if rest.len() > 0 { block(text(0.9em, show-pairs(rest))) }
    } else { show-value(r) }
    [#figure(kind: _reference-kind, supplement: none, numbering: "1", body) #label(key)]
  }
}

// ---------------------------------------------------------------------------
// The document

/// Fits math that is wider than its container: it wraps where Typst can break
/// it, and when even the wrapped math is too wide (a display, or a bracket Typst
/// cannot break inside), it is scaled down, so it never runs off the page.
#let _fit(body) = layout(size => {
  if measure(body, width: size.width).width <= size.width { return body }
  let w = measure(body).width
  if w > 0pt { scale(size.width / w * 100%, reflow: true, body) } else { body }
})

/// A template or rule figure: its number in the margin column, then the
/// display and the fields, then the description as the caption.
#let _figure-layout(it) = block(width: 100%, above: 1.2em, below: 1.2em, {
  grid(
    columns: (auto, 1fr),
    column-gutter: 0.8em,
    text(0.85em, fill: _muted, [#it.supplement #it.counter.display()]),
    align(start, it.body),
  )
  if it.caption != none {
    block(inset: (left: 1.5em), above: 0.5em, text(0.92em, it.caption.body))
  }
})

/// A tag, as a small rounded label.
#let _tag(t) = box(
  inset: (x: 0.35em, y: 0.15em),
  radius: 2pt,
  fill: luma(240),
  text(0.8em, raw(show-value(t))),
)

/// The document: its front matter (the named arguments) as a title, a line of
/// facts and tags, and, after the body, its references.
#let esm-document(..front, body) = {
  let meta = front.named()
  let name = meta.at("name", default: none)
  let tags = meta.at("tags", default: ())
  let refs = meta.at("references", default: ())
  let authors = meta.at("authors", default: ())
  if type(tags) != array { tags = (tags,) }
  if type(refs) != array { refs = (refs,) }
  if type(authors) != array { authors = (authors,) }
  set document(title: name) if type(name) == str
  set document(
    author: authors.filter(a => type(a) == str),
    keywords: tags.filter(t => type(t) == str),
  )
  set page(numbering: "1", number-align: center)
  set par(justify: true)
  set heading(numbering: none)
  show heading.where(level: 1): set block(above: 1.6em, below: 0.9em)
  show heading.where(level: 2): set text(1em)
  // Display equations are numbered, so a label after one (`$ … $ <eq-loss>`)
  // can be referenced from the prose (`@eq-loss`). A wide one is scaled to fit.
  set math.equation(numbering: "(1)")
  show math.equation.where(block: true): _fit
  // Templates and rules are numbered figures, left-aligned, the description as
  // the caption; an equation inside one is numbered by the figure instead.
  show figure: set block(breakable: true)
  show figure.where(kind: _template-kind): it => _figure-layout(it)
  show figure.where(kind: _rule-kind): it => _figure-layout(it)
  show figure.where(kind: _reference-kind): it => block(
    above: 0.6em,
    grid(columns: (2.2em, 1fr), align: (start, start), [\[#it.counter.display()\]], it.body),
  )
  show ref: it => {
    let el = it.element
    if el != none and el.func() == figure and el.kind == _reference-kind {
      link(it.target)[\[#numbering("1", ..el.counter.at(it.target))\]]
    } else { it }
  }

  if name != none {
    align(center, text(1.6em, weight: "bold", show-value(name)))
  }
  let facts = meta.pairs().filter(((k, _)) => k in ("esm", "license"))
  if facts.len() > 0 {
    align(center, text(0.85em, fill: _muted, facts.map(((k, v)) => {
      if k == "esm" [ESM #show-value(v)] else [#k #show-value(v)]
    }).join[ · ]))
  }
  if authors.len() > 0 {
    align(center, authors.map(show-value).join(", "))
  }
  if tags.len() > 0 {
    align(center, block(width: 85%, tags.map(_tag).join(h(0.3em))))
  }
  let rest = meta.pairs().filter(((k, _)) => k not in ("name", "esm", "license", "tags", "references", "authors"))
  if rest.len() > 0 {
    align(center, text(0.85em, show-pairs(rest)))
  }
  v(0.5em)
  body
  if refs.len() > 0 { _references(refs) }
}

// ---------------------------------------------------------------------------
// Prose and sections

/// A component's description, set ragged-right: descriptions name files and
/// paths that cannot break, which justification would stretch lines around.
#let description(body) = block(
  width: 100%,
  inset: (left: 0.9em, y: 0.2em),
  stroke: (left: 2pt + _faint),
  { set par(justify: false); body },
)

/// The start of a model section.
#let model(name) = heading(level: 1, [#smallcaps[Model] #name])

/// The start of a reaction-system section.
#let reaction-system(name) = heading(level: 1, [#smallcaps[Reaction system] #name])

// ---------------------------------------------------------------------------
// Declarations

/// Attribute rows: `key: value`, muted keys.
#let _attr-rows(pairs) = pairs.map(((k, v)) => [#text(fill: _muted, raw(k)): #show-value(v)])

// Declarations share their column widths, so consecutive ones line up as the
// rows of one table: the name, then its kind, units and shape, then its
// description and any other attributes.
#let _decl(kind, name, attrs) = {
  let units = attrs.at("units", default: none)
  let shape = attrs.at("shape", default: none)
  let desc = attrs.at("description", default: none)
  let rest = attrs.pairs().filter(((k, _)) => k not in ("units", "shape", "description"))
  let facts = (text(fill: _muted, _kind-names.at(kind)),)
  if units != none { facts.push(raw(show-value(units))) }
  if shape != none { facts.push(raw(show-value(shape))) }
  block(
    breakable: false,
    above: 0.9em,
    grid(
      columns: (7em, 1fr),
      column-gutter: 1em,
      row-gutter: 0.45em,
      [#name], facts.join(h(0.4em) + text(fill: _faint)[|] + h(0.4em)),
      ..if desc != none { (none, text(0.95em, show-value(desc))) },
      ..if rest.len() > 0 { (none, text(0.9em, _attr-rows(rest).join(h(1em)))) },
    ),
  )
}

/// A variable declaration: the name in math, then its attributes.
#let var(name, ..attrs) = _decl("var", name, attrs.named())

/// A parameter declaration.
#let param(name, ..attrs) = _decl("param", name, attrs.named())

/// A species declaration.
#let species(name, ..attrs) = _decl("species", name, attrs.named())

// ---------------------------------------------------------------------------
// Path blocks

/// Whether a path block's value holds an expression (math, `$…$`) anywhere.
#let _has-math(v) = if type(v) == content { true } else if type(v) == dictionary {
  v.values().any(_has-math)
} else if type(v) == array { v.any(_has-math) } else { false }

/// A path block's value: a part that holds an expression as nested key and
/// item rows, the expression (math, `$…$`) as typeset math, and any part with
/// no expression as JSON.
#let _block-value(v) = {
  let rows(pairs) = grid(
    columns: (auto, 1fr),
    column-gutter: 0.6em,
    row-gutter: 0.45em,
    ..pairs.map(((k, x)) => (raw(k), _block-value(x))).flatten(),
  )
  if type(v) == content { _fit(v) }
  else if not _has-math(v) { raw(json.encode(v)) }
  else if type(v) == dictionary { rows(v.pairs().map(((k, x)) => (k + ":", x))) }
  else { rows(v.map(x => ("-", x))) }
}

/// A table with a rule above and below and one under its header, its cells
/// ragged-right (a narrow justified column stretches its words apart).
#let _table(columns, header, rows) = {
  set par(justify: false)
  table(
    columns: columns,
    stroke: none,
    inset: (x: 0.5em, y: 0.35em),
    align: start + top,
    table.hline(),
    table.header(..header.map(h => text(weight: "bold", h))),
    table.hline(stroke: 0.5pt),
    ..rows.flatten(),
    table.hline(),
  )
}

/// An entry's fields other than the named ones, as `key: value` lines.
#let _other-fields(entry, shown) = {
  let rest = entry.pairs().filter(((k, _)) => k not in shown)
  if rest.len() > 0 { text(0.9em, _attr-rows(rest).join(linebreak())) }
}

/// `index_sets`: one row per set, its size as math.
#let _index-sets(v) = _table(
  (auto, auto, auto, 1fr),
  ([Index set], [Kind], [Size], []),
  v.pairs().map(((n, s)) => if type(s) == dictionary {
    (raw(n), show-value(s.at("kind", default: "")), show-expr(s.at("size", default: [])),
      _other-fields(s, ("kind", "size")))
  } else { (raw(n), [], [], raw(show-value(s))) }),
)

/// `metaparameters`: one row per metaparameter.
#let _metaparameters(v) = _table(
  (auto, auto, auto, 1fr),
  ([Metaparameter], [Type], [Default], [Description]),
  v.pairs().map(((n, m)) => if type(m) == dictionary {
    let d = m.at("description", default: none)
    let other = _other-fields(m, ("type", "default", "description"))
    (raw(n), show-value(m.at("type", default: "")), show-expr(m.at("default", default: [])),
      [#if d != none { show-value(d) }#if other != none { linebreak() + other }])
  } else { (raw(n), [], raw(show-value(m)), []) }),
)

/// Definition and coupling imports: each `ref` with what it binds or renames.
#let _imports(v) = list(..v.map(i => if type(i) == dictionary {
  let r = i.at("ref", default: none)
  let b = i.at("bindings", default: none)
  let rest = i.pairs().filter(((k, _)) => k not in ("ref", "bindings"))
  [#if r != none { raw(show-value(r)) }#if type(b) == dictionary and b.len() > 0 {
    [ with ] + b.pairs().map(((k, x)) => show-expr(k) + $=$ + show-expr(x)).join[, ]
  }#if rest.len() > 0 { linebreak() + text(0.9em, _attr-rows(rest).join(h(1em))) }]
} else { raw(show-value(i)) }))

/// The renderers of the path blocks with a layout of their own, by the last
/// segment of their path. Every other block is shown as JSON.
#let _block-layouts = (
  index_sets: _index-sets,
  metaparameters: _metaparameters,
  operator_imports: _imports,
  expression_template_imports: _imports,
  coupling_imports: _imports,
)

/// A section title from a JSON path: its last segment, words capitalized
/// (`index_sets` → "Index sets").
#let _block-title(path) = {
  let words = path.split(".").last().split("_").filter(w => w != "")
  if words.len() == 0 { return raw(path) }
  let first = words.first()
  upper(first.first()) + first.slice(first.first().len()) + words.slice(1).map(w => " " + w).join()
}

/// A field of the document with no surface of its own, keyed by its JSON path:
/// a section headed by its name, then its value, laid out by `_block-layouts`
/// when it has a layout there, else as JSON.
#let esm-block(path, value) = {
  let layout-of = _block-layouts.at(path.split(".").last(), default: none)
  block(sticky: true, heading(level: 2, outlined: false, _block-title(path)))
  if layout-of != none and type(value) in (dictionary, array) and not _has-math(value) {
    layout-of(value)
  } else if type(value) not in (dictionary, array) {
    raw(json.encode(value))
  } else {
    block(
      width: 100%,
      inset: 0.6em,
      stroke: 0.5pt + _faint,
      radius: 2pt,
      if _has-math(value) { _block-value(value) } else {
        raw(json.encode(value), lang: "json", block: true)
      },
    )
  }
}

// ---------------------------------------------------------------------------
// Templates, rules and the other labelled entries

/// A template's or rule's fields below its display, as `key: value` rows.
#let _fields(pairs) = if pairs.len() > 0 {
  block(above: 0.5em, text(0.9em, _attr-rows(pairs).join(h(1.2em))))
}

#let _labelled(name, body, attrs) = block(
  breakable: false,
  grid(
    columns: (auto, 1fr),
    column-gutter: 1em,
    row-gutter: 0.4em,
    text(fill: _muted, name), body,
    ..attrs.pairs().map(((k, v)) => (none, [#raw(k): #show-value(v)])).flatten(),
  ),
)

/// A reaction with fields besides its equation: the `#ce[…]` line, then the fields.
#let reaction(..attrs, body) = _labelled("reaction", body, attrs.named())

/// An initialization equation.
#let initialization(body) = _labelled("initialization", body, (:))

/// A constraint equation.
#let constraints(body) = _labelled("constraint", body, (:))

/// An expression template with fields besides its definition: a numbered
/// figure (referenced as `@label` when a label follows it), the description its
/// caption.
#let template(..attrs, body) = {
  let a = attrs.named()
  let desc = a.at("description", default: none)
  figure(
    kind: _template-kind,
    supplement: [Template],
    numbering: "1",
    caption: if desc != none { show-value(desc) },
    {
      set math.equation(numbering: none)
      body
      _fields(a.pairs().filter(((k, _)) => k != "description"))
    },
  )
}

/// A rewrite rule: `lhs ⇒ rhs` under its name, then its fields, as a numbered
/// figure, the description its caption.
#let rule(name, lhs, rhs, ..attrs) = {
  let a = attrs.named()
  let desc = a.at("description", default: none)
  figure(
    kind: _rule-kind,
    supplement: [Rule],
    numbering: "1",
    caption: if desc != none { show-value(desc) },
    {
      set math.equation(numbering: none)
      text(0.9em, raw(name))
      math.equation(block: true, $#lhs arrow.r.double #rhs$)
      _fields(a.pairs().filter(((k, _)) => k != "description"))
    },
  )
}

/// A subsystem included by reference.
#let subsystem(name, ..attrs) = _labelled("subsystem", strong(name), attrs.named())

/// An analysis with one plot: its fields.
#let plot(..attrs) = _labelled("plot", none, attrs.named())
