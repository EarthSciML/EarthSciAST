import Esm.Expr.Core

/-!
# Expanding a match-less expression template (esm-spec §9.6.1–9.6.3)

`expand t bindings` is the expansion an `apply_expression_template` node
denotes (§9.6.2, §9.6.4 rule 2): after the §9.6.3 constraint 3 check (the
bindings cover the template's `params` exactly), every parameter occurrence in
the body is replaced by its bound AST — §9.6.3 constraint 5, pure syntactic
substitution, no evaluation:

* a bare parameter-name string in a variable-reference position (`Ast.var`),
  anywhere, including a `faq`'s `args` list and the inside of its `expr`;
* a `faq` dense `ranges` tuple entry (§9.6.1: `"ranges": {"k": [1, "n"]}`
  with `"n": 5` becomes `[1, 5]`), which `Ast` holds as expressions, so it is
  the same rule;
* a scalar Expression-node field whose string value is a parameter name (here
  `reduce` and the `output_idx` entries). The value substituted MUST be a
  literal admissible for the field, which substitution does not check
  (§9.6.3 constraint 5): a bare name is substituted as that string, and any
  other bound AST leaves the empty string, which no field admits, so the
  node's own evaluation refuses it.

Params shadow coincident literals and index symbols (§9.6.1), which
position-blind substitution gives for free. `ranges` keys are object keys, not
string values, so they are not substitution sites. Nested
`apply_expression_template` references are outside the modelled slice.
-/

namespace Esm.Expr

/-- A match-less `expression_templates` entry (§9.6.1). -/
structure Template where
  params : List String
  body : Ast

abbrev Bindings := List (String × Ast)

/-- The value a scalar field takes when its string is a parameter name. -/
def fieldSub (σ : Bindings) (s : String) : String :=
  match σ.lookup s with
  | some (.var t) => t
  | some _ => ""
  | none => s

mutual

/-- §9.6.3 constraint 5: substitute every parameter occurrence. -/
def subst (σ : Bindings) : Ast → Ast
  | .num m e => .num m e
  | .var s =>
    match σ.lookup s with
    | some a => a
    | none => .var s
  | .const c => .const c
  | .node op args => .node op (substList σ args)
  | .faq out red rs body args =>
    .faq (out.map (fieldSub σ)) (fieldSub σ red) (substRanges σ rs) (subst σ body)
      (substList σ args)

def substList (σ : Bindings) : List Ast → List Ast
  | [] => []
  | a :: as => subst σ a :: substList σ as

def substRanges (σ : Bindings) : Ranges → Ranges
  | .nil => .nil
  | .cons k t rs => .cons k (substList σ t) (substRanges σ rs)

end

inductive ExpandError where
  /-- §9.6.3 constraint 3: a parameter with no binding. -/
  | missingBinding (p : String)
  /-- §9.6.3 constraint 3: a binding for no parameter, or two for one. -/
  | extraBinding (b : String)

/-- The expansion of `apply_expression_template` on `t` with `bindings`. -/
def expand (t : Template) (σ : Bindings) : Except ExpandError Ast :=
  match t.params.find? (fun p => !(σ.any (·.1 == p))) with
  | some p => .error (.missingBinding p)
  | none =>
    match σ.find? (fun b => !(t.params.contains b.1) || σ.countP (·.1 == b.1) ≠ 1) with
    | some b => .error (.extraBinding b.1)
    | none => .ok (subst σ t.body)

end Esm.Expr
