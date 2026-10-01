---
title: "Expressions, three ways"
description: "Every example on this page is parsed at build time: the text, the mathematics and the JSON are the same expression."
weight: 20
---

An `.esm` document stores expressions as JSON trees, but nobody wants to write
them that way. The text syntax is the input form, and every binding parses it.

Each example below is one expression, written once in the text syntax and then
printed by the parser as mathematics and as the JSON the file stores. They
cannot drift apart: if the parser changes, this page changes with it, and if an
example stops parsing, the build fails.

## Arithmetic

The usual five operators, with the usual precedence:

::esm-example[a + b*c]

Parentheses group, and division is printed as a fraction:

::esm-example[(a + b) / (c - d)]

Exponentiation binds tighter than multiplication:

::esm-example[k * T^2]

## Functions

The closed function registry (esm-spec §9.2) covers the elementary functions:

::esm-example[exp(-E_a / (R*T))]

::esm-example[sqrt(2*pi*sigma^2)]

## Derivatives and equations

`D(x, t)` is the derivative of `x` with respect to `t`, and an equation is two
expressions with `=` between them:

::esm-example[D(c, t) = -k*c]

A second derivative nests:

::esm-example[D(D(u, x), x) = 0]

## Scoped references

A dotted name reaches into another component, which is how a coupled model
reads a variable it does not own:

::esm-example[k_0 * Meteorology.Temperature]
