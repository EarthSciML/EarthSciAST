import Esm.Units.Laws
import Esm.Float64

/-!
# The identities §4.8.1 states, checked against the table

Every entry of `table` is built from the scale the spec states for it, so each
identity below is a genuine check that the stated scales are consistent with
the stated relations, exactly (rational arithmetic on exponent maps).
-/

namespace Esm.Units

open Dims

/-- A dimensionless exact rational scale. -/
def num (q : ℚ) : U := mk dimless q

theorem dim_ext {d e : Dim} (h : ∀ a, d a = e a) : d = e := funext h

theorem agree_mk {d d' : Dim} {q q' : ℚ} (hd : d = d') (hq : q = q') :
    (mk d q).Agree (mk d' q') := by
  subst hd hq; rfl

theorem mk_mul (d d' : Dim) (q q' : ℚ) (hq : q ≠ 0) (hq' : q' ≠ 0) :
    ((mk d q).mul (mk d' q')).Agree (mk (d + d') (q * q')) := by
  rw [U.agree_iff]
  exact ⟨rfl, (Scale.exp_ofRat_mul q q' hq hq').symm⟩

theorem mk_inv (d : Dim) (q : ℚ) : (mk d q).inv.Agree (mk (-d) q⁻¹) := by
  rw [U.agree_iff]
  refine ⟨by simp [U.inv, U.rpow, mk], ?_⟩
  exact (Scale.exp_ofRat_inv q).symm

theorem mk_div (d d' : Dim) (q q' : ℚ) (hq : q ≠ 0) (hq' : q' ≠ 0) :
    ((mk d q).div (mk d' q')).Agree (mk (d - d') (q / q')) := by
  unfold U.div
  have h1 := (U.abelian_group.2.2.2.2) (mk d q) (mk d q) _ _ (U.agree_refl _) (mk_inv d' q')
  refine U.agree_trans h1 ?_
  refine U.agree_trans (mk_mul d (-d') q q'⁻¹ hq (inv_ne_zero hq')) ?_
  exact agree_mk (by abel) (by rw [div_eq_mul_inv])

theorem mk_rpow_nat (d : Dim) (q : ℚ) (_hq : q ≠ 0) (n : ℕ) :
    ((mk d q).rpow n).Agree (mk ((n : ℚ) • d) (q ^ n)) := by
  rw [U.agree_iff]
  refine ⟨rfl, ?_⟩
  funext b
  cases b with
  | pi => simp [U.rpow, mk]
  | prime p =>
    have : Fact p.1.Prime := ⟨p.2⟩
    simp [U.rpow, mk, padicValRat.pow]

/-! ### Table entries, by key (each is `rfl`: the table says so) -/

theorem sym_m : sym "m" = mk len 1 := rfl
theorem sym_kg : sym "kg" = mk mass 1 := rfl
theorem sym_s : sym "s" = mk time 1 := rfl
theorem sym_A : sym "A" = mk current 1 := rfl
theorem sym_rad : sym "rad" = mk angle 1 := rfl
theorem sym_ft : sym "ft" = mk len 0.3048 := rfl
theorem sym_mi : sym "mi" = mk len 1609.344 := rfl
theorem sym_h : sym "h" = mk time 3600 := rfl
theorem sym_lb : sym "lb" = mk mass 0.45359237 := rfl
theorem sym_short_ton : sym "short_ton" = mk mass 907.18474 := rfl
theorem sym_ug : sym "ug" = mk mass (1 / 10 ^ 9) := rfl
theorem sym_atm : sym "atm" = mk pressure 101325 := rfl
theorem sym_Torr : sym "Torr" = mk pressure (101325 / 760) := rfl
theorem sym_mmHg : sym "mmHg" = mk pressure 133.322387415 := rfl
theorem sym_inHg : sym "inHg" = mk pressure 3386.388640341 := rfl
theorem sym_psi : sym "psi" = mk pressure (0.45359237 * 9.80665 / 0.0254 ^ 2) := rfl
theorem sym_hp : sym "hp" = mk power (550 * 0.3048 * 0.45359237 * 9.80665) := rfl
theorem sym_W : sym "W" = mk power 1 := rfl
theorem sym_gal : sym "gal" = mk vol 0.003785411784 := rfl
theorem sym_yr : sym "yr" = mk time 31557600 := rfl
theorem sym_year : sym "year" = mk time 31557600 := rfl
theorem sym_day : sym "day" = mk time 86400 := rfl
theorem sym_deg : sym "deg" = mkPi angle (1 / 180) 1 := rfl
theorem sym_sr : sym "sr" = mk solidAngle 1 := rfl
theorem sym_percent : sym "%" = mk dimless (1 / 100) := rfl
theorem sym_C : sym "C" = mk charge 1 := rfl
theorem sym_DU : sym "DU" = mk column 2.6867e20 := rfl
theorem sym_Dobson : sym "Dobson" = mk column 2.6867e20 := rfl
theorem sym_degF : sym "degF" = mk temp (5 / 9) := rfl
theorem sym_BTU : sym "BTU" = mk energy 1055.05585262 := rfl

/-! ### The stated identities -/

/-- `mi` is exactly `5280 × ft` (§4.8.1 customary table). -/
theorem mi_eq_5280_ft : (sym "mi").Agree ((num 5280).mul (sym "ft")) := by
  rw [sym_mi, sym_ft, num]
  refine U.agree_symm (U.agree_trans (mk_mul _ _ _ _ (by norm_num) (by norm_num)) ?_)
  exact agree_mk (dim_ext fun a => by cases a <;> simp [dimless, len, D]) (by norm_num)

/-- `mi` is `201168/125` m `= 2⁴ · 3² · 5⁻³ · 11 · 127` m, the factorization the
spec writes out. -/
theorem mi_factorization :
    (sym "mi").scale.exp = Scale.exp
      [(.prime ⟨2, Nat.prime_two⟩, 4), (.prime ⟨3, Nat.prime_three⟩, 2),
       (.prime ⟨5, Nat.prime_five⟩, -3), (.prime ⟨11, by norm_num⟩, 1),
       (.prime ⟨127, by norm_num⟩, 1)] := by
  rw [sym_mi]
  have e : (1609.344 : ℚ) = 2 ^ 4 * 3 ^ 2 * (5 ^ 3)⁻¹ * 11 * 127 := by norm_num
  show Scale.exp (Scale.ofRat 1609.344) = _
  rw [e]
  funext b
  cases b with
  | pi => simp
  | prime p =>
    have : Fact p.1.Prime := ⟨p.2⟩
    have hpr : ∀ q : ℕ, q.Prime → padicValRat p.1 q = if p.1 = q then 1 else 0 := by
      intro q hq
      have := padicValRat.of_nat (p := p.1) (n := q)
      rw [this]
      split_ifs with h
      · subst h; simp [padicValNat_self]
      · have : ¬ p.1 ∣ q := fun hd => h ((Nat.prime_dvd_prime_iff_eq p.2 hq).1 hd)
        simp [padicValNat.eq_zero_of_not_dvd this]
    have n2 := hpr 2 Nat.prime_two
    have n3 := hpr 3 Nat.prime_three
    have n5 := hpr 5 Nat.prime_five
    have n11 := hpr 11 (by norm_num)
    have n127 := hpr 127 (by norm_num)
    push_cast at n2 n3 n5 n11 n127
    rw [Scale.exp_ofRat_prime, padicValRat.mul (by norm_num) (by norm_num),
      padicValRat.mul (by norm_num) (by norm_num), padicValRat.mul (by norm_num) (by norm_num),
      padicValRat.mul (by norm_num) (by norm_num), padicValRat.inv]
    simp only [padicValRat.pow, n2, n3, n5, n11, n127]
    rcases p with ⟨p, hp⟩
    simp only [Scale.exp_cons, Scale.exp_nil]
    by_cases h2 : p = 2
    · subst h2; simp only [Base.prime_mk_eq]; norm_num
    by_cases h3 : p = 3
    · subst h3; simp only [Base.prime_mk_eq]; norm_num
    by_cases h5 : p = 5
    · subst h5; simp only [Base.prime_mk_eq]; norm_num
    by_cases h11 : p = 11
    · subst h11; simp only [Base.prime_mk_eq]; norm_num
    by_cases h127 : p = 127
    · subst h127; simp only [Base.prime_mk_eq]; norm_num
    simp [Base.prime_mk_eq, h2, h3, h5, h11, h127, Ne.symm h2, Ne.symm h3, Ne.symm h5, Ne.symm h11, Ne.symm h127]

/-- `lb` is exactly `short_ton / 2000`. -/
theorem lb_eq_short_ton_div_2000 : (sym "lb").Agree ((sym "short_ton").div (num 2000)) := by
  rw [sym_lb, sym_short_ton, num]
  refine U.agree_symm (U.agree_trans (mk_div _ _ _ _ (by norm_num) (by norm_num)) ?_)
  exact agree_mk (dim_ext fun a => by cases a <;> simp [dimless, mass, D]) (by norm_num)

/-- `short_ton` is exactly `907184740000 ug` — InMAP's conversion constant. -/
theorem short_ton_eq_ug : (sym "short_ton").Agree ((num 907184740000).mul (sym "ug")) := by
  rw [sym_short_ton, sym_ug, num]
  refine U.agree_symm (U.agree_trans (mk_mul _ _ _ _ (by norm_num) (by norm_num)) ?_)
  exact agree_mk (dim_ext fun a => by cases a <;> simp [dimless, mass, D]) (by norm_num)

/-- `Torr` is exactly `atm / 760`, i.e. `20265/152` Pa. -/
theorem torr_eq_atm_div_760 :
    (sym "Torr").Agree ((sym "atm").div (num 760)) ∧
    (sym "Torr").Agree (mk pressure (20265 / 152)) := by
  rw [sym_Torr, sym_atm, num]
  refine ⟨U.agree_symm (U.agree_trans (mk_div _ _ _ _ (by norm_num) (by norm_num)) ?_),
    agree_mk rfl (by norm_num)⟩
  exact agree_mk (dim_ext fun a => by cases a <;> simp [dimless, pressure, D]) (by norm_num)

/-- `Torr` is NOT `mmHg`: same dimension, different exact scale. -/
theorem torr_ne_mmHg : ¬ (sym "Torr").Agree (sym "mmHg") := by
  rw [sym_Torr, sym_mmHg, U.agree_iff]
  rintro ⟨-, h⟩
  have := (Scale.exp_ofRat_inj _ _ (by norm_num) (by norm_num)).1 h
  norm_num at this

/-- `inHg` is exactly `25.4 × mmHg`. -/
theorem inHg_eq_25_4_mmHg : (sym "inHg").Agree ((num 25.4).mul (sym "mmHg")) := by
  rw [sym_inHg, sym_mmHg, num]
  refine U.agree_symm (U.agree_trans (mk_mul _ _ _ _ (by norm_num) (by norm_num)) ?_)
  exact agree_mk (dim_ext fun a => by cases a <;> simp [dimless, pressure, D]) (by norm_num)

/-- `psi` is lbf/in²: `lb × 9.80665 m/s²` over `(0.0254 m)²`. -/
theorem psi_eq_lbf_per_in2 :
    (sym "psi").Agree
      ((((num 9.80665).mul (sym "lb")).mul ((sym "m").mul ((sym "s").rpow (-2)))).div
        (((num 0.0254).mul (sym "m")).rpow 2)) := by
  rw [U.agree_iff]
  simp only [sym_psi, sym_lb, sym_m, sym_s, num, mk, U.div, U.mul, U.inv, U.rpow]
  refine ⟨dim_ext fun a => by cases a <;> simp [dimless, pressure, mass, len, time, D]; norm_num, ?_⟩
  funext b
  cases b with
  | pi => simp
  | prime p =>
    have : Fact p.1.Prime := ⟨p.2⟩
    simp only [Scale.exp_append, Scale.exp_rpow, Scale.exp_ofRat_prime]
    rw [padicValRat.div (by norm_num) (by norm_num), padicValRat.mul (by norm_num) (by norm_num),
      padicValRat.pow, padicValRat.one]
    push_cast; ring

/-- `hp` is `550 ft·lbf/s = 550 × ft × lb × 9.80665` W, exactly. -/
theorem hp_eq_550_ft_lbf_per_s :
    (sym "hp").Agree
      (((((num 550).mul (sym "ft")).mul (sym "lb")).mul (num 9.80665)).mul
        ((sym "m").mul ((sym "s").rpow (-3)))) := by
  rw [U.agree_iff]
  simp only [sym_hp, sym_ft, sym_lb, sym_m, sym_s, num, mk, U.mul, U.rpow]
  refine ⟨dim_ext fun a => by cases a <;> simp [dimless, power, mass, len, time, D]; norm_num, ?_⟩
  funext b
  cases b with
  | pi => simp
  | prime p =>
    have : Fact p.1.Prime := ⟨p.2⟩
    simp only [Scale.exp_append, Scale.exp_rpow, Scale.exp_ofRat_prime]
    rw [padicValRat.mul (by norm_num) (by norm_num), padicValRat.mul (by norm_num) (by norm_num),
      padicValRat.mul (by norm_num) (by norm_num), padicValRat.one]
    push_cast; ring

/-- `yr` = `year` = the Julian year, `31557600 s` = `365.25 day`. -/
theorem yr_julian :
    sym "yr" = sym "year" ∧
    (sym "yr").Agree (mk time 31557600) ∧
    (sym "yr").Agree ((num 365.25).mul (sym "day")) := by
  refine ⟨rfl, rfl, ?_⟩
  rw [sym_yr, sym_day, num]
  refine U.agree_symm (U.agree_trans (mk_mul _ _ _ _ (by norm_num) (by norm_num)) ?_)
  exact agree_mk (dim_ext fun a => by cases a <;> simp [dimless, time, D]) (by norm_num)

/-- `deg` is `π/180 rad`: dimension `rad¹`, real scale `π / 180`. -/
theorem deg_eq_pi_div_180 :
    (sym "deg").dim = angle ∧ Scale.real (sym "deg").scale = Real.pi / 180 := by
  refine ⟨rfl, ?_⟩
  rw [sym_deg]
  show Scale.real (Scale.ofRat (1 / 180) ++ Scale.pi 1) = _
  rw [Scale.real_append, Scale.real_ofRat _ (by norm_num), Scale.real_pi]
  push_cast; rw [Real.rpow_one]; ring

/-- `sr = rad²`. -/
theorem sr_eq_rad_sq : (sym "sr").Agree ((sym "rad").rpow 2) := by
  rw [sym_sr, sym_rad]
  refine U.agree_symm (U.agree_trans (mk_rpow_nat _ _ (by norm_num) 2) ?_)
  exact agree_mk (dim_ext fun a => by cases a <;> simp [solidAngle, angle, D])
    (by norm_num)

/-- The mixing ratios, fractions and counts are dimensionless. -/
theorem dimensionless_entries :
    ∀ k ∈ ["ppm", "ppb", "ppt", "ppmv", "ppbv", "pptv", "%", "percent", "psu",
      "molec", "molecule", "individuals", "vehicles", "units", "count",
      "", "1", "dimensionless"], (sym k).dim = 0 := by
  intro k hk
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hk
  rcases hk with h | h | h | h | h | h | h | h | h | h | h | h | h | h | h | h | h | h <;>
    subst h <;> exact dim_ext fun a => by cases a <;> rfl

/-- `%` (and `percent`) is dimensionless at scale exactly `0.01`; the counts are
dimensionless at scale 1 (not `mol`, not `cd`). -/
theorem percent_and_counts :
    (sym "%").Agree (num 0.01) ∧ (sym "percent").Agree (num 0.01) ∧
    ∀ k ∈ ["molec", "molecule", "individuals", "vehicles", "units", "count", "psu"],
      (sym k).Agree U.one := by
  refine ⟨agree_mk rfl (by norm_num), agree_mk rfl (by norm_num), ?_⟩
  intro k hk
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hk
  have h1 : (mk dimless 1).Agree U.one := by
    rw [U.agree_iff]
    exact ⟨dim_ext fun a => by cases a <;> rfl, Scale.exp_ofRat_one⟩
  rcases hk with h | h | h | h | h | h | h <;> subst h <;> exact h1

/-- `C` is the coulomb, `A·s` — no temperature component. -/
theorem C_is_coulomb : (sym "C").Agree ((sym "A").mul (sym "s")) ∧ (sym "C").dim .K = 0 := by
  refine ⟨?_, rfl⟩
  rw [sym_C, sym_A, sym_s]
  refine U.agree_symm (U.agree_trans (mk_mul _ _ _ _ (by norm_num) (by norm_num)) ?_)
  exact agree_mk (dim_ext fun a => by cases a <;> simp [charge, current, time, D]) (by norm_num)

/-- `DU` and `Dobson` have dimension `m⁻²` and scale exactly `2.6867e20`. -/
theorem dobson :
    (sym "DU").Agree (mk ((-2 : ℚ) • len) 2.6867e20) ∧ sym "Dobson" = sym "DU" ∧
    Scale.real (sym "DU").scale = 2.6867e20 := by
  refine ⟨agree_mk (dim_ext fun a => by cases a <;> simp [column, len, D]) rfl, rfl, ?_⟩
  rw [sym_DU]
  show Scale.real (Scale.ofRat 2.6867e20) = _
  rw [Scale.real_ofRat _ (by norm_num)]
  norm_num

/-- The pinned customary scales (§4.8.1 "A binding MUST use the values above"):
each entry's real scale is the stated exact value. -/
theorem customary_scales :
    Scale.real (sym "ft").scale = 0.3048 ∧ Scale.real (sym "mi").scale = 1609.344 ∧
    Scale.real (sym "lb").scale = 0.45359237 ∧
    Scale.real (sym "hp").scale = 550 * 0.3048 * 0.45359237 * 9.80665 ∧
    Scale.real (sym "gal").scale = 0.003785411784 ∧
    Scale.real (sym "inHg").scale = 3386.388640341 ∧
    Scale.real (sym "Torr").scale = 101325 / 760 ∧
    Scale.real (sym "psi").scale = 0.45359237 * 9.80665 / 0.0254 ^ 2 ∧
    Scale.real (sym "degF").scale = 5 / 9 ∧
    Scale.real (sym "BTU").scale = 1055.05585262 := by
  simp only [sym_ft, sym_mi, sym_lb, sym_hp, sym_gal, sym_inHg, sym_Torr, sym_psi, sym_degF,
    sym_BTU, mk]
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    (rw [Scale.real_ofRat _ (by norm_num)]; norm_num)

/-- `mi/h` is exactly `0.44704 m/s`, the constant MOVES's SQL writes. -/
theorem mi_per_h : ((sym "mi").div (sym "h")).Agree (mk (len - time) 0.44704) := by
  rw [sym_mi, sym_h]
  exact U.agree_trans (mk_div _ _ _ _ (by norm_num) (by norm_num)) (agree_mk rfl (by norm_num))

/-- `gal` is 231 in³ with the international inch `0.0254 m`. -/
theorem gal_eq_231_in3 :
    (sym "gal").Agree ((num 231).mul (((num 0.0254).mul (sym "m")).rpow 3)) := by
  rw [U.agree_iff]
  simp only [sym_gal, sym_m, num, mk, U.mul, U.rpow]
  refine ⟨dim_ext fun a => by cases a <;> simp [dimless, vol, len, D], ?_⟩
  funext b
  cases b with
  | pi => simp
  | prime p =>
    have : Fact p.1.Prime := ⟨p.2⟩
    simp only [Scale.exp_append, Scale.exp_rpow, Scale.exp_ofRat_prime]
    have e : (0.003785411784 : ℚ) = 231 * 0.0254 ^ 3 := by norm_num
    rw [e, padicValRat.mul (by norm_num) (by norm_num), padicValRat.pow,
      padicValRat.one]
    push_cast; ring

/-! ### `hp` in binary64 (§4.8.1: "folded LEFT TO RIGHT") -/

open Esm.F64 in
/-- The left-to-right binary64 fold `((550 × ft) × lb) × 9.80665`, from the
doubles nearest each literal, lands on the double nearest `745.6998715822702`,
which is also the double nearest the exact product. -/
theorem hp_fold_left_to_right :
    fmul (fmul (fmul (rn (550 : ℚ)) (rn 0.3048)) (rn 0.45359237)) (rn 9.80665)
      = rn (745.6998715822702 : ℚ) ∧
    rn (745.6998715822702 : ℚ) = rn (550 * 0.3048 * 0.45359237 * 9.80665 : ℚ) := by
  constructor <;> decide +kernel

open Esm.F64 in
/-- The fold order matters: `((550 × ft) × 9.80665) × lb` lands on a different
double, and the exact product is not a double. -/
theorem hp_fold_order_matters :
    fmul (fmul (fmul (rn (550 : ℚ)) (rn 0.3048)) (rn 9.80665)) (rn 0.45359237)
      ≠ fmul (fmul (fmul (rn (550 : ℚ)) (rn 0.3048)) (rn 0.45359237)) (rn 9.80665) ∧
    rn (550 * 0.3048 * 0.45359237 * 9.80665 : ℚ) ≠ 550 * 0.3048 * 0.45359237 * 9.80665 := by
  constructor <;> decide +kernel

end Esm.Units
