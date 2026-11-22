#import "@preview/esm:0.1.0": *
#show: esm-document.with(esm: "2.3.0", authors: (
  "EarthSciML",
), name: "removed_op")

#description[A model whose equation calls fn, an operator removed at esm 2.0.0: the Typst reader refuses it with removed_op.]

#model("Leaf")

#param($k$, default: 0.5, units: "1")

#var($x$, default: 1, units: "1")

$ (dif x)/(dif t) = op("fn")(k) $
