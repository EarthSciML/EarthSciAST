#import "@preview/esm:0.1.0": *
#show: esm-document.with(esm: "2.3.0", authors: (
  "EarthSciML",
), name: "root")

#description[Imports the upwind\_flux template from a template library and mounts a decay model as a subsystem.]

#model("Transport")

#var($F$, units: "1/s")

#param($c$, default: 2, units: "1/s")

#subsystem("Leaf", ref: "./leaf.md")

$ F = op("upwind_flux")(c = c, u = italic("Leaf")"."x) $

#esm-block("expression_template_imports", (
  (
    ref: "./library.typ",
  ),
))
