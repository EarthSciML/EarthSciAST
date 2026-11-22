---
esm: "2.3.0"
authors:
  - "EarthSciML"
name: "removed_op"
---

```esm:description
A model whose equation calls fn, an operator removed at esm 2.0.0: the Markdown reader refuses it with removed_op.
```

::model[Leaf]

:param[$k$]{default=0.5 units="1"}

:var[$x$]{default=1 units="1"}

$$
\frac{\mathrm{d}x}{\mathrm{d}t} = \operatorname{fn}(k)
$$
