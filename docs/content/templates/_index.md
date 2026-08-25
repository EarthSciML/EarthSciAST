---
title: "Expression templates"
description: "Rewrite rules: match, body, where, imports, and discretization."
---

An `expression_templates` entry is a **rewrite rule**. It is the *single*
structural-substitution mechanism in the format, and it covers three jobs with
one engine:

| Job | `match` | Applied by |
|---|---|---|
| Variable substitution | a bare metavariable | binding a name to an AST |
| Named template expansion | *absent* | an explicit `apply_expression_template` node |
| Operator lowering | an operator pattern | automatically, wherever the pattern matches |

The mechanism is purely **structural** — no evaluation, no metaprogramming.
Discretization, boundary conditions included, is not special schema machinery;
it is an ordinary rewrite rule.

## Where they live

`expression_templates` is declared inside a single `model` or `reaction_system`,
or at the **top level** of a template-library file shared across components and
files via `expression_template_imports`.

## Fields

| Field | Required | Meaning |
|---|---|---|
| `params` | yes | Ordered array of unique metavariable names. May be empty — a zero-parameter template is a named constant fragment. |
| `body` | yes | The replacement expression. |
| `match` | no | A pattern that makes the entry an auto-applied rewrite rule. |
| `where` | no | Static constraints on captured parameters. Only valid alongside `match`. |
| `priority` | no | Explicit ordering when several rules could fire. |

## A named template

With no `match`, a template is applied only where you invoke it.

```json
{
  "expression_templates": {
    "arrhenius": {
      "params": ["A_pre", "Ea"],
      "body": {
        "op": "*",
        "args": [
          "A_pre",
          { "op": "exp",
            "args": [{ "op": "/", "args": [{ "op": "-", "args": ["Ea"] }, "T"] }] },
          "num_density"
        ]
      }
    }
  }
}
```

Invoked as:

**Text**
```text
arrhenius<A_pre=1.8e-12, Ea=1370>
```
**JSON**
```json
{
  "op": "apply_expression_template",
  "name": "arrhenius",
  "bindings": { "A_pre": 1.8e-12, "Ea": 1370.0 },
  "args": []
}
```

Bindings are **by name**, not positional, and `args` is empty — the operands
travel in `bindings`. A binding value is any expression, so a template may be
invoked with a computed argument as easily as a literal.

Note what the body may reference beyond its `params`: `T` and `num_density` are
**not** parameters, so they resolve as ordinary variable references in whatever
scope the template expands into.

## Substitution sites

A parameter name appearing anywhere in `body` as a bare string is a substitution
site — in an `args` position, and also **in a scalar-field position** such as
`dim`, `side`, `wrt`, or `manifold`.

**Params shadow literals.** Every string equal to a declared parameter name is a
substitution site, so do not name a parameter after a field literal the body
means literally — a parameter called `planar` over a body pinning
`"manifold": "planar"` will substitute where you meant a constant. Bindings may
warn, but they must still substitute.

Substitution is pure syntax and checks nothing. An inadmissible substituted
value — `"manifold": "bogus"` — is caught by that field's own validation on the
expanded form, and reported at the offending call site.

## Auto-applied rules

Add `match` and the rule fires wherever the pattern structurally matches.

```json
{
  "expression_templates": {
    "central_difference_x": {
      "params": ["f"],
      "match": { "op": "D", "args": ["f"], "wrt": "x" },
      "body": {
        "op": "/",
        "args": [
          { "op": "-",
            "args": [
              { "op": "index", "args": ["f", { "op": "+", "args": ["i", 1] }] },
              { "op": "index", "args": ["f", { "op": "-", "args": ["i", 1] }] }
            ] },
          { "op": "*", "args": [2, "dx"] }
        ]
      }
    }
  }
}
```

### Wildcards versus literals

Inside `match`:

- a **parameter** name in an `args` position is a **wildcard** — it binds the
  matched sub-AST;
- a parameter in a scalar field binds the matched **literal**;
- a **non-parameter** string in an `args` position is a **literal** — it matches
  only that exact bare variable reference.

That last rule is the sanctioned **per-variable selector**. With `u` *not* in
`params`, `{"op":"D","args":["u"],"wrt":"x"}` fires only on the derivative of
`u` — so mixed schemes on one axis (upwind for `u`, central for `v`) are two
rules with ground patterns, ordered by explicit `priority`.

Numbers and booleans match literally; arrays match elementwise at equal length;
an object pattern constrains exactly the fields it names, and extra fields on
the node are permitted.

### Arity is part of the pattern

Pattern and node `args` must be equal in length. A rule written for a bare
`D(f, wrt:x)` does **not** fire on a `D` carrying
[trailing boundary operands](../operators/calculus/), and vice versa. That is
intended: the closure is part of the rule's identity, so a rule that does not
consume the boundary data cannot silently discard it.

## `where` — scoping rules to a mesh

`where` constrains the captured parameters. The v1 vocabulary has exactly one
constraint: `shape`.

```json
{
  "params": ["F"],
  "match": { "op": "div", "args": ["F"] },
  "where": { "F": { "shape": ["edges"] } },
  "body": { "op": "aggregate", "output_idx": ["c"], "expr": "…", "args": ["F"] }
}
```

The constraint on `F` is satisfied only if the sub-AST bound to it is a **bare
variable reference** naming a declaration whose `shape` equals the list exactly
— same names, same order. Anything else fails: a compound expression, a literal,
a scoped reference, an undeclared name, a scalar variable.

The judgment is deliberately **syntactic and conservative** — there is no shape
inference over compound expressions — so eligibility depends only on
declarations visible at lowering time, never on runtime values.

A `where` failure is not an error. The rule is filtered *before* priority
selection and treated exactly like a non-match at that node, and the next
candidate is considered. A constrained rule that never fires is fine; if no rule
remains for a rewrite-target op, the op simply survives and the ordinary
`unlowered_operator` gate rejects it before evaluation.

This is how discretization rules are shared across meshes: a divergence rule
constrained to `["edges"]` fires only on edge-fields of *its* mesh, and a second
mesh's rule constrained to `["edges_b"]` coexists in the same component without
priority games.

## Imports

`expression_template_imports` is an ordered array of imports of template-library
files. An import edge may **rename** index sets, and a rename rewrites the
imported templates' `where.*.shape` entries together with the imported
`index_sets` and range references — so a renamed grid instance arrives with its
rules correctly constrained.

Index-set names in a `shape` constraint resolve against the **consuming**
document's merged registry at rule registration. A constraint naming a set the
registry does not declare is rejected with
`template_constraint_unknown_index_set`. Validating a library file standalone
does not run this check, because no component has registered its rules yet.

## Metaparameters

A library body may carry open metaparameter expressions — a region bound of
`[2, "N-1"]`, say. These fold at the **binding site**, when the consuming
document supplies `N`. Bounds still carrying open expressions inside a library
body are not checked until they fold, which is why a library validates
standalone even though its regions are not yet concrete.

`where` is a structural field: metaparameter substitution never rewrites its
contents.

## Discretization

Putting it together: spatial discretization is a rule that lowers a
rewrite-target operator into an [`aggregate`](../operators/aggregation/) stencil
wrapped in a [`makearray`](../operators/arrays/), with the boundary treatment in
the `makearray`'s later regions.

```json
{
  "params": ["f"],
  "match": { "op": "D", "args": ["f"], "wrt": "x" },
  "body": {
    "op": "makearray",
    "regions": [[[2, "N-1"]], [[1, 1]], [["N", "N"]]],
    "values": [
      { "op": "aggregate",
        "output_idx": ["i"],
        "expr": { "op": "/",
                  "args": [{ "op": "-",
                             "args": [{ "op": "index", "args": ["f", { "op": "+", "args": ["i", 1] }] },
                                      { "op": "index", "args": ["f", { "op": "-", "args": ["i", 1] }] }] },
                           { "op": "*", "args": [2, "dx"] }] },
        "args": ["f"] },
      0.0,
      0.0
    ],
    "args": []
  }
}
```

The interior region carries the stencil; the two face regions overwrite it with
the boundary condition. **There is no separate boundary-condition declaration
anywhere in the format** — this is it.

At the minimum admissible extent the interior region folds to an
[empty region](../operators/arrays/) (`[2, N-1]` at `N = 2` becomes `[2, 1]`),
leaving the faces to cover the whole axis. That is legal and load-clean; folding
to `[2, 0]` at `N = 1` is *inverted* and rejected, because it means the scheme
was instantiated below the extent it is defined for.

This format ships **no** discretization rules. The standard library lives in
[EarthSciDiscretizations](https://github.com/EarthSciML/EarthSciDiscretizations).

## The fixpoint

Rules are applied to a fixpoint: rewriting continues until no rule fires. The
process is deterministic — priority order, then declaration order as the
tie-break, over a bounded number of passes, producing byte-identical results
across bindings.

A document may **load** with rewrite-target ops still present; one that reaches
evaluation still carrying them is rejected with `unlowered_operator`.
