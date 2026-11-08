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
string values, so they are not substitution sites; nor are a nested
`apply_expression_template` reference's `name` and binding keys, while its
binding values are expressions and are substituted.

A template body may reference other match-less templates in scope (§9.7.3); a
reference denotes its expansion (§9.6.4 rule 2). `expandRefs lib fuel`
replaces every reference, bindings first, by the expansion of the template
`lib` names, recursively, `fuel` levels deep (§9.7.3 bounds a chain at
`MAX_TEMPLATE_EXPANSION_DEPTH = 32`); a reference left at depth 0, or one
naming no template of `lib`, is an error. `expandIn` and `evalApplyIn` are
`expand` and `evalApply` followed by it.
-/

namespace Esm.Expr

open Esm.Closed (Scalar)

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
  | .faqWhere out red rs p body args =>
    .faqWhere (out.map (fieldSub σ)) (fieldSub σ red) (substRanges σ rs) (subst σ p)
      (subst σ body) (substList σ args)
  | .apply n bs => .apply n (substBinds σ bs)

def substList (σ : Bindings) : List Ast → List Ast
  | [] => []
  | a :: as => subst σ a :: substList σ as

def substRanges (σ : Bindings) : Ranges → Ranges
  | .nil => .nil
  | .cons k t rs => .cons k (substList σ t) (substRanges σ rs)
  | .fromSet k set rs => .fromSet k (fieldSub σ set) (substRanges σ rs)

def substBinds (σ : Bindings) : Binds → Binds
  | .nil => .nil
  | .cons p v bs => .cons p (subst σ v) (substBinds σ bs)

end

inductive ExpandError where
  /-- §9.6.3 constraint 3: a parameter with no binding. -/
  | missingBinding (p : String)
  /-- §9.6.3 constraint 3: a binding for no parameter, or two for one. -/
  | extraBinding (b : String)
  /-- A reference to a template not in scope. -/
  | unknownTemplate (n : String)
  /-- §9.7.3: a reference chain deeper than the bound. -/
  | tooDeep

/-- The expansion of `apply_expression_template` on `t` with `bindings`. -/
def expand (t : Template) (σ : Bindings) : Except ExpandError Ast :=
  match t.params.find? (fun p => !(σ.any (·.1 == p))) with
  | some p => .error (.missingBinding p)
  | none =>
    match σ.find? (fun b => !(t.params.contains b.1) || σ.countP (·.1 == b.1) ≠ 1) with
    | some b => .error (.extraBinding b.1)
    | none => .ok (subst σ t.body)

/-- The `bindings` of a reference as a list. -/
def Binds.toList : Binds → Bindings
  | .nil => []
  | .cons p v bs => (p, v) :: bs.toList

mutual

/-- Apply `f` at every `apply_expression_template` node, bottom-up (a
reference's bindings first), rebuilding the rest of the tree. -/
def walkRefs (f : String → Binds → Except ExpandError Ast) : Ast → Except ExpandError Ast
  | .num m e => .ok (.num m e)
  | .var s => .ok (.var s)
  | .const c => .ok (.const c)
  | .node op args => do return .node op (← walkRefsList f args)
  | .faq out red rs body args => do
    return .faq out red (← walkRefsRanges f rs) (← walkRefs f body) (← walkRefsList f args)
  | .faqWhere out red rs p body args => do
    return .faqWhere out red (← walkRefsRanges f rs) (← walkRefs f p) (← walkRefs f body)
      (← walkRefsList f args)
  | .apply n bs => do f n (← walkRefsBinds f bs)

def walkRefsList (f : String → Binds → Except ExpandError Ast) :
    List Ast → Except ExpandError (List Ast)
  | [] => .ok []
  | a :: as => do return (← walkRefs f a) :: (← walkRefsList f as)

def walkRefsRanges (f : String → Binds → Except ExpandError Ast) :
    Ranges → Except ExpandError Ranges
  | .nil => .ok .nil
  | .cons k t rs => do return .cons k (← walkRefsList f t) (← walkRefsRanges f rs)
  | .fromSet k set rs => do return .fromSet k set (← walkRefsRanges f rs)

def walkRefsBinds (f : String → Binds → Except ExpandError Ast) :
    Binds → Except ExpandError Binds
  | .nil => .ok .nil
  | .cons p v bs => do return .cons p (← walkRefs f v) (← walkRefsBinds f bs)

end

/-- Replace every reference by its expansion through the templates of `lib`,
at most `fuel` levels deep (§9.7.3, §9.6.4 rule 2). -/
def expandRefs (lib : List (String × Template)) : Nat → Ast → Except ExpandError Ast
  | 0 => walkRefs (fun _ _ => .error .tooDeep)
  | fuel + 1 => walkRefs (fun n bs =>
      match lib.lookup n with
      | none => .error (.unknownTemplate n)
      | some t => do expandRefs lib fuel (← expand t bs.toList))

/-- The expansion of a reference to `t` whose body may reference the templates
of `lib`. -/
def expandIn (lib : List (String × Template)) (fuel : Nat) (t : Template) (σ : Bindings) :
    Except ExpandError Ast := do
  expandRefs lib fuel (← expand t σ)

inductive ApplyError where
  | expand (e : ExpandError)
  | eval (e : EvalError)

/-- The value of an `apply_expression_template` node: expand, then evaluate
the expansion (§9.6.4 rule 2: a reference denotes its expansion). -/
def evalApply {α : Type} [Scalar α] [Lits α] [Elem α] (t : Template) (σ : Bindings) (env : Env α) :
    Except ApplyError (Val α) :=
  match expand t σ with
  | .error e => .error (.expand e)
  | .ok a =>
    match eval a env with
    | .ok v => .ok v
    | .error e => .error (.eval e)

end Esm.Expr

namespace Esm.Expr

open Esm.Closed (Scalar)

/-- `evalApply` for a template whose body references other templates of
`lib`: expand everything (`expandIn`), then evaluate. -/
def evalApplyIn {α : Type} [Scalar α] [Lits α] [Elem α] (lib : List (String × Template))
    (fuel : Nat) (t : Template) (σ : Bindings) (env : Env α) : Except ApplyError (Val α) :=
  match expandIn lib fuel t σ with
  | .error e => .error (.expand e)
  | .ok a =>
    match eval a env with
    | .ok v => .ok v
    | .error e => .error (.eval e)

end Esm.Expr
