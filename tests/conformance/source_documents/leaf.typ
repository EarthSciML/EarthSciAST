#import "@preview/esm:0.1.0": *
#show: esm-document.with(esm: "2.3.0", authors: (
  "EarthSciML",
), name: "leaf")

#description[First-order decay of x at rate k.]

#model("Decay")

#param($k$, default: 0.5, units: "1/s")

#var($x$, default: 1, units: "1")

$ (dif x)/(dif t) = -k x $
