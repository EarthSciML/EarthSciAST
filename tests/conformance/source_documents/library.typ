#import "@preview/esm:0.1.0": *
#show: esm-document.with(esm: "2.3.0", authors: (
  "EarthSciML",
), name: "library")

#description[A template library with one match-less template, the upwind flux c u.]

$ op("upwind_flux")(u, c) := c u $
