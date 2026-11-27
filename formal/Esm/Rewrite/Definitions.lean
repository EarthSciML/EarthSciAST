import Esm.Document.Notation
import Esm.Rewrite.Engine

/-! Definition registration and arity checking for a component's rewrite scope
(esm-spec §9.6.1 and §9.6.12). -/

namespace Esm.Rewrite

open Esm.Document (Json)

inductive DefinitionError where
  | reservedCore (definition op : String)
  | arityMismatch (op : String) (actual : Nat) (expected : List Nat)
  deriving BEq, Repr

def DefinitionError.code : DefinitionError → String
  | .reservedCore .. => "operator_defines_core_op"
  | .arityMismatch .. => "operator_arity_mismatch"

def DefinitionError.detail : DefinitionError → String
  | .reservedCore definition op => s!"{definition} defines the reserved core operator '{op}'"
  | .arityMismatch op actual expected =>
    let counts := ", ".intercalate (expected.mergeSort.map toString)
    s!"Call of '{op}' carries {actual} operand(s), but its definitions in scope take {counts}"

abbrev DefinitionArities := Std.HashMap String (List Nat)

private def rootOp (fields : List (String × Json)) : Option String :=
  match field? fields "op" with
  | some (.str op) => some op
  | _ => none

private def operandCount (fields : List (String × Json)) : Nat :=
  match field? fields "args" with
  | some (.arr args) => args.length
  | _ => 0

private def coreOp (op : String) : Bool := Document.Notation.coreOpNames.contains op

/-- Collect every operand count supplied by the definitions in scope. A
core-rooted pattern has no callable name, and a reference-only definition
contributes no count. -/
def buildDefinitionArities (rules : List Rule) : Except DefinitionError DefinitionArities :=
  rules.foldlM (init := {}) fun arities rule => do
    if rule.referenceOnly then return arities
    let root := match rule.pattern with
      | some (.obj fields) => rootOp fields
      | _ => none
    if root.any coreOp then return arities
    let op := rule.defines.getD (root.getD rule.name)
    if coreOp op then throw (.reservedCore rule.name op)
    let count := match rule.pattern with
      | none => rule.params.length
      | some (.obj fields) => operandCount fields
      | some _ => 0
    if rule.pattern.isSome && root.isNone then return arities
    let known := arities[op]?.getD []
    return if known.contains count then arities else arities.insert op (count :: known)

private def checkNodeArity (arities : DefinitionArities) (fields : List (String × Json)) :
    Except DefinitionError Unit := do
  let some op := rootOp fields | return ()
  let some expected := arities[op]? | return ()
  let actual := operandCount fields
  unless expected.contains actual do throw (.arityMismatch op actual expected)

private inductive CallFields where
  | expression
  | reference
  | bindings

mutual

/-- Check surviving calls after the rewrite fixpoint. With no definition in
scope, the name stays a placeholder. Inside a reference, only the binding
values are expressions at the current call site. -/
def checkCallArities (arities : DefinitionArities) : Json → Except DefinitionError Unit
  | .arr values => checkOperands arities values
  | .obj fields => do
    match rootOp fields with
    | some "apply_operator" | some "apply_expression_template" =>
      checkCallFields arities .reference fields
    | _ =>
      checkNodeArity arities fields
      checkCallFields arities .expression fields
  | _ => pure ()
termination_by tree => sizeOf tree

private def checkOperands (arities : DefinitionArities) : List Json → Except DefinitionError Unit
  | [] => pure ()
  | value :: rest => do
    checkCallArities arities value
    checkOperands arities rest
termination_by values => sizeOf values

private def checkCallFields (arities : DefinitionArities) (mode : CallFields) :
    List (String × Json) → Except DefinitionError Unit
  | [] => pure ()
  | (key, value) :: rest => do
    match mode with
    | .expression =>
      if ["args", "expr", "filter", "key", "lower", "upper", "values"].contains key then
        checkCallArities arities value
    | .reference =>
      if key == "bindings" then
        match value with
        | .obj bindings => checkCallFields arities .bindings bindings
        | _ => pure ()
    | .bindings => checkCallArities arities value
    checkCallFields arities mode rest
termination_by fields => sizeOf fields

end

end Esm.Rewrite
