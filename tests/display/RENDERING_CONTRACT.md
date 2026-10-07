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
(args-only ⇒ already non-lossy), except as follows.

### skolem  `{op:"skolem", args:[…], label?:L}`
Without `label`: the generic fallback, `skolem(u, v)`. With the documentary
`label` (the relation-kind tag, e.g. `"edge"`/`"bin"`/`"pair"`), it is a trailing
named argument in all three formats, exactly like `intersect_polygon`'s
`manifold=`: `skolem(u, v, label=edge)`, latex `\mathrm{skolem}(u, v, label=edge)`.
The label does not affect the key, but the text form is lossless, so it is
shown. (Changed 2026-10-06; it was previously not rendered.)

### const  `{op:"const", value:V, args:[]}`
Render the literal value `V` itself — indistinguishable from a bare literal.
Scalar → number formatting; array → `[e0, e1, …]`. All three formats.
`{const 5}` → `5`.

### true, false  `{op:"true", args:[]}`, `{op:"false", args:[]}`
Bare `true` / `false` (all formats). Not `true()` / `false()`.

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

### faq  `{op:"faq", output_idx:[…], expr:E, reduce:R, semiring?, ranges?, join?, filter?, distinct?, key?}`
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
2. join → ` join(C0; C1; …)`, one item per clause, clauses joined `; `. latex
   `\mathrm{…}` wrapper not used — literal ` join(…)` in all three formats. A
   clause is EITHER:
   - an equality clause `{on:[[l0,r0], …], syms?:[s0,s1]}` → `l0=r0, l1=r1`,
     followed by `, syms=[s0, s1]` when `syms` is present (the self-join side
     assignment, CONFORMANCE_SPEC §5.5.8 — it changes the result, so it is never
     dropped). e.g. `join(row_prior=row_id, syms=[b, a])`;
   - an overlap clause `{overlap:{src_env:[…], tgt_env:[…], eps?:E}}` →
     `overlap(src=[a0, a1], tgt=[b0, b1, b2, b3])`, with `, eps=E` appended
     inside the parentheses whenever `eps` is present — including an explicit
     `0`, so the field round-trips as written (absent ⇒ 0, the schema default,
     and nothing is printed). `E` is formatted per the number rules of each format.
     e.g. `join(overlap(src=[px, py], tgt=[W, S, E, N], eps=1.0e-3))`.

   A parser MUST refuse an empty `join()`, an empty clause, a `syms` that does
   not name exactly two symbols, and an `overlap(…)` mixed with key pairs in
   one clause — none is a schema-valid clause. (Changed 2026-10-06: `syms` and
   overlap clauses were previously dropped, printing an empty `join()`.)
3. filter → ` if F` (F recursive).
4. distinct (true) → ` distinct`.
5. key → ` key=K` (K recursive).
6. semiring present and ≠ `sum_product` → ` [semiring=NAME]`.

### argmin / argmax  `{op:"argmin"|"argmax", arg:G, expr:E, ranges?:{…}, join?, filter?, id?}`
- unicode `argmin[G] (E)`, latex `\mathrm{argmin}_{G} (E)`, ascii `argmin[G] (E)`.
- Then append, in this order, each clause only when present, spelled exactly as
  on `faq`: ranges ` where {…}`, join ` join(…)`, filter ` if F`, ` id=ID`.
  e.g. `argmin[g] (d[g]) where {g in gens} join(point_bin=gen_bin) if d[g] > 0`.
  (Changed 2026-10-06: `join` and `filter` were previously dropped.)

## Associativity and parenthesization (NORMATIVE — added 2026-07-15)

The generic rule (a sub-expression that is an operator node is parenthesized where a leaf
would not be) leaves three cases that every binding at some point got WRONG. All are
correctness bugs, not style, and the fixtures pin the CORRECT answer — do not "fix" the
fixture to match the code:

- **`^` is RIGHT-associative, so a LEFT-nested power MUST be parenthesized.**
  `{op:"^", args:[{op:"^", args:["a","b"]}, "c"]}` is `(a^b)^c` and MUST render
  `(a^b)^c` / `(a^{b})^{c}`. Emitting `a^b^c` is a **semantic error**: read back, it means
  `a^(b^c)`.
- **`D`'s operand is parenthesized when it is an operator node.**
  `D(x + y)` MUST render `∂(x + y)/∂t`, never `∂x + y/∂t`, which reads as `(∂x) + (y/∂t)`.
- **A negated SUM or DIFFERENCE MUST be parenthesized** (NORMATIVE — added 2026-09-22).
  `{op:"-", args:[{op:"+", args:["a","b"]}]}` is `−(a + b)` and MUST render `−(a + b)` /
  `-(a + b)`; likewise `−(a − b)`. Emitting `−a + b` is a **semantic error**: unary minus
  binds TIGHTER than `+` and binary `-` (§ "Unary minus" below), so read back, `−a + b`
  means `(−a) + b`. A negated PRODUCT, QUOTIENT or POWER needs no parentheses, because
  unary minus binds LOOSER than `*`, `/` and `^`: `−a · b` reads back as
  `−(a · b)` and `−a^2` as `−(a^2)`, the very nodes that were printed.

- **A RIGHT operand at the SAME precedence level is parenthesized unless it is the very
  same associative operator** (NORMATIVE — added 2026-10-06). The parser groups
  same-level operators to the LEFT, so `{op:"*", args:["a", {op:"/", args:["b","c"]}]}`
  MUST render `a * (b / c)` (bare `a * b / c` reads back as `(a * b) / c`), `a + (b - c)`
  likewise, and `{op:"==", args:["a", {op:"<", args:["b","c"]}]}` MUST render
  `a == (b < c)`. "Right operand" means every argument after the first, so in an
  n-ary `+`/`*`/`and`/`or` the rule applies to arguments 2…n: `k * (a / b) * c`. The
  associative operators are `+`, `*`, `and` and `or`; a same-op right operand of one
  of them needs no parentheses because the parser re-flattens it into one n-ary node
  (`a + b + c`). `^` is not in that set, so a right-nested power keeps its explicit
  parentheses: `a^(b^c)`. The one exception is latex, where a `\frac{…}{…}` operand of
  `*` is self-delimiting and is not wrapped: `a \cdot \frac{b}{c}`.
- **A comparison or logical operand of an arithmetic operator MUST be parenthesized.**
  Comparisons and `and`/`or` bind looser than every arithmetic operator, so
  `{op:"*", args:[{op:"<=", args:["a","b"]}, {op:"<", args:["c","d"]}]}` (a product
  of indicator factors, common in `faq` filters) MUST render `(a <= b) * (c < d)`;
  bare `a <= b * c < d` reads back as a different expression.
- **An n-ary `and` renders infix**, like `or`: `a <= b and b < c and c < d`. A
  function-call spelling `and(…)` is not parseable — `and` is an infix keyword.

Conversely, parentheses are NOT added where precedence already disambiguates: a comparison
inside an `and`/`or` renders `x > 0 and x < 10`, not `(x > 0) and (x < 10)` (only a
logical-`or` *argument* is parenthesized — see Generic fallback).

### Unary minus (NORMATIVE — added 2026-09-22)

Unary `-` binds **tighter than `+` and binary `-`** and **looser than `^`** — the standard
mathematical reading, and the one `parse_expression` implements (its operand is parsed at
MULTIPLICATIVE precedence). The printer's parenthesization is the exact inverse, so every
rendering re-parses to the node it came from:

| AST | Renders | Why |
|---|---|---|
| `{op:"+", args:[{op:"-",args:["a"]}, "b"]}` | `−a + b` | unary `-` binds tighter than `+` |
| `{op:"-", args:[{op:"-",args:["a"]}, "b"]}` | `−a − b` | same, for binary `-` |
| `{op:"-", args:[{op:"+", args:["a","b"]}]}` | `−(a + b)` | a negated sum MUST keep its parentheses |
| `{op:"-", args:[{op:"*", args:["a","b"]}]}` | `−a · b` | unary `-` binds looser than `*` |
| `{op:"-", args:[{op:"^", args:["a",2]}]}` | `−a^2` | unary `-` binds looser than `^` |
| `{op:"*", args:[{op:"-",args:["a"]}, "b"]}` | `(−a)·b` | unary minus IS an operator node, and `−a · b` would read back as `−(a · b)` |
| `{op:"^", args:[{op:"-",args:["a"]}, 2]}` | `(−a)^2` | `−a^2` would read back as `−(a^2)` |

A negative *literal* is a number, not a unary-minus node, so it is never parenthesized:
`{op:"^", args:[{op:"/",args:[300,"T"]}, -1.3]}` renders `(300 / T)^-1.3`.

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
