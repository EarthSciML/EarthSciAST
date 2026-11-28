import Esm.Document.Json

/-! A reference-preserving component expression fixpoint (esm-spec §9.6.3).
The caller supplies the effective declaration sequence and the eligibility
judgment. Definition instances run separately, with their call's rewrite depth
as the starting depth. -/

namespace Esm.Rewrite

open Esm.Document (Json)

/-- Object keys and zero-based array indices, from the expression root. -/
abbrev Path := List String

structure Capture where
  value : Json
  /-- The path of a captured operand within the matched node, when it has one. -/
  source : Option Path := none
  deriving Repr

abbrev Bindings := List (String × Capture)

structure Rule where
  name : String
  params : List String
  body : Json
  pattern : Option Json := none
  defines : Option String := none
  referenceOnly : Bool := false
  constraints : Option Json := none
  priority : Int := 0
  deriving Repr

/-- Eligibility includes structural matching, call arity and `where`. The
first argument names loop symbols currently shadowing component declarations. -/
abbrev MatchRule := (shadowed : List String) → Rule → Json → Option Bindings

structure Origin where
  path : Path
  depth : Nat
  deriving DecidableEq, Repr

structure Nontermination where
  path : String
  rule : String
  depth : Nat
  deriving Repr

def Nontermination.code (_ : Nontermination) : String := "rewrite_rule_nonterminating"

structure RewriteResult where
  tree : Json
  /-- Paths of references produced by rewriting. Authored references need no entry. -/
  origins : List Origin
  productivePasses : Nat
  deriving Repr

def field? {α : Type} (fields : List (String × α)) (key : String) : Option α :=
  (fields.find? (fun entry => entry.1 == key)).map Prod.snd

private def asString : Json → Option String
  | .str value => some value
  | _ => none

private def operator? : Json → Option String
  | .obj fields => (field? fields "op").bind asString
  | _ => none

private def isReference (op : String) : Bool :=
  op == "apply_operator" || op == "apply_expression_template"

/-- Loop symbols bound at a node. Their declarations shadow free variables
while walking the node's children (§4.3.1). -/
def loopNames (fields : List (String × Json)) : List String :=
  let outputs := match field? fields "output_idx" with
    | some (.arr names) => names.filterMap asString
    | _ => []
  let ranges := match field? fields "ranges" with
    | some (.obj entries) => entries.map Prod.fst
    | _ => []
  let integral := ((field? fields "int_var").bind asString).toList
  outputs ++ ranges ++ integral

/-- The only strict improvements in the priority/constraint comparison.
Equal candidates keep the earlier declaration. -/
def outranks (candidate incumbent : Rule) : Bool :=
  decide (candidate.priority > incumbent.priority) ||
    (candidate.priority == incumbent.priority && candidate.constraints.isSome && !incumbent.constraints.isSome)

private def consider (matcher : MatchRule) (shadowed : List String) (term : Json)
    (best : Option (Rule × Bindings)) (candidate : Rule) : Option (Rule × Bindings) :=
  match matcher shadowed candidate term with
  | none => best
  | some bindings =>
    match best with
    | none => some (candidate, bindings)
    | some (incumbent, _) => if outranks candidate incumbent then some (candidate, bindings) else best

def select (rules : List Rule) (matcher : MatchRule) (shadowed : List String) (term : Json) :
    Option (Rule × Bindings) :=
  rules.foldl (consider matcher shadowed term) none

/-- A prefix of ineligible rules cannot affect which later rule is selected. -/
theorem select_ignores_ineligible (matcher : MatchRule) (shadowed : List String) (term : Json)
    (earlier candidates : List Rule) (ineligible : ∀ rule ∈ earlier, matcher shadowed rule term = none) :
    select (earlier ++ candidates) matcher shadowed term = select candidates matcher shadowed term := by
  induction earlier with
  | nil => rfl
  | cons rule rest ih =>
    simp only [List.cons_append, select, List.foldl_cons, consider, ineligible rule (by simp)]
    exact ih (fun entry member => ineligible entry (List.mem_cons_of_mem _ member))

/-- At equal priority, equally scoped eligible rules keep declaration order. -/
theorem select_declaration_tie (matcher : MatchRule) (shadowed : List String) (term : Json)
    (first second : Rule) (firstCapture secondCapture : Bindings)
    (firstMatches : matcher shadowed first term = some firstCapture)
    (secondMatches : matcher shadowed second term = some secondCapture)
    (priority : first.priority = second.priority) (scope : first.constraints.isSome = second.constraints.isSome) :
    select [first, second] matcher shadowed term = some (first, firstCapture) := by
  have notBetter : outranks second first = false := by
    unfold outranks
    rw [priority, scope]
    cases second.constraints.isSome <;> simp
  simp [select, consider, firstMatches, secondMatches, notBetter]

private def pointer (path : Path) : String :=
  String.join (path.map fun part => "/" ++ ((part.replace "~" "~0").replace "/" "~1"))

private def atOrBelow (path : Path) (origins : List Origin) : List Origin :=
  origins.filter fun origin => path.isPrefixOf origin.path

private def movedOrigins (origins : List Origin) (matchedPath destination : Path) (capture : Capture) : List Origin :=
  match capture.source with
  | none => []
  | some localPath =>
    let source := matchedPath ++ localPath
    (atOrBelow source origins).map fun origin => { origin with path := destination ++ origin.path.drop source.length }

structure Firing where
  path : Path
  rule : String
  deriving DecidableEq, Repr

structure PassResult where
  tree : Json
  origins : List Origin
  last : Option Firing := none
  deriving Repr

private def unchanged (origins : List Origin) (path : Path) (tree : Json) : PassResult :=
  ⟨tree, atOrBelow path origins, none⟩

private def lastFiring (children : List PassResult) : Option Firing :=
  children.reverse.findSome? fun child => child.last

private def replace (origins : List Origin) (depth : Nat) (path : Path) (rule : Rule)
    (captured : Bindings) : PassResult :=
  let last := some ⟨path, rule.name⟩
  match rule.body with
  | .num _ | .bool _ => ⟨rule.body, [], last⟩
  | .str name =>
    let capture := if rule.params.contains name then field? captured name else none
    match capture with
    | none => ⟨rule.body, [], last⟩
    | some arg =>
      let inherited := movedOrigins origins path path arg
      let inherited := if ((operator? arg.value).any isReference) then
        ⟨path, depth⟩ :: inherited.filter (fun origin => origin.path != path)
      else inherited
      ⟨arg.value, inherited, last⟩
  | _ =>
    let binds : Bindings := rule.params.map fun param =>
      (param, (field? captured param).getD ⟨.str param, none⟩)
    let written := Json.obj [("op", .str "apply_operator"), ("args", .arr []),
      ("name", .str rule.name), ("bindings", .obj (binds.map fun (k, capture) => (k, capture.value)))]
    let nested := binds.flatMap fun (k, capture) => movedOrigins origins path (path ++ ["bindings", k]) capture
    ⟨written, ⟨path, depth⟩ :: nested, last⟩

private inductive Walk where
  | expression
  | bindings (params : List String)

private def expressionField (key : String) : Bool :=
  ["args", "expr", "filter", "key", "lower", "upper", "values"].contains key

private def referenceParams (rules : List Rule) (fields : List (String × Json)) : List String :=
  let named := (field? fields "name").bind asString
  match rules.find? (fun rule => named == some rule.name) with
  | some rule => rule.params
  | none => []

private def walk (rules : List Rule) (matcher : MatchRule) (origins : List Origin)
    (depth : Nat) (shadowed : List String) (mode : Walk) (path : Path) (term : Json) : PassResult :=
  match term with
  | .arr args =>
    let children := args.attach.zipIdx.map fun (arg, index) =>
      walk rules matcher origins depth shadowed .expression (path ++ [toString index]) arg.val
    ⟨.arr (children.map PassResult.tree), children.flatMap PassResult.origins, lastFiring children⟩
  | .obj fields =>
    match mode with
    | .bindings params =>
      let ordered := fields.attach.mergeSort fun lhs rhs => params.idxOf lhs.val.1 ≤ params.idxOf rhs.val.1
      let rewritten := ordered.map fun entry =>
        (entry.val.1, walk rules matcher origins depth shadowed .expression (path ++ [entry.val.1]) entry.val.2)
      let values := fields.map fun (key, value) => (key, ((field? rewritten key).map PassResult.tree).getD value)
      let children := rewritten.map Prod.snd
      ⟨.obj values, children.flatMap PassResult.origins, lastFiring children⟩
    | .expression =>
      let op := operator? term
      let reference := op.any isReference
      let eligible := if reference || op.isNone then none else select rules matcher shadowed term
      match eligible with
      | some (winner, captured) => replace origins depth path winner captured
      | none =>
        let innerShadowed := loopNames fields ++ shadowed
        let children := fields.attach.map fun entry =>
          let key := entry.val.1
          let value := entry.val.2
          let childPath := path ++ [key]
          let result := if reference then
            if key == "bindings" then
              walk rules matcher origins depth innerShadowed (.bindings (referenceParams rules fields)) childPath value
            else unchanged origins childPath value
          else if expressionField key then
            walk rules matcher origins depth innerShadowed .expression childPath value
          else unchanged origins childPath value
          (key, result)
        let prior := origins.filter fun origin => origin.path == path
        let visits := children.map Prod.snd
        ⟨.obj (children.map fun (key, result) => (key, result.tree)),
          prior ++ visits.flatMap PassResult.origins, lastFiring visits⟩
  | .str _ | .num _ | .bool _ =>
    match select rules matcher shadowed term with
    | some (winner, captured) => replace origins depth path winner captured
    | none => unchanged origins path term
  | .null | .math _ => unchanged origins path term
termination_by sizeOf term
decreasing_by
  all_goals
    first
      | have smaller := List.sizeOf_lt_of_mem arg.property
        simp_wf
        omega
      | have smaller := List.sizeOf_lt_of_mem entry.property
        have component : sizeOf entry.val.2 ≤ sizeOf entry.val := by
          cases entry.val
          simp_wf
        simp_wf
        omega

/-- One outermost-first pass. A firing seals its replacement until the next pass. -/
def rewritePass (rules : List Rule) (matcher : MatchRule) (origins : List Origin)
    (depth : Nat) (term : Json) : PassResult :=
  walk rules matcher origins depth [] .expression [] term

def maxRewritePasses : Nat := 64

private def drive (rules : List Rule) (matcher : MatchRule) (start : Nat) :
    Nat → Nat → Json → List Origin → Except Nontermination RewriteResult
  | fuel, depth, current, origins =>
    let pass := rewritePass rules matcher origins depth current
    match pass.last with
    | none => .ok ⟨current, origins, depth - start - 1⟩
    | some firing =>
      match fuel with
      | 0 => .error ⟨pointer firing.path, firing.rule, depth⟩
      | remaining + 1 => drive rules matcher start remaining (depth + 1) pass.tree pass.origins

/-- Run enough passes to detect a fixpoint within the allowed depth. A
nonproductive probe at depth 65 is permitted; a firing there is rejected. -/
def rewriteTracked (rules : List Rule) (matcher : MatchRule) (tree : Json)
    (initialDepth : Nat := 0) : Except Nontermination RewriteResult :=
  drive rules matcher initialDepth (maxRewritePasses - initialDepth) (initialDepth + 1) tree []

def rewrite (rules : List Rule) (matcher : MatchRule) (tree : Json) : Except Nontermination Json :=
  (rewriteTracked rules matcher tree).map RewriteResult.tree

private theorem drive_success_bounded (rules : List Rule) (matcher : MatchRule) (start : Nat)
    (fuel depth : Nat) (term : Json) (origins : List Origin) (result : RewriteResult)
    (h : drive rules matcher start fuel depth term origins = .ok result) :
    result.productivePasses ≤ fuel + (depth - start - 1) := by
  induction fuel generalizing depth term origins with
  | zero =>
    rw [drive] at h
    split at h
    · cases h
      simp
    · cases h
  | succ fuel ih =>
    rw [drive] at h
    split at h
    · cases h
      change depth - start - 1 ≤ fuel + 1 + (depth - start - 1)
      omega
    · have bound := ih _ _ _ h
      omega

/-- Every successful result fits the original budget, including the caller's
starting depth when rewriting the body of an instance. -/
theorem rewriteTracked_bounded (rules : List Rule) (matcher : MatchRule) (term : Json) (depth : Nat)
    (result : RewriteResult) (h : rewriteTracked rules matcher term depth = .ok result) :
    result.productivePasses ≤ maxRewritePasses - depth := by
  have bound := drive_success_bounded rules matcher depth _ _ term [] result h
  omega

private theorem drive_failure_depth (rules : List Rule) (matcher : MatchRule) (start : Nat)
    (fuel depth : Nat) (term : Json) (origins : List Origin) (failure : Nontermination)
    (h : drive rules matcher start fuel depth term origins = .error failure) :
    failure.depth = depth + fuel := by
  induction fuel generalizing depth term origins with
  | zero =>
    rw [drive] at h
    split at h
    · cases h
    · cases h
      simp
  | succ fuel ih =>
    rw [drive] at h
    split at h
    · cases h
    · have rejected := ih _ _ _ h
      omega

/-- Starting from a legal depth, the engine rejects precisely the first firing
that would exceed the shared depth limit. -/
theorem rewriteTracked_failure_depth (rules : List Rule) (matcher : MatchRule) (term : Json)
    (depth : Nat) (failure : Nontermination) (legal : depth ≤ maxRewritePasses)
    (h : rewriteTracked rules matcher term depth = .error failure) :
    failure.depth = maxRewritePasses + 1 := by
  have rejected := drive_failure_depth rules matcher depth _ _ term [] failure h
  omega

end Esm.Rewrite
