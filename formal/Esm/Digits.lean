import Mathlib.Data.Nat.Digits.Lemmas

/-!
# Decimal digits

The big-endian decimal digits of a natural number, from Mathlib's `Nat.digits`, and
the character of a digit. Shared by the number spelling of the document codecs
(`Esm.Document.Number`) and the canonical unit spelling (`Esm.Units.Canonical`).
-/

namespace Esm

/-- The character of a decimal digit. -/
def digitChar (d : ℕ) : Char := Char.ofNat (48 + d)

theorem digitChar_toNat {d : ℕ} (h : d < 10) : (digitChar d).toNat = 48 + d := by
  interval_cases d <;> rfl

theorem digitChar_isDigit {d : ℕ} (h : d < 10) : (digitChar d).isDigit = true := by
  interval_cases d <;> rfl

/-- The big-endian decimal digits of `n`; empty for `0`. -/
def decDigits (n : ℕ) : List ℕ := (Nat.digits 10 n).reverse

theorem decDigits_lt (n : ℕ) : ∀ d ∈ decDigits n, d < 10 := fun _ hd =>
  Nat.digits_lt_base (by norm_num) (List.mem_reverse.mp hd)

theorem decDigits_eq_nil_iff (n : ℕ) : decDigits n = [] ↔ n = 0 := by
  simp [decDigits, Nat.digits_eq_nil_iff_eq_zero]

/-- The leading digit of a positive number is not `0`. -/
theorem decDigits_head (n : ℕ) (h : n ≠ 0) : (decDigits n).head? ≠ some 0 := by
  have hne : Nat.digits 10 n ≠ [] := by simpa [Nat.digits_eq_nil_iff_eq_zero] using h
  have := Nat.getLast_digit_ne_zero 10 h
  rw [decDigits, List.head?_reverse, List.getLast?_eq_some_getLast hne]
  simpa using this

/-- Reading big-endian digits, most significant first. -/
theorem foldl_reverse_ofDigits (L : List ℕ) :
    L.reverse.foldl (fun a d => 10 * a + d) 0 = Nat.ofDigits 10 L := by
  induction L with
  | nil => rfl
  | cons d L ih =>
    rw [List.reverse_cons, List.foldl_append, ih, Nat.ofDigits_cons]
    simp only [List.foldl_cons, List.foldl_nil]
    ring

theorem foldl_decDigits (n : ℕ) : (decDigits n).foldl (fun a d => 10 * a + d) 0 = n := by
  rw [decDigits, foldl_reverse_ofDigits, Nat.ofDigits_digits]

end Esm
