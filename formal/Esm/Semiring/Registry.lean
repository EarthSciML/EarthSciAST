/-! # The closed FAQ semiring registry (CONFORMANCE_SPEC §5.6) -/

namespace Esm.Semiring

/-- The spellings accepted by the `faq` semiring field. -/
inductive Name where
  | sumProduct
  | maxProduct
  | minSum
  | maxSum
  | boolAndOr
  deriving DecidableEq

def Name.spelling : Name → String
  | .sumProduct => "sum_product"
  | .maxProduct => "max_product"
  | .minSum => "min_sum"
  | .maxSum => "max_sum"
  | .boolAndOr => "bool_and_or"

def Name.parse : String → Except String Name
  | "sum_product" => .ok .sumProduct
  | "max_product" => .ok .maxProduct
  | "min_sum" => .ok .minSum
  | "max_sum" => .ok .maxSum
  | "bool_and_or" => .ok .boolAndOr
  | other => .error s!"unregistered semiring {other}"

/-- The reduction operation. The author writes the product of factors in the
body Expression (esm-spec §4.8.3); a scalar FAQ evaluator uses only ⊕. -/
def Name.reduction : Name → String
  | .sumProduct => "+"
  | .maxProduct | .maxSum => "max"
  | .minSum => "min"
  | .boolAndOr => "bool_and_or"

/-- A registered semiring takes precedence over the legacy reduction field. -/
def resolveReduction (semiring legacy : Option String) : Except String String :=
  match semiring with
  | some name => Name.reduction <$> Name.parse name
  | none =>
    match legacy with
    | some "bool_and_or" => .error "bool_and_or requires the semiring field"
    | _ => .ok (legacy.getD "+")

/-- Test every term, including those after the first true term, because
evaluation of an admitted term can fail. -/
def foldBoolM {α : Type} {m : Type → Type} [Monad m] (items : List α)
    (term : α → m Bool) : m Bool :=
  items.foldlM (fun acc item => do
    let value ← term item
    pure (acc || value)) false

end Esm.Semiring
