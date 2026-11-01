---
title: "Arithmetic, comparison, logic"
description: "+ - * / ^ neg and the relational and boolean operators."
---

## Arithmetic

| Op | Arity | Result |
|---|---|---|
| `+` | 1 or more | sum of the arguments |
| `-` | 1 or 2 | negation (unary) or difference (binary) |
| `*` | 1 or more | product of the arguments |
| `/` | 2 | `args[0] / args[1]` |
| `^` | 2 | `args[0]` raised to `args[1]` |
| `neg` | 1 | negation — the canonical form of unary `-` |

`+` and `*` are **n-ary**, not binary: write `k·A·B` as one node with three
arguments, not as nested pairs. Canonicalization flattens and sorts them anyway,
so `(a+b)+c` and `a+(b+c)` have the same canonical form.

**Text**
```text
a + b + c
```
**JSON**
```json
{ "op": "+", "args": ["a", "b", "c"] }
```
With `a=1, b=2, c=3` this evaluates to `6.0`.

**Text**
```text
k * A * B
```
**JSON**
```json
{ "op": "*", "args": ["k", "A", "B"] }
```
With `k=2, A=3, B=4` → `24.0`.

`-` is the one operator whose arity changes its meaning:

**Text**
```text
-a
```
**JSON**
```json
{ "op": "-", "args": ["a"] }
```
With `a=5` → `-5.0` (negation).

**Text**
```text
a - b
```
**JSON**
```json
{ "op": "-", "args": ["a", "b"] }
```
With `a=5, b=2` → `3.0` (difference).

**Text**
```text
a / b
```
**JSON**
```json
{ "op": "/", "args": ["a", "b"] }
```
With `a=7, b=2` → `3.5`. Division is always binary — there is no n-ary form.

**Text**
```text
x^2
```
**JSON**
```json
{ "op": "^", "args": ["x", 2] }
```
With `x=3` → `9.0`.

`neg` is unary negation as a named operator — the form canonicalization emits,
and one of the scalar operators admissible as a
[`broadcast`](../arrays/) `fn`. It means exactly what unary `-` means:

```json
{ "op": "neg", "args": ["x"] }
```

It shares the text surface of unary `-` (`-x`), so text round-trips to `-`
rather than back to `neg`. Write `-` unless you are emitting canonical form.

There is **no `pow`**, and `**` is not a spelling of `^`. Bindings reject both,
along with `power` and `=`.

**Dimensions.** `+` and `-` require their operands to share a dimension and
propagate it. `*` and `/` combine dimensions. `^` requires a dimensionless
exponent.

## Comparison

`<`, `<=`, `>`, `>=`, `==`, `!=` — all **binary**.

Comparisons return `1.0` for true and `0.0` for false. They do not return a
boolean type; there is no boolean type in the value domain.

**Text**
```text
a < b
```
**JSON**
```json
{ "op": "<", "args": ["a", "b"] }
```
With `a=1, b=2` → `1.0`. With the same values,
`{"op": ">=", "args": ["a","b"]}` → `0.0`.

**Text**
```text
a == b
```
**JSON**
```json
{ "op": "==", "args": ["a", "b"] }
```
With `a=2, b=2` → `1.0`.

**Text**
```text
a != b
```
**JSON**
```json
{ "op": "!=", "args": ["a", "b"] }
```
With `a=2, b=2` → `0.0`.

**Dimensions.** Both operands must share a dimension; the result is
dimensionless.

## Logic

| Op | Arity | Result |
|---|---|---|
| `and` | 2 or more | `1.0` if every argument is non-zero |
| `or` | 2 or more | `1.0` if any argument is non-zero |
| `not` | 1 | `1.0` if the argument is zero, else `0.0` |

Operands are numbers, and the convention is the comparison convention: zero is
false, non-zero is true.

**Text**
```text
a < b and b > 0
```
**JSON**
```json
{
  "op": "and",
  "args": [
    { "op": "<", "args": ["a", "b"] },
    { "op": ">", "args": ["b", 0] }
  ]
}
```
With `a=1, b=2` → `1.0`.

**Text**
```text
a < b or b > 99
```
**JSON**
```json
{
  "op": "or",
  "args": [
    { "op": "<", "args": ["a", "b"] },
    { "op": ">", "args": ["b", 99] }
  ]
}
```
With `a=9, b=2` → `0.0` — neither disjunct holds.

**Text**
```text
not (a < b)
```
**JSON**
```json
{ "op": "not", "args": [{ "op": "<", "args": ["a", "b"] }] }
```
With `a=9, b=2` → `1.0`.

**Short-circuiting is not guaranteed.** The scalar evaluators short-circuit
`and`/`or`, but the array evaluators are **eager by construction** — they
broadcast over lanes, and per-lane laziness would require masked evaluation. Do
not rely on a logical operator to guard a domain error inside an array
expression. See [`ifelse`](../constants-and-conditionals/) for the same caveat.

**Dimensions.** Operands must be dimensionless; the result is dimensionless.
