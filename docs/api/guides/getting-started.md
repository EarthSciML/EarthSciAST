---
title: "Getting started"
description: "Load a document, check it, look inside, print it, change it, flatten a coupled one, derive a reaction system's equations, and simulate."
weight: 10
---

This guide takes one small document through everything a binding does with
it, in the order you would usually meet those steps. Each step shows the same
task in every binding; pick your language on any tab and the rest of the site
follows. Every snippet is cut from a program that runs, and checks its own
result, in CI.

The examples use four small documents from
[`docs/api/examples/fixtures/`](https://github.com/EarthSciML/EarthSciAST/tree/main/docs/api/examples/fixtures):

- `decay.esm` — one model, `Decay`: an amount `N` that decays at rate
  `lambda`, with its half-life as an observed quantity, `half_life = ln 2 / lambda`.
- `invalid.esm` — a model whose equation uses a variable, `k`, that it never
  declares.
- `coupled.esm` — two models, `Heater` and `Box`, where the heater's
  temperature is mapped onto the box's wall temperature.
- `ozone.esm` — the NO–NO₂–O₃ photostationary cycle written as a reaction
  system of two reactions.

## Load a document

A document can be read from a file path or from a string of JSON. Either way,
loading parses the JSON, checks it against the schema, and runs the load-time
passes a document needs before it can be used, such as resolving subsystem
references and expanding expression templates. A document that is not valid
JSON, or does not match the schema, fails here with an error. The result is the binding's
in-memory document, whose sections mirror the file: its `models`,
`reaction_systems`, `coupling` and so on.

<!-- example: load -->

See [`load_path`](/generated/api/ref/load_path),
[`load_string`](/generated/api/ref/load_string) and
[`load_document`](/generated/api/ref/load_document) for the options each one
takes.

## Validate it

Loading already rejects a document that does not match the schema. Validation
goes further: it applies the structural rules of the specification, such as
every variable an equation uses being declared, and checks units. A document
can be valid JSON, match the schema, and still fail here, as `invalid.esm`
does: its equation multiplies by `k`, which no variable declares.

Validation reports rather than raises. It returns a result that says whether
the document is valid and lists what is wrong, sorted into schema errors,
structural errors and unit warnings, each with a diagnostic code that is the
same in every binding and a message for people.

<!-- example: validate -->

## Look inside: models, variables and their roles

A model's variables are declared as unknowns or parameters, but what each one
*is* depends on its equations. `N` has a time derivative, so it is a state that
a solver integrates. `half_life` is defined by an algebraic equation from a
parameter, so it is an observed quantity: computed from the others, never
integrated. `lambda` is a constant parameter. The classification functions
derive these roles the same way in every binding
([esm-spec §6.3.1](https://github.com/EarthSciML/EarthSciAST/blob/main/esm-spec.md)).

<!-- example: inspect -->

The [Variable classification](/generated/api/topics/classification) topic lists
the rest, including the parameter kinds for discrete, sampled and Brownian
parameters.

## Display equations

The display functions render an expression, an equation, or a larger part of
a document for people to read: plain text, Unicode with sub- and superscripts,
or LaTeX for papers and notebooks.

<!-- example: display -->

## Build and change expressions

Expressions are trees of operators and their arguments. You can build one
directly, or parse it from text, then ask which variables it uses and
substitute values or other expressions into it.

<!-- example: expressions -->

## Edit a document

The editing operations add, remove and rename the parts of a document. Here a
new variable and an equation for it are added to the `Decay` model, and the
result is serialized back to JSON and written to a file. A document you have
edited can be loaded again, by this binding or any other.

<!-- example: edit -->

## Flatten a coupled document

A document with several components and coupling between them is turned into
one system by flattening. Each variable gets a name qualified by its component
(`Heater.T`, `Box.T_air`), and the coupling is applied: here, `Box.T_wall` is
replaced by `Heater.T`, so the box's air temperature now follows the heater.

<!-- example: flatten -->

Flattening reports problems with the coupling as errors of its own; the
[Flatten](/generated/api/topics/flatten) topic lists them.

## Derive equations from reactions

A reaction system lists species, parameters and reactions. Deriving its
ordinary differential equations applies mass-action kinetics: each reaction
consumes its substrates and makes its products at a rate given by its rate
constant times the product of its substrates. For `ozone.esm`, `d[O3]/dt` is
`jNO2·[NO2] − k1·[NO]·[O3]`.

<!-- example: reactions -->

## Simulate

Julia, Python and Rust can integrate a document; TypeScript and Go read, check
and transform documents but deliberately do not simulate them. Simulation
follows the SciML vocabulary in every binding that has it: build a *problem*
from the document, then *solve* it over a time span. Starting from
`N = 100` with `lambda = 0.1 /s`, after one half-life (`ln 2 / 0.1 ≈ 6.93 s`)
half the amount is left, and the observed `half_life` can be read from the
solution like any state.

<!-- example: simulate -->

## Where next

- The [API reference](/generated/api) has a page for each operation, with
  every binding's signature and documentation side by side.
- [File structure](/file-structure) describes each section of an `.esm`
  document.
