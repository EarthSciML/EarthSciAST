import Mathlib.Data.List.Nodup

/-!
# Document notation: the Phase 0 tables, as data

The signed-off notation for ESM source documents (`.md` with LaTeX math, `.typ` with
Typst math). This module is DATA ONLY: the operator tiers, the precedence levels, the
name rules, where each schema field lives in a document, and the accepted variants.
The printers, parsers and round-trip theorems of the later phases are stated against
these tables, so a notation change is a change here first.

"Lossless" for documents means equality after the canonical form (key order, number
spelling, unit spelling). Numbers follow CONFORMANCE §5.5.3.1: a literal's type is
fixed by its value, so an integral `Int64`-representable `1.0` IS the integer `1`. The canonical
form gains spelling rules for the redundant spellings listed in `spellingRules`; each
gets a meaning-preservation proof when it lands.

Decisions of record (2026-11-13):

* Redundant spellings are normalized in the canonical form, not kept apart in notation.
* `neg` and `pow` are deprecated: loaders warn and rewrite them to unary `-` and `^`;
  the §5.4 algebraic canonicalizer emits `-x` instead of `neg(x)`.
* Chemical-formula-shaped names print as formulas everywhere, with no package.
* Reactions print with the rate over the arrow, one line per reaction, `id` as its
  label. There is no reaction-table form, on output or input.
* Template arguments are positional when the parameter list is known, named otherwise.
* Index subscripts are italic expressions; the subscript part of a name is upright;
  an ambiguous digit subscript prints the index in brackets (`k[1]`).
* Expression-valued fields inside blocks are math strings (spelled 2026-11-20: a math
  leaf `$…$`, see "Expressions inside path blocks"); an equation's `_comment` is a comment
  line inside its math.
* Models and reaction systems keep separate directives.

Decisions of record (2026-11-15), array notation:

* `makearray` prints as a bracketed two-column table, value then region, rows in JSON
  order; a region is its bound pairs joined by `\times`; a lifted `makearray` carries its
  `output_idx` as the bracket's subscript.
* A `faq` whose `args` are names other than the arrays its body indexes carries them as a
  superscript set; with it a lone dense range uses the one-row subscript.
* An array `const` of any size prints as a matrix (rank 1 or 2); the named reference into
  a data block is no longer planned for printing.
* A template applied with no bindings and no known parameter list is its bare name.
* `broadcast`, `reshape`, `transpose`, `concat` and every `faq`, `makearray` or `const`
  without a native shape use the call form with named fields; the escape form is left for
  annotated nodes, non-identifier field keys and shapes no notation covers.

Operators in the source formats (esm-spec §1.2, esm 2.4.0; "one operator type", §9.6.12):

* `D` is only the time derivative. The spatial derivative is the defined operator `partial`
  (spec §4.2): `\frac{\partial u}{\partial x}` / `(partial u)/(partial x)`, and with trailing
  operands `\partial_{x}(u, a, b)` / `partial_(x)(u, a, b)`. A fraction of differentials along an
  axis other than `t` reads as `partial`; along `t`, with `\mathrm{d}` / `dif` (or the
  `\partial` variant), as `D`. The earlier trailing-operand form `\operatorname{D}_{x}(…)` /
  `op("D")_(x)(…)` is read as `partial` and never printed. A `D` node whose `wrt` is not `t`
  (which a loader reads as `partial`, `Adapter.Doc.spellRules`) prints in the escape form.
* The defined operators `grad`, `div`, `laplacian`, `curl` with one operand and no field print
  `\nabla f`, `\nabla \cdot F`, `\nabla^{2} u`, `\nabla \times F` / `nabla f`, `nabla dot F`,
  `nabla^2 u`, `nabla times F`, at the level of `not`, the operand at the level of a power
  base (parenthesized unless it is a postfix form or an atom), except that an operand which
  is itself a `\nabla` form is written as it is. They are trees, not identities:
  `\nabla \cdot \nabla u` is `div(grad(u))`, not `laplacian(u)`. A `\nabla` form as the base of a
  power or an index is parenthesized (`\left(\nabla f\right)^{2}`); `\nabla f^{2}` is refused
  on input. After the
  `\times` of a curl an operand that starts with a number is parenthesized too
  (`\nabla \times \left(2\right)`), so that no `\times 10^{…}` follows a token: the lexers read
  that as a number's scientific tail.
* Any other call of a defined operator prints in the call form. A call whose operator name is
  also the key of a definition with known `params` prints in the escape form, since the call
  form would read back as a reference to that definition (`callCond` in
  `Esm.Document.Math.Print` requires the symbol table to have no parameters for the name).
* The reference is `apply_operator` (the old `apply_expression_template` is read as it by a
  loader, `Adapter.Doc.spellRules`, never printed).
-/

namespace Esm.Document.Notation

/-! ## Operators (spec §4.2) -/

/-- How an operator is written.

* `native`: conventional notation.
* `call`: `\operatorname{name}(…)` in LaTeX, `op("name")(…)` in Typst. Every open
  (rewrite-target) operator and every template application also uses this form,
  with node fields such as `dim` as named arguments after a semicolon. The core
  operators of `fieldCallOps` (`broadcast`, `reshape`, `transpose`, `concat`, and a
  `faq`, `makearray` or `const` with no native shape) use it too when no field annotates
  the node: `\operatorname{reshape}(A; \mathrm{shape} = [2, 3])`. Their expression-valued
  fields (`expr`, `filter`, `key`) print as math, every other field as JSON, a string as
  `\text{"…"}` even when it is a name (decided 2026-11-15); an open operator's fields print
  as math whenever they are expressions. Core operator names are
  never template or open-operator names in this form, so it reads back as the core node.
  A template applied with no bindings and no known parameter list is its bare name,
  `\operatorname{n}` / `op("n")`, at the level of a product (so a product with it, a
  power or an index of it, parenthesizes it); `\operatorname{n}()` is an open operator
  with no operands.
* `escape`: the generic node form, `\esm{op}{fields}{args}` / `esm.node("op", fields)[args]`,
  whose arguments are still ordinary math. Since 2026-11-15 it is left for what has no
  other notation: a node annotated with `id` or `expect_cadence` (outside the open
  operators), a field key that is not an identifier, and shapes no notation covers (an
  `index` with one argument, a `D` with no `wrt`, an `ic` of a non-name, …).

A JSON string among a node's fields prints in LaTeX as `\text{"…"}` (decided 2026-11-13, so
that KaTeX in strict mode renders it): printable ASCII as itself, `_`, `{`, `}` as `\_`,
`\{`, `\}`, and every other character as `{\char NNN}` (three decimal digits below 1000,
seven above), so no `$` or line break reaches the LaTeX. The earlier spelling, the string
double-quoted with JSON escapes in math mode, is still read. In Typst the string is a code
string, `#"…"`, which Typst sets whatever it holds.
* `deprecated`: read on input with a warning, rewritten, never printed. -/
inductive Tier where
  | native
  | call
  | escape
  | deprecated
  deriving DecidableEq, Repr

/-- One core operator, or one shape of a core operator when its notation depends on
its fields (`D` with `wrt: "t"` vs a spatial `wrt`, `faq` with the plain semirings vs
the rest, a small vs a large array `const`). -/
structure OpRow where
  op : String
  /-- Which nodes with this `op` the row covers; empty when it covers all of them. -/
  shape : String := ""
  tier : Tier
  latex : String
  typst : String
  deriving Repr

open Tier in
/-- Every evaluable-core operator of spec §4.2, by notation tier. -/
def coreOps : List OpRow := [
  { op := "+", tier := native, latex := "a + b", typst := "a + b" },
  { op := "-", tier := native, latex := "a - b, -a", typst := "a - b, -a" },
  { op := "*", tier := native,
    latex := r"juxtaposition k A B; \cdot when the right factor starts with a digit or sign",
    typst := "k A B, dot" },
  { op := "/", tier := native, latex := r"\frac{a}{b}", typst := "a/b with grouping parentheses" },
  { op := "^", tier := native, latex := "x^{2}", typst := "x^2" },
  { op := "pow", tier := deprecated, latex := "rewritten to ^", typst := "rewritten to ^" },
  { op := "neg", tier := deprecated, latex := "rewritten to unary -", typst := "rewritten to unary -" },
  { op := "<", tier := native, latex := "<", typst := "<" },
  { op := "<=", tier := native, latex := r"\le", typst := "<=" },
  { op := ">", tier := native, latex := ">", typst := ">" },
  { op := ">=", tier := native, latex := r"\ge", typst := ">=" },
  { op := "==", tier := native, latex := "=, parenthesized at equation top level", typst := "=" },
  { op := "!=", tier := native, latex := r"\ne", typst := "!=" },
  { op := "and", tier := native, latex := r"\land", typst := "and" },
  { op := "or", tier := native, latex := r"\lor", typst := "or" },
  { op := "not", tier := native, latex := r"\lnot", typst := "not" },
  { op := "true", tier := native, latex := r"\text{true}", typst := r#""true""# },
  { op := "false", tier := native, latex := r"\text{false}", typst := r#""false""# },
  { op := "ifelse", tier := native,
    latex := "cases; a right-nested chain is one multi-row cases block", typst := "cases(…)" },
  { op := "exp", tier := native, latex := r"\exp(x)", typst := "exp(x)" },
  { op := "log", tier := native, latex := r"\ln(x)", typst := "ln(x)" },
  { op := "log10", tier := native, latex := r"\log_{10}(x)", typst := "log_10(x)" },
  { op := "sqrt", tier := native, latex := r"\sqrt{x}", typst := "sqrt(x)" },
  { op := "abs", tier := native, latex := r"\left|x\right|", typst := "abs(x)" },
  { op := "floor", tier := native, latex := r"\lfloor x \rfloor", typst := "floor(x)" },
  { op := "ceil", tier := native, latex := r"\lceil x \rceil", typst := "ceil(x)" },
  { op := "sin", tier := native, latex := r"\sin", typst := "sin" },
  { op := "cos", tier := native, latex := r"\cos", typst := "cos" },
  { op := "tan", tier := native, latex := r"\tan", typst := "tan" },
  { op := "asin", tier := native, latex := r"\arcsin", typst := "arcsin" },
  { op := "acos", tier := native, latex := r"\arccos", typst := "arccos" },
  { op := "atan", tier := native, latex := r"\arctan", typst := "arctan" },
  { op := "sinh", tier := native, latex := r"\sinh", typst := "sinh" },
  { op := "cosh", tier := native, latex := r"\cosh", typst := "cosh" },
  { op := "tanh", tier := native, latex := r"\tanh", typst := "tanh" },
  { op := "min", tier := native, latex := r"\min(a, b)", typst := "min(a, b)" },
  { op := "max", tier := native, latex := r"\max(a, b)", typst := "max(a, b)" },
  { op := "sign", tier := call, latex := r"\operatorname{sign}(x)", typst := r#"op("sign")(x)"# },
  { op := "atan2", tier := call, latex := r"\operatorname{atan2}(y, x)", typst := r#"op("atan2")(y, x)"# },
  { op := "asinh", tier := call, latex := r"\operatorname{asinh}(x)", typst := r#"op("asinh")(x)"# },
  { op := "acosh", tier := call, latex := r"\operatorname{acosh}(x)", typst := r#"op("acosh")(x)"# },
  { op := "atanh", tier := call, latex := r"\operatorname{atanh}(x)", typst := r#"op("atanh")(x)"# },
  { op := "D", shape := r#"wrt "t" (or absent, normalized to "t")"#, tier := native,
    latex := r"\frac{\mathrm{d} N}{\mathrm{d} t}; compound operand \frac{\mathrm{d}}{\mathrm{d} t}\left(…\right)",
    typst := "(dif N)/(dif t)" },
  { op := "D", shape := r#"any other wrt (read as partial by a loader, spec §4.2 "Reading earlier documents")"#,
    tier := escape,
    latex := r"the escape form \esm{D}{fields}{u}; the earlier \operatorname{D}_{x}(u, a, b) is read as partial",
    typst := r#"the escape form esm.node("D", #(…), u); the earlier op("D")_(x)(u, a, b) is read as partial"# },
  { op := "ic", tier := native, latex := "N(t_{0}) = …, equation left-hand side only",
    typst := "N(t_0) = …" },
  { op := "Pre", tier := call, latex := r"\operatorname{Pre}(x)", typst := r#"op("Pre")(x)"# },
  { op := "enum", tier := call, latex := r"\operatorname{enum}(\mathit{Land}, \mathit{urban})",
    typst := r#"op("enum")(italic("Land"), italic("urban"))"# },
  { op := "const", shape := "scalar", tier := native,
    latex := r"the number; with units 3\,\mathrm{m/s}", typst := r#"3 thin upright("m") thin upright("s")^(-1)"# },
  { op := "const", shape := "array of rank 1 or 2, any size, every entry a number", tier := native,
    latex := r"bmatrix (a column for rank 1; a matrix of more than 10 columns, which bmatrix cannot hold, \left[\begin{array}{c…c} … \end{array}\right] with one c per column); with units, a thin space and the unit after it, as for a scalar: \begin{bmatrix}1\\2\end{bmatrix}\,\mathrm{m}",
    typst := r#"vec(…), mat(…); with units vec(1, 2) thin upright("m")"# },
  { op := "const", shape := "any other const: rank 3 or more, non-number entries, units without a typeset form",
    tier := call,
    latex := r"\operatorname{const}(; \mathrm{value} = [[[1, 2], [3, 4]], …]) with the value as JSON (decided 2026-11-15: an array of any size prints as a matrix; the named reference into a data block decided 2026-11-13 is no longer planned for printing)",
    typst := r#"op("const")(; upright("value") = #(…))"# },
  { op := "index", tier := native, latex := "A_{i, j}; A[i, j] on a subscript collision",
    typst := "A_(i, j)" },
  { op := "faq",
    shape := r#"no semiring (or "sum_product"), reduce "+", "*", "max" or "min"; no join, distinct or key"#,
    tier := native,
    latex := r"one \sum, \prod, \max or \min over all reduced indices. A range prints as k \in S (from), k \in S(i) (from with of) or a \le k \le b (dense [a, b]); a lone dense range as \sum_{k=a}^{b}. Several ranges, then the filter, stack in \substack; a range row is never an expression, so the filter row is unambiguous. Output indices as \left[ … \right] with the same range forms in its subscript. args: empty is unmarked; exactly the arrays the body indexes is \sum\limits; any other list of names is a superscript set, on the operator for rank 0 (\sum_{…}^{\{f, g\}} …, the lone dense range then in the one-row form _{a \le k \le b}) and on the output bracket, before its subscript, otherwise (\left[ … \right]^{\{f\}}_{2 \le i \le N - 1}; decided 2026-11-15)",
    typst := r#"sum_(…), product_(…), max_(…), min_(…) with the same range forms (k in S, k in S(i), a <= k <= b), rows stacked with \ and the filter last; output indices as lr([…])_(…); the args marker limits(sum); a superscript set sum_(…)^({f, g}) and lr([…])^({f})_(…)"# },
  { op := "faq", shape := r#"join, distinct, key, a semiring other than "sum_product", or args that are not names"#,
    tier := call, latex := r"\operatorname{faq}(f; \mathrm{expr} = …, \mathrm{join} = …, …)",
    typst := r#"op("faq")(f; upright("expr") = …, …)"# },
  { op := "makearray", shape := "args [], regions and values of one nonzero length, each region a nonempty list of bound pairs [a, b] of expressions, every value an expression, output_idx absent or a nonempty list of names",
    tier := native,
    latex := r"\left[\begin{array}{l|l} v_{1} & [2, N - 1] \\ v_{2} & [1, 1] \times [2, N] \end{array}\right], rows in JSON order; output_idx as the bracket's subscript \left[…\right]_{i, j} (decided 2026-11-15)",
    typst := r#"mat(delim: "[", augment: #1, v_1, [2, N - 1]; v_2, [1, 1] times [2, N]); output_idx as mat(…)_(i, j)"# },
  { op := "makearray", shape := "any other makearray", tier := call,
    latex := r"\operatorname{makearray}(; \mathrm{regions} = …, \mathrm{values} = …)", typst := r#"op("makearray")(; …)"# },
  { op := "broadcast", tier := call, latex := r#"\operatorname{broadcast}(a, x; \mathrm{fn} = \text{"+"})"#,
    typst := r#"op("broadcast")(a, x; upright("fn") = #"+")"# },
  { op := "reshape", tier := call, latex := r"\operatorname{reshape}(A; \mathrm{shape} = [2, 3])",
    typst := r#"op("reshape")(A; upright("shape") = #(2, 3))"# },
  { op := "transpose", tier := call, latex := r"\operatorname{transpose}(A)", typst := r#"op("transpose")(A)"# },
  { op := "concat", tier := call, latex := r"\operatorname{concat}(a, b; \mathrm{axis} = 0)",
    typst := r#"op("concat")(a, b; upright("axis") = 0)"# },
  { op := "apply_operator", tier := call,
    latex := r"\operatorname{name}(args), positional when the parameters are known, named otherwise; with no bindings and no known parameters the bare \operatorname{name}",
    typst := r#"op("name")(args); bare op("name")"# }
]

/-- The evaluable-core operator names (spec §4.2). `scripts/formal-audit.py notation`
checks this list against the operator tables of spec §4.2, so an operator added to the
spec fails that audit until it is listed here, and then `coreOps_covers` fails until it
has a row. -/
def coreOpNames : List String := [
  "+", "-", "*", "/", "^", "pow", "neg",
  "<", "<=", ">", ">=", "==", "!=", "and", "or", "not", "true", "false", "ifelse",
  "exp", "log", "log10", "sqrt", "abs", "sign", "floor", "ceil",
  "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh",
  "asinh", "acosh", "atanh", "atan2", "min", "max",
  "D", "ic", "Pre", "enum", "const",
  "faq", "makearray", "index", "broadcast", "reshape", "transpose", "concat",
  "apply_operator"
]

open Tier in
/-- The defined operators (spec §9.6.12) with a notation of their own (spec §1.2). Every other
call of a defined operator, and these outside the shapes listed, use the call form; a call
named like a definition key with known parameters uses the escape form. -/
def definedOps : List OpRow := [
  { op := "partial", shape := r#"one operand, wrt a name other than "t", no other field"#, tier := native,
    latex := r"\frac{\partial u}{\partial x}; compound operand \frac{\partial}{\partial x}\left(…\right)",
    typst := "(partial u)/(partial x)" },
  { op := "partial", shape := r#"trailing operands, wrt a name other than "t", no other field"#, tier := native,
    latex := r"\partial_{x}(u, a, b)", typst := "partial_(x)(u, a, b)" },
  { op := "grad", shape := "one operand, no field", tier := native,
    latex := r"\nabla f", typst := "nabla f" },
  { op := "div", shape := "one operand, no field", tier := native,
    latex := r"\nabla \cdot F", typst := "nabla dot F" },
  { op := "laplacian", shape := "one operand, no field", tier := native,
    latex := r"\nabla^{2} u", typst := "nabla^2 u" },
  { op := "curl", shape := "one operand, no field", tier := native,
    latex := r"\nabla \times F", typst := "nabla times F" },
  { op := "any other", shape := "any other call", tier := call,
    latex := r"\operatorname{name}(args; fields)", typst := r#"op("name")(args; fields)"# }
]

/-- No defined operator with a notation of its own is a core operator. -/
theorem definedOps_not_core : ∀ r ∈ definedOps, r.op ∉ coreOpNames := by decide +kernel

/-- Any node carrying `id` or `expect_cadence` prints in its normal notation wrapped
in an annotation (the escape tier's wrapper), whatever its operator. -/
def annotatedNodeFields : List String := ["id", "expect_cadence"]

theorem coreOpNames_nodup : coreOpNames.Nodup := by decide +kernel

/-- Every core operator has at least one notation row. -/
theorem coreOps_covers : ∀ o ∈ coreOpNames, ∃ r ∈ coreOps, r.op = o := by decide +kernel

/-- Every row is for a core operator. -/
theorem coreOps_sound : ∀ r ∈ coreOps, r.op ∈ coreOpNames := by decide +kernel

/-- A deprecated operator has exactly one row, and it is never printed. -/
def deprecatedOps : List String :=
  (coreOps.filter (fun r => r.tier == .deprecated)).map OpRow.op

theorem deprecatedOps_eq : deprecatedOps = ["pow", "neg"] := by decide +kernel

/-! ## Precedence (spec §4.1.1), loosest first

Fractions, roots, subscripts, `cases` and big operators are atoms. A right operand at
the same level is parenthesized unless it is the same n-ary `+`, `*`, `and` or `or`.
A negated sum or difference keeps its parentheses. -/

inductive Assoc where
  | left
  | right
  | pre
  deriving DecidableEq, Repr

structure PrecLevel where
  level : Nat
  ops : List String
  assoc : Assoc
  deriving Repr

/-- `"unary -"` names negation, to keep it apart from binary `-`. -/
def precedence : List PrecLevel := [
  { level := 1, ops := ["or"], assoc := .left },
  { level := 2, ops := ["and"], assoc := .left },
  { level := 3, ops := ["==", "!=", "<", ">", "<=", ">="], assoc := .left },
  { level := 4, ops := ["+", "-"], assoc := .left },
  { level := 5, ops := ["*", "/", "unary -"], assoc := .left },
  { level := 6, ops := ["not"], assoc := .pre },
  { level := 7, ops := ["^"], assoc := .right }
]

/-- Operators a parser flattens into one n-ary node. -/
def flattening : List String := ["+", "*", "and", "or"]

theorem precedence_levels_strict :
    precedence.map PrecLevel.level = [1, 2, 3, 4, 5, 6, 7] := by decide

/-! ## Names -/

/-- The shapes a declared name can take. The printer decides the shape from the name
alone. `single`, `subscripted`, `formula` and `word` partition the names and each keeps
every character of the name, so two distinct names never print alike (a Phase 2 lemma);
the printer never needs `explicit`. -/
inductive NameShape where
  /-- One letter, or a Greek letter name: `T`, `lambda`. Prints italic. -/
  | single
  /-- A single letter or Greek name, `_`, then the rest: `T_air`, `k_1`. The rest is
  an upright subscript. -/
  | subscripted
  /-- A sequence of at least two element-symbol and count tokens: `NO2`, `CH2O`.
  Prints upright with subscripted counts. -/
  | formula
  /-- Any other multi-letter name: `half_life`, `RT`, `k1`. Prints italic as one word
  (ISO 80000-2). -/
  | word
  /-- The literal name in full, `\mathit{…}` / `italic("…")`, accepted on input for ANY
  name and read as that name. It is how an author resolves a juxtaposition the parser
  rejects: with `R`, `T` and `RT` all declared, bare `RT` is refused, and the author
  writes `\mathit{RT}` for the name or `R T` for the product. For a `word` name it is the
  same text as the printed form; for the other shapes it differs (`T_air` prints
  `T_{\mathrm{air}}`, and `\mathit{T\_air}` reads back as the same name). -/
  | explicit
  deriving DecidableEq, Repr

structure NameRule where
  shape : NameShape
  example_ : String
  latex : String
  typst : String
  deriving Repr

def nameRules : List NameRule := [
  { shape := .single, example_ := "lambda", latex := r"\lambda", typst := "lambda" },
  { shape := .subscripted, example_ := "T_air", latex := r"T_{\mathrm{air}}",
    typst := r#"T_(upright("air"))"# },
  { shape := .formula, example_ := "NO2", latex := r"\mathrm{NO_{2}}", typst := r#"upright("NO")_2"# },
  { shape := .word, example_ := "half_life", latex := r"\mathit{half\_life}",
    typst := r#"italic("half_life")"# },
  { shape := .explicit, example_ := "T_air", latex := r"\mathit{T\_air}", typst := r#"italic("T_air")"# }
]

/-- A scoped reference (`Chem.O3`) prints each segment by its own rule, joined by `.`.
Index subscripts are italic expressions (`A_{i, j}`); the subscript of a name is upright
text. A digit subscript that could be either (`k_{1}` for the name `k_1` or index 1 of
an arrayed `k`) prints the index in brackets, `k[1]`. -/
def indexCollisionForm : String := "k[1]"

/-! ## Literals and units -/

/-- Numbers print in the CONFORMANCE §5.5.3.1 canonical spelling: an integral
`Int64`-representable value is an integer with no point (`1.0` prints as `1`); any other
finite value prints its shortest round-trip digits, positional for decimal exponents
-4 to 5 and scientific otherwise. In math, scientific notation is exactly
`<decimal> \times 10^{<integer>}`, read back as one literal (with any spacing, and from an
integer mantissa too); a real product with a power of ten prints with `\cdot`. A negative literal prints as `-3`; unary minus on a
positive literal prints as `-(3)`. A `const` with units prints as the number, a thin
space, then the canonical unit spelling upright: LaTeX `3\,\mathrm{m/s}`, Typst one
`upright("sym")^(exp)` per unit factor, factors separated by `thin` (Typst sets adjacent
`upright` texts with no space), positive exponents first. No unit package is used.
The forms, their parsers and round-trip theorems are `Esm.Units.Typeset`. -/
def scientificLatex : String := r"1.8 \times 10^{-12}"

/-! ## Reactions

mhchem `\ce{…}` in Markdown, typsium `#ce[…]` in Typst, the rate over the arrow. The
printer writes a restricted spelling both packages read correctly: every
stoichiometric coefficient and every non-formula species name is quoted as math, and
an empty side is the empty-set symbol. Names inside the quoted math follow the name rules
(the rate `k_1` is `k_{\mathrm{1}}`, the word name `SO4_aer` is `\mathit{SO4\_aer}`); a
formula-shaped species such as `NO2` is left to the package.

The line (`Esm.Document.Source.Reaction`, decided 2026-11-13 with the native surfaces):

* Markdown: `$$\ce{…}$$ {#id key=value …}` on one line. To remark-math this is a
  paragraph holding inline math with a two-dollar fence (not display math, which needs
  `$$` on lines of its own), and a renderer that does not know the label shows
  `{#id …}` as text. The fence is two dollars because single `$…$` would close at the
  first `$` of a quoted piece. The arrow
  label is braced, `->[{$k$}]`, since mhchem ends the label at the first `]` (an index
  `k[1]` or a `\left[`). The label holds the `id` and the reaction's other fields as
  attributes, in the declaration attribute syntax.
* Typst: `#ce[…] <id>`; a reaction with other fields is `#reaction(key: value, …)[#ce[…]] <id>`.
* A coefficient of 1 is left out. A term without `stoichiometry`, a side `[]`, a reaction
  without `id`, `substrates`, `products` or `rate`, or an id outside letters, digits,
  `_`, `-`, `.` and `:` keeps the whole `reactions` field a path block.
* The id is part of the reaction line, not a skipped label: removing it changes the
  parse.
* What the packages would misread keeps the field a block: an escaped brace `\{` or `\}`
  anywhere inside `\ce{…}` (mhchem matches braces by character), and `//` or `/*` anywhere
  inside `#ce[…]` (a Typst comment would swallow the rest of the line). -/

def reactionLatex : String :=
  r"$$\ce{$\varnothing$ ->[{$k_{\mathrm{1}}$}] $0.5$ $\mathit{SO4\_aer}$ + $2$ NO2}$$ {#R1}"
def reactionTypst : String :=
  r#"#ce[$emptyset$ ->[$k_(upright("1"))$] $0.5$ $italic("SO4_aer")$ + $2$ NO2] <R1>"#

/-- Pinned with the format version. -/
def typstVersion : String := "0.15.1"
def typsiumVersion : String := "0.3.2"

/-! ## Document skeleton

Every schema field has exactly one home. A field with no row falls back to a block
keyed by its JSON path, so a field added to the schema later round-trips with no
grammar change. -/

inductive Home where
  | frontMatter
  | descriptionBlock
  | componentDirective
  | declaration
  | displayMath
  | mathInContainer
  | reactionLine
  | templateDefinition
  | ruleDirective
  | subsystemDirective
  | plotDirective
  /-- `esm:<path>` block in the strict YAML subset (Markdown) or a Typst dictionary,
  with math strings for expression-valued fields. -/
  | pathBlock
  deriving DecidableEq, Repr

structure SkeletonRow where
  field : String
  home : Home
  markdown : String
  typst : String
  deriving Repr

def skeleton : List SkeletonRow := [
  { field := "esm, metadata (except description)", home := .frontMatter,
    markdown := "YAML front matter", typst := r#"#show: esm-document.with(esm: "…", …)"# },
  { field := "metadata.description, component description", home := .descriptionBlock,
    markdown := "```esm:description fenced block", typst := "#description[…]" },
  { field := "models.<name>", home := .componentDirective,
    markdown := "::model[Name]", typst := r#"#model("Name")"# },
  { field := "reaction_systems.<name>", home := .componentDirective,
    markdown := "::reaction-system[Name]", typst := r#"#reaction-system("Name")"# },
  { field := "variables, species, parameters", home := .declaration,
    markdown := r#":var[$N$]{…}, :param, :species; other fields as key=value attributes, each value a YAML scalar or a YAML flow collection; a list or object (empty ones too) single-quoted, with ' written &#39; and & written &amp; inside the quotes (shape='["x", "y"]', update='{…}'), since remark-directive refuses an unquoted value holding a bracket or brace and decodes those character references in a quoted one (decided 2026-11-13); the unquoted form is still read. A string value holding " or & cannot be double-quoted for remark-directive (the YAML escape \" ends the value; & would start a character reference), so a declaration, plot, template or rule with such an attribute stays in its field's block"#,
    typst := "#var($N$, …)" },
  { field := "equations", home := .displayMath,
    markdown := "one $$…$$ per equation, in order", typst := "one $ … $ per equation" },
  { field := "initialization_equations, constraint_equations", home := .mathInContainer,
    markdown := ":::initialization / :::constraints on a line of its own, one $$ display per equation, then :::",
    typst := "#initialization[$ … $] / #constraints[$ … $], one per equation" },
  { field := "reactions", home := .reactionLine,
    markdown := r"one line per reaction, $$\ce{A + B ->[{$k$}] C}$$ {#id key=value}",
    typst := "one line per reaction, #ce[A + B ->[$k$] C] <id>; with other fields #reaction(key: value)[#ce[…]] <id>" },
  { field := "operators (without match), of a component or of the document; defines, units and any other field are attributes (units, an expression, as its JSON value)", home := .templateDefinition,
    markdown := r#"$$, \operatorname{f}(a, b) \coloneqq body on one line, then $$; with other fields (description) the display sits in a container directive holding them, :::template{description="…"} … :::"#,
    typst := r#"$ op("f")(a, b) := body $; with other fields #template(description: "…")[$ op("f")(a, b) := body $]"# },
  { field := "operators (with match), of a component or of the document", home := .ruleDirective,
    markdown := r#"$$, \text{rule } \operatorname{r}: \; lhs \Rightarrow rhs on one line, then $$; params, where, priority and any other field in a container directive around it, :::rule{params='["u"]' priority=1} … :::"#,
    typst := r#"#rule("r", $lhs$, $rhs$, params: ("u",), priority: 1, …)"# },
  { field := "subsystems (by ref)", home := .subsystemDirective,
    markdown := r#"::subsystem[Name]{ref="…" key=value …} on a line of its own; the name is not a declared name of the component"#,
    typst := r#"#subsystem("Name", ref: "…", key: value, …)"# },
  { field := "subsystems (inline, for now)", home := .pathBlock,
    markdown := "the inline entries stay in the subsystems block beside the by-reference directives",
    typst := "same" },
  { field := "subsystems (inline), future work: not printed this way yet", home := .componentDirective,
    markdown := "a nested ::model under a deeper heading", typst := "nested #model" },
  { field := "analyses (one plot)", home := .plotDirective,
    markdown := r#"::plot{key=value …} on one line: the analysis's fields as attributes, its one plot as plot={…}; the whole analyses field is a block unless every analysis has exactly one plot and no field named plot"#,
    typst := r#"#plot(key: value, …, plot: (…)), the same fields"# },
  { field := "everything else", home := .pathBlock,
    markdown := "```esm:<path> block", typst := r#"#esm-block("<path>", (…))"# }
]

/-! ## Expressions inside path blocks

Decided 2026-11-13 ("expression-valued fields inside blocks are math strings"), spelled
2026-11-20: a field of a path block whose schema type is `Expression` holds math when its
value is a well-formed expression whose math text the container can delimit: `$…$` in a
Typst dictionary (Typst math content) for text that is `Json.mathOK`, and the plain
scalar `$…$` in YAML (where a string is always double-quoted) for text that is
`Yaml.plainMathOK` (no `: ` or ` #`, which a YAML parser would read as a mapping or a
comment). Every other value there stays as it is. The math is printed under the section's symbol table (a component's, or the
document's for a top-level block). The reader reads every math leaf back under the same
table, wherever it is (`Source.cookBlocks`); a math leaf anywhere else is refused (the
document read back is not canonical).

The fields are listed as paths from the block's key: `Seg.key k` steps into the entry
`k` of an object, `Seg.any` into every element of an array and every value of an object,
and `Seg.elem` into every element of an array only (a field that is either one object or
an array of them, `ParameterUpdateSpec`, whose object form's own keys are not elements).
Fields with a surface of their own (equations, reactions, templates and rules, which fall
back to a block only when their math cannot be printed natively) are not listed. -/

/-- One step of a path inside a block value. -/
inductive Seg where
  | key (k : String)
  | any
  | elem
  deriving DecidableEq, Repr

open Seg in
/-- The expression-valued fields of a component's path blocks (esm-schema.json:
`Assertion.reference`, `ContinuousEvent.conditions`, `AffectEquation.rhs`,
`DiscreteEventTrigger.expression`, `Model.guesses`, `ParameterUpdate.expression` and
`.when`, `DataSourceBinding.unit_conversion` under `ParameterUpdate.from`; an update is
one rule or an array of them, `ParameterUpdateSpec`). -/
def compExprPaths : List (List Seg) := [
  [key "continuous_events", any, key "affect_neg", any, key "rhs"],
  [key "continuous_events", any, key "affects", any, key "rhs"],
  [key "continuous_events", any, key "conditions", any],
  [key "discrete_events", any, key "affects", any, key "rhs"],
  [key "discrete_events", any, key "trigger", key "expression"],
  [key "guesses", any],
  [key "parameters", any, key "update", key "expression"],
  [key "parameters", any, key "update", key "from", key "unit_conversion"],
  [key "parameters", any, key "update", key "when"],
  [key "parameters", any, key "update", elem, key "expression"],
  [key "parameters", any, key "update", elem, key "from", key "unit_conversion"],
  [key "parameters", any, key "update", elem, key "when"],
  [key "tests", any, key "assertions", any, key "reference"],
  [key "variables", any, key "update", key "expression"],
  [key "variables", any, key "update", key "from", key "unit_conversion"],
  [key "variables", any, key "update", key "when"],
  [key "variables", any, key "update", elem, key "expression"],
  [key "variables", any, key "update", elem, key "from", key "unit_conversion"],
  [key "variables", any, key "update", elem, key "when"]
]

open Seg in
/-- The expression-valued fields of the document's top-level path blocks (the coupling
entries' events and connector equations). -/
def topExprPaths : List (List Seg) := [
  [key "coupling", any, key "affect_neg", any, key "rhs"],
  [key "coupling", any, key "affects", any, key "rhs"],
  [key "coupling", any, key "conditions", any],
  [key "coupling", any, key "connector", key "equations", any, key "expression"],
  [key "coupling", any, key "trigger", key "expression"]
]

/-! ## Templates and rules

`Esm.Document.Source.Skeleton` (`Tm`), decided 2026-11-13 with the native surfaces:

* A template is a display whose math is its header, then `\coloneqq` (`:=` in Typst), then
  its body. The header is `\operatorname{name}(p, q)`: the name as in a template
  application (`\operatorname{}` with `escT`), the parameters as names under the empty
  symbol table, separated by `, `, `()` when there are none. Typst: `op("name")(p, q)`, the
  name a quoted string.
* A rule is `\text{rule } \operatorname{name}: \; lhs \Rightarrow rhs` in a Markdown display;
  in Typst `#rule("name", $lhs$, $rhs$, key: value, …)`. Its parameters are not in the header:
  `params` is an attribute like `where` and `priority`.
* The lexer reads the header (and splits a rule at its first ` \Rightarrow `); only the body
  and the left-hand side are math, read under the component's symbol table (or, at the top
  level of a library file, the document's index sets and templates) with the parameters
  declared. A rule's left-hand side (its `match`) is read with no templates in the
  table: a pattern never applies a template (spec §9.7.3), and an operator in it named like
  a template in scope (the rule itself is in scope under its own name) is then the
  operator, in the call form `\operatorname{r}(f)`, not the escape form (decided
  2026-11-15). The symbol table takes each template's parameter list from its header, never
  from its math.
* Every other field is an attribute. Markdown: the display sits in a container directive,
  `:::template{description="…"}` or `:::rule{params='["u"]' priority=1}`, then the display,
  then a line `:::` (attributes after the closing `$$` would keep remark-math from closing
  the display). Typst: named arguments (a template with fields is `#template(…)[$ … $]`).
* A template or rule prints natively only when its header reads back as written (checked
  by printing it and reading it back) and its math has no `$` or line break; otherwise the
  whole `operators` field is one path block. A display whose math would read as
  a template header is never printed as an equation (the equations field falls back). -/

def templateLatex : String := r"\operatorname{upwind\_flux}(u, c) \coloneqq c u"
def ruleLatex : String := r"\text{rule } \operatorname{Dx}: \; \frac{\partial f}{\partial x} \Rightarrow …"

/-- Skipped by the parser: prose outside these constructs, Typst `<labels>` and `@refs`,
Markdown `{#id}` after an equation. The Phase 3 theorem says inserting or removing them
never changes the parse. A reaction's id label (`{#id}` after its `$$\ce{…}$$`, `<id>`
after its `#ce[…]`) is not skipped: it is part of the reaction line. -/
def skippedConstructs : List String := ["prose", "Typst <label>", "Typst @ref", "Markdown {#id}"]

/-! ## Accepted variants

Spellings the parser reads and normalizes; the printer never writes them. Each math
variant has a Phase 2 lemma in `Esm.Document.Math.Variants` (the variant parses to the
same JSON as the canonical spelling) and hand-written checks in
`Esm.Document.Math.HandWritten`. The document-layer rows have theirs in the Phase 3
document layer: the declarations table in `Esm.Document.Source.Markdown` (`lex_table`),
and aligned blocks, continuation rows and row breaks nested in a delimiter in
`Esm.Document.Source.MultiLine` (`cookRows_layout`; `ckMd_aligned` in
`Esm.Document.Source.MarkdownDoc` for a Markdown `aligned` display); the reaction rows in
`Esm.Document.Source.Reaction` (`pTerm_coef`, `pSpecies_math`), and the container row in
`Esm.Document.Source.Markdown` (`contBody_many`). Unquoted `upright(e)` lexes to the token of
`upright("e")` (`variant_upright_e`); named template arguments in any order read sorted
(`variant_named_args`); a native operator in the call form reads as its native node
(`variant_native_call`). Each gets a Phase 4 fixture. `rejected` rows pin spellings the
parser refuses (the reaction table: `rateTable` in `Esm.Document.Source.Markdown`). -/

inductive Surface where
  | latex
  | typst
  | both
  | markdown
  deriving DecidableEq, Repr

structure Variant where
  spelling : String
  surface : Surface
  readsAs : String
  rejected : Bool := false
  deriving Repr

def variants : List Variant := [
  { spelling := r"\frac{\partial N}{\partial t}, \dot{N}", surface := .latex,
    readsAs := "D(N, wrt t)" },
  { spelling := "dot(N)", surface := .typst, readsAs := "D(N, wrt t)" },
  { spelling := r"\frac{dN}{dt}, \frac{d N}{d t} with an italic d", surface := .latex,
    readsAs := r"D(N, wrt t) only when no variable d is declared, neither dN nor dt written as one word is itself a declared name, and the fraction is exactly d<name> over d<name>; otherwise the fraction reads as written: with d declared, the quotient (d N)/(d t), which is what the printer means by that text; with dN and dt declared, the quotient of those names (a declared whole word wins, as for any word); with only one of them declared, the other word is unknown and the input is refused" },
  { spelling := "(d N)/(d t) with an italic d", surface := .typst,
    readsAs := "D(N, wrt t) under the same conditions as the LaTeX row; otherwise the quotient" },
  { spelling := r#"\mathrm{e}^{x}, upright(e)^x, upright("e")^x"#, surface := .both, readsAs := "exp(x), always" },
  { spelling := "e^{x}, e^x with an italic e", surface := .both,
    readsAs := "exp(x) only when no variable e is declared (a bare undeclared e is otherwise an error, so this changes the reading of no valid document); with e declared, the variable e raised to x" },
  { spelling := r"\log", surface := .latex, readsAs := r"log, the same as \ln" },
  { spelling := r"\left( \right), ( ), \bigl( \bigr)", surface := .both, readsAs := "grouping" },
  { spelling := "[ ] where no operand precedes it: at the start of an expression, after an operator, or after an opening delimiter",
    surface := .both, readsAs := "grouping" },
  { spelling := r"\cdot, \times, juxtaposition", surface := .both,
    readsAs := "* (except the scientific-literal shape)" },
  { spelling := "a / b inline", surface := .latex, readsAs := "/" },
  { spelling := r"\leq \geq \neq", surface := .latex, readsAs := "comparisons" },
  { spelling := r"k-1, k -1: a minus sign written against the number after an operand", surface := .both,
    readsAs := r"binary minus, k - 1; a negative literal only where no operand precedes it (at the start, after an operator or an opening delimiter: -1, a \cdot -1, x^{-1}); -0 is a minus sign and 0" },
  { spelling := r"scientific literal with any spacing: 2	imes10^{3}, 2 	imes  10 ^ {3}, 2times 10^( 3 ); an integer mantissa", surface := .both,
    readsAs := r"the one literal, as 2 	imes 10^{3} (a non-integer exponent, 3 	imes 10^{n}, is an ordinary product)" },
  { spelling := r"\, between operands (k\,T)", surface := .latex,
    readsAs := r"a space; \, is the unit separator only right before \mathrm{…} spelling a unit" },
  { spelling := "[i, j] directly after an operand (a name, a closing ) or ]), in any position",
    surface := .both,
    readsAs := r"index, never a product: k [A + B] is index(k, A + B); the faq output form \left[ … \right]_{i \in S} is a whole term, so x \left[ … \right]_{i \in S} is a product" },
  { spelling := r#"\mathit{name}, italic("name") for any name"#, surface := .both,
    readsAs := "that name (the explicit name shape); bare juxtaposition that could be one name or a product of several is rejected" },
  { spelling := "named template arguments, in any order", surface := .both,
    readsAs := "apply_operator, the bindings sorted (two arguments with one name are refused)" },
  { spelling := r#"\operatorname{D}_{x}(u, a, b), op("D")_(x)(u, a, b): the earlier trailing-operand form"#,
    surface := .both, readsAs := r"partial(u, a, b; wrt: x), as \partial_{x}(u, a, b)" },
  { spelling := r"\frac{\partial N}{\partial x}, (partial N)/(partial x), \frac{dN}{dx}: a derivative along an axis other than t",
    surface := .both, readsAs := "partial(N; wrt: x), never D" },
  { spelling := r#"a native operator in the call form: \operatorname{exp}(x), op("exp")(x)"#, surface := .both,
    readsAs := "the native node, exp(x)" },
  { spelling := "per-model declarations table", surface := .markdown, readsAs := "the declarations" },
  { spelling := ":::initialization or :::constraints holding several displays, blank lines between",
    surface := .markdown, readsAs := "consecutive initialization equations or constraints" },
  { spelling := r"a stoichiometric coefficient of 1 written out ($1$ A)", surface := .both,
    readsAs := "coefficient 1" },
  { spelling := r#"a formula-shaped species written as math ($\mathrm{NO_{2}}$, $upright("NO")_2$)"#,
    surface := .both, readsAs := "that species" },
  { spelling := "pow(x, n) and neg(x) in the call form", surface := .both,
    readsAs := "x ^ n and -x, with the deprecation warning" },
  { spelling := r"several equations in one aligned block (Typst $ … $ with \ and &): a row with something before its first & starts a new equation",
    surface := .both, readsAs := "consecutive equations" },
  { spelling := r"aligned row with an empty left cell (&\quad + k_{2} B); every \\ in split and multline",
    surface := .both, readsAs := "a continuation of one equation; printed on one line" },
  { spelling := "row breaks inside cases, bmatrix and similar", surface := .both,
    readsAs := "never split an equation; only top-level breaks count" },
  { spelling := "a continuation row starting with its own = (&= …)", surface := .both,
    readsAs := "an equation has one top-level =", rejected := true },
  { spelling := "reaction table with a rate column (a table row with a cell rate at the start of a line)",
    surface := .markdown, readsAs := "not a reaction notation; refused, never skipped as prose",
    rejected := true }
]

/-! ## Canonical-form spelling rules

Redundant spellings the canonical form merges (landing with the canonical unit spelling).
`esm-lean canon` (`spellRules` in `Adapter/Doc.lean`) applies the `neg`, `pow` and `faq`
default-field rules (the last as `faqDefaults`) and
respells every `units` and `default_units` string (`Esm.Units.canon`, under which `""`,
`"1"` and `"dimensionless"` are all `"1"`); a `const` node whose units spell `"1"` drops
them, so one whose value is a number is that bare number, whatever other fields it has
(ruling 2026-11-14; a declaration keeps `units: "1"`).

Only the unit respelling is proved: `Esm.Units.canon` keeps the unit a string resolves to
(`resolve_canon`, `resolve_of_canon` in `Esm.Units.Canonical`). The other rules, and the
walk that decides which fields are units strings and which objects are name-keyed maps or
free-form (key lists copied from esm-schema.json), are adapter code with no proof that they
preserve meaning. They are pinned instead by the golden files every binding and `esm-lean`
are checked against: `tests/conformance/canonical_document/` and
`tests/conformance/document_format/`. -/

structure SpellingRule where
  from_ : String
  into : String
  corpusCount : Nat
  deriving Repr

def spellingRules : List SpellingRule := [
  { from_ := r#"faq with reduce "+" and/or semiring "sum_product""#, into := "faq with neither field",
    corpusCount := 463 },
  { from_ := "faq that reduces no index but sets reduce or semiring", into := "the field dropped",
    corpusCount := 110 },
  { from_ := "neg(x)", into := "-(x)", corpusCount := 53 },
  { from_ := "const scalar with no units", into := "the bare number", corpusCount := 18 },
  { from_ := "D with wrt absent", into := r#"D with wrt "t""#, corpusCount := 4 },
  { from_ := "pow(x, n)", into := "x ^ n", corpusCount := 1 },
  { from_ := "apply_expression_template (spec §9.6.12, old name)", into := "apply_operator", corpusCount := 804 },
  { from_ := "expression_template_imports (old name)", into := "operator_imports", corpusCount := 212 },
  { from_ := "expression_templates (old name)", into := "operators", corpusCount := 196 },
  { from_ := r#"D with wrt present and not "t" (spec §4.2, unless the wrt is a parameter of the enclosing definition), δ, ∂"#,
    into := "partial", corpusCount := 140 }
]

end Esm.Document.Notation
