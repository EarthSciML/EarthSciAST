import Mathlib.Data.List.Nodup
import Mathlib.Data.Int.Basic

/-!
# The `enums` block (esm-spec §9.3, CONFORMANCE §5.26), values and uniqueness

An `enums` block maps enum names to objects mapping symbols to integers. JSON
objects have unique keys, so the model takes the symbol lists as given and
checks only what the spec adds:

* §9.3 / Q-2 / Q-8: within one enum, values are unique; a duplicate is
  `enum_duplicate_value` (new code). Across enums values may collide.
* §9.3 / CONFORMANCE §5.26: every integer is a legal value (zero and negatives
  included), and an `enum` op resolves to exactly its declared integer.
-/

namespace Esm.Closed.Enums

abbrev Enum := List (String × ℤ)
abbrev EnumsBlock := List (String × Enum)

/-- The load-time check on an `enums` block. -/
def validateEnums (es : EnumsBlock) : Except String Unit :=
  if es.all (fun e => decide (e.2.map Prod.snd).Nodup) then .ok ()
  else .error "enum_duplicate_value"

/-- Resolve `enum(name, symbol)`. -/
def resolve (es : EnumsBlock) (name sym : String) : Except String ℤ :=
  match es.lookup name with
  | none => .error "unknown_enum"
  | some m => match m.lookup sym with
    | none => .error "unknown_enum_symbol"
    | some v => .ok v

/-- §9.3 / Q-2 / Q-8: a block loads iff values are unique WITHIN each enum; a
duplicate is `enum_duplicate_value`. Nothing constrains the values themselves
(zero and negatives are accepted), nor values across enums. -/
theorem validateEnums_iff (es : EnumsBlock) :
    (validateEnums es = .ok () ↔ ∀ e ∈ es, (e.2.map Prod.snd).Nodup) ∧
      ((∃ e ∈ es, ¬ (e.2.map Prod.snd).Nodup) → validateEnums es = .error "enum_duplicate_value") := by
  have key : validateEnums es = .ok () ↔ ∀ e ∈ es, (e.2.map Prod.snd).Nodup := by
    by_cases h : ∀ e ∈ es, (e.2.map Prod.snd).Nodup
    · have : es.all (fun e => decide (e.2.map Prod.snd).Nodup) = true := by
        simpa using h
      simp only [validateEnums, this, ↓reduceIte, true_iff]
      exact h
    · have : es.all (fun e => decide (e.2.map Prod.snd).Nodup) = false := by
        simpa using h
      simp only [validateEnums, this, Bool.false_eq_true, ↓reduceIte]
      exact ⟨fun h' => (nomatch h'), fun h' => absurd h' h⟩
  refine ⟨key, ?_⟩
  rintro ⟨e, he, hd⟩
  have : es.all (fun e => decide (e.2.map Prod.snd).Nodup) = false := by
    rw [List.all_eq_false]; exact ⟨e, he, by simpa using hd⟩
  simp only [validateEnums, this]
  rfl

/-- Values may coincide across enums: two enums each with unique values load,
whatever values they share. -/
theorem validateEnums_cross (n₁ n₂ : String) (m₁ m₂ : Enum) (h₁ : (m₁.map Prod.snd).Nodup)
    (h₂ : (m₂.map Prod.snd).Nodup) : validateEnums [(n₁, m₁), (n₂, m₂)] = .ok () := by
  simp [validateEnums, h₁, h₂]

/-- CONFORMANCE §5.26 / §9.3: an `enum` op resolves to exactly the declared
integer — zero, negative or positive — with no clamping or defaulting. -/
theorem resolve_exact (es : EnumsBlock) (name sym : String) (m : Enum) (v : ℤ)
    (hm : es.lookup name = some m) (hv : m.lookup sym = some v) :
    resolve es name sym = .ok v := by
  simp [resolve, hm, hv]

/-- §9.3 lowering contract: an undeclared enum is `unknown_enum`, an undeclared
symbol `unknown_enum_symbol`. -/
theorem resolve_unknown (es : EnumsBlock) (name sym : String) :
    (es.lookup name = none → resolve es name sym = .error "unknown_enum") ∧
      (∀ m, es.lookup name = some m → m.lookup sym = none →
        resolve es name sym = .error "unknown_enum_symbol") := by
  refine ⟨fun h => by simp [resolve, h], fun m hm hs => by simp [resolve, hm, hs]⟩

end Esm.Closed.Enums
