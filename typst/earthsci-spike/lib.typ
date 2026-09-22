// Phase 0 spike: thin Typst wrappers over the earthsci-ast plugin.
// Build the plugin with `pkg/earthsci-typst-plugin/build.sh`, which writes
// `earthsci.wasm` next to this file.

#let _p = plugin("earthsci.wasm")

#let _call(f, ..args) = json(f(..args.pos().map(a => bytes(a))))

/// The plugin's crate version.
#let version() = str(_p.version())

/// Parse an equation in the text syntax; returns (ascii:, unicode:, latex:).
#let render(eq) = _call(_p.render_equation, eq)

/// Validate an `.esm` document given as a JSON string.
#let validate(esm) = _call(_p.validate, esm)

/// Solve an `.esm` document. Named arguments are the solve options:
/// t0, t_end, params, ic, alg, reltol, abstol, outputPoints.
#let solve(esm, ..opts) = _call(_p.solve_esm, esm, json.encode(opts.named()))

/// Minimal line plot drawn with Typst's own `curve`, for the spike only.
#let lineplot(xs, ys, width: 8cm, height: 4.5cm, stroke: 1pt + blue) = {
  let (x0, x1) = (calc.min(..xs), calc.max(..xs))
  let (y0, y1) = (calc.min(..ys), calc.max(..ys))
  let sx(x) = (x - x0) / (x1 - x0) * width
  let sy(y) = height - (y - y0) / calc.max(y1 - y0, 1e-300) * height
  box(width: width, height: height, stroke: 0.5pt + gray, place(curve(
    stroke: stroke,
    curve.move((sx(xs.first()), sy(ys.first()))),
    ..xs.zip(ys).slice(1).map(((x, y)) => curve.line((sx(x), sy(y)))),
  )))
}
