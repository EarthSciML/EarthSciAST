import Esm.Expr.Template

/-! Stability of explicit template expansion (§9.6.4 rule 2). A successful
expansion is independent of excess fuel and of the order of the registry when
the lookup for each definition name is unchanged. -/

namespace Esm.Expr

private def KeepsSuccess {α : Type} (left right : Except ExpandError α) : Prop :=
  ∀ result, left = .ok result → right = .ok result

private theorem keepsSelf {α : Type} (value : Except ExpandError α) : KeepsSuccess value value :=
  fun _ equal => equal

private theorem keepsBind {α β : Type} {left right : Except ExpandError α}
    {f g : α → Except ExpandError β} (input : KeepsSuccess left right)
    (continuation : ∀ value, KeepsSuccess (f value) (g value)) :
    KeepsSuccess (left >>= f) (right >>= g) := by
  intro result equal
  cases h : left with
  | error err => simp [h, bind, Except.bind] at equal
  | ok value =>
    have rightEq := input value h
    rw [rightEq]
    exact continuation value result (by simpa [h, bind, Except.bind] using equal)

mutual

private theorem walkKeeps (f g : String → Binds → Except ExpandError Ast)
    (refines : ∀ name bindings, KeepsSuccess (f name bindings) (g name bindings)) :
    ∀ term, KeepsSuccess (walkRefs f term) (walkRefs g term)
  | .num _ _ | .var _ | .const _ => keepsSelf _
  | .node _ args | .array _ args => keepsBind (listKeeps f g refines args) fun _ => keepsSelf _
  | .faq _ _ ranges value args =>
    keepsBind (rangesKeep f g refines ranges) fun _ =>
      keepsBind (walkKeeps f g refines value) fun _ =>
        keepsBind (listKeeps f g refines args) fun _ => keepsSelf _
  | .faqWhere _ _ ranges filter value args =>
    keepsBind (rangesKeep f g refines ranges) fun _ =>
      keepsBind (walkKeeps f g refines filter) fun _ =>
        keepsBind (walkKeeps f g refines value) fun _ =>
          keepsBind (listKeeps f g refines args) fun _ => keepsSelf _
  | .faqJoin _ _ ranges _ filter value args =>
    keepsBind (rangesKeep f g refines ranges) fun _ =>
      keepsBind (walkKeeps f g refines filter) fun _ =>
        keepsBind (walkKeeps f g refines value) fun _ =>
          keepsBind (listKeeps f g refines args) fun _ => keepsSelf _
  | .apply name bindings => keepsBind (bindsKeep f g refines bindings) (refines name)

private theorem listKeeps (f g : String → Binds → Except ExpandError Ast)
    (refines : ∀ name bindings, KeepsSuccess (f name bindings) (g name bindings)) :
    ∀ args, KeepsSuccess (walkRefsList f args) (walkRefsList g args)
  | [] => keepsSelf _
  | a :: rest => keepsBind (walkKeeps f g refines a) fun _ =>
      keepsBind (listKeeps f g refines rest) fun _ => keepsSelf _

private theorem rangesKeep (f g : String → Binds → Except ExpandError Ast)
    (refines : ∀ name bindings, KeepsSuccess (f name bindings) (g name bindings)) :
    ∀ ranges, KeepsSuccess (walkRefsRanges f ranges) (walkRefsRanges g ranges)
  | .nil => keepsSelf _
  | .cons _ args rest => keepsBind (listKeeps f g refines args) fun _ =>
      keepsBind (rangesKeep f g refines rest) fun _ => keepsSelf _
  | .fromSet _ _ rest | .fromRagged _ _ _ rest =>
    keepsBind (rangesKeep f g refines rest) fun _ => keepsSelf _

private theorem bindsKeep (f g : String → Binds → Except ExpandError Ast)
    (refines : ∀ name bindings, KeepsSuccess (f name bindings) (g name bindings)) :
    ∀ bindings, KeepsSuccess (walkRefsBinds f bindings) (walkRefsBinds g bindings)
  | .nil => keepsSelf _
  | .cons _ v rest => keepsBind (walkKeeps f g refines v) fun _ =>
      keepsBind (bindsKeep f g refines rest) fun _ => keepsSelf _

end

/-- A larger fuel bound preserves an already successful explicit expansion,
including expansions whose references occur inside other references' bindings. -/
theorem expandRefs_of_le (lib : List (String × Template)) (fuel larger : Nat)
    (budget : fuel ≤ larger) (term result : Ast) (expanded : expandRefs lib fuel term = .ok result) :
    expandRefs lib larger term = .ok result := by
  induction fuel generalizing larger term result with
  | zero =>
    cases larger with
    | zero => exact expanded
    | succ larger =>
      apply walkKeeps _ _ _ term result expanded
      intro _ _ _ impossible
      cases impossible
  | succ fuel ih =>
    cases larger with
    | zero => omega
    | succ larger =>
      apply walkKeeps _ _ _ term result expanded
      intro name bindings
      cases lib.lookup name with
      | none => exact keepsSelf _
      | some definition =>
        exact keepsBind (keepsSelf (expand definition bindings.toList)) fun body output resultEq =>
          ih larger (by omega) body output resultEq

/-- Keeping the same name lookup while changing registry order preserves
successful expansions. -/
theorem expandRefs_of_lookup_eq (left right : List (String × Template))
    (lookup : ∀ name, left.lookup name = right.lookup name) (fuel : Nat) (term result : Ast)
    (expanded : expandRefs left fuel term = .ok result) : expandRefs right fuel term = .ok result := by
  induction fuel generalizing term result with
  | zero => exact expanded
  | succ fuel ih =>
    apply walkKeeps _ _ _ term result expanded
    intro name bindings
    rw [← lookup name]
    cases left.lookup name with
    | none => exact keepsSelf _
    | some definition =>
      exact keepsBind (keepsSelf (expand definition bindings.toList)) fun body output resultEq =>
        ih body output resultEq

/-- Two successful explicit expansions with the same definition lookup agree
exactly, even when their traversal budgets differ. -/
theorem expandRefs_unique (left right : List (String × Template))
    (lookup : ∀ name, left.lookup name = right.lookup name) (leftFuel rightFuel : Nat)
    (term leftResult rightResult : Ast) (leftOk : expandRefs left leftFuel term = .ok leftResult)
    (rightOk : expandRefs right rightFuel term = .ok rightResult) : leftResult = rightResult := by
  have leftCommon := expandRefs_of_le left leftFuel (max leftFuel rightFuel)
    (Nat.le_max_left _ _) term leftResult leftOk
  have rightCommon := expandRefs_of_le right rightFuel (max leftFuel rightFuel)
    (Nat.le_max_right _ _) term rightResult rightOk
  have equal := expandRefs_of_lookup_eq left right lookup _ term leftResult leftCommon
  exact Except.ok.inj (equal.symm.trans rightCommon)

/-- Instantiating an outer body does not bind a same-spelled free name in a
separate nested definition. The nested definition is expanded in its own scope. -/
theorem expandRefs_preserves_nested_free_name (outer inner parameter : String)
    (different : outer ≠ inner) (coefficient : Int) (exponent : Nat) :
    expandRefs [(outer, ⟨[parameter], .apply inner .nil⟩), (inner, ⟨[], .var parameter⟩)] 2
      (.apply outer (.cons parameter (.num coefficient exponent) .nil)) = .ok (.var parameter) := by
  have differentBEq : (inner == outer) = false := beq_eq_false_iff_ne.2 different.symm
  simp [expandRefs, walkRefs, walkRefsBinds, Binds.toList, expand, subst, substBinds,
    List.lookup, differentBEq, bind, Except.bind, pure, Except.pure]

end Esm.Expr
