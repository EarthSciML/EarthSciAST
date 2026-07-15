# Pretty-print rendering contract

Authoritative specification for how every AST `op` renders in the three text
formats (`unicode`, `latex`, `ascii`). All language implementations
(`pretty-print.ts`, `display.py`, `display.rs`, `display.go`, `display.jl`)
MUST produce byte-identical output, verified by the shared fixtures in this
directory via `./scripts/test-conformance.sh`.

## Guiding principle

Special (non-`op(args)`) rendering is reserved for the **closed evaluable-core
set** (esm-spec §4.2) plus `integral`. Open-tier rewrite-target sugar
(`grad`, `div`, `laplacian`) and any unknown user op render with the **generic
fallback**. Ops that are not in the format at all (`binomial`, `gamma`, `erf`,
`erfc`) get NO special rendering and are not represented in any fixture.

## Generic fallback

Applies to `grad`, `div`, `laplacian`, and any op with no dedicated rendering.
Only `args` are shown; non-`args` fields (e.g. `grad`'s `dim`) are NOT rendered.

| Format  | Form |
|---------|------|
| ascii   | `name(a1, a2, …)` |
| unicode | `name(a1, a2, …)` |
| latex   | `\mathrm{ESC(name)}(a1, a2, …)` |

`ESC` escapes LaTeX-special chars in the op name: `_` → `\_`. Args render
recursively; a function-call argument is parenthesized only when it is a
logical-`or` (loosest precedence), matching existing behavior.

Examples: `grad(phi)`, `div(v)`, `laplacian(u)`; latex `\mathrm{grad}(phi)`.

## Per-op rendering

Args are written `a0, a1, …`; a sub-expression that is an operator node is
parenthesized where a leaf would not be (existing `needsParentheses` rule),
except where noted. Map/keyed fields (`axes`, `bindings`, `ranges`) are
emitted in **sorted key order** for determinism.

### Leaves and already-correct ops (unchanged)
Numbers, variable strings, `+ - * / ^`, comparisons, `and/or/not`, `ifelse`,
all elementary/trig/hyperbolic functions, `D` (uses `wrt`), `Pre`, `ic`,
`min/max`, `skolem`, `rank`. `skolem`/`rank`/`ic` use the generic fallback
(args-only ⇒ already non-lossy). `skolem` additionally carries a documentary
`label` field (the relation-kind tag, e.g. `"edge"`/`"bin"`/`"pair"`) that
lives outside `args` and is **not rendered** — only its component `args` are
shown, e.g. `skolem(u, v)`.

### const  `{op:"const", value:V, args:[]}`
Render the literal value `V` itself — indistinguishable from a bare literal.
Scalar → number formatting; array → `[e0, e1, …]`. All three formats.
`{const 5}` → `5`.

### true  `{op:"true", args:[]}`
Bare `true` (all formats). Not `true()`.

### fn  `{op:"fn", name:N, args:[…]}`
`N(a0, …)`; latex `\mathrm{ESC(N)}(a0, …)`.
`{fn datetime.year (t)}` → `datetime.year(t)`; latex `\mathrm{datetime.year}(t)`.

### enum  `{op:"enum", args:[Type, Member]}`
`Type.Member`; latex `\mathrm{ESC(Type.Member)}`.

### index  `{op:"index", args:[A, i0, i1, …]}`
`A[i0, i1, …]` in all formats (brackets, not subscripts). `A` parenthesized
if an operator node.

### broadcast  `{op:"broadcast", fn:F, args:[…]}`
Renders identically to the scalar expression `{op:F, args:[…]}` (element-wise
application). `{broadcast fn:"+" (A,B)}` → `A + B`.

### integral  `{op:"integral", args:[f], var:V, lower:L, upper:U}`
| Format  | Form |
|---------|------|
| unicode | `∫[L, U] f dV` |
| latex   | `\int_{L}^{U} f \, dV` |
| ascii   | `integral(f, V, L, U)` |

`{integral (f) var:x lower:0 upper:1}` → unicode `∫[0, 1] f dx`,
latex `\int_{0}^{1} f \, dx`, ascii `integral(f, x, 0, 1)`.

### table_lookup  `{op:"table_lookup", table:T, axes:{…}, output?:O}`
Base `T[k0=v0, k1=v1, …]` (axis keys sorted; values recursive). If `output`
present, append `:O`. latex wraps the table name: `\mathrm{ESC(T)}[k0 = v0]`
(note ` = ` spacing in latex only).
`{table_lookup table:visc axes:{T:temp}}` → `visc[T=temp]`;
latex `\mathrm{visc}[T = temp]`.

### apply_expression_template  `{op:"apply_expression_template", name:N, bindings:{…}}`
Template instantiation with angle brackets (bindings keys sorted):
| Format  | Form |
|---------|------|
| unicode | `N⟨p0=e0, p1=e1⟩` |
| ascii   | `N<p0=e0, p1=e1>` |
| latex   | `\mathrm{ESC(N)}\langle p0 = e0 \rangle` |

### makearray  `{op:"makearray", regions:[…], values:[…]}`
Region→value pairs. Each region `[[a0,b0],[a1,b1],…]` renders `[a0:b0, a1:b1, …]`;
paired with its value by ` = `; pairs joined `, `.
`makearray([1:3] = 0, [4:6] = 1)`. latex `\mathrm{makearray}([1:3] = 0)`.

### reshape  `{op:"reshape", shape:[…], args:[A]}`
`reshape(A, [s0, s1, …])`; latex `\mathrm{reshape}(A, [s0, s1])`.

### transpose  `{op:"transpose", perm?:[…], args:[A]}`
No `perm`: unicode `Aᵀ`, latex `A^{T}`, ascii `transpose(A)` (A parenthesized
if operator node). With `perm`: `transpose(A, [p0, p1, …])` (latex `\mathrm{…}`).

### concat  `{op:"concat", axis:X, args:[…]}`
`concat(a0, a1, …, axis=X)`; latex `\mathrm{concat}(a0, a1, axis=X)`.

### intersect_polygon / polygon_intersection_area  `{…, manifold:M, args:[P,Q]}`
`name(P, Q, manifold=M)`; latex `\mathrm{ESC(name)}(P, Q, manifold=M)`.

### aggregate  `{op:"aggregate", output_idx:[…], expr:E, reduce:R, semiring?, ranges?, join?, filter?, distinct?, key?}`
Big-operator symbol `⊕` chosen from `semiring` if present else `reduce`:

| ⊕ source | unicode | latex | ascii |
|----------|---------|-------|-------|
| `+` / sum_product | `Σ` | `\sum` | `sum` |
| `*` | `Π` | `\prod` | `prod` |
| `max` / max_product / max_sum | `max` | `\max` | `max` |
| `min` / min_sum | `min` | `\min` | `min` |
| bool_and_or | `⋁` | `\bigvee` | `any` |

Base (a space precedes the `(E)` in all three formats):
- unicode `⊕[o0, o1] (E)`  (output_idx joined `, `; integer `1` prints `1`)
- latex `⊕_{o0, o1} (E)`
- ascii `sum[o0, o1] (E)`  (⊕-word)

Then append, in this exact order, each clause only when the field is present:
1. ranges → ` where {k0∈r0, k1∈r1}` (keys sorted). Range `[a,b]`→`a:b`,
   `[a,s,b]`→`a:s:b`, `{from:F}`→`F` (with `of:[…]` → `F(of…)`). latex uses
   `\text{ where } \{k0 \in r0\}`; ascii ` where {k0 in r0}`.
2. join → ` join(l0=r0, l1=r1)` (pairs from every clause's `on`, clauses
   joined `; `). latex `\mathrm{…}` wrapper not used — literal ` join(…)`.
3. filter → ` if F` (F recursive).
4. distinct (true) → ` distinct`.
5. key → ` key=K` (K recursive).
6. semiring present and ≠ `sum_product` → ` [semiring=NAME]`.

### argmin / argmax  `{op:"argmin"|"argmax", arg:G, expr:E, ranges?:{…}}`
- unicode `argmin[G] (E)`, latex `\mathrm{argmin}_{G} (E)`, ascii `argmin[G](E)`.
- If `ranges` present, append the same ` where {…}` clause as `aggregate`.

## Associativity and parenthesization (NORMATIVE — added 2026-07-15)

The generic rule (a sub-expression that is an operator node is parenthesized where a leaf
would not be) leaves two cases that every binding currently gets WRONG. Both are
correctness bugs, not style, and the fixtures pin the CORRECT answer — do not "fix" the
fixture to match the code:

- **`^` is RIGHT-associative, so a LEFT-nested power MUST be parenthesized.**
  `{op:"^", args:[{op:"^", args:["a","b"]}, "c"]}` is `(a^b)^c` and MUST render
  `(a^b)^c` / `(a^{b})^{c}`. Emitting `a^b^c` is a **semantic error**: read back, it means
  `a^(b^c)`.
- **`D`'s operand is parenthesized when it is an operator node.**
  `D(x + y)` MUST render `∂(x + y)/∂t`, never `∂x + y/∂t`, which reads as `(∂x) + (y/∂t)`.

Conversely, parentheses are NOT added where precedence already disambiguates: a comparison
inside an `and`/`or` renders `x > 0 and x < 10`, not `(x > 0) and (x < 10)` (only a
logical-`or` *argument* is parenthesized — see Generic fallback).

Unary minus IS an operator node, so `{op:"*", args:[{op:"-",args:["a"]}, "b"]}` renders
`(−a)·b`.

## Number formatting (NORMATIVE — added 2026-07-15)

Previously UNSPECIFIED — the contract said only "Scalar → number formatting" and left the
rule to whatever each binding happened to do, which is why the number goldens drifted.

- **Sign.** `unicode` uses U+2212 MINUS SIGN (`−`); `latex` and `ascii` use ASCII `-`.
  This applies to the mantissa and the exponent alike.
- **Non-finite values are RENDERED, never stringified.** `Infinity` / `-Infinity` / `NaN`
  MUST render as `∞` / `−∞` / `NaN` (unicode), `\infty` / `-\infty` / `\text{NaN}` (latex),
  `inf` / `-inf` / `nan` (ascii). Emitting the literal token `Infinity` is a bug.
- **Precision is never lost.** The rendered mantissa MUST round-trip the input value at full
  precision: `0.009999` renders with mantissa `9.999`, NOT `1.0` — a golden that rounds it to
  `1.0×10⁻²` is wrong.
- **Exponent form.** `ascii` writes `1.5e4`, with NO `+` on a positive exponent.

## Removed

`binomial`, `gamma`, `erf`, `erfc` special cases are deleted from every
implementation and from `all_operators.json`. They are not format ops; if one
appears it renders through the generic fallback like any unknown identifier.
