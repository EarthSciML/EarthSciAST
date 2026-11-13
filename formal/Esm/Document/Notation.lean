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
* Expression-valued fields inside blocks are math strings; an equation's `_comment`
  is a comment line inside its math.
* Models and reaction systems keep separate directives.
-/

namespace Esm.Document.Notation

/-! ## Operators (spec §4.2) -/

/-- How an operator is written.

* `native`: conventional notation.
* `call`: `\operatorname{name}(…)` in LaTeX, `op("name")(…)` in Typst. Every open
  (rewrite-target) operator and every template application also uses this form,
  with node fields such as `dim` as named arguments after a semicolon.
* `escape`: the generic node form, `\esm{op}{fields}{args}` / `esm.node("op", fields)[args]`,
  whose arguments are still ordinary math.
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
  { op := "D", shape := "spatial wrt", tier := native,
    latex := r"\frac{\partial u}{\partial x}; with trailing operands \operatorname{D}_{x}(u, a, b)",
    typst := r#"(partial u)/(partial x); with trailing operands op("D")_(x)(u, a, b)"# },
  { op := "ic", tier := native, latex := "N(t_{0}) = …, equation left-hand side only",
    typst := "N(t_0) = …" },
  { op := "Pre", tier := call, latex := r"\operatorname{Pre}(x)", typst := r#"op("Pre")(x)"# },
  { op := "enum", tier := call, latex := r"\operatorname{enum}(\mathit{Land}, \mathit{urban})",
    typst := r#"op("enum")(italic("Land"), italic("urban"))"# },
  { op := "const", shape := "scalar", tier := native,
    latex := r"the number; with units 3\,\mathrm{m/s}", typst := r#"3 thin upright("m")\/upright("s")"# },
  { op := "const", shape := "array of at most 16 entries", tier := native,
    latex := r"bmatrix (a column for rank 1); with units, a thin space and the unit after it, as for a scalar: egin{bmatrix}1\2\end{bmatrix}\,\mathrm{m}",
    typst := r#"vec(…), mat(…); with units vec(1, 2) thin upright("m")"# },
  { op := "const", shape := "array of more than 16 entries", tier := escape,
    latex := "a named reference into a data block keyed by the JSON path; the block holds the values and the units",
    typst := "same" },
  { op := "index", tier := native, latex := "A_{i, j}; A[i, j] on a subscript collision",
    typst := "A_(i, j)" },
  { op := "faq",
    shape := r#"no semiring (or "sum_product"), reduce "+", "*", "max" or "min"; no join, distinct or key"#,
    tier := native,
    latex := r"one \sum, \prod, \max or \min over all reduced indices. A range prints as k \in S (from), k \in S(i) (from with of) or a \le k \le b (dense [a, b]); a lone dense range as \sum_{k=a}^{b}. Several ranges, then the filter, stack in \substack; a range row is never an expression, so the filter row is unambiguous. Output indices as \left[ … \right] with the same range forms in its subscript",
    typst := r#"sum_(…), product_(…), max_(…), min_(…) with the same range forms (k in S, k in S(i), a <= k <= b), rows stacked with \ and the filter last; output indices as lr([…])_(…)"# },
  { op := "faq", shape := r#"join, distinct, key, or a semiring other than "sum_product""#, tier := escape,
    latex := r"\esm", typst := "esm.node" },
  { op := "makearray", tier := escape, latex := r"\esm", typst := "esm.node" },
  { op := "broadcast", tier := escape, latex := r"\esm", typst := "esm.node" },
  { op := "reshape", tier := escape, latex := r"\esm", typst := "esm.node" },
  { op := "transpose", tier := escape, latex := r"\esm", typst := "esm.node" },
  { op := "concat", tier := escape, latex := r"\esm", typst := "esm.node" },
  { op := "apply_expression_template", tier := call,
    latex := r"\operatorname{name}(args), positional when the parameters are known, named otherwise",
    typst := r#"op("name")(args)"# }
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
  "apply_expression_template"
]

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
`<decimal> \times 10^{<integer>}`, read back as one literal; a real product with a
power of ten prints with `\cdot`. A negative literal prints as `-3`; unary minus on a
positive literal prints as `-(3)`. A `const` with units prints as the number, a thin
space, then the canonical unit spelling upright: LaTeX `3\,\mathrm{m/s}`, Typst one
`upright("sym")^(exp)` per unit factor. No unit package is used. -/
def scientificLatex : String := r"1.8 \times 10^{-12}"

/-! ## Reactions

mhchem `\ce{…}` in Markdown, typsium `#ce[…]` in Typst, the rate over the arrow. The
printer writes a restricted spelling both packages read correctly: every
stoichiometric coefficient and every non-formula species name is quoted as math, and
an empty side is the empty-set symbol. Names inside the quoted math follow the name rules
(the rate `k_1` is `k_{\mathrm{1}}`, the word name `SO4_aer` is `\mathit{SO4\_aer}`); a
formula-shaped species such as `NO2` is left to the package. -/

def reactionLatex : String :=
  r"\ce{$\varnothing$ ->[$k_{\mathrm{1}}$] $0.5$ $\mathit{SO4\_aer}$ + $2$ NO2}"
def reactionTypst : String :=
  r#"#ce[$emptyset$ ->[$k_(upright("1"))$] $0.5$ $italic("SO4_aer")$ + $2$ NO2]"#

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
    markdown := ":var[$N$]{…}, :param, :species; other fields as attributes in the YAML subset",
    typst := "#var($N$, …)" },
  { field := "equations", home := .displayMath,
    markdown := "one $$…$$ per equation, in order", typst := "one $ … $ per equation" },
  { field := "initialization_equations, constraint_equations", home := .mathInContainer,
    markdown := ":::initialization / :::constraints", typst := "#initialization[$ … $]" },
  { field := "reactions", home := .reactionLine,
    markdown := r"one line per reaction, id as label, \ce{A + B ->[$k$] C}",
    typst := "one line per reaction, #ce[A + B ->[$k$] C]" },
  { field := "expression_templates (without match)", home := .templateDefinition,
    markdown := r"$$ \operatorname{f}(a, b) \coloneqq … $$", typst := r#"$ op("f")(a, b) := … $"# },
  { field := "expression_templates (with match)", home := .ruleDirective,
    markdown := r"$$ \text{rule } r: \; lhs \Rightarrow rhs $$; where and priority as attributes",
    typst := r#"#rule("r", $lhs$, $rhs$, …)"# },
  { field := "subsystems (by ref)", home := .subsystemDirective,
    markdown := r#"::subsystem[Name]{ref="…"}"#, typst := r#"#subsystem("Name", ref: "…")"# },
  { field := "subsystems (inline)", home := .componentDirective,
    markdown := "a nested ::model under a deeper heading", typst := "nested #model" },
  { field := "analyses (one plot)", home := .plotDirective,
    markdown := "::plot{…}", typst := "#plot(…)" },
  { field := "everything else", home := .pathBlock,
    markdown := "```esm:<path> block", typst := r#"#esm-block("<path>", (…))"# }
]

/-- Skipped by the parser: prose outside these constructs, Typst `<labels>` and `@refs`,
Markdown `{#id}` after an equation. The Phase 3 theorem says inserting or removing them
never changes the parse. -/
def skippedConstructs : List String := ["prose", "Typst <label>", "Typst @ref", "Markdown {#id}"]

/-! ## Accepted variants

Spellings the parser reads and normalizes; the printer never writes them. Each gets a
Phase 2 lemma (the variant parses to the same JSON as the canonical spelling) and a
Phase 4 fixture. `rejected` rows pin spellings the parser refuses. -/

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
    readsAs := r"D(N, wrt t) only when no variable d is declared and the fraction is exactly d<name> over d<name>; with d declared, the quotient (d N)/(d t), which is what the printer means by that text" },
  { spelling := "(d N)/(d t) with an italic d", surface := .typst,
    readsAs := "D(N, wrt t) under the same condition as the LaTeX row; otherwise the quotient" },
  { spelling := r#"\mathrm{e}^{x}, upright(e)^x"#, surface := .both, readsAs := "exp(x), always" },
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
  { spelling := "[i, j] directly after an operand (a name, a closing ) or ]), in any position",
    surface := .both,
    readsAs := r"index, never a product: k [A + B] is index(k, A + B); the faq output form \left[ … \right]_{i \in S} is a whole term, so x \left[ … \right]_{i \in S} is a product" },
  { spelling := r#"\mathit{name}, italic("name") for any declared name"#, surface := .both,
    readsAs := "that name (the explicit name shape); bare juxtaposition that could be one name or a product of several is rejected" },
  { spelling := "named template arguments", surface := .both, readsAs := "apply_expression_template" },
  { spelling := "per-model declarations table", surface := .markdown, readsAs := "the declarations" },
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
  { spelling := "reaction table with a rate column", surface := .markdown,
    readsAs := "not a reaction notation", rejected := true }
]

/-! ## Canonical-form spelling rules

Redundant spellings the canonical form merges (landing with the canonical unit spelling).
Each rule gets a Lean proof that it preserves meaning. -/

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
  { from_ := "pow(x, n)", into := "x ^ n", corpusCount := 1 }
]

end Esm.Document.Notation
