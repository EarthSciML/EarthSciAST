# Spec questions

Ambiguities, contradictions and unstatable clauses found while modelling the
spec. Each entry has an anchor `Q-n`, the inventory clauses it concerns, how it
was found, what is wrong, and, once made, the ruling and the change that
carries it. Entries Q-2 onward were generated from the `concern` fields of
`inventory/*.json` (2026-10-26); each one still needs triage: some will be
misreadings by the inventory pass, which is recorded as the ruling. Triage
happens when each phase starts; purely editorial defects (numbering,
wording, a default only one reading permits) are fixed without a ruling
and recorded here, and substantive ones go to the maintainer.

Ordered by the plan phase that needs the ruling first. A phase cannot close
with a pending question among its own clauses.

## Q-1 CONFORMANCE_SPEC.md section numbering
- Clauses: `conf.5.52.doubly-defined-refused`, `conf.5.52.control-must-run`
- Phase: 0
- Found by: inventory (citation audit: section 5.45 resolves to two headings)
- Problem: Two sections are numbered 5.45 ("A Doubly-Defined Unknown Is Refused" and "Inline-Test Conformance Tiers"), and 5.44.6 appears after 5.46. In §7.1, 7.1.3 precedes 7.1.2, the 7.1.x headings mix `###` and `####`, the tail of the §7.1 error-code table is detached from its header and falls under 7.1.2, and the §7.1.3 rule rows run a–f, i, j, k, h with no g. Code and docs cite "§5.45" for the inline-test tiers.
- Ruling: Renumber and repair (2026-10-26): DONE in the phase-0 spec PR: the doubly-defined-unknown section is now §5.52 at the end of §5 (5.50 and 5.51 were taken); §5.44.6 is back under §5.44 and §5 reads in order; §7.1.0–7.1.3 are all `####` and in order; the detached E_* rows are back in the §7.1 table; the §7.1.3 rules are relettered a–j (old h→g, i→h, j→i, k→j, with the cross-reference in old k updated). The audit's blocked_by markers were removed when the citations resolved.

## Q-2 CONFORMANCE_SPEC.md §5.26: enum values unique
- Clauses: `conf.5.26.enum-values-unique`
- Phase: 1
- Found by: inventory
- Problem: 'MAY NOT' is not an RFC 2119 keyword and can be read as 'is permitted not to'; and no diagnostic code is named for the duplicate-value rejection (5.26.5 records three bindings accepting duplicates silently).
- Ruling: MUST NOT; new code enum_duplicate_value (2026-10-26). Phase-1 PR with binding support and fixture.

## Q-3 esm-spec.md §9.2: datetime exact integer
- Clauses: `spec.9.2.datetime-exact-integer`
- Phase: 1
- Found by: inventory
- Problem: t_utc is a binary64 that need not be an integer, so time-of-day is not an integer and 'exact integer arithmetic' does not say how second/minute treat fractions; floor(t/86400) computed as a rounded binary64 division can be off by one for t just below a multiple of 86400, making the floor-divmod pair inconsistent; and julian_day involves a divide and an add (two roundings), so the '<= 1 ulp' guarantee does not follow.
- Ruling: Floor toward −∞ (2026-10-26): hour/minute/second come from floor(time-of-day). The float floor(t/86400) and the julian_day ≤1-ulp claim are to be proven in phase 1 (the inventory concern was partly a misreading). Python (datetime.fromtimestamp rounds to µs) is a phase-1 binding finding.

## Q-4 esm-spec.md §9.2: interp axis no nan
- Clauses: `spec.9.2.interp-axis-no-nan`
- Phase: 1
- Found by: inventory
- Problem: A NaN axis entry also violates strict monotonicity, so both interp_nan_in_axis and interp_non_monotonic_axis apply and no precedence between the two codes is given.
- Ruling: interp_nan_in_axis takes precedence over interp_non_monotonic_axis; table_axis_nan over table_axis_non_monotonic (2026-10-26). Phase-1 PR.

## Q-5 esm-spec.md §9.2: interp const finite shape
- Clauses: `spec.9.2.interp-const-finite-shape`
- Phase: 1
- Found by: inventory
- Problem: 'Arrays of finite floats' includes table, contradicting the bullet two lines below that says 'Table arrays MAY contain NaN'.
- Ruling: Clarify only (2026-10-26): axes must be finite; inline tables MAY hold NaN. Phase-0 spec PR.

## Q-6 esm-spec.md §9.2: interp fma tolerance
- Clauses: `spec.9.2.interp-fma-tolerance`
- Phase: 1
- Found by: inventory
- Problem: The bound is defined by whatever tolerance a fixture file carries, so it is not a spec-level property; and rel 4e-16 cannot hold in general: fusing t_i + w*(d) removes one rounding of w*d, which relative to a result near zero by cancellation is unbounded.
- Ruling: Allow FMA with an absolute bound in ulps of max(|tᵢ|,|tᵢ₊₁|) (2026-10-26); the constant is proven in phase 1 before it enters the spec; the rel 4e-16 relaxation is removed.
- Done (phase 1): `interp.linear` 2·ulp(max(|tᵢ|,|tᵢ₊₁|)), attained (`P-interp-fma-two-ulp-attained`); `interp.bilinear` 17/2·ulp(max |corner|), proven but not known tight (`P-interp-bilinear-fma-bound`; least constant open, `P-interp-bilinear-fma-least-constant`, ≥ 4 by search). Both in §9.2's tolerance paragraph; the rel 4e-16 relaxation is gone from §9.2 and §9.5.6.

## Q-7 esm-spec.md §9.2: searchsorted xs monotone
- Clauses: `spec.9.2.searchsorted-xs-monotone`
- Phase: 1
- Found by: inventory
- Problem: 'Strictly non-decreasing' is self-contradictory (strictly increasing vs non-decreasing); the next bullet allows duplicates so non-decreasing is meant. NaN entries in xs are 'forbidden' with no diagnostic code, and a NaN makes every comparison-based monotonicity check pass or fail depending on how it is written.
- Ruling: New code searchsorted_nan, checked before searchsorted_non_monotonic; wording becomes non-decreasing (2026-10-26). Wording in the phase-0 spec PR; the code in the phase-1 PR.

## Q-8 esm-spec.md §9.3: enum values unique
- Clauses: `spec.9.3.enum-values-unique`
- Phase: 1
- Found by: inventory
- Problem: No diagnostic code is given for a duplicate value, and 'MAY NOT' in the same sentence is not an RFC 2119 keyword and can be read as a permission not to.
- Ruling: Same ruling as Q-2.

## Q-9 esm-spec.md §9.5.1: data finite
- Clauses: `spec.9.5.1.data-finite`
- Phase: 1
- Found by: inventory
- Problem: Only NaN has a diagnostic code; an infinite leaf violates 'finite' with no code (though JSON cannot spell one), and this is stricter than the §9.2 inline form, which allows NaN in tables, so a table with NaN cannot be lifted even though the lifting is said not to change semantics.
- Ruling: function_tables stays deliberately stricter than inline tables, and the spec says so: a NaN-bearing inline table cannot be lifted (2026-10-26). Phase-0 spec PR.

## Q-10 esm-spec.md §9.5.1: outputs leading dim
- Clauses: `spec.9.5.1.outputs-leading-dim`
- Phase: 1
- Found by: inventory
- Problem: The §9.5.3 lowering always slices data[i], but for a table without outputs data has no leading output dimension, so data[0] would be the first table entry rather than the whole table; the lowering for single-output tables is not stated.
- Ruling: Single-output tables lower with the whole data; the data[i] slice applies only with outputs (2026-10-26). Phase-1 PR.

## Q-11 esm-spec.md §9.5.2: lookup args empty
- Clauses: `spec.9.5.2.lookup-args-empty`
- Phase: 1
- Found by: inventory
- Problem: No diagnostic code is listed in §9.5.5 for non-empty args, and it is not said whether an absent args is equivalent to [].
- Ruling: Absent args means []; non-empty args is rejected with new code table_lookup_args_nonempty (2026-10-26). Phase-1 PR.

## Q-12 esm-spec.md §9.5.2: lookup output name
- Clauses: `spec.9.5.2.lookup-output-name`
- Phase: 1
- Found by: inventory
- Problem: It is not said what happens when output is omitted on a table that declares outputs (default 0, or an error).
- Ruling: Omitted output means 0 whether or not outputs is declared (2026-10-26). Phase-1 PR.

## Q-13 esm-spec.md §9.5: table lookup bit equivalent
- Clauses: `spec.9.5.table-lookup-bit-equivalent`
- Phase: 1
- Found by: inventory
- Problem: §9.5.3 qualifies this as 'modulo the same FMA caveats', so 'bit-equivalent' is not unconditional; and the 'nearest' lowering index(data, searchsorted(x, axis)) is neither nearest (searchsorted returns the first knot >= x) nor clamped (it returns N+1 above the last knot, an out-of-range index), contradicting out_of_bounds: "clamp".
- Ruling: True nearest knot, ties to the lower knot, out_of_bounds respected (2026-10-26). Phase-1 PR with binding lowering changes and fixtures.

## Q-14 CONFORMANCE_SPEC.md §5.5.1: float key normalized
- Clauses: `conf.5.5.1.float-key-normalized`
- Phase: 2
- Found by: inventory
- Problem: It says normalization happens 'via the canonicalize float formatting' before comparison but not whether the comparison is then numeric or on the formatted string; a lexicographic comparison of formatted numbers is not numeric order ("10" < "9"), so the total order on float keys is unspecified.
- Ruling: (pending)

## Q-15 CONFORMANCE_SPEC.md §5.5.1: join oplus assoc comm
- Clauses: `conf.5.5.1.join-oplus-assoc-comm`
- Phase: 2
- Found by: inventory
- Problem: The parenthetical claims every registry ⊕ (sum, product, ...) is associative and commutative 'so input and parallel order cannot change the result'; IEEE-754 floating-point + and × are not associative, which is why the next sentence has to require a fixed sequential order — the claim is false for floats as stated.
- Ruling: (pending)

## Q-16 CONFORMANCE_SPEC.md §5.5.3.1: literal type by value
- Clauses: `conf.5.5.3.1.literal-type-by-value`
- Phase: 2
- Found by: inventory
- Problem: Narrowing integral floats to integer literals is called value-preserving only on the strength of '/' being true division; nothing says + - * ^ on integer literals are evaluated without Int64 overflow, so an author's 1e18 * 1e18 (narrowed to integers) could overflow where the float form would not.
- Ruling: (pending)

## Q-17 CONFORMANCE_SPEC.md §5.6: identities not in file
- Clauses: `conf.5.6.identities-not-in-file`
- Phase: 2
- Found by: inventory
- Problem: Does not say whether a document that does write an identity is invalid (rejected) or the field is ignored, so the verdict on such a document is unspecified.
- Ruling: (pending)

## Q-18 CONFORMANCE_SPEC.md §7.1: unresolved order not unbound
- Clauses: `conf.7.1.unresolved-order-not-unbound`
- Phase: 2
- Found by: inventory
- Problem: This row belongs to the §7.1 error-code table but sits after the §7.1.2 prose as an orphaned table fragment with no header, so its nearest heading is 7.1.2; it is also unclear what 'claim the stronger one' permits instead (a generic error, or E_TREEWALK_UNRESOLVED_ORDER for every case).
- Ruling: (pending)

## Q-19 CONFORMANCE_SPEC.md §7.1: alias warning once per document
- Clauses: `conf.7.1.alias-warning-once-per-document`
- Phase: 2
- Found by: inventory
- Problem: The sentence is a fragment ('…reaches `emit` untouched. and MUST report this…') whose subject and 'this' are unclear, and it does not say whether a ref-loaded child or library counts as a separate DOCUMENT for the once-per-document count, though the preceding sentence treats each as a document the load touches.
- Ruling: (pending)

## Q-20 CONFORMANCE_SPEC.md §7.1: faq version gate authored form
- Clauses: `conf.7.1.faq-version-gate-authored-form`
- Phase: 2
- Found by: inventory
- Problem: The next sentence ('a document whose EXPANDED form contains `faq` declares 1.1.0 even when its authored bytes do not') does not say whether a pre-1.1.0 document whose expansion produces faq is rejected or has its version raised, and sits awkwardly with the gate reading only the authored form.
- Ruling: (pending)

## Q-21 esm-spec.md §2.2.6: external unresolved message
- Clauses: `spec.2.2.6.external-unresolved-message`
- Phase: 2
- Found by: inventory
- Problem: This pins diagnostic prose, while §4.9.6 says the prose is 'as everywhere else, not pinned across bindings'; and 'nothing escaped' makes the message ambiguous when the authored string itself contains a double quote or newline.
- Ruling: (pending)

## Q-22 esm-spec.md §4.1.1: printer parenthesize same level right
- Clauses: `spec.4.1.1.printer-parenthesize-same-level-right`
- Phase: 2
- Found by: inventory
- Problem: 'every level groups to the LEFT' contradicts the precedence table, where level 7 `^` is right-associative and level 6 `not` is prefix; for `^` the rule as written parenthesizes the wrong side (a right `^` operand needs none, a left one does).
- Ruling: (pending)

## Q-23 esm-spec.md §4.1.1: text surface single reading
- Clauses: `spec.4.1.1.text-surface-single-reading`
- Phase: 2
- Found by: inventory
- Problem: 'parse_expression is the inverse of to_ascii' cannot hold for all trees: §4.1.1 itself says a parser flattens `a + (b + c)` into one n-ary `+` (so a nested `+` tree does not round-trip), and a `-` before a numeric literal is read as part of the literal (so a unary-minus node on a literal does not round-trip); the class of trees on which it is an inverse is not stated.
- Ruling: (pending)

## Q-24 esm-spec.md §4.2: structural d unary
- Clauses: `spec.4.2.structural-d-unary`
- Phase: 2
- Found by: inventory
- Problem: The expected diagnostic is binding-dependent (a schema maxItems error, or operator_arity in a binding that also checks arity), so the clause does not fix one verdict code to pin.
- Ruling: (pending)

## Q-25 esm-spec.md §4.8.2: percent symbol token
- Clauses: `spec.4.8.2.percent-symbol-token`
- Phase: 2
- Found by: inventory
- Problem: 'A symbol is a maximal run of characters that is a table key' does not say whether a run is delimited by character class (so `s1` is one unresolvable token) or is the longest table-key prefix (so `s1` lexes as `s` followed by the legal atom `1`, i.e. `s*1`, which the grammar's optional-operator juxtaposition accepts); the two readings disagree on strings like `kg1` and `s1`.
- Ruling: Character-class runs (2026-10-26, reading A): a run of letters/digits is one symbol, so `s1`, `kgm`, `cm3` are unresolvable; bindings that split by longest table-key prefix are fixed.

## Q-26 esm-spec.md §4.8.3: agreement dimension and scale
- Clauses: `spec.4.8.3.agreement-dimension-and-scale`
- Phase: 2
- Found by: inventory
- Problem: The same paragraph refers to 'the ten strict transcendentals', but the §4.8.3 table says the strict set is 'EXACTLY ... nine ops, and no others'.
- Ruling: (pending)

## Q-27 esm-spec.md §4.8.3: sum operands share unit
- Clauses: `spec.4.8.3.sum-operands-share-unit`
- Phase: 2
- Found by: inventory
- Problem: The row is headed '`+` `-` (n-ary)' and the constant-expression rule treats `-` over two or more operands as a left fold, but the §4.2 arithmetic table gives `-` arity 'unary or binary'; whether a three-operand `-` is legal is stated both ways.
- Ruling: (pending)

## Q-28 esm-spec.md §4.9.5: evaluator fail closed
- Clauses: `spec.4.9.5.evaluator-fail-closed`, `conf.5.23.unbound-name-is-fault`
- Phase: 2
- Found by: inventory
- Problem: (`spec.4.9.5.evaluator-fail-closed`) The supporting claim that 'IEEE-754 max and min return the non-NaN operand' is not true in general: IEEE 754-2019 `maximum`/`minimum` propagate NaN (only `maximumNumber`/`minimumNumber`, and 2008's maxNum, return the number), and of the binding languages Julia `max`, JS `Math.max`, Go `math.Max` and NumPy `maximum` propagate NaN while Rust `f64::max` and C `fmax` do not. / (`conf.5.23.unbound-name-is-fault`) The supporting sentence that follows ('IEEE-754 `max` and `min` return the non-NaN operand') is not true of IEEE 754 as a whole: 754-2008 maxNum/minNum do, but 754-2019 maximum/minimum propagate NaN, and e.g. Julia's max(NaN, 0.0) returns NaN; the clause stands without it, but the stated fact is a property of particular functions, not of IEEE-754.
- Ruling: Propagate (2026-10-26): if any operand is NaN the result is NaN, also for the max/min ⊕ of faq; the false sentence is rewritten. Spec fix in the phase-0 PR; the Rust divergence (#568) is held for phase 2 to find.

## Q-29 esm-spec.md §6.6.3: nonfinite actual fails
- Clauses: `spec.6.6.3.nonfinite-actual-fails`
- Phase: 2
- Found by: inventory
- Problem: The motivating claims are false as stated: not every IEEE-754 comparison with NaN is false (!= is true), and with rel = 0 the right side rel * inf is NaN, so the unguarded bound does not 'PASS for every expected value' (and max(abs, NaN) differs by language: Julia max propagates NaN, C fmax drops it).
- Ruling: (pending)

## Q-30 esm-spec.md §6.6.4: null tolerance is absent
- Clauses: `spec.6.6.4.null-tolerance-is-absent`
- Phase: 2
- Found by: inventory
- Problem: The same sentence says null 'is not conforming input', so a model must choose between rejecting it and treating it as absent; the clause permits both, so the verdict on a null tolerance is not determined.
- Ruling: (pending)

## Q-31 CONFORMANCE_SPEC.md §5.28.4: shape mismatch rejected
- Clauses: `conf.5.28.4.shape-mismatch-rejected`
- Phase: 3
- Found by: inventory
- Problem: The heading calls this a load-time error, but the text describes per-binding runners and language-specific build/run error types, and no diagnostic code is named although 'the CLASSIFICATION is the cross-binding contract'; when it is raised and with which code is unspecified.
- Ruling: (pending)

## Q-32 CONFORMANCE_SPEC.md §5.30: dimension name clash fault
- Clauses: `conf.5.30.dimension-name-clash-fault`
- Phase: 3
- Found by: inventory
- Problem: The clash scope is defined by what each binding's build happens to carry ('Which names a build carries in each half is an implementation matter'; Rust has no const_arrays), so whether a given document is rejected can differ between bindings; the clause cannot be stated as a function of the document alone.
- Ruling: (pending)

## Q-33 CONFORMANCE_SPEC.md §5.5.7: computed cell position rejected
- Clauses: `conf.5.5.7.computed-cell-position-rejected`
- Phase: 3
- Found by: inventory
- Problem: Unlike the neighbouring rejections, no diagnostic code is assigned, so the cross-binding verdict can be pinned only as 'some error', not by code.
- Ruling: (pending)

## Q-34 CONFORMANCE_SPEC.md §5.5.7: pushdown identity idempotent pure
- Clauses: `conf.5.5.7.pushdown-identity-idempotent-pure`
- Phase: 3
- Found by: inventory
- Problem: 'Byte-identical' is undefined for an in-memory document transform unless a serialization is fixed, and the section header says the pushdown corpus is 'compared as parsed JSON'; it is unclear whether the requirement is byte equality of some canonical emission or structural (parsed-JSON) equality.
- Ruling: (pending)

## Q-35 CONFORMANCE_SPEC.md §5.5.8: computed key exact equality
- Clauses: `conf.5.5.8.computed-key-exact-equality`
- Phase: 3
- Found by: inventory
- Problem: Contradicts §5.5.1 rule 1 (floats forbidden in keys; NaN rejected; -0.0 normalized), and justifies itself by claiming the values are 'the same in every binding', which is false for computed values that pass through elementary functions (§5.9.2 and §5.18.1 both say libm results differ in the last ulp across bindings).
- Ruling: (pending)

## Q-36 CONFORMANCE_SPEC.md §5.5.8: float data not key
- Clauses: `conf.5.5.8.float-data-not-key`
- Phase: 3
- Found by: inventory
- Problem: The text then says declining the gate while the lowered predicate computes float equality is also conforming and that 'a document that can tell them apart is outside the contract', so the MUST NOT constrains no observable result and cannot be stated as a property.
- Ruling: (pending)

## Q-37 CONFORMANCE_SPEC.md §5.5.8: on fallback same answer
- Clauses: `conf.5.5.8.on-fallback-same-answer`
- Phase: 3
- Found by: inventory
- Problem: The match set is ordered 'by the canonical key first … then by left position', and the first driving shape drives 'from the sorted candidate PAIRS'; if pairs are walked in key order rather than position order, a floating-point ⊕ accumulates in a different order from the full product, so bit-identity holds only if the driver re-sorts by position, which the text implies but does not state.
- Ruling: (pending)

## Q-38 CONFORMANCE_SPEC.md §5.5.8: three candidates rejected
- Clauses: `conf.5.5.8.three-candidates-rejected`
- Phase: 3
- Found by: inventory
- Problem: Stated unconditionally, but a few lines later `syms` is 'REQUIRED for the |C| >= 3 case' and overrides the default, so the rejection must apply only when no `syms` is present; the table under 'two refusals' says so, this bullet does not.
- Ruling: (pending)

## Q-39 CONFORMANCE_SPEC.md §5.8.5: bin key integer
- Clauses: `conf.5.8.5.bin-key-integer`
- Phase: 3
- Found by: inventory
- Problem: Says 'No FP comparison in the broad phase', but §5.5.6 defines the overlap gate's broad phase as a floating-point closed AABB comparison of envelope factors; the two broad phases are different constructs but the text does not say this rule is limited to the bin-Skolem regridding join.
- Ruling: (pending)

## Q-40 esm-spec.md §4.2: aggregate alias normalized
- Clauses: `spec.4.2.aggregate-alias-normalized`
- Phase: 3
- Found by: inventory
- Problem: It says normalization runs 'ahead of the version gates', but the next paragraph says the faq_version_too_old gate 'reads the authored form, before normalization' — the order is stated both ways; and 'once per document' is ambiguous when one load touches several documents (root, ref-loaded children, libraries), each of which is normalized.
- Ruling: (pending)

## Q-41 esm-spec.md §4.3.1.1: recurrence coefficient one
- Clauses: `spec.4.3.1.1.recurrence-coefficient-one`
- Phase: 3
- Found by: inventory
- Problem: 'Provably 1' names no decision procedure: whether forms such as `(k+k)-k`, `1*k`, or `p*k` with a parameter p = 1 count as coefficient 1 is unspecified, so validators of different strength can reach different verdicts — the validator/evaluator divergence the following paragraph says is never defensible.
- Ruling: (pending)

## Q-42 esm-spec.md §4.7: from faq document scope
- Clauses: `spec.4.7.from-faq-document-scope`
- Phase: 3
- Found by: inventory
- Problem: It justifies document scope by 'the §3 field table', but §3 is Metadata; the field table that makes index_sets document-scoped is in §2.
- Ruling: (pending)

## Q-43 esm-spec.md §4.7: node id unique per document
- Clauses: `spec.4.7.node-id-unique-per-document`
- Phase: 3
- Found by: inventory
- Problem: A duplicate id is called 'a load-time error' but no diagnostic code is given, so the verdict cannot be pinned as a (code, pointer) pair like the others.
- Ruling: (pending)

## Q-44 esm-spec.md §6.3.1: bare index unsupported form
- Clauses: `spec.6.3.1.bare-index-unsupported-form`
- Phase: 3
- Found by: inventory
- Problem: The preceding text says the definition runs 'when all three hold' but then lists four conditions (the fourth being the rank check), so the set of forms this clause refuses is stated inconsistently.
- Ruling: (pending)

## Q-45 esm-spec.md §6.3: inline default matches shape
- Clauses: `spec.6.3.inline-default-matches-shape`
- Phase: 3
- Found by: inventory
- Problem: No diagnostic code is named for this load-time error (contrast array_default_without_shape just below), so cross-binding agreement can only be on the verdict, not the code.
- Ruling: (pending)

## Q-46 esm-spec.md §6.6.2: override array matches shape
- Clauses: `spec.6.6.2.override-array-matches-shape`
- Phase: 3
- Found by: inventory
- Problem: No diagnostic code is named for the mismatch, so the property can only fix the verdict.
- Ruling: (pending)

## Q-47 CONFORMANCE_SPEC.md §2.2.3: substitute semantics
- Clauses: `conf.2.2.3.substitute-semantics`
- Phase: 4
- Found by: inventory
- Problem: Rule 3 lists a faq's `expr` among sidecar fields 'carried through unchanged', but `expr` is the faq's body expression; read literally, substitution never reaches variables inside a faq body, which contradicts rule 2's 'descends into every args child' intent and is likely not meant.
- Ruling: (pending)

## Q-48 esm-spec.md §6.6.6: standalone undeclared index set
- Clauses: `spec.6.6.6.standalone-undeclared-index-set`
- Phase: 4
- Found by: inventory
- Problem: 'Such a document' is not delimited: the clause reads as if every standalone document defers undefined_index_set, which would also stop catching genuine typos in components that are never injected.
- Ruling: (pending)

## Q-49 esm-spec.md §8.9.4: extent check idempotent
- Clauses: `spec.8.9.4.extent-check-idempotent`
- Phase: 4
- Found by: inventory
- Problem: The resolved-shape test is satisfied by an authored single file with literal integer index-set sizes and no mounts, so the misspelled-extent typo the preceding paragraph insists must stay caught escapes the check; 'at least one index_sets entry with every interval size' is also ambiguous about whether 'every' ranges over that entry or all entries.
- Ruling: (pending)

## Q-50 esm-spec.md §9.6.1: where shape rename
- Clauses: `spec.9.6.1.where-shape-rename`
- Phase: 4
- Found by: inventory
- Problem: The §9.7.7 'Transitivity (normative occurrence sites)' list for index-set renames enumerates registry keys, `of`, `from`, wrt/dim/var, integral bounds and join `on`, but not `where.*.shape`; the two normative enumerations of rename sites disagree.
- Ruling: (pending)

## Q-51 esm-spec.md §9.6.2: apply args empty
- Clauses: `spec.9.6.2.apply-args-empty`
- Phase: 4
- Found by: inventory
- Problem: No diagnostic code is assigned to a non-empty `args`; the §9.6.6 table has no matching row (invalid_declaration covers template declarations, not call sites).
- Ruling: (pending)

## Q-52 esm-spec.md §9.6.3: match no apply node
- Clauses: `spec.9.6.3.match-no-apply-node`
- Phase: 4
- Found by: inventory
- Problem: No diagnostic code is named for this rejection here or in §9.7.3, and the §9.6.6 table has no row for it (only possibly the catch-all 'other structural defects' of invalid_declaration).
- Ruling: (pending)

## Q-53 esm-spec.md §9.6.4: load preservation
- Clauses: `spec.9.6.4.load-preservation`
- Phase: 4
- Found by: inventory
- Problem: The 'only differences this rule admits' list omits differences the spec itself requires elsewhere: consumption of component expression_template_imports (§9.7.6), materialized registry entries added by rule 5, the esm version bump of rule 8, lowering of rewrite-target ops by the §9.6.3 fixpoint, and consumption of composition-form injections (§9.7.10); read literally, every conforming emit of a document with imports or match rules violates it.
- Ruling: (pending)

## Q-54 esm-spec.md §9.6.8: spatial d must lower
- Clauses: `spec.9.6.8.spatial-d-must-lower`
- Phase: 4
- Found by: inventory
- Problem: The clause prescribes the output form (faq + makearray stencil), but nothing checks the body a rule produces; a rule lowering D to any evaluable-core expression passes the gate, and §9.6.8's own grad_is_Dx example shows rules whose bodies are not stencils, so only 'eliminated before evaluation' is enforceable.
- Ruling: (pending)

## Q-55 esm-spec.md §9.7.6: metaparameter exact division
- Clauses: `spec.9.7.6.metaparameter-exact-division`
- Phase: 4
- Found by: inventory
- Problem: 'exact 64-bit integer arithmetic' does not say signed or unsigned, which fixes where overflow occurs; unary minus suggests signed int64 but it is not stated.
- Ruling: (pending)

## Q-56 esm-spec.md §9.7.6: structural key set equals file
- Clauses: `spec.9.7.6.structural-key-set-equals-file`
- Phase: 4
- Found by: inventory
- Problem: The normative structural key set is delegated to a test-data file outside the spec, so the spec text alone does not determine substitution; nothing states which wins if that file disagrees with the four families enumerated in the preceding paragraph.
- Ruling: (pending)

## Q-57 esm-spec.md §9.7.6: subsystem binding names closed
- Clauses: `spec.9.7.6.subsystem-binding-names-closed`
- Phase: 4
- Found by: inventory
- Problem: Defaults apply only at the root's close (site 5) and a non-root document may leave metaparameters open for its importer (site 2), so a non-root mounting document's names need not be closed when its refs resolve; the clause does not say what happens then or which diagnostic applies to a declared-but-still-open name.
- Ruling: (pending)

## Q-58 esm-spec.md §9.7.7: rename template references
- Clauses: `spec.9.7.7.rename-template-references`
- Phase: 4
- Found by: inventory
- Problem: The parenthetical says references are 'in practice already inlined by the target's own §9.7.3 composition', but §9.7.3 says bodies are not inlined from esm 0.9.0; under the current model every binding must rewrite these references, not only those that 'compose lazily'.
- Ruling: (pending)

## Q-59 CONFORMANCE_SPEC.md §5.36.2: bare index refused
- Clauses: `conf.5.36.2.bare-index-refused`
- Phase: 5
- Found by: inventory
- Problem: The section records but does not settle that structural validation disagrees on the offset fixture (Rust's validator calls `k` in w_offset[k+1] undeclared, Python loads it), so the required verdict for that shape is not pinned; and the exemption 'Value-invention outputs are materialized by their own engine and are outside this rule' uses a term the clause does not define.
- Ruling: (pending)

## Q-60 CONFORMANCE_SPEC.md §5.42: literal t every layer
- Clauses: `conf.5.42.literal-t-every-layer`
- Phase: 5
- Found by: inventory
- Problem: The section says wrt "t" is always the structural time derivative, yet its rationale says reading wrt: "t" as the independent variable in a document that renames it to s and declares t as air temperature would leave d/d(air temperature) unwritable, which implies wrt "t" should then mean the declared variable t; and a derivative along the renamed independent variable is made a spatial rewrite target, so in such a document it is unclear what the time derivative is with respect to.
- Ruling: (pending)

## Q-61 CONFORMANCE_SPEC.md §5.7.7: cadence agreement
- Clauses: `conf.5.7.7.cadence-agreement`
- Phase: 5
- Found by: inventory
- Problem: Requiring byte-identical CONST-folded buffers across bindings is unachievable when a folded buffer passes through elementary functions, whose results §5.9.2 and §5.18.1 acknowledge differ in the last ulp between language math libraries.
- Ruling: (pending)

## Q-62 esm-spec.md §10.4: transform references from
- Clauses: `spec.10.4.transform-references-from`
- Phase: 5
- Found by: inventory
- Problem: No diagnostic code is named, and it is unclear whether a reference reaching `from` only through an apply_expression_template binding (as in the §10.5 example) counts, i.e. whether the check runs on the reference-preserving tree or on Expand(tree).
- Ruling: (pending)

## Q-63 esm-spec.md §10.4: transform refs fully scoped
- Clauses: `spec.10.4.transform-refs-fully-scoped`
- Phase: 5
- Found by: inventory
- Problem: A regridding transform is a faq whose bound index symbols (and possibly t or metaparameter names) appear as bare strings in variable-reference positions; the clause does not exempt them, and no diagnostic is named for a violation.
- Ruling: (pending)

## Q-64 esm-spec.md §11.4: ic coordinate symbols declared
- Clauses: `spec.11.4.ic-coordinate-symbols-declared`
- Phase: 5
- Found by: inventory
- Problem: The set of 'spatial coordinate names' is given only by example (x, y, z, lon, lat, lev, 'not necessarily the index-set key'), so which bare names an ic RHS may use without being undefined_variable is not defined.
- Ruling: (pending)

## Q-65 esm-spec.md §4.7: merge after mounting close
- Clauses: `spec.4.7.merge-after-mounting-close`
- Phase: 5
- Found by: inventory
- Problem: This states normatively that the merge runs after the mounting document's close, yet the 'Two mount forms' paragraph above says Rust and Julia merge before it, Python/TypeScript/Go after, and that 'which side of that merge order is right' is open — the spec both decides and leaves open the same question.
- Ruling: (pending)

## Q-66 esm-spec.md §4.9.6: observed cycle deterministic
- Clauses: `spec.4.9.6.observed-cycle-deterministic`
- Phase: 5
- Found by: inventory
- Problem: 'Sorted' names no order (code point, UTF-8 bytes, locale), and which cycle and rotation a DFS reports depends on unstated details (whether it stops at the first back edge, which node it enters on), so two compliant bindings can report different `details.cycle` paths.
- Ruling: (pending)

## Q-67 esm-spec.md §6.3.1: derived classification functions
- Clauses: `spec.6.3.1.derived-classification-functions`
- Phase: 5
- Found by: inventory
- Problem: The text claims the three unknown sets partition the unknowns, but nothing forbids one unknown being both under D(.,t) on one LHS and the bare LHS of another equation (it would be in ode_states and observed_unknowns), and an unknown that appears in no equation at all is put in algebraic_unknowns by the 'no equation names them on its LHS' wording even though nothing constrains it.
- Ruling: (pending)

## Q-68 esm-spec.md §6.3: no declared subtype
- Clauses: `spec.6.3.no-declared-subtype`
- Phase: 5
- Found by: inventory
- Problem: No diagnostic or observable test is given: it is unclear whether this means a loader must reject a legacy type such as "state", or only that binding APIs must not expose such a field, so it cannot be stated as an accept/reject property as written.
- Ruling: (pending)

## Q-69 esm-spec.md §6.6.2: override dropped prefix declared
- Clauses: `spec.6.6.2.override-dropped-prefix-declared`
- Phase: 5
- Found by: inventory
- Problem: Rule 2 says 'the longest such suffix wins' and separately that every dropped segment must be declared; it does not say whether, when the longest suffix's dropped prefix fails the check, a shorter suffix whose dropped prefix passes is tried or rule 2 fails outright.
- Ruling: (pending)

## Q-70 esm-spec.md §6.6.2: override reject run
- Clauses: `spec.6.6.2.override-reject-run`
- Phase: 5
- Found by: inventory
- Problem: This sentence makes any variable that two keys both resolve to an error, but the paragraph after the table says an exact hit plus a rule-2/3 claim on the same variable is resolved silently in favour of the exact hit; the two statements disagree on that case.
- Ruling: (pending)

## Q-71 esm-spec.md §6.6.5: buildtime ambiguous qualify
- Clauses: `spec.6.6.5.buildtime-ambiguous-qualify`
- Phase: 5
- Found by: inventory
- Problem: The clause says an ambiguous suffix 'binds nothing' and the expression must qualify further, but does not say whether this is a distinct error or falls under 'unbound', so the diagnostic for it is undetermined.
- Ruling: (pending)

## Q-72 esm-spec.md §6.6.5: coords index in range
- Clauses: `spec.6.6.5.coords-index-in-range`
- Phase: 5
- Found by: inventory
- Problem: No diagnostic code or stage is given for an out-of-range resolved index, and validators cannot always check it because index-set sizes may depend on metaparameters closed only at build.
- Ruling: (pending)

## Q-73 esm-spec.md §6.6.5: coords keys match index sets
- Clauses: `spec.6.6.5.coords-keys-match-index-sets`
- Phase: 5
- Found by: inventory
- Problem: No diagnostic code or rejection stage (validation vs run) is given for a coords key naming a set the field is not shaped over.
- Ruling: (pending)

## Q-74 esm-spec.md §6.6.5: coords partial pin
- Clauses: `spec.6.6.5.coords-partial-pin`
- Phase: 5
- Found by: inventory
- Problem: The example ('a 1-D component with a single dimension') does not fit the rule: in a 1-D field a strict subset pins nothing, and the single remaining dimension resolves to one sample only if its size is 1; no diagnostic code is named either.
- Ruling: (pending)

## Q-75 esm-spec.md §8.2.1: unresolved source fails
- Clauses: `spec.8.2.1.unresolved-source-fails`
- Phase: 5
- Found by: inventory
- Problem: 'Cannot be resolved' is defined only by the ${ and ?/# cases; it is unclear whether a resolved URL whose file is missing at read time also falls under this diagnostic and its no-default rule.
- Ruling: (pending)

## Q-76 esm-spec.md §6.7.4: field plot x spatial
- Clauses: `spec.6.7.4.field-plot-x-spatial`
- Phase: 6
- Found by: inventory
- Problem: Since v0.8.0 (§6.3.1) the domain carries nothing spatial, so 'a domain spatial dimension' and 'more spatial dimensions than the plot uses' have no referent in the format.
- Ruling: (pending)

## Q-77 esm-spec.md §6.7.4: field plot y spatial
- Clauses: `spec.6.7.4.field-plot-y-spatial`
- Phase: 6
- Found by: inventory
- Problem: Contradicts the field_slice bullet just above and the §6.7.6 example, where y names the plotted variable (u), not a spatial dimension; only field_snapshot's y is a spatial dimension.
- Ruling: (pending)

## Q-78 esm-spec.md §6.7.4: field slice pinned
- Clauses: `spec.6.7.4.field-slice-pinned`
- Phase: 6
- Found by: inventory
- Problem: Since v0.8.0 (§6.3.1) the domain carries nothing spatial, so 'a domain spatial dimension' and 'more spatial dimensions than the plot uses' have no referent in the format.
- Ruling: (pending)

## Q-79 esm-spec.md §6.7.4: field snapshot pinned
- Clauses: `spec.6.7.4.field-snapshot-pinned`
- Phase: 6
- Found by: inventory
- Problem: Since v0.8.0 (§6.3.1) the domain carries nothing spatial, so 'a domain spatial dimension' and 'more spatial dimensions than the plot uses' have no referent in the format.
- Ruling: (pending)

## Q-80 esm-spec.md §6.7.6: extra dims pinned
- Clauses: `spec.6.7.6.extra-dims-pinned`
- Phase: 6
- Found by: inventory
- Problem: Since v0.8.0 (§6.3.1) the domain carries nothing spatial, so 'a domain spatial dimension' and 'more spatial dimensions than the plot uses' have no referent in the format.
- Ruling: (pending)

## Q-81 esm-spec.md §9.6.6: pinned parameter builds
- Clauses: `spec.9.6.6.pinned-parameter-builds`
- Phase: 6
- Found by: inventory
- Problem: The data_source_unbound row says the code fires only 'in a case none of the following rules answers', but the rules that follow (default builds, no default is E_TREEWALK_MISSING_DATA, unresolved key is data_source_undefined, pinned builds) appear to cover every case, so the condition under which data_source_unbound is raised is undefined.
- Ruling: (pending)

## Q-82 CONFORMANCE_SPEC.md §5.18.1: index extent below 2 24
- Clauses: `conf.5.18.1.index-extent-below-2-24`
- Phase: 7
- Found by: inventory
- Problem: Rejecting extents above 2^24 does not ensure index arithmetic stays exact: a flat-offset subscript such as layer · N_C + c (used in §5.5.7) can exceed 2^24 with every extent below it; and the sentence is unconditional, so it reads as also rejecting such extents in Float64 documents.
- Ruling: (pending)

## Q-83 CONFORMANCE_SPEC.md §5.18.2a: no override matches document
- Clauses: `conf.5.18.2a.no-override-matches-document`
- Phase: 7
- Found by: inventory
- Problem: 'On the same code path' is an implementation constraint with no observable meaning; only the bit-for-bit part can be stated as a property.
- Ruling: (pending)

## Q-84 CONFORMANCE_SPEC.md §5.18.2b: no binary32 evaluator refuses
- Clauses: `conf.5.18.2b.no-binary32-evaluator-refuses`
- Phase: 7
- Found by: inventory
- Problem: Says Julia and Python refuse such variables, but §5.18.4 says 'Julia, Python, Go and TypeScript ignore element_type'; the two statements of the bindings' current behaviour contradict each other (and §5.18.2b point 1 binds Go/TS to write and preserve the field, which 'ignore' also contradicts).
- Ruling: (pending)

## Q-85 CONFORMANCE_SPEC.md §5.49.1: refusals
- Clauses: `conf.5.49.1.refusals`
- Phase: 7
- Found by: inventory
- Problem: The text says 'Seven fixtures' but enumerates eight: empty, reversed, conversion-only reversal, 02-30, 02-29 in 2100, unreadable origin, null origin, and the 1.2.0 document.
- Ruling: (pending)

## Q-86 CONFORMANCE_SPEC.md §5.5.8: key comparison exact
- Clauses: `conf.5.5.8.key-comparison-exact`
- Phase: 7
- Found by: inventory
- Problem: Contradicts §5.18.1's table, which says 'every arithmetic, comparison and logical operator' has its operands narrowed to binary32 under "Float32"; §5.18.2a's comparison rule exempts only operands declared binary64, not a lowered join predicate over keys in a document-wide Float32 model.
- Ruling: (pending)

## Q-87 CONFORMANCE_SPEC.md §5.5.8: same lowering same check
- Clauses: `conf.5.5.8.same-lowering-same-check`
- Phase: 7
- Found by: inventory
- Problem: 'Check the same thing' has no stated referent (mark the comparison binary64? verify it at build?), and the follow-on conformance condition ('exactly when that precision separates its key values') depends on the data, so the clause cannot be stated precisely.
- Ruling: (pending)

## Q-88 esm-spec.md §11.3.1: mixed element type
- Clauses: `spec.11.3.1.mixed-element-type`
- Phase: 7
- Found by: inventory
- Problem: Operands are arbitrary sub-expressions whose precision is inferred from leaves, not necessarily variables, so 'naming both variables' is undefined when an operand is compound or when several variables of each precision feed it.
- Ruling: (pending)

## Q-89 esm-spec.md §8.6.1: ring dedup equal
- Clauses: `spec.8.6.1.ring-dedup-equal`
- Phase: 7
- Found by: inventory
- Problem: Deduplication 'under the shared point-equality tolerance' is not well defined: closeness under atol/rtol is not transitive (a chain of near-duplicates), np.allclose's rtol is asymmetric, and which of two near-equal vertices is kept is unspecified, so 'MUST equal the same op over the already-distinct ring' cannot hold exactly.
- Ruling: (pending)

## Q-90 CONFORMANCE_SPEC.md §5.24.1: selectivity exact comparison
- Clauses: `conf.5.24.1.selectivity-exact-comparison`
- Phase: none (out_of_scope)
- Found by: inventory
- Problem: This MUST (and the tie-break MUST after it) sits inside an estimate the section calls 'explicitly NOT normative' that a binding 'MAY' replace or omit, and since the result cannot depend on the driver choice, a violation is unobservable; also the justification that a float division rounds 'differently in different languages' is doubtful, as IEEE-754 division is correctly rounded and gives identical results for identical binary64 inputs in every conforming language.
- Ruling: (pending)

## Q-91 CONFORMANCE_SPEC.md §5.24.2: both contracted driver intersects
- Clauses: `conf.5.24.2.both-contracted-driver-intersects`
- Phase: none (out_of_scope)
- Found by: inventory
- Problem: A MUST inside a SHOULD-level optimisation whose violation the section says cannot change any result (the lowered filter still decides every leaf), so it is not observable and reads as a SHOULD.
- Ruling: (pending)

## Q-92 CONFORMANCE_SPEC.md §5.27: scope not mode switch
- Clauses: `conf.5.27.scope-not-mode-switch`
- Phase: none (out_of_scope)
- Found by: inventory
- Problem: This normative paragraph is placed in the middle of the binding table (between the Julia and Python rows) and names only Julia functions, so it is unclear whether it binds every binding or is a Julia-specific note; it also breaks the Markdown table.
- Ruling: (pending)

## Q-93 CONFORMANCE_SPEC.md §5.5.6: three shapes driven
- Clauses: `conf.5.5.6.three-shapes-driven`
- Phase: none (out_of_scope)
- Found by: inventory
- Problem: The permitted fallback example ('a faq with additional contracted axes beside two contracted gated ones') is inside the first mandatory shape ('both gated symbols contracted ⇒ drive from the sorted candidate PAIRS, then take the cartesian product with any ungated ranges'); and driving pairs first then ungated ranges is not the full product's relative order when an ungated axis precedes the gated ones, so the 'same relative order' claim fails for that shape.
- Ruling: (pending)

## Q-94 CONFORMANCE_SPEC.md §7.1.2: schema errors pinned
- Clauses: `conf.7.1.2.schema-errors-pinned`
- Phase: none (out_of_scope)
- Found by: inventory
- Problem: Schema pins are {path, message, keyword} triples, so they pin message prose, which contradicts §5.19.5's 'What is pinned is the (code, path) pair, and NOT the diagnostic prose' and is fragile across validator libraries whose messages differ.
- Ruling: (pending)

## Q-95 esm-spec.md §8.9.1: unknown reader option
- Clauses: `spec.8.9.1.unknown-reader-option`
- Phase: none (out_of_scope)
- Found by: inventory
- Problem: Validity then depends on which format reader a binding binds, so the same document can be valid in one binding and invalid in another; no diagnostic code is named.
- Ruling: (pending)

## Q-96 esm-spec.md §9.6.1: param name author collision
- Clauses: `spec.9.6.1.param-name-author-collision`
- Phase: none (out_of_scope)
- Found by: inventory
- Problem: Phrased as an author MUST NOT, yet the same sentence requires bindings to accept and substitute such a body; a violating document is not rejected by anything, so this behaves as a SHOULD and a document can be non-conforming while every conforming tool accepts it.
- Ruling: (pending)

## Q-97 esm-spec.md §9.2: interp endpoint and alternative-cell claims (editorial)
- Clauses: `spec.9.2.interp-fma-tolerance`
- Phase: 1
- Found by: phase-1 formalization (`Esm.Closed.Rounding.blend64_w_one_refuted`)
- Problem: §9.2 claimed `w = 1 ⇒ result = tᵢ₊₁` and that bilinear's alternative cell `i = k − 1` is bit-identical to the pinned `i = k`. In binary64 `1 ⊕ (1 ⊗ (2⁻⁶⁰ ⊖ 1)) = 0`, refuting both. Also: the "equivalent formulation" of the bilinear cell via `interp.searchsorted` picks `k − 1` at an interior knot; the linear composition rationale clamped the index but not the weight, so it extrapolated; `w = 0` exactness needs `tᵢ₊₁` finite; the `interp.searchsorted` row said `(1..N)` where it returns `1..N+1`.
- Ruling: Editorial (2026-10-26): text corrected to the proven facts (exact at `w = 0` for finite `tᵢ₊₁`; at `w = 1` exact under Sterbenz, else within 3/2 ulp; alternative cell equal over ℝ only; searchsorted formulation marked not equivalent; rationale clamps `x`; return range `1..N+1`).

## Q-98 esm-spec.md §9.5.3: nearest is decided on binary64 differences, not exact distance
- Clauses: `spec.9.5.table-lookup-bit-equivalent`
- Phase: 1
- Found by: phase-1 formalization (`nearest64_not_exact`, `nearest64_spec`)
- Problem: Ruling Q-13 says "true nearest knot". The §9.5.3 lowering written for it decides on the binary64 differences `A[hi] − x` and `x − A[lo]`. On axis `[−1, 1]` with `x = 2⁻⁶⁰` both round to `1.0`, so it returns the lower knot although the upper is nearer. Proven: it is otherwise exact, it errs only toward the lower knot, and only when the exact distances differ by at most `ulp(x − A[lo])`. Fixture `q_rounding_tie` pins the binary64 answer.
- Ruling: Keep the binary64 comparison as the definition (2026-10-26): nearest is decided on the two rounded differences; amends Q-13. The spec states the proven bound (it can err only toward the lower knot, and only when the exact distances differ by at most ulp(x − A[lo])).

## Q-99 esm-spec.md §9.2: julian_day before −4800-03-01
- Clauses: `spec.9.2.datetime-exact-integer`
- Phase: 1
- Found by: phase-1 formalization (`julianDay_ne_standard`)
- Problem: §9.2 names Fliegel–van Flandern with truncating division as the reference computation and the standard Julian Date (JD 0 at noon, 4713 BC Jan 1) as the convention. They agree from −4800-03-01 on and disagree by −2 to +1 days on most earlier dates (FvF is 1 day ahead on −4800-02-29). Python, Go, Julia and Rust use FvF; TypeScript the standard JD. No fixture pins a date before −4800-03-01.
- Ruling: The standard Julian Date everywhere (2026-10-26; the user chose the more scientifically accurate of the two): julian_day = t/86400 + 2440587.5 for every t. Fliegel–van Flandern becomes an informative note valid from −4800-03-01. Python, Go, Julia and Rust change for dates before −4800-03-01; fixtures there.

## Q-100 esm-spec.md §9.2: datetime of a non-finite t
- Clauses: `spec.9.2.datetime-exact-integer`
- Phase: 1
- Found by: phase-1 formalization
- Problem: No result or diagnostic is given for a NaN or ±Inf `t_utc`.
- Ruling: Raise closed_function_overflow (2026-10-26) for a NaN or ±Inf t in every datetime.* function; fixtures and a guard per binding.

## Q-101 esm-spec.md §9.2: datetime fields when the year overflows
- Clauses: `spec.9.2.datetime-exact-integer`
- Phase: 1
- Found by: phase-1 binding work
- Problem: "If a result would overflow" — only `year` can leave Int32. It is unspecified whether `month`, `day`, `hour`, … raise `closed_function_overflow` too for such a `t`. Go raises for |t| ≥ 2⁶²; the others return deterministic values.
- Ruling: All fields raise (2026-10-26): every datetime.* function raises closed_function_overflow when the year of t is outside Int32.

## Q-102 esm-spec.md §9.2: single floor-divmod "zero drift" (editorial)
- Clauses: `spec.9.2.datetime-exact-integer`
- Phase: 1
- Found by: phase-1 formalization (`fSecondOfDay_ne`)
- Problem: "A single floor-divmod gives zero drift on the integer outputs" is false for a binary64 floor-divmod: at `t = −1 − 2⁻⁵²`, `86400 ⊕ t` rounds to 86399.
- Ruling: Editorial (2026-10-26): the Q-3 text defines the day number and time of day exactly, as real numbers; reproducer `tests/closed_functions/datetime/second/expected.json` scenario `frac_pre_epoch_minute_1969_12_31T23_59_below_ulp`.

## Q-103 esm-spec.md §4.8.1: unit scales with no stated value
- Clauses: `spec.4.8.1.customary-scales-pinned`
- Phase: 1
- Found by: phase-1 formalization
- Problem: `cal`, `kcal`, `ppm`, `ppb` and `ppt` have no stated scale. The model uses cal = 4.184 J and ppt = 10⁻¹² (every binding agrees), but `ppt` reads as parts per trillion or per thousand.
- Ruling: Pin what the bindings do (2026-10-26): cal = 4.184 J (thermochemical), kcal = 4184 J, ppm/ppb/ppt and the v forms = 1e-6/1e-9/1e-12, ppt explicitly parts per trillion.

## Q-104 esm-spec.md §4.8.2: unit-string grammar edge cases
- Clauses: `spec.4.8.2.percent-symbol-token`
- Phase: 1
- Found by: phase-1 formalization (Python compared)
- Problem: Unspecified: (a) a whitespace-only string (Python: dimensionless; model: reject); (b) `m^+2` (Python accepts; model rejects); (c) `01/s` and `1.0/s` — the grammar's atom is literally `'1'`, the prose says "value exactly 1"; (d) whether `%h` is `%`·`h`; (e) whitespace inside a term (`m ^ 2`), accepted by both.
- Ruling: Strict grammar (2026-10-26): (a) a whitespace-only string is rejected (only "" is dimensionless); (b) no `+` sign on exponents; (c) only the literal `1` (`01`, `1.0` are scaling-factor errors); (d) `%h` is `%`·`h`; (e) whitespace is allowed around `^`, `*`, `/`. Python changes for (a)–(c).

## Q-105 esm-spec.md §9.2, §9.5.5: unnamed diagnostic codes and check order
- Clauses: `spec.9.2.searchsorted-xs-monotone`
- Phase: 1
- Found by: phase-1 formalization
- Problem: No code is named for an `interp.searchsorted` `xs` that is not a rank-1 const array, nor for a function-table axis with fewer than 2 values; the order of the §9.5.5 checks beyond Q-4 is unpinned (the model's order is in `Esm/Closed/Tables.lean`).
- Ruling: (2026-10-26) searchsorted's non-const xs reuses interp_axis_not_const; new code table_axis_too_short; the model's §9.5.5 check order is pinned in the spec. Fixtures; bindings fixed where they differ.

## Q-106 esm-spec.md §9.2, §9.5.5: when closed-function and table checks run
- Clauses: `spec.9.5.5.table-check-order`, `spec.9.2.searchsorted-xs-not-const`
- Phase: 1
- Found by: phase-1 binding work
- Problem: The spec says these errors are raised at load time; every binding raises them at build or evaluation instead, so an unreferenced broken table is never reported and none of these cases can be a `tests/invalid` fixture.
- Ruling: Bindings check at load (2026-10-27): every binding runs the closed-function argument checks and the §9.5.5 table checks in load/`validate()`, for every table whether referenced or not; the cases become `tests/invalid` fixtures.

## Q-107 esm-spec.md §9.5.5: lookup checks relative to the table checks
- Clauses: `spec.9.5.5.table-check-order`
- Phase: 1
- Found by: phase-1 binding work
- Problem: Unpinned whether a `table_lookup`'s own checks (args, axis keys, output) come before or after validating the table it names. The model and Julia check args first; the other four after.
- Ruling: Table checks first (2026-10-27): unknown table, then the ten table checks, then the lookup's args, axis keys and output. Julia and the model change.

## Q-108 esm-spec.md §9.2: empty searchsorted table; wrong-rank interp arrays
- Clauses: `spec.9.2.searchsorted-xs-not-const`
- Phase: 1
- Found by: phase-1 binding work
- Problem: (1) Whether `xs = []` is a valid rank-1 table (Python and the model return 1; TypeScript rejects). (2) The code for a wrong-rank `const` axis or table of `interp.linear`/`interp.bilinear` differs across bindings and the model.
- Ruling: (2026-10-27) (1) `[]` is valid and searchsorted returns 1; (2) a wrong-rank axis or table is `interp_axis_not_const` / `interp_table_not_const`.

## Q-109 esm-spec.md §9.5.1, §9.5.5: infinite table values (editorial)
- Clauses: `spec.9.5.5.table-check-order`
- Phase: 1
- Found by: phase-1 binding work
- Problem: §9.5.1 and the schema require finite values, but the codes only name NaN; bindings differ on infinities in tables built in memory.
- Ruling: Editorial (2026-10-27): a non-finite value (NaN or ±Inf) is reported by `table_axis_nan` / `table_data_nan`; the code descriptions say "not finite".

## Q-110 esm-spec.md §9.2: order of the interp.linear / interp.bilinear argument checks
- Clauses: `spec.9.2.interp-axis-no-nan`
- Phase: 1
- Found by: phase-1 binding work
- Problem: Beyond not-const first and Q-4, the order of too-short, length-mismatch, NaN and non-monotonic differs across bindings.
- Ruling: (2026-10-27) not-const/rank → too short → length mismatch → NaN → non-monotonic (the Lean/Python order).

## Q-111 esm-spec.md §9.2: an empty table for interp.bilinear
- Clauses: `spec.9.2.interp-axis-no-nan`
- Phase: 1
- Found by: phase-1 binding work
- Problem: `[]` as a bilinear table reads as rank 1 (Rust, Lean) or an empty rank-2 table (Go, TypeScript).
- Ruling: (2026-10-27) `[]` is rank 1, so `interp_table_not_const` (Q-108's wrong-rank rule).

## Q-112 esm-spec.md §9.2, §9.5.2: the remaining static checks run at load
- Clauses: `spec.9.5.5.table-check-order`
- Phase: 1
- Found by: phase-1 binding work
- Problem: After Q-106, a `table_lookup`'s own checks (unknown table, non-empty args, axis keys, output) and `interp.*` arity still run at lowering/evaluation in most bindings.
- Ruling: (2026-10-27) Both move to load and `validate()`, like Q-106; they become `tests/invalid` fixtures.

## Q-113 esm-spec.md §9.2, §9.5: editorial consequences of Q-106..Q-112
- Clauses: `spec.9.5.5.table-check-order`
- Phase: 1
- Found by: phase-1 binding work
- Problem: (a) which error a document with several failures reports; (b) an infinite `interp.*` axis entry has no code; (c) a `fn` inside an expression-template body.
- Ruling: Editorial (2026-10-27): (a) tables are checked before `fn` nodes, as all five bindings already do, and the spec says so; (b) a non-finite axis entry is `interp_nan_in_axis` (the Q-109 reading); (c) checked where the template is applied.
