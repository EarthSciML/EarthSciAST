# Per-term provenance through flatten

Fixtures for the `equation_contributions` field of the canonical `FlattenedSystem`
(esm-libraries-spec §4.7.5, "Per-term provenance"; CONFORMANCE_SPEC §5.48; issue #539).

Every flattened equation carries an ordered list of **contributions**. Each holds one
summand of the right-hand side and its **origins**: `{"component": "<dotted path>"}` for
an expression a component wrote, `{"coupling": <k>}` for one a coupling entry wrote itself,
where `k` is the entry's 0-based index in the coupling sequence after `coupling_import`
expansion. The invariant: `body(eq)` (the right-hand side, or the `faq` body of a
pointwise-lifted equation) evaluates bit for bit to the LEFT-FOLD sum of the contribution
expressions.

## How the fixtures are run

There is no separate runner. Each fixture is a case of the flatten corpus,
`tests/conformance/flatten/cases.json`, under the tier `term_provenance` with the id
`term_provenance_<fixture name>`, so every binding's existing flatten-corpus test covers
it. The corpus records each equation's `contributions` as

```json
{"rhs": "<to_ascii of the expression>", "origins": [{"component": "Chem"}]}
```

and a binding compares the list exactly and in order, for every case of the corpus, not
just these. The Python oracle generates it (`scripts/generate-flatten-corpus.py`).

Two checks need more than the corpus, and live in each binding's own suite:

- **The invariant, by evaluation.** A binding with an expression evaluator evaluates
  `body(eq)` and the left fold of the contribution values at a sampled non-default state
  for every equation of these fixtures and asserts bit equality. Python:
  `pkg/earthsci-ast-py/tests/test_term_provenance.py`.
- **The systems-order pair.** `systems_order_ab` and `systems_order_ba` are compared
  against each other: the same `(expression, origins)` pairs, in `rhs_A + rhs_B` order.

## The fixtures

| Fixture | Step-table row it pins |
|---|---|
| (corpus case `chained_operator_compose`, fixture `tests/coupling/chained_operator_compose.esm`) | Chained `operator_compose` with the operator as `systems[0]`: four contributions, `Src`, `Sink`, `Chem`, `Adv`, where the slot owner (`source_system`) names only `Src`. Reused, not copied. |
| `systems_order_ab.esm`, `systems_order_ba.esm` | One compose in both argument orders. Origins match; order follows `rhs_A + rhs_B`. Merges add no coupling origin. |
| `placeholder_expansion.esm` | `_var` clones carry the operator's component (`Adv`). |
| `couple_additive.esm` | `couple` additive onto an existing tendency (appended, `{"coupling": 1}`) and onto an unknown with no tendency (the term becomes `D(Atm.O2)`, a second term is appended to it). A parameter target takes no tendency. A later `variable_map` rewrites an input inside the coupling's contribution without changing its origin. |
| `couple_multiplicative.esm` | `couple` multiplicative collapses the list to one contribution, origins the union in first-appearance order, then the coupling. |
| `variable_map.esm` | `variable_map` `additive` (a scaled replacement) substitutes inside the authoring contribution and adds no origin; an Expression transform's new observed is authored by the coupling entry. |
| `pointwise_lift.esm` | The pointwise lift indexes inside each contribution and wraps the sum in one `faq`; `body(eq)` is the `faq` body. |
| `template_reference.esm` | An expression-template reference whose body is a sum sits inside one contribution; every term of its expansion inherits that contribution's origin. The Python oracle expands at load, so the golden records the expansion. |
| `deposition_sink.esm` | A sink term that, after `translate` and `variable_map`, reads two components (`DryDep`, `SuperFast`) and is authored by a third (`DepSink`). |
| `non_vacuity.esm` | Two operators contribute structurally identical expressions (`Emis.flux`) to one state. Two contributions, two origins. A binding that hangs provenance on interned nodes fails it. |
| `translate_factor.esm` | A `translate` factor scales a single-contribution B as `factor * expr`, and COLLAPSES a multi-contribution B into one `factor * (b1 + b2)` with the union of origins. |
| `rhs_time_derivative.esm` | Step 3a: a resolved `D(x, t)` replaces the node inside the referencing contribution and keeps that contribution's origin. |
