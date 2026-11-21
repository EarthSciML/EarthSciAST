---
esm: "2.3.0"
authors:
  - "EarthSciML"
name: "root"
---

```esm:description
Imports the upwind_flux template from a template library and mounts a decay model as a subsystem.
```

::model[Transport]

:var[$F$]{units="1/s"}

:param[$c$]{default=2 units="1/s"}

::subsystem[Leaf]{ref="./leaf.typ"}

$$
F = \operatorname{upwind\_flux}(c = c, u = \mathit{Leaf}.x)
$$

```esm:expression_template_imports
- ref: "./library.md"
```
