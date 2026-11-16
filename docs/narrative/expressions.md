---
title: "Expressions, three ways"
description: "Every example on this page is read at build time: the LaTeX, the mathematics and the JSON are the same expression."
weight: 20
show_source: true
---

An `.esm` document stores expressions as JSON trees, but nobody wants to write
them that way. An ESM Markdown document writes them as LaTeX math (the content
of a `$$` display), and every binding reads and prints that math.

Each example below is one expression, written once as that LaTeX, then shown as
the mathematics it typesets to and as the JSON the file stores. They cannot
drift apart: if the reader or the printer changes, this page changes with it,
and if an example stops reading, the build fails.

The reader takes the one spelling the printer writes, so the examples are
written that way: `T^{2}`, not `T^2`. A name of one letter, Greek ones
included, reads as itself; a longer name is read only when the example declares
it, in a `names` attribute: `::esm-example[...]{names="E_a k_0"}`.

## Arithmetic

The usual five operators, with the usual precedence; multiplication is
juxtaposition:

::esm-example[a + b c]

Division is a fraction, which also groups:

::esm-example[\frac{a + b}{x - y}]

Exponentiation binds tighter than multiplication:

::esm-example[k T^{2}]

## Functions

The elementary functions (esm-spec §4.2) are written as their LaTeX
operators. The subscript of a declared name is upright:

::esm-example[\exp(\frac{-E_{\mathrm{a}}}{R T})]{names="E_a"}

::esm-example[\sqrt{2 \pi \sigma^{2}}]

## Derivatives and equations

The derivative of `c` with respect to time `t` is an upright `d` fraction (a
`D` node with `wrt: "t"`), and an equation is two expressions with `=` between
them:

::esm-example[\frac{\mathrm{d} c}{\mathrm{d} t} = -k c]

A derivative with respect to any other variable is a partial one, and a second
derivative nests:

::esm-example[\frac{\partial\frac{\partial u}{\partial x}}{\partial x} = 0]

## Scoped references

A dotted name reaches into another component, which is how a coupled model
reads a variable it does not own. Each part prints as a name of its own, joined
by `.`; the whole dotted name is what the example declares:

::esm-example[k_{\mathrm{0}} \mathit{Meteorology}.\mathit{Temperature}]{names="k_0 Meteorology.Temperature"}
