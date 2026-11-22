#import "@preview/esm:0.1.0": *
#show: esm-document.with(esm: "2.3.0", authors: (
  "EarthSciML",
), name: "coupling_library")

#description[A coupling library: the state x of the role Driver sets the rate parameter k of the role Decayer.]

#esm-block("coupling", (
  (
    from: "Driver.x",
    to: "Decayer.k",
    transform: "param_to_var",
    type: "variable_map",
  ),
))

#esm-block("coupling_roles", (
  Decayer: (
    description: "the component whose rate parameter k is set",
  ),
  Driver: (
    description: "the component whose state x is read",
  ),
))
