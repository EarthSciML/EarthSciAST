import Esm.Expr.Canonical
import Esm.Units.Canonical
import Mathlib.Order.Prod.Lex.Basic

/-! The typed expression tree and executable canonicalization of discretization
RFC §5.4. The wire adapter supplies compact JSON and binary64 rounding. -/

namespace Esm.Expr.Canonical.Typed

inductive Literal where
  | int (value : Int)
  | float (negative : Bool) (significand : Nat) (exponent : Int)

inductive Payload where
  | number (value : Literal)
  | string (value : String)
  | bool (value : Bool)
  | null
  | array (values : List Payload)

inductive Expression where
  | number (value : Literal)
  | reference (name : String)
  | node (op : String) (args : List Expression) (fields : List (String × Payload))

structure Failure where
  code : String
  path : String
  message : String
  deriving Inhabited

def invalid (path message : String) : Failure :=
  ⟨"E_CANONICAL_INVALID_EXPRESSION", path, message⟩

def nonFinite (path : String) : Failure :=
  ⟨"E_CANONICAL_NONFINITE", path, "float is outside the finite binary64 range"⟩

def look {α : Type} (fields : List (String × α)) (key : String) : Option α :=
  (fields.find? (fun field => field.1 == key)).map Prod.snd

def floatZero (negative : Bool) : Literal := .float negative 0 (-1074)

/-! ### Canonical form -/

private def Literal.ratio : Literal → Int × Nat
  | .int n => (n, 1)
  | .float neg m k =>
    let a : Int := m * (2 ^ k.toNat : Nat)
    (if neg then -a else a, 2 ^ (-k).toNat)

private def Literal.isFloat : Literal → Bool
  | .int _ => false
  | .float .. => true

private def Literal.is (literal : Literal) (n : Int) : Bool :=
  let (a, b) := literal.ratio
  a == n * (b : Int)

private def Literal.negate : Literal → Literal
  | .int n => .int (-n)
  | .float negative m k => .float (!negative) m k

private def Literal.negativeZero : Literal → Bool
  | .float true 0 _ => true
  | _ => false

private inductive SortKey where
  | number (value : ℚ) (kind : Nat)
  | reference (name : String)
  | node (canonical : String)

private def sortKey (render : Expression → String) : Expression → SortKey
  | .number n =>
    let (numerator, denominator) := n.ratio
    .number (mkRat numerator denominator) (if n.isFloat then 1 else 0)
  | .reference s => .reference s
  | e@(.node ..) => .node (render e)

private def before : SortKey → SortKey → Bool
  | .number a kindA, .number b kindB => decide (toLex (a, kindA) ≤ toLex (b, kindB))
  | .number .., _ => true
  | _, .number .. => false
  | .reference a, .reference b => a ≤ b
  | .reference _, .node _ => true
  | .node _, .reference _ => false
  | .node a, .node b => a ≤ b

private theorem before_trans : ∀ a b c, before a b → before b c → before a c := by
  intro a b c
  cases a <;> cases b <;> cases c <;> simp [before] <;> exact le_trans

private theorem before_total : ∀ a b, before a b || before b a := by
  intro a b
  cases a <;> cases b <;> simp [before, le_total]

private def withSortedArgs (render : Expression → String) (op : String) (args : List Expression) (fields : List (String × Payload)) :
    Expression :=
  .node op (orderArgs (sortKey render) before args) fields

private def childrenOf (op : String) : Expression → Option (List Expression)
  | .node child children [] => if op == child then some children else none
  | _ => none

private def flatten (op : String) (args : List Expression) : List Expression :=
  flattenArgs (childrenOf op) args

private def numberIs (value : Int) : Expression → Bool
  | .number n => n.is value
  | _ => false

private def firstZero (args : List Expression) : Option Expression :=
  args.findSome? fun a => if numberIs 0 a then some a else none

private def isFloating : Expression → Bool
  | .number n => n.isFloat
  | _ => false

private def isNegativeZero : Expression → Bool
  | .number n => n.negativeZero
  | _ => false

private def floatIdentity (identity : Int) (negativeZero : Bool) : Literal :=
  if identity == 0 then floatZero negativeZero else .float false (2 ^ 52) (-52)

private def retainFloatIdentity (identity : Int) (neutral rest : List Expression) :
    Option Expression :=
  if neutral.any isFloating && (!rest.all isFloating || rest.isEmpty) then
    some (.number (floatIdentity identity (neutral.all isNegativeZero)))
  else none

private def eraseIdentity (render : Expression → String) (op : String) (identity : Int) (args : List Expression)
    (fields : List (String × Payload)) : Expression :=
  let rest := identityArgs (numberIs identity) (retainFloatIdentity identity) args
  match fields with
  | [] =>
    match rest with
    | [] => .number (.int identity)
    | [a] => a
    | a :: b :: tail => withSortedArgs render op (a :: b :: tail) []
  | _ :: _ => withSortedArgs render op rest fields

private def promoteInt (roundFloat : Bool → Nat → Int → Option Literal) (path : String) (n : Literal) : Except Failure Literal :=
  match n with
  | .int n =>
    match roundFloat (n < 0) n.natAbs 0 with
    | some v => .ok v
    | none => .error (nonFinite path)
  | v => .ok v

private def canonicalConst (args : List Expression) (fields : List (String × Payload)) :
    Expression :=
  match look fields "units" with
  | some (.string u) =>
    let canonical := Esm.Units.canon u
    if canonical == "1" then
      match look fields "value" with
      | some (.number n) => .number n
      | _ => .node "const" args (fields.filter (fun entry => entry.1 != "units"))
    else .node "const" args (fields.map fun (k, v) => (k, if k == "units" then .string canonical else v))
  | _ => .node "const" args fields

private def negate : Expression → Expression
  | .number n => .number n.negate
  | .node "-" [x] [] => x
  | x => .node "-" [x] []

private def canonicalizeProduct (render : Expression → String) (args : List Expression)
    (fields : List (String × Payload)) : Expression :=
  let flattened := flatten "*" args
  match fields with
  | [] =>
    match firstZero flattened with
    | some zero => zero
    | none => eraseIdentity render "*" 1 flattened []
  | _ :: _ => eraseIdentity render "*" 1 flattened fields

def canonicalizeRoot (render : Expression → String) (roundFloat : Bool → Nat → Int → Option Literal)
    (path op : String) (args : List Expression) (fields : List (String × Payload)) :
    Except Failure Expression := do
  let original := Expression.node op args fields
  match op, args, fields with
  | "const", _, _ => return canonicalConst args fields
  | "+", _, _ => return eraseIdentity render op 0 (flatten op args) fields
  | "*", _, _ => return canonicalizeProduct render args fields
  | "-", [a], [] | "neg", [a], [] => return negate a
  | "neg", [_], _ => return .node "-" args fields
  | "pow", [_, _], _ => return .node "^" args fields
  | "-", [.number a, .number b], [] =>
    if a.is 0 then
      if b.is 0 && (a.isFloat || b.isFloat) then
        return .number (floatZero (a.negativeZero && !b.negativeZero))
      if a.isFloat then return .number (← promoteInt roundFloat path b.negate)
      return .number b.negate
    if b.is 0 then return .number (← if b.isFloat then promoteInt roundFloat path a else pure a)
    return original
  | "-", [a, .number b], [] => return if b.is 0 then a else original
  | "/", [.number a, .number b], [] =>
    if a.is 0 && b.is 0 then throw ⟨"E_CANONICAL_DIVBY_ZERO", path, "literal zero divided by zero"⟩
    if b.is 1 then return .number (← if b.isFloat then promoteInt roundFloat path a else pure a)
    if a.is 0 then return .number a
    return original
  | "/", [a, .number b], [] => return if b.is 1 then a else original
  | "/", [.number a, _], [] => return if a.is 0 then .number a else original
  | _, _, _ => return original

/-- Canonicalize children in input order, then normalize the root. The attached
argument only carries the proof needed for recursion on the input tree. -/
def canonicalize (render : Expression → String) (roundFloat : Bool → Nat → Int → Option Literal)
    (path : String) (expression : Expression) : Except Failure Expression :=
  match expression with
  | .node op args fields => do
    let args ← args.attach.zipIdx.mapM fun (a, i) =>
      canonicalize render roundFloat (s!"{path}/args/{i}") a.val
    canonicalizeRoot render roundFloat path op args fields
  | .number n => .ok (.number n)
  | .reference name => .ok (.reference name)
termination_by sizeOf expression
decreasing_by
  have smaller := List.sizeOf_lt_of_mem a.property
  simp_wf
  omega

@[simp]
theorem canonicalize_number (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (path : String) (n : Literal) : canonicalize render round path (.number n) = .ok (.number n) := by
  rw [canonicalize]

@[simp]
theorem canonicalize_reference (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (path name : String) : canonicalize render round path (.reference name) = .ok (.reference name) := by
  rw [canonicalize]

/-! ### Induction over the executable traversal -/

private theorem mapM_forall₂ {α β ε : Type} (P : α → β → Prop) (f : α → Except ε β)
    (xs : List α) (ys : List β) (h : xs.mapM f = .ok ys)
    (sound : ∀ x ∈ xs, ∀ y, f x = .ok y → P x y) : List.Forall₂ P xs ys := by
  induction xs generalizing ys with
  | nil =>
    change Except.ok [] = Except.ok ys at h
    cases h
    exact .nil
  | cons x xs ih =>
    rw [List.mapM_cons] at h
    cases hx : f x with
    | error err =>
      rw [hx] at h
      cases h
    | ok y =>
      cases hxs : xs.mapM f with
      | error err =>
        rw [hx, hxs] at h
        cases h
      | ok rest =>
        rw [hx, hxs] at h
        cases h
        exact .cons (sound x (by simp) y hx) (ih _ hxs (by
          intro a ha b hb
          exact sound a (List.mem_cons_of_mem _ ha) b hb))

/-- Bottom-up rewriting transports any relation preserved by the root rules.
The child inputs in the relation are the parsed expressions, before sorting. -/
theorem canonicalize_induct (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (P : Expression → Expression → Prop)
    (number : ∀ n, P (.number n) (.number n)) (reference : ∀ name, P (.reference name) (.reference name))
    (node : ∀ path op fields inputs args out, List.Forall₂ P inputs args →
      canonicalizeRoot render round path op args fields = .ok out → P (.node op inputs fields) out) :
    ∀ (path : String) (expression out : Expression),
      canonicalize render round path expression = .ok out → P expression out
  | _, .number n, out, h => by
    have eq : Expression.number n = out := by simpa using h
    exact eq ▸ number n
  | _, .reference name, out, h => by
    have eq : Expression.reference name = out := by simpa using h
    exact eq ▸ reference name
  | path, .node op inputs fields, out, h => by
    rw [canonicalize] at h
    let rewrite := fun (indexed : {e // e ∈ inputs} × Nat) =>
      canonicalize render round (s!"{path}/args/{indexed.2}") indexed.1.val
    change (inputs.attach.zipIdx.mapM rewrite >>= fun args => canonicalizeRoot render round path op args fields) =
      .ok out at h
    cases children : inputs.attach.zipIdx.mapM rewrite with
    | error err =>
      rw [children] at h
      cases h
    | ok args =>
      have related := mapM_forall₂ (fun pair => P pair.1.val) rewrite inputs.attach.zipIdx args children (by
        intro ⟨⟨arg, member⟩, index⟩ _ outArg child
        exact canonicalize_induct render round P number reference node _ arg outArg child)
      have mapped : List.Forall₂ P (inputs.attach.zipIdx.map (fun pair => pair.1.val)) args :=
        List.forall₂_map_left_iff.mpr related
      change List.Forall₂ P (inputs.attach.zipIdx.map (Subtype.val ∘ Prod.fst)) args at mapped
      rw [← List.map_map, List.zipIdx_map_fst, List.attach_map_subtype_val] at mapped
      rw [children] at h
      exact node path op fields inputs args out mapped h
termination_by _ expression _ _ => sizeOf expression
decreasing_by
  have smaller := List.sizeOf_lt_of_mem member
  simp_wf
  omega

/-! ### Exact preservation on the polynomial fragment -/

/-- The fragment with numeric literals, references, and field-free n-ary sums
and products. Its exact meaning does not use binary64 reassociation. -/
inductive Polynomial : Expression → Prop where
  | number (literal : Literal) : Polynomial (.number literal)
  | reference (name : String) : Polynomial (.reference name)
  | node {op : String} (args : List Expression) (arithmetic : op = "+" ∨ op = "*")
      (terms : ∀ arg ∈ args, Polynomial arg) : Polynomial (.node op args [])

private theorem Literal.ratio_den_ne_zero (literal : Literal) : literal.ratio.2 ≠ 0 := by
  cases literal <;> simp [Literal.ratio]

private def Literal.exactValue {K : Type} [Field K] (literal : Literal) : K :=
  (literal.ratio.1 : K) / (literal.ratio.2 : K)

private theorem Literal.exactValue_of_is {K : Type} [Field K] [CharZero K]
    (literal : Literal) (n : Int) (h : literal.is n = true) : literal.exactValue = (n : K) := by
  unfold Literal.exactValue
  rw [div_eq_iff (Nat.cast_ne_zero.mpr literal.ratio_den_ne_zero)]
  have eq : literal.ratio.1 = n * (literal.ratio.2 : Int) := by simpa [Literal.is] using h
  exact_mod_cast eq

/-- Exact algebraic value. The preservation theorem uses this function only
on the polynomial fragment. -/
def polynomialValue {K : Type} [Field K] (env : String → K) (expression : Expression) : K :=
  match expression with
  | .number n => n.exactValue
  | .reference s => env s
  | .node op terms _ =>
    let values := terms.attach.map fun t => polynomialValue env t.val
    if op == "+" then values.sum else if op == "*" then values.prod else 0
termination_by sizeOf expression
decreasing_by
  have smaller := List.sizeOf_lt_of_mem t.property
  simp_wf
  omega

private theorem polynomialValue_sum {K : Type} [Field K] (env : String → K) (args : List Expression) :
    polynomialValue env (.node "+" args []) = (args.map (polynomialValue env)).sum := by
  rw [polynomialValue]
  simp

private theorem polynomialValue_product {K : Type} [Field K] (env : String → K) (args : List Expression) :
    polynomialValue env (.node "*" args []) = (args.map (polynomialValue env)).prod := by
  rw [polynomialValue]
  simp

private theorem childrenOf_eq (op : String) (term : Expression) (args : List Expression)
    (h : childrenOf op term = some args) : term = .node op args [] := by
  cases term with
  | number n => simp [childrenOf] at h
  | reference name => simp [childrenOf] at h
  | node name children fields =>
    cases fields with
    | nil =>
      by_cases same : op = name
      · subst name
        simpa [childrenOf] using h
      · simp [childrenOf, same] at h
    | cons field fields => simp [childrenOf] at h

private theorem flatten_polynomial (op : String) (args : List Expression)
    (polynomials : ∀ a ∈ args, Polynomial a) : ∀ a ∈ flatten op args, Polynomial a := by
  intro arg member
  obtain ⟨a, aMember, h⟩ := List.mem_flatMap.mp member
  cases hChildren : childrenOf op a with
  | none =>
    have eq : arg = a := by simpa [hChildren] using h
    exact eq ▸ polynomials a aMember
  | some embedded =>
    have p : Polynomial (.node op embedded []) := childrenOf_eq op a embedded hChildren ▸ polynomials a aMember
    cases p with
    | node _ _ terms => exact terms arg (by simpa [hChildren] using h)

private theorem retained_identity (identity : Int) (neutral rest : List Expression) (arg : Expression)
    (isZeroOrOne : identity = 0 ∨ identity = 1)
    (retained : retainFloatIdentity identity neutral rest = some arg) :
    Polynomial arg ∧ numberIs identity arg = true := by
  simp only [retainFloatIdentity] at retained
  split at retained
  · injection retained with h
    subst arg
    rcases isZeroOrOne with rfl | rfl
    · generalize neutral.all isNegativeZero = neg
      cases neg <;> exact ⟨.number _, by decide +kernel⟩
    · change Polynomial (.number (.float false (2 ^ 52) (-52))) ∧
        numberIs 1 (.number (.float false (2 ^ 52) (-52))) = true
      exact ⟨.number _, by decide +kernel⟩
  · cases retained

private theorem numberIs_value {K : Type} [Field K] [CharZero K] (env : String → K)
    (arg : Expression) (identity : Int) (h : numberIs identity arg = true) :
    polynomialValue env arg = (identity : K) := by
  cases arg with
  | number n =>
    rw [polynomialValue]
    exact Literal.exactValue_of_is n identity h
  | reference name => cases h
  | node op terms fields => cases h

private theorem neutralArgs_closed (predicate : Expression → Prop) (identity : Int)
    (args : List Expression) (members : ∀ a ∈ args, predicate a)
    (kept : ∀ neutral rest arg, retainFloatIdentity identity neutral rest = some arg → predicate arg) :
    ∀ a ∈ identityArgs (numberIs identity) (retainFloatIdentity identity) args, predicate a := by
  intro a member
  simp only [identityArgs, List.partition_eq_filter_filter] at member
  split at member
  · exact members a (List.mem_filter.mp member).1
  · rename_i arg retained
    rcases List.mem_cons.mp member with h | h
    · rw [h]
      exact kept _ _ arg retained
    · exact members a (List.mem_filter.mp h).1

private theorem eraseIdentity_polynomial (render : Expression → String) (op : String) (identity : Int)
    (args : List Expression) (operator : op = "+" ∨ op = "*") (isZeroOrOne : identity = 0 ∨ identity = 1)
    (polynomials : ∀ a ∈ args, Polynomial a) : Polynomial (eraseIdentity render op identity args []) := by
  have normal := neutralArgs_closed Polynomial identity args polynomials (fun neutral rest arg h =>
    (retained_identity identity neutral rest arg isZeroOrOne h).1)
  unfold eraseIdentity
  generalize identityArgs (numberIs identity) (retainFloatIdentity identity) args = kept at normal ⊢
  cases kept with
  | nil => exact .number _
  | cons arg rest =>
    cases rest with
    | nil => exact normal arg (by simp)
    | cons next rest =>
      apply Polynomial.node _ operator
      intro x member
      apply normal x
      simpa [orderArgs_eq_mergeSort] using member

private theorem eraseIdentity_sum_value {K : Type} [Field K] [CharZero K]
    (render : Expression → String) (env : String → K) (args : List Expression) :
    polynomialValue env (eraseIdentity render "+" 0 args []) = (args.map (polynomialValue env)).sum := by
  have values : ((identityArgs (numberIs 0) (retainFloatIdentity 0) args).map (polynomialValue env)).sum =
      (args.map (polynomialValue env)).sum :=
    identityArgs_preserves_sum _ _ _ _ (fun a h => by simpa using numberIs_value env a 0 h)
      (fun before after a h => by
        simpa using numberIs_value env a 0 (retained_identity 0 before after a (Or.inl rfl) h).2)
  rw [← values]
  unfold eraseIdentity
  generalize identityArgs (numberIs 0) (retainFloatIdentity 0) args = kept
  cases kept with
  | nil => simp [polynomialValue, Literal.exactValue, Literal.ratio]
  | cons arg rest =>
    cases rest with
    | nil => simp
    | cons next rest =>
      change polynomialValue env (.node "+" (orderArgs (sortKey render) before (arg :: next :: rest)) []) = _
      rw [polynomialValue_sum]
      exact orderArgs_preserves_sum _ _ _ _

private theorem eraseIdentity_product_value {K : Type} [Field K] [CharZero K]
    (render : Expression → String) (env : String → K) (args : List Expression) :
    polynomialValue env (eraseIdentity render "*" 1 args []) = (args.map (polynomialValue env)).prod := by
  have values : ((identityArgs (numberIs 1) (retainFloatIdentity 1) args).map (polynomialValue env)).prod =
      (args.map (polynomialValue env)).prod :=
    identityArgs_preserves _ _ _ _ (fun a h => by simpa using numberIs_value env a 1 h)
      (fun before after a h => by
        simpa using numberIs_value env a 1 (retained_identity 1 before after a (Or.inr rfl) h).2)
  rw [← values]
  unfold eraseIdentity
  generalize identityArgs (numberIs 1) (retainFloatIdentity 1) args = kept
  cases kept with
  | nil => simp [polynomialValue, Literal.exactValue, Literal.ratio]
  | cons arg rest =>
    cases rest with
    | nil => simp
    | cons next rest =>
      change polynomialValue env (.node "*" (orderArgs (sortKey render) before (arg :: next :: rest)) []) = _
      rw [polynomialValue_product]
      exact orderArgs_preserves _ _ _ _

private theorem zeroWitness {K : Type} [Field K] [CharZero K] (env : String → K)
    (arg selected : Expression) (h : (if numberIs 0 arg then some arg else none) = some selected) :
    polynomialValue env arg = 0 ∧ polynomialValue env selected = 0 := by
  split at h
  · rename_i isZero
    have eq : arg = selected := Option.some.inj h
    have value : polynomialValue env arg = 0 := by simpa using numberIs_value env arg 0 isZero
    exact ⟨value, eq ▸ value⟩
  · cases h

private theorem canonicalizeRoot_preserves_polynomial {K : Type} [Field K] [CharZero K]
    (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (env : String → K) (path op : String) (args : List Expression) (out : Expression)
    (arithmetic : op = "+" ∨ op = "*") (terms : ∀ a ∈ args, Polynomial a)
    (h : canonicalizeRoot render round path op args [] = .ok out) :
    Polynomial out ∧ polynomialValue env out = polynomialValue env (.node op args []) := by
  rcases arithmetic with rfl | rfl
  · have eq : eraseIdentity render "+" 0 (flatten "+" args) [] = out := by
      exact Except.ok.inj h
    subst out
    refine ⟨eraseIdentity_polynomial render "+" 0 _ (Or.inl rfl) (Or.inl rfl)
      (flatten_polynomial "+" args terms), ?_⟩
    rw [eraseIdentity_sum_value, polynomialValue_sum]
    exact flattenArgs_preserves_sum (childrenOf "+") _ _ (fun arg children embed => by
      rw [childrenOf_eq "+" arg children embed, polynomialValue_sum])
  · let flat := flatten "*" args
    have flattened : (flat.map (polynomialValue env)).prod = polynomialValue env (.node "*" args []) := by
      rw [polynomialValue_product]
      exact flattenArgs_preserves (childrenOf "*") _ _ (fun arg children embed => by
        rw [childrenOf_eq "*" arg children embed, polynomialValue_product])
    have hRoot : canonicalizeRoot render round path "*" args [] = Except.ok
        (match firstZero flat with
        | some zero => zero
        | none => eraseIdentity render "*" 1 flat []) := rfl
    rw [hRoot] at h
    cases zero : firstZero flat with
    | none =>
      have eq : eraseIdentity render "*" 1 flat [] = out := by simpa [zero] using h
      subst out
      exact ⟨eraseIdentity_polynomial render "*" 1 flat (Or.inr rfl) (Or.inr rfl)
        (flatten_polynomial "*" args terms), (eraseIdentity_product_value render env flat).trans flattened⟩
    | some selected =>
      have eq : selected = out := by simpa [zero] using h
      subst out
      have productValue := firstZero_preserves _ (polynomialValue env) flat selected zero (zeroWitness env)
      obtain ⟨arg, member, chosen⟩ := List.exists_of_findSome?_eq_some zero
      split at chosen
      · have eq := Option.some.inj chosen
        exact ⟨eq ▸ flatten_polynomial "*" args terms arg member, productValue.symm.trans flattened⟩
      · cases chosen

private theorem polynomial_results {K : Type} [Field K] (env : String → K)
    {inputs outputs : List Expression}
    (related : List.Forall₂ (fun input output => Polynomial input →
      Polynomial output ∧ polynomialValue env output = polynomialValue env input) inputs outputs)
    (polynomials : ∀ arg ∈ inputs, Polynomial arg) :
    (∀ arg ∈ outputs, Polynomial arg) ∧
      outputs.map (polynomialValue env) = inputs.map (polynomialValue env) := by
  induction related with
  | nil => simp
  | @cons input output inputs outputs head tail ih =>
    obtain ⟨outPolynomial, value⟩ := head (polynomials input (by simp))
    obtain ⟨outPolynomials, values⟩ := ih (fun arg h => polynomials arg (List.mem_cons_of_mem _ h))
    refine ⟨?_, by simp [value, values]⟩
    intro arg member
    rcases List.mem_cons.mp member with rfl | member
    · exact outPolynomial
    · exact outPolynomials arg member

/-- On arbitrarily nested field-free sums and products, the executable tree
canonicalizer preserves the polynomial and its value under every exact assignment. -/
theorem canonicalize_preserves_polynomial {K : Type} [Field K] [CharZero K]
    (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (env : String → K) (path : String) (input output : Expression)
    (h : canonicalize render round path input = .ok output) (p : Polynomial input) :
    Polynomial output ∧ polynomialValue env output = polynomialValue env input := by
  apply canonicalize_induct render round (fun before after => Polynomial before →
    Polynomial after ∧ polynomialValue env after = polynomialValue env before) ?_ ?_ ?_ path input output h p
  · intro literal hp
    exact ⟨hp, rfl⟩
  · intro name hp
    exact ⟨hp, rfl⟩
  · intro path op fields inputs args out related hRoot hp
    cases hp with
    | node _ opIsArithmetic terms =>
      obtain ⟨polynomials, values⟩ := polynomial_results env related terms
      obtain ⟨outPolynomial, preserved⟩ :=
        canonicalizeRoot_preserves_polynomial render round env path op args out opIsArithmetic polynomials hRoot
      refine ⟨outPolynomial, preserved.trans ?_⟩
      rcases opIsArithmetic with rfl | rfl
      · rw [polynomialValue_sum, polynomialValue_sum, values]
      · rw [polynomialValue_product, polynomialValue_product, values]

/-! ### Idempotence on the polynomial fragment -/

private theorem retainFloatIdentity_again (identity : Int) (isZeroOrOne : identity = 0 ∨ identity = 1)
    (neutral rest ordered : List Expression) (arg : Expression) (perm : rest.Perm ordered)
    (h : retainFloatIdentity identity neutral rest = some arg) :
    retainFloatIdentity identity [arg] ordered = some arg := by
  simp only [retainFloatIdentity] at h
  split at h
  · rename_i keep
    simp only [Bool.and_eq_true] at keep
    have need := keep.2
    have eq := Option.some.inj h
    subst arg
    rw [retainFloatIdentity, ← perm.all_eq (f := isFloating), ← perm.isEmpty_eq]
    rcases isZeroOrOne with rfl | rfl
    · generalize neutral.all isNegativeZero = sign
      cases sign <;>
        simp [floatIdentity, floatZero, isFloating, isNegativeZero, Literal.isFloat, Literal.negativeZero, need]
    · simp [floatIdentity, isFloating, Literal.isFloat, need]
  · cases h

private inductive Normal (render : Expression → String) (round : Bool → Nat → Int → Option Literal) :
    Expression → Prop where
  | number (n : Literal) : Normal render round (.number n)
  | reference (name : String) : Normal render round (.reference name)
  | node (op : String) (args : List Expression)
      (children : ∀ arg ∈ args, Normal render round arg)
      (flat : ∀ arg ∈ args, childrenOf op arg = none)
      (root : ∀ path, canonicalizeRoot render round path op args [] = .ok (.node op args [])) :
      Normal render round (.node op args [])

private theorem normal_literal (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (arg : Expression) (n : Int) (h : numberIs n arg = true) : Normal render round arg := by
  cases arg with
  | number n => exact .number n
  | reference name => cases h
  | node op args fields => cases h

private theorem numberIs_noChildren (op : String) (arg : Expression) (n : Int)
    (h : numberIs n arg = true) : childrenOf op arg = none := by
  cases arg with
  | number n => rfl
  | reference name => cases h
  | node op args fields => cases h

private theorem mapM_ok_map {α β ε : Type} (f : α → Except ε β) (g : α → β) (xs : List α)
    (h : ∀ x ∈ xs, f x = .ok (g x)) : xs.mapM f = .ok (xs.map g) := by
  induction xs with
  | nil => rfl
  | cons x tail ih =>
    rw [List.mapM_cons, h x (by simp), ih (fun a ha => h a (List.mem_cons_of_mem _ ha))]
    rfl

private theorem Normal.canonicalize (render : Expression → String) (round : Bool → Nat → Int → Option Literal) :
    ∀ expr, Normal render round expr → ∀ path, canonicalize render round path expr = .ok expr
  | .number n, _, path => canonicalize_number render round path n
  | .reference name, _, path => canonicalize_reference render round path name
  | .node op args fields, normal, path => by
    cases normal with
    | node _ _ ready _ root =>
      rw [Typed.canonicalize]
      let rewrite := fun (indexed : {e // e ∈ args} × Nat) =>
        Typed.canonicalize render round (s!"{path}/args/{indexed.2}") indexed.1.val
      have children := mapM_ok_map rewrite (fun indexed => indexed.1.val) args.attach.zipIdx (by
        intro ⟨⟨arg, member⟩, index⟩ _
        exact Normal.canonicalize render round arg (ready arg member) _)
      change (args.attach.zipIdx.mapM rewrite >>= fun args => canonicalizeRoot render round path op args []) = _
      rw [children]
      have unattach : args.attach.zipIdx.map (fun (p : {e // e ∈ args} × Nat) => p.1.val) = args := by
        change args.attach.zipIdx.map (Subtype.val ∘ Prod.fst) = args
        rw [← List.map_map, List.zipIdx_map_fst, List.attach_map_subtype_val]
      rw [unattach]
      exact root path
termination_by expr _ _ => sizeOf expr
decreasing_by
  have smaller := List.sizeOf_lt_of_mem member
  simp_wf
  omega

private theorem normalFlatten (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (op : String) (args : List Expression) (ready : ∀ a ∈ args, Normal render round a) :
    ∀ a ∈ flatten op args, Normal render round a ∧ childrenOf op a = none := by
  intro a member
  obtain ⟨arg, argMember, h⟩ := List.mem_flatMap.mp member
  cases child : childrenOf op arg with
  | none =>
    have eq : a = arg := by simpa [child] using h
    subst a
    exact ⟨ready arg argMember, child⟩
  | some embedded =>
    have normal := childrenOf_eq op arg embedded child ▸ ready arg argMember
    cases normal with
    | node _ _ children flat _ =>
      have inEmbedded : a ∈ embedded := by simpa [child] using h
      exact ⟨children a inEmbedded, flat a inEmbedded⟩

private theorem firstZero_free (args : List Expression) :
    firstZero args = none ↔ ∀ a ∈ args, numberIs 0 a = false := by
  unfold firstZero
  rw [List.findSome?_eq_none_iff]
  constructor
  · intro h a mem
    cases zero : numberIs 0 a with
    | false => rfl
    | true =>
      have impossible := h a mem
      simp [zero] at impossible
  · intro h a mem
    simp [h a mem]

private def packArithmetic (op : String) (identity : Int) : List Expression → Expression
  | [] => .number (.int identity)
  | [arg] => arg
  | a :: b :: rest => .node op (a :: b :: rest) []

private theorem eraseIdentity_eq_pack (render : Expression → String) (op : String) (identity : Int)
    (args : List Expression) : eraseIdentity render op identity args [] =
      packArithmetic op identity (orderArgs (sortKey render) before
        (identityArgs (numberIs identity) (retainFloatIdentity identity) args)) := by
  unfold eraseIdentity
  generalize identityArgs (numberIs identity) (retainFloatIdentity identity) args = kept
  cases kept with
  | nil => simp [orderArgs, packArithmetic]
  | cons a rest =>
    cases rest with
    | nil => simp [orderArgs, packArithmetic]
    | cons b rest =>
      have length : (orderArgs (sortKey render) before (a :: b :: rest)).length = (a :: b :: rest).length := by
        simp [orderArgs_eq_mergeSort]
      change withSortedArgs render op (a :: b :: rest) [] = _
      unfold withSortedArgs
      generalize eq : orderArgs (sortKey render) before (a :: b :: rest) = sorted at length ⊢
      match sorted with
      | [] | [_] => simp at length
      | _ :: _ :: _ => rfl

private theorem numeric_one_is_not_zero (a : Expression) (one : numberIs 1 a = true) : numberIs 0 a = false := by
  have oneValue := numberIs_value (fun _ => (0 : ℚ)) a 1 one
  cases zero : numberIs 0 a with
  | false => rfl
  | true =>
    have zeroValue := numberIs_value (fun _ => (0 : ℚ)) a 0 zero
    rw [oneValue] at zeroValue
    norm_num at zeroValue

private theorem normalArithmetic (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (op : String) (identity : Int) (args : List Expression)
    (rule : (op = "+" ∧ identity = 0) ∨ (op = "*" ∧ identity = 1))
    (ready : ∀ arg ∈ args, Normal render round arg)
    (noZero : op = "*" → firstZero (flatten op args) = none) :
    Normal render round (eraseIdentity render op identity (flatten op args) []) := by
  let flat := flatten op args
  let kept := identityArgs (numberIs identity) (retainFloatIdentity identity) flat
  let sorted := orderArgs (sortKey render) before kept
  have identityChoice : identity = 0 ∨ identity = 1 := rule.elim (fun h => .inl h.2) (fun h => .inr h.2)
  have flatNormal := normalFlatten render round op args ready
  have keptNormal := neutralArgs_closed
    (fun a => Normal render round a ∧ childrenOf op a = none) identity flat flatNormal
    (fun neutral rest arg h => by
      have number := (retained_identity identity neutral rest arg identityChoice h).2
      exact ⟨normal_literal render round arg identity number, numberIs_noChildren op arg identity number⟩)
  have sortedNormal : ∀ arg ∈ sorted, Normal render round arg ∧ childrenOf op arg = none := by
    intro arg mem
    exact keptNormal arg (by simpa [sorted, orderArgs_eq_mergeSort] using mem)
  have stable : orderArgs (sortKey render) before
      (identityArgs (numberIs identity) (retainFloatIdentity identity) (flatten op sorted)) = sorted := by
    apply associativeArgs_idempotent (childrenOf op) (numberIs identity) (retainFloatIdentity identity)
      (sortKey render) before args before_trans before_total
    · intro arg mem inner h child childMem
      exact (flatNormal child (List.mem_flatMap.mpr ⟨arg, mem, by simpa [h] using childMem⟩)).2
    · intro rest
      simp [retainFloatIdentity]
    · intro neutral rest arg h
      have number := (retained_identity identity neutral rest arg identityChoice h).2
      exact ⟨number, numberIs_noChildren op arg identity number⟩
    · exact retainFloatIdentity_again identity identityChoice
  have root : ∀ path,
      canonicalizeRoot render round path op sorted [] = .ok (packArithmetic op identity sorted) := by
    intro path
    rcases rule with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · change Except.ok (eraseIdentity render "+" 0 (flatten "+" sorted) []) = _
      rw [eraseIdentity_eq_pack, stable]
    · have zeroFree : ∀ a ∈ flat, numberIs 0 a = false := (firstZero_free flat).mp (noZero rfl)
      have keptZeroFree := neutralArgs_closed (fun a => numberIs 0 a = false) 1 flat zeroFree
        (fun neutral rest a h => numeric_one_is_not_zero a (retained_identity 1 neutral rest a (.inr rfl) h).2)
      have sortedZeroFree : firstZero sorted = none := (firstZero_free sorted).mpr (fun a mem =>
        keptZeroFree a (by simpa [sorted, orderArgs_eq_mergeSort] using mem))
      have sortedFlat : flatten "*" sorted = sorted :=
        flattenArgs_of_leaves (childrenOf "*") sorted (fun arg mem => (sortedNormal arg mem).2)
      change Except.ok (canonicalizeProduct render sorted []) = _
      have keepProduct : canonicalizeProduct render sorted [] = eraseIdentity render "*" 1 (flatten "*" sorted) [] := by
        simp [canonicalizeProduct, sortedFlat, sortedZeroFree]
      rw [keepProduct, eraseIdentity_eq_pack, stable]
  rw [eraseIdentity_eq_pack]
  change Normal render round (packArithmetic op identity sorted)
  generalize h : sorted = xs at sortedNormal root ⊢
  match xs with
  | [] => exact .number _
  | [arg] => exact (sortedNormal arg (by simp)).1
  | a :: b :: rest =>
    exact .node op _ (fun arg mem => (sortedNormal arg mem).1) (fun arg mem => (sortedNormal arg mem).2) root

private theorem normalPolynomialRoot (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (path op : String) (args : List Expression) (out : Expression)
    (arithmetic : op = "+" ∨ op = "*") (ready : ∀ arg ∈ args, Normal render round arg)
    (h : canonicalizeRoot render round path op args [] = .ok out) : Normal render round out := by
  rcases arithmetic with rfl | rfl
  · have eq : eraseIdentity render "+" 0 (flatten "+" args) [] = out := Except.ok.inj h
    subst out
    exact normalArithmetic render round "+" 0 args (.inl ⟨rfl, rfl⟩) ready (fun same =>
      False.elim ((show ("+" : String) ≠ "*" by decide) same))
  · change Except.ok (canonicalizeProduct render args []) = Except.ok out at h
    unfold canonicalizeProduct at h
    cases zero : firstZero (flatten "*" args) with
    | none =>
      have eq : eraseIdentity render "*" 1 (flatten "*" args) [] = out := by simpa [zero] using h
      subst out
      exact normalArithmetic render round "*" 1 args (.inr ⟨rfl, rfl⟩) ready (fun _ => zero)
    | some selected =>
      have eq : selected = out := by simpa [zero] using h
      subst out
      obtain ⟨arg, _, detected⟩ := List.exists_of_findSome?_eq_some zero
      split at detected
      · rename_i found
        have eq := Option.some.inj detected
        exact eq ▸ normal_literal render round arg 0 found
      · cases detected

private theorem normalPolynomialOutputs (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    {inputs outputs : List Expression}
    (related : List.Forall₂ (fun input output => Polynomial input → Normal render round output) inputs outputs)
    (polynomials : ∀ arg ∈ inputs, Polynomial arg) : ∀ arg ∈ outputs, Normal render round arg := by
  induction related with
  | nil => simp
  | @cons input output inputs outputs head tail ih =>
    intro arg member
    rcases List.mem_cons.mp member with rfl | member
    · exact head (polynomials input (by simp))
    · exact ih (fun arg h => polynomials arg (List.mem_cons_of_mem _ h)) arg member

/-- Every successful tree normalization of the polynomial fragment is a fixed
point, even if the result is canonicalized at a different diagnostic path. -/
theorem canonicalize_polynomial_idempotent
    (render : Expression → String) (round : Bool → Nat → Int → Option Literal)
    (path nextPath : String) (input output : Expression)
    (h : canonicalize render round path input = .ok output) (p : Polynomial input) :
    canonicalize render round nextPath output = .ok output := by
  apply Normal.canonicalize render round output ?_ nextPath
  apply canonicalize_induct render round (fun before after => Polynomial before →
    Normal render round after) ?_ ?_ ?_ path input output h p
  · exact fun n _ => .number n
  · exact fun name _ => .reference name
  · intro path op fields inputs args out related hRoot hp
    cases hp with
    | node _ operator terms =>
      exact normalPolynomialRoot render round path op args out operator
        (normalPolynomialOutputs render round related terms) hRoot

end Esm.Expr.Canonical.Typed
