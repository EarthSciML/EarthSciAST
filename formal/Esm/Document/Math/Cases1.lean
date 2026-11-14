import Esm.Document.Math.Main

/-!
# Round trip, case by case: atoms, prefix operators, functions
-/

namespace Esm.Document.Math

open Esm.Document

theorem M_PL {c : Ctx} {a : Json} (h : M c a) : PL c a := h.1
theorem M_head {c : Ctx} {a : Json} (h : M c a) : HeadOK c (pr c a).toks := h.2.2.2.1

/-- A child's tokens for level 1 read back before a closing token. -/
theorem child1 {c : Ctx} {a : Json} (h : M c a) (rest : List Tok) (hr : Fol c.sf 1 rest) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pOr c f ((pr c a).at c.sf 1 ++ rest) = some (a, rest) := by
  have := h.1 1 le_rfl (by omega) rest hr f hf
  rwa [pLvl1] at this

theorem fol1_kw (sf : Sf) (k : Kw) (hk : k = .rp ∨ k = .rpg ∨ k = .rb ∨ k = .rbk ∨ k = .comma ∨
    k = .amp ∨ k = .nl ∨ k = .rabs ∨ k = .rfloor ∨ k = .rceil ∨ k = .semi ∨ k = .ecases) (r : List Tok) :
    Fol sf 1 (.kw k :: r) := by
  intro t r' e
  cases e
  rcases hk with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp [conts, isCmpTok, cmpOf, atomStart]

theorem pPrim_num (c : Ctx) (n : JNum) (rest : List Tok) (hr : Fol c.sf 10 rest) (f : Nat) :
    pPrim c (f + 1) (.num n :: rest) = some (.num n, rest) := by
  rw [pPrim.eq_def]
  simp only
  split
  · have := hr _ _ rfl; simp [conts] at this
  · rfl

theorem sqrt_latex (c : Ctx) (hs : c.sf = .latex) (a : Json) (ha : M c a) (rest : List Tok)
    (f : Nat) (hf : need 1 ((pr c a).at c.sf 1).length + 1 ≤ f) :
    pPrim c (f + 1) ([.kw .sqrt, .kw .lb] ++ (pr c a).at c.sf 1 ++ [.kw .rb] ++ rest) =
      some (node "sqrt" [a], rest) := by
  have h1 := child1 ha _ (fol1_kw _ .rb (by simp) rest) f (by omega)
  rw [pPrim.eq_def]
  simp only [List.cons_append, List.nil_append, List.append_assoc, hs] at h1 ⊢
  rw [h1]

end Esm.Document.Math

namespace Esm.Document.Math
open Esm.Document

theorem headOK_at {c : Ctx} {a : Json} (h : M c a) (L : Nat) : HeadOK c ((pr c a).at c.sf L) := by
  rw [at_eq]
  split
  · exact M_head h
  · simp only [grp, List.cons_append, HeadOK]
    refine ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩

theorem head_ne {c : Ctx} {ts : List Tok} (h : HeadOK c ts) (k : Kw)
    (hk : k = .rp ∨ k = .rpg ∨ k = .rb ∨ k = .rbk ∨ k = .comma ∨ k = .semi) :
    ∃ t r, ts = t :: r ∧ t ≠ .kw k := by
  match ts, h with
  | t :: r, h =>
    refine ⟨t, r, rfl, ?_⟩
    rintro rfl
    obtain ⟨-, -, -, -, -, h6⟩ := h
    rcases hk with rfl | rfl | rfl | rfl | rfl | rfl <;> simp [startA, atomStart] at h6

theorem need_mono {L len len' : Nat} (h : len ≤ len') : need L len ≤ need L len' := by
  unfold need; omega

theorem sepBy_cons2 (sep x y : List Tok) (ys : List (List Tok)) :
    sepBy sep (x :: y :: ys) = x ++ sep ++ sepBy sep (y :: ys) := rfl

theorem length_sepBy_ge (sep : List Tok) : ∀ (xs : List (List Tok)) (x : List Tok), x ∈ xs →
    x.length ≤ (sepBy sep xs).length
  | [], _, hx => by simp at hx
  | [y], x, hx => by simp at hx; subst hx; simp [sepBy]
  | y :: z :: zs, x, hx => by
    rw [sepBy_cons2]
    simp only [List.mem_cons] at hx
    rcases hx with rfl | hx
    · simp
    · have := length_sepBy_ge sep (z :: zs) x (by simpa using hx)
      simp only [List.length_append]; omega

/-- A comma-separated list of printed expressions at level `L` reads back. -/
theorem pItems_list (c : Ctx) (L : Nat) (hL : L = 1 ∨ L = 4) (closer : Tok)
    (hcl : ∀ r, Fol c.sf L (closer :: r)) (hcc : closer ≠ .kw .comma) :
    ∀ (xs : List Json), xs ≠ [] → (∀ x ∈ xs, M c x) → ∀ rest f,
      need 1 (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf L)).length + 2 ≤ f →
      pItems c f L (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf L) ++ closer :: rest) =
        some (xs, closer :: rest)
  | [], hne, _, _, _, _ => absurd rfl hne
  | [x], _, hM, rest, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by omega⟩
    have hx := (hM x (by simp)).1 L (by omega) (by omega) (closer :: rest) (hcl rest) g
      (by simp only [List.map_cons, List.map_nil, sepBy] at hf; unfold need at hf ⊢; omega)
    simp only [List.map_cons, List.map_nil, sepBy]
    rw [pItems, pLv]
    rcases hL with rfl | rfl
    · simp only [show (1 = 4) = False by decide, ↓reduceIte]
      have : pOr c g ((pr c x).at c.sf 1 ++ closer :: rest) = some (x, closer :: rest) := by
        rwa [pLvl1] at hx
      rw [this]
      split
      · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq, List.cons.injEq] at heq
        exact absurd heq.2.1 hcc
      · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq] at heq
        obtain ⟨rfl, rfl⟩ := heq; rfl
      · rename_i heq; cases heq
    · simp only [↓reduceIte]
      have : pAdd c g ((pr c x).at c.sf 4 ++ closer :: rest) = some (x, closer :: rest) := by
        rwa [pLvl4] at hx
      rw [this]
      split
      · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq, List.cons.injEq] at heq
        exact absurd heq.2.1 hcc
      · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq] at heq
        obtain ⟨rfl, rfl⟩ := heq; rfl
      · rename_i heq; cases heq
  | x :: y :: ys, _, hM, rest, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by omega⟩
    simp only [List.map_cons, sepBy_cons2, List.length_append, List.length_singleton] at hf ⊢
    have hrest := pItems_list c L hL closer hcl hcc (y :: ys) (by simp)
      (fun z hz => hM z (by simp [hz])) rest (g + 1) (by
        simp only [List.map_cons]; unfold need at hf ⊢; omega)
    have hcomma : Fol c.sf L (Tok.kw .comma ::
        (sepBy [.kw .comma] ((y :: ys).map fun x => (pr c x).at c.sf L) ++ closer :: rest)) := by
      intro t r e; cases e; rcases hL with rfl | rfl <;> simp [conts, isCmpTok, cmpOf, atomStart]
    have hx := (hM x (by simp)).1 L (by omega) (by omega) _ hcomma g (by unfold need at hf ⊢; omega)
    simp only [List.map_cons] at hrest hcomma hx
    rw [pItems, pLv]
    simp only [List.append_assoc, List.cons_append, List.nil_append]
    rcases hL with rfl | rfl
    · simp only [show (1 = 4) = False by decide, ↓reduceIte]
      have : pOr c g ((pr c x).at c.sf 1 ++ Tok.kw .comma ::
          (sepBy [.kw .comma] ((pr c y).at c.sf 1 :: ys.map fun x => (pr c x).at c.sf 1) ++ closer :: rest)) =
          some (x, Tok.kw .comma ::
          (sepBy [.kw .comma] ((pr c y).at c.sf 1 :: ys.map fun x => (pr c x).at c.sf 1) ++ closer :: rest)) := hx
      rw [this]
      simp only [hrest, Option.map_some]
    · simp only [↓reduceIte]
      have : pAdd c g ((pr c x).at c.sf 4 ++ Tok.kw .comma ::
          (sepBy [.kw .comma] ((pr c y).at c.sf 4 :: ys.map fun x => (pr c x).at c.sf 4) ++ closer :: rest)) =
          some (x, Tok.kw .comma ::
          (sepBy [.kw .comma] ((pr c y).at c.sf 4 :: ys.map fun x => (pr c x).at c.sf 4) ++ closer :: rest)) := hx
      rw [this]
      simp only [hrest, Option.map_some]

/-! ## Assembling the induction facts -/

theorem PA_generic (c : Ctx) (e : Json) (hPL : PL c e) (hlvl : (pr c e).lvl ≠ 4)
    (hacc : addAcc e = [e]) : PA c e := by
  intro rest hr f hf
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
  -- the tokens at level 4 are also the tokens at level 5
  have h45 : (pr c e).at c.sf 4 = (pr c e).at c.sf 5 := by
    rw [at_eq, at_eq]
    by_cases h : 5 ≤ (pr c e).lvl
    · simp [h, show 4 ≤ (pr c e).lvl by omega]
    · simp [h, show ¬ 4 ≤ (pr c e).lvl by omega]
  have hm := hPL 5 (by omega) (by omega) rest hr g (by rw [← h45]; unfold need at hf ⊢; omega)
  rw [pLvl5] at hm
  refine ⟨g, by omega, ?_⟩
  rw [pAdd, h45, hm, hacc]

theorem PCr_generic (c : Ctx) (e : Json) (hPL : PL c e)
    (hcrow : (pr c e).crow = (pr c e).toks ++ [.kw .amp, .txt "otherwise"]) (hl1 : 1 ≤ (pr c e).lvl) :
    PCr c e := by
  intro rest f hf
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
  have h1 : (pr c e).at c.sf 1 = (pr c e).toks := by rw [at_eq]; simp [hl1]
  have hfol : Fol c.sf 1 (Tok.kw .amp :: Tok.txt "otherwise" :: casesEnd c.sf :: rest) := by
    intro t r e; cases e; simp [conts, isCmpTok, cmpOf, atomStart]
  have hm := hPL 1 le_rfl (by omega) _ hfol g (by
    rw [h1]; rw [hcrow] at hf; simp only [List.length_append, List.length_cons] at hf
    unfold need at hf ⊢; omega)
  rw [h1, pLvl1] at hm
  rw [hcrow, pCases]
  simp only [List.append_assoc, List.cons_append, List.nil_append]
  rw [hm]
  cases c.sf <;> simp [casesEnd]

/-- The facts for an expression printed with the generic `crow` and not a `+` chain. -/
theorem M_of (c : Ctx) (e : Json) (h0 : P0 c e) (hh : HeadOK c (pr c e).toks)
    (hl1 : 1 ≤ (pr c e).lvl) (hl : (pr c e).lvl ≤ 10) (hlvl : (pr c e).lvl ≠ 4)
    (hacc : addAcc e = [e]) (hcrow : (pr c e).crow = (pr c e).toks ++ [.kw .amp, .txt "otherwise"]) :
    M c e := by
  have hPL := PL_of c e h0 hh hl1 hl
  exact ⟨hPL, PA_generic c e hPL hlvl hacc, PCr_generic c e hPL hcrow hl1, hh, hl1, hl⟩

end Esm.Document.Math
