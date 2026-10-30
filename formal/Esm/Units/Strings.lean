import Esm.Units.Identities
import Esm.Units.GrammarLaws

/-!
# Whole unit strings, end to end (esm-spec §4.8.2)

Facts about `resolve` on specific strings the spec names, and about the
scaling-factor diagnostic text. The parse step is checked by the kernel; the
table lookup and composition by `rfl`.
-/

namespace Esm.Units

/-- Resolution of a nonempty string: normalise, lex, parse, then evaluate. -/
theorem resolveChars_eq (cs : List Char) (h : cs ≠ []) :
    resolveChars cs = (lex (normalize cs) >>= parse) >>= UExpr.eval := by
  unfold resolveChars
  rw [if_neg h]
  cases lex (normalize cs) with
  | error e => rfl
  | ok ts => cases parse ts <;> rfl

/-- `%` is a symbol token (§4.8.2): `"%"` resolves to dimensionless scale 0.01, and
`"%/h"` to `h⁻¹` at scale `1/360000`. -/
theorem percent_resolves :
    (∃ u, resolve "%" = .ok u ∧ u.Agree (num 0.01)) ∧
    (∃ u, resolve "%/h" = .ok u ∧ u.Agree (mk (Dims.dimless - Dims.time) (1 / 360000))) := by
  have p1 : (lex (normalize "%".toList) >>= parse) = .ok (.sym "%") := by decide +kernel
  have p2 : (lex (normalize "%/h".toList) >>= parse) = .ok (.div (.sym "%") (.sym "h")) := by
    decide +kernel
  refine ⟨⟨sym "%", ?_, agree_mk rfl (by norm_num)⟩, ⟨(sym "%").div (sym "h"), ?_, ?_⟩⟩
  · rw [resolve, resolveChars_eq _ (by decide), p1]; rfl
  · rw [resolve, resolveChars_eq _ (by decide), p2]; rfl
  · rw [sym_percent, sym_h]
    exact U.agree_trans (mk_div _ _ _ _ (by norm_num) (by norm_num)) (agree_mk rfl (by norm_num))

/-- `"(m/s)^-1/3"` reads as `((m/s)^-1)/3`, and the `3` is a scaling factor. -/
theorem m_per_s_pow_scaling_factor :
    resolve "(m/s)^-1/3" = .error (.scalingFactor "3") := by
  have p : (lex (normalize "(m/s)^-1/3".toList) >>= parse) = .error (.scalingFactor "3") := by
    decide +kernel
  rw [resolve, resolveChars_eq _ (by decide), p]; rfl

/-- MOVES's `"g/hp-hr"` does not resolve: `-` is not an operator. -/
theorem g_per_hp_hr_rejected :
    resolve "g/hp-hr" =
      .error (.syntax "'-' is not an operator in a unit string (a negative exponent is ^-n)") := by
  have p : (lex (normalize "g/hp-hr".toList) >>= parse) =
      .error (.syntax "'-' is not an operator in a unit string (a negative exponent is ^-n)") := by
    decide +kernel
  rw [resolve, resolveChars_eq _ (by decide), p]; rfl

/-- The scaling-factor diagnostic, for every literal, says that the number is a
scaling factor and that a rational exponent is spelled `^(p/q)`. -/
theorem scaling_factor_message :
    ∀ lit : String,
      "scaling factor".toList <:+: (Err.scalingFactor lit).message.toList ∧
      "^(p/q)".toList <:+: (Err.scalingFactor lit).message.toList := by
  intro lit
  simp only [Err.message, String.toList_append]
  constructor
  · have := List.infix_append ("the number ".toList ++ lit.toList ++ " is a ".toList)
      scalingFactorText.toList
      (", not a unit: the only numeric atom a unit string admits is 1, and a rational exponent ".toList
        ++ ("is spelled ".toList ++ rationalExponentText.toList))
    simpa [scalingFactorText, List.append_assoc] using this
  · have := List.infix_append ("the number ".toList ++ lit.toList ++ " is a ".toList ++
      scalingFactorText.toList ++
      ", not a unit: the only numeric atom a unit string admits is 1, and a rational exponent ".toList
        ++ "is spelled ".toList) rationalExponentText.toList []
    simpa [rationalExponentText, List.append_assoc] using this

end Esm.Units
