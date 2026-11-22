---
esm: "2.3.0"
authors:
  - "EarthSciML"
name: "leaf"
---

```esm:description
First-order decay of x at rate k.
```

::model[Decay]

:param[$k$]{default=0.5 units="1/s"}

:var[$x$]{default=1 units="1"}

$$
\frac{\mathrm{d} x}{\mathrm{d} t} = -k x
$$
