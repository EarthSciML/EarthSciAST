// Phase 1 check: the narrative core running inside Typst. The elements are
// written out by hand here; the Typst package (Phase 4) will collect them from
// `#var`, `#eq`, `#test` and `#plot` calls in the prose.
#import "../lib.typ": build

#set page(width: 16cm, height: auto, margin: 1.2cm)
#set text(size: 10pt)

#let doc = (
  version: 1,
  name: "TwoBox",
  elements: (
    (kind: "model", name: "TwoBox", description: "Exchange of a tracer between two boxes"),
    (kind: "var", name: "A", default: 1, units: "mol", description: "Tracer in box A"),
    (kind: "var", name: "B", default: 0, units: "mol", description: "Tracer in box B"),
    (kind: "param", name: "k_ab", default: 0.3, units: "1/s", description: "Rate from A to B"),
    (kind: "param", name: "k_ba", default: 0.1, units: "1/s", description: "Rate from B to A"),
    (kind: "eq", text: "D(A, t) = -k_ab*A + k_ba*B", label: "eq-a"),
    (kind: "eq", text: "D(B, t) = k_ab*A - k_ba*B", label: "eq-b"),
    (kind: "test", id: "equilibrium", time_span: (start: 0, end: 100),
     assertions: ((variable: "B", time: 100, expected: 0.75, tolerance: (rel: 1e-3)),)),
    (kind: "plot", id: "boxes", time_span: (start: 0, end: 20), y: ("A", "B"),
     description: "Tracer in each box."),
    (kind: "analysis", id: "rates", time_span: (start: 0, end: 100),
     parameter_sweep: (type: "cartesian", dimensions: (
       (parameter: "k_ab", range: (start: 0.1, stop: 1, count: 10)),
       (parameter: "k_ba", range: (start: 0.01, stop: 1, count: 5, scale: "log")),
     )),
     plots: ((id: "final_B", type: "heatmap", x: (variable: "k_ab"), y: (variable: "k_ba"),
              value: (variable: "B")),)),
  ),
)

#let out = build(doc, width: 440, height: 260)
#let el(i) = out.elements.at(i)

= Two-box exchange

The tracer in box #eval(el(1).math.typst, mode: "math") moves to box
#eval(el(2).math.typst, mode: "math") at rate #eval(el(3).math.typst, mode: "math")
and back at rate #eval(el(4).math.typst, mode: "math"):

#for i in (5, 6) { math.equation(block: true, numbering: "(1)", eval(el(i).math.typst, mode: "math")) }

#table(
  columns: 5,
  [*Name*], [*Role*], [*Default*], [*Units*], [*Description*],
  ..out.quantities.map(q => (
    eval(el(q.elements.at(0)).math.typst, mode: "math"),
    q.role, str(q.default), q.units, q.description,
  )).flatten(),
)

Test #raw(el(7).test.id): #if el(7).test.passed [passed] else [*failed*]
(B at t = 100 is #calc.round(el(7).test.assertions.at(0).actual, digits: 4)).

#figure(image(bytes(el(8).figures.at(0).svg), format: "svg", width: 100%),
  caption: [Tracer in each box.])

#figure(image(bytes(el(9).figures.at(0).svg), format: "svg", width: 100%),
  caption: [Final tracer in box B across a sweep of both rates.])

#if out.diagnostics.len() > 0 [
  *Diagnostics:* #for d in out.diagnostics [- #d.code: #d.message]
] else [No diagnostics; `ok` = #out.ok.]
