import Esm.Document.Math.Templates

/-!
# Round trip, case by case: derivatives and quantities
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## Generic steps -/

theorem M_of_toks (c : Ctx) (e : Json) (L : Nat) (toks : List Tok)
    (hpr : pr c e = mkOut c.sf L toks) (h1 : 1 ≤ L) (h10 : L ≤ 10) (h4 : L ≠ 4)
    (hacc : addAcc e = [e]) (hh : HeadOK c toks)
    (hp : ∀ rest, Fol c.sf 10 rest → ∀ f, need 10 toks.length ≤ f →
      pPrim c f (toks ++ rest) = some (e, rest)) : M c e := by
  apply M_of
  · apply P0_of_prim
    · rw [hpr]; exact hp
    · rw [hpr]; exact h1
    · rw [hpr]; exact h10
  · rw [hpr]; exact hh
  · rw [hpr]; exact h1
  · rw [hpr]; exact h10
  · rw [hpr]; exact h4
  · exact hacc
  · rw [hpr]; rfl

theorem hOK_kw (c : Ctx) (k : Kw) (r : List Tok) (hk : startA (.kw k) = true)
    (h1 : k ≠ .dif) (h2 : k ≠ .pdiff) : HeadOK c (.kw k :: r) :=
  ⟨fun e => h1 (by cases e; rfl), fun e => h2 (by cases e; rfl), by simp, by simp, by simp, Or.inl hk⟩

theorem hOK_tok (c : Ctx) (t : Tok) (r : List Tok) (hk : startA t = true)
    (h1 : t ≠ .kw .dif) (h2 : t ≠ .kw .pdiff) (h3 : ∀ s, t ≠ .rm s) (h4 : ∀ w, t ≠ .word w)
    (h5 : ∀ ch, t ≠ .letter ch) : HeadOK c (t :: r) :=
  ⟨h1, h2, h3 _, h4, fun e => absurd e (h5 _), Or.inl hk⟩

theorem nameStop_kw (sf : Sf) (k : Kw) (hk : k ≠ .sdot) (hk2 : k ≠ .us) (r : List Tok) :
    NameStop sf (.kw k :: r) := by
  refine ⟨fun r' e => by cases e; exact hk rfl, ?_⟩
  rcases r with _ | ⟨t2, _ | ⟨t3, _ | ⟨t4, r4⟩⟩⟩
  · rfl
  · rfl
  · rfl
  · show subPat4 sf (.kw k) t2 t3 t4 = false
    unfold subPat4
    split
    all_goals first | rfl | (exfalso; simp_all)

theorem pName_t (sf : Sf) (X : List Tok) (h : NameStop sf X) :
    pName sf (.letter 't' :: X) = some ("t", X) := by
  unfold pName pSeg
  simp only [show isLetter 't' = true from rfl, ↓reduceIte, subOrPlain_stop sf ['t'] X h.2]
  rw [pNameLoop_stop sf _ _ X h.1]
  rfl

theorem headA {c : Ctx} {a : Json} (ha : M c a) (L : Nat) :
    ∃ t r, (pr c a).at c.sf L = t :: r ∧ t ≠ .kw .rb ∧ t ≠ .kw .rp ∧ isRp t = false := by
  obtain ⟨t, r, he, h1, h2, -, -, -, -⟩ := headOK_closer (headOK_at ha L)
  exact ⟨t, r, he, h2, by rintro rfl; simp [isRp] at h1, h1⟩

theorem pPrim_frac (c : Ctx) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .frac :: .kw .lb :: r) = pFracL c f r := by
  rw [pPrim.eq_def]

theorem pPrim_dif {c : Ctx} (h : c.sf = .typst) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .lpg :: .kw .dif :: r) = pDT c f .dif r := by
  rw [pPrim.eq_def]; simp only; rw [h]

theorem pPrim_pdiff {c : Ctx} (h : c.sf = .typst) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .lpg :: .kw .pdiff :: r) = pDT c f .pdiff r := by
  rw [pPrim.eq_def]; simp only; rw [h]

theorem pPrim_opn (c : Ctx) (f : Nat) (n : String) (r : List Tok) :
    pPrim c (f + 1) (.opn n :: r) = pOpn c f n r := by
  rw [pPrim.eq_def]

theorem pOpn_D (c : Ctx) (f : Nat) (r : List Tok) :
    pOpn c (f + 1) "D" (.kw .us :: r) = pDCall c f r := by
  rw [pOpn.eq_def]; simp [isLp]

theorem fol1_rb (sf : Sf) (r : List Tok) : Fol sf 1 (.kw .rb :: r) := fol1_kw sf .rb (by simp) r
theorem fol1_rp (sf : Sf) (r : List Tok) : Fol sf 1 (.kw .rp :: r) := fol1_kw sf .rp (by simp) r
theorem fol1_rpg (sf : Sf) (r : List Tok) : Fol sf 1 (.kw .rpg :: r) := fol1_kw sf .rpg (by simp) r

theorem pOr_at {c : Ctx} {a : Json} (ha : M c a) (X : List Tok) (hX : Fol c.sf 1 X) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pOr c f ((pr c a).at c.sf 1 ++ X) = some (a, X) := by
  have := PL_at ha 1 (by omega) (by omega) X hX f hf
  rwa [pLvl1] at this

theorem grp_latex {sf : Sf} (h : sf = .latex) (X : List Tok) : grp sf X = .kw .lpg :: X ++ [.kw .rpg] := by
  simp [grp, h]

theorem grp_typst {sf : Sf} (h : sf = .typst) (X : List Tok) : grp sf X = .kw .lpg :: X ++ [.kw .rp] := by
  simp [grp, h]

/-! ## The time derivative -/

theorem M_dTime (c : Ctx) (a : Json) (ha : M c a) (hpr : pr c (dNode a "t") = dTime c.sf (pr c a)) :
    M c (dNode a "t") := by
  obtain ⟨t, tr, hA, hrb, hrp, hrp'⟩ := headA ha 1
  have hacc : addAcc (dNode a "t") = [dNode a "t"] := rfl
  obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
  · by_cases hin : inlineD (pr c a) = true
    · have hpr' : pr c (dNode a "t") = mkOut c.sf 10 ([.kw .frac, .kw .lb, .rm "d"] ++ (pr c a).at c.sf 1 ++
          [.kw .rb, .kw .lb, .rm "d", .letter 't', .kw .rb]) := by
        rw [hpr]; simp only [dTime, hsf, hin, ↓reduceIte]
      refine M_of_toks c _ 10 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .frac _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; simp at hf; omega⟩
      have hp := pOr_at ha _ (fol1_rb c.sf (.kw .lb :: .rm "d" :: .letter 't' :: .kw .rb :: rest)) g
        (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append]
      rw [pPrim_frac, pFracL.eq_3 _ _ _ (by intro r1 e; rw [hA] at e; simp at e; exact hrb e.1)]
      rw [hp]; rfl
    · have hpr' : pr c (dNode a "t") = mkOut c.sf 6 ([.kw .frac, .kw .lb, .rm "d", .kw .rb, .kw .lb, .rm "d",
          .letter 't', .kw .rb] ++ grp c.sf ((pr c a).at c.sf 1)) := by
        rw [hpr]; simp only [dTime, hsf, hin, Bool.false_eq_true, ↓reduceIte]
      refine M_of_toks c _ 6 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .frac _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; simp at hf; omega⟩
      rw [grp_latex hsf] at hf ⊢
      have hp := pOr_at ha _ (fol1_rpg c.sf rest) g (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append]
      rw [pPrim_frac, pFracL.eq_2, pDApply.eq_2, hp]
      simp [isRp]
  · by_cases hin : inlineD (pr c a) = true
    · have hpr' : pr c (dNode a "t") = mkOut c.sf 7 ([.kw .lpg, .kw .dif] ++ (pr c a).at c.sf 1 ++
          [.kw .rp, .kw .slash, .kw .lpg, .kw .dif, .letter 't', .kw .rp]) := by
        rw [hpr]; simp only [dTime, hsf, hin, ↓reduceIte]
      refine M_of_toks c _ 7 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .lpg _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; simp at hf; omega⟩
      have hp := pOr_at ha _ (fol1_rp c.sf (.kw .slash :: .kw .lpg :: .kw .dif :: .letter 't' :: .kw .rp :: rest)) g
        (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append]
      rw [pPrim_dif hsf, pDT.eq_3 _ _ _ _ (by intro k r1 e; rw [hA] at e; simp at e; exact hrp e.1)]
      rw [hp]
      simp only [↓reduceIte]
      rw [pName_t c.sf _ (nameStop_kw c.sf .rp (by decide) (by decide) rest)]
      simp
    · have hpr' : pr c (dNode a "t") = mkOut c.sf 6 ([.kw .lpg, .kw .dif, .kw .rp, .kw .slash, .kw .lpg, .kw .dif,
          .letter 't', .kw .rp] ++ grp c.sf ((pr c a).at c.sf 1)) := by
        rw [hpr]; simp only [dTime, hsf, hin, Bool.false_eq_true, ↓reduceIte]
      refine M_of_toks c _ 6 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .lpg _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; simp at hf; omega⟩
      rw [grp_typst hsf] at hf ⊢
      have hp := pOr_at ha _ (fol1_rp c.sf rest) g (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append]
      rw [pPrim_dif hsf, pDT.eq_2]
      simp only [↓reduceIte]
      rw [pName_t c.sf _ (nameStop_kw c.sf .rp (by decide) (by decide) _)]
      simp only [bne_self_eq_false, Bool.and_false, Bool.false_eq_true, ↓reduceIte]
      rw [pDApply.eq_2, hp]
      simp [isRp]

/-! ## The spatial derivative -/

theorem M_dSpace (c : Ctx) (w : String) (a : Json) (hwn : nameOK w = true) (ha : M c a)
    (hpr : pr c (dNode a w) = dSpace c.sf (nameToks c w) (pr c a)) : M c (dNode a w) := by
  obtain ⟨t, tr, hA, hrb, hrp, hrp'⟩ := headA ha 1
  have hacc : addAcc (dNode a w) = [dNode a w] := rfl
  have hW := pName_nameToks c w hwn
  have hlw : 1 ≤ (nameToks c w).length := by
    obtain ⟨t, tr, he, -⟩ := nameToks_head c w; rw [he]; simp
  obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
  · by_cases hin : inlineD (pr c a) = true
    · have hpr' : pr c (dNode a w) = mkOut c.sf 10 ([.kw .frac, .kw .lb, .kw .pdiff] ++ (pr c a).at c.sf 1 ++
          [.kw .rb, .kw .lb, .kw .pdiff] ++ nameToks c w ++ [.kw .rb]) := by
        rw [hpr]; simp only [dSpace, hsf, hin, ↓reduceIte]
      refine M_of_toks c _ 10 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .frac _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; simp at hf; omega⟩
      have hp := pOr_at ha _ (fol1_rb c.sf (.kw .lb :: .kw .pdiff :: (nameToks c w ++ .kw .rb :: rest))) g
        (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append] at hp ⊢
      rw [pPrim_frac, pFracL.eq_5 _ _ _ (by intro r1 e; rw [hA] at e; simp at e; exact hrb e.1)]
      rw [hp]
      simp only
      rw [hW _ (nameStop_kw c.sf .rb (by decide) (by decide) rest)]
    · have hpr' : pr c (dNode a w) = mkOut c.sf 6 ([.kw .frac, .kw .lb, .kw .pdiff, .kw .rb, .kw .lb, .kw .pdiff] ++
          nameToks c w ++ [.kw .rb] ++ grp c.sf ((pr c a).at c.sf 1)) := by
        rw [hpr]; simp only [dSpace, hsf, hin, Bool.false_eq_true, ↓reduceIte]
      refine M_of_toks c _ 6 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .frac _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; simp at hf; omega⟩
      rw [grp_latex hsf] at hf ⊢
      have hp := pOr_at ha _ (fol1_rpg c.sf rest) g (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append]
      rw [pPrim_frac, pFracL.eq_4]
      rw [hW _ (nameStop_kw c.sf .rb (by decide) (by decide) _)]
      simp only
      rw [pDApply.eq_2, hp]
      simp [isRp]
  · by_cases hin : inlineD (pr c a) = true
    · have hpr' : pr c (dNode a w) = mkOut c.sf 7 ([.kw .lpg, .kw .pdiff] ++ (pr c a).at c.sf 1 ++
          [.kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] ++ nameToks c w ++ [.kw .rp]) := by
        rw [hpr]; simp only [dSpace, hsf, hin, ↓reduceIte]
      refine M_of_toks c _ 7 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .lpg _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; simp at hf; omega⟩
      have hp := pOr_at ha _ (fol1_rp c.sf (.kw .slash :: .kw .lpg :: .kw .pdiff :: (nameToks c w ++ .kw .rp :: rest))) g
        (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append] at hp ⊢
      rw [pPrim_pdiff hsf, pDT.eq_3 _ _ _ _ (by intro k r1 e; rw [hA] at e; simp at e; exact hrp e.1)]
      rw [hp]
      simp only [↓reduceIte]
      rw [hW _ (nameStop_kw c.sf .rp (by decide) (by decide) rest)]
      simp
    · have hpr' : pr c (dNode a w) = mkOut c.sf 6 ([.kw .lpg, .kw .pdiff, .kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] ++
          nameToks c w ++ [.kw .rp] ++ grp c.sf ((pr c a).at c.sf 1)) := by
        rw [hpr]; simp only [dSpace, hsf, hin, Bool.false_eq_true, ↓reduceIte]
      refine M_of_toks c _ 6 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .lpg _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; simp at hf; omega⟩
      rw [grp_typst hsf] at hf ⊢
      have hp := pOr_at ha _ (fol1_rp c.sf rest) g (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append]
      rw [pPrim_pdiff hsf, pDT.eq_2]
      simp only [↓reduceIte]
      rw [hW _ (nameStop_kw c.sf .rp (by decide) (by decide) _)]
      simp only [show decide (Kw.pdiff = Kw.dif) = false from rfl, Bool.false_and, Bool.false_eq_true,
        ↓reduceIte]
      rw [pDApply.eq_2, hp]
      simp [isRp]

/-! ## The spatial derivative with trailing operands -/

theorem M_dCall (c : Ctx) (w : String) (xs : List Json) (hwn : nameOK w = true)
    (hx : ∀ x ∈ xs, M c x)
    (hpr : pr c (dCallNode w xs) =
      mkOut c.sf 10 (dCall c.sf (nameToks c w) (xs.map fun x => (pr c x).at c.sf 4))) :
    M c (dCallNode w xs) := by
  have hacc : addAcc (dCallNode w xs) = [dCallNode w xs] := by unfold addAcc dCallNode; simp
  refine M_of_toks c _ 10 _ hpr (by omega) (by omega) (by omega) hacc ?_ ?_
  · unfold dCall
    split <;> (simp only [List.cons_append]
               exact hOK_tok c _ _ (by simp [startA, atomStart]) (by simp) (by simp) (by simp) (by simp)
                 (by simp))
  · intro rest hr f hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by
      unfold need at hf; unfold dCall at hf; split at hf <;> simp at hf <;> omega⟩
    have hca := pCallArgs_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart]))
      (Or.inl rfl) xs hx rest g (by
        unfold need at hf ⊢; unfold dCall at hf; split at hf <;> simp [callToks] at hf <;> omega)
    obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
    · have hd : ∀ W args, dCall c.sf W args =
          [.opn "D", .kw .us, .kw .lb] ++ W ++ [.kw .rb] ++ callToks c.sf [] args := by
        intro W args; simp only [dCall, hsf]
      rw [hd]
      simp only [callToks, lpC, List.nil_append, List.cons_append, List.append_assoc]
      generalize sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4) = X at hca ⊢
      rw [pPrim_opn, pOpn_D]
      have hname : pName .latex (nameToks c w ++ .kw .rb :: .kw .lp :: (X ++ .kw .rp :: rest)) =
          some (w, .kw .rb :: .kw .lp :: (X ++ .kw .rp :: rest)) := by
        rw [← hsf]; exact pName_nameToks c w hwn _ (nameStop_kw _ .rb (by decide) (by decide) _)
      rw [pDCall.eq_def]; simp only; rw [hsf]; simp only; rw [hname]
      simp only [isLp, ↓reduceIte]
      rw [hca]; simp [allPos_map]
    · have hd : ∀ W args, dCall c.sf W args =
          [.opn "D", .kw .us, .kw .lpg] ++ W ++ [.kw .rp] ++ callToks c.sf [] args := by
        intro W args; simp only [dCall, hsf]
      rw [hd]
      simp only [callToks, lpC, List.nil_append, List.cons_append, List.append_assoc]
      generalize sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4) = X at hca ⊢
      rw [pPrim_opn, pOpn_D]
      have hname : pName .typst (nameToks c w ++ .kw .rp :: .kw .lp :: (X ++ .kw .rp :: rest)) =
          some (w, .kw .rp :: .kw .lp :: (X ++ .kw .rp :: rest)) := by
        rw [← hsf]; exact pName_nameToks c w hwn _ (nameStop_kw _ .rp (by decide) (by decide) _)
      rw [pDCall.eq_def]; simp only; rw [hsf]; simp only; rw [hname]
      simp only [isLp, ↓reduceIte]
      rw [hca]; simp [allPos_map]

/-! ## Quantities -/

theorem M_qty (c : Ctx) (u : String) (n : JNum) (hu : unitsOK c.sf u = true)
    (hpr : pr c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)]) =
      mkOut c.sf 7 (qtyToks c.sf n (factorsOf u))) :
    M c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)]) := by
  have hacc : addAcc (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)]) =
      [.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)]] := by
    unfold addAcc; simp
  have hsp : Esm.Units.spell (factorsOf u) = u := by
    simp only [unitsOK, Bool.and_eq_true, beq_iff_eq] at hu; exact hu.1.1.2
  have hq : qty n (factorsOf u) =
      .obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)] := by
    simp [qty, hsp]
  refine M_of_toks c _ 7 _ hpr (by omega) (by omega) (by omega) hacc ?_ ?_
  · unfold qtyToks
    split <;> exact hOK_tok c _ _ (by simp [startA, atomStart]) (by simp) (by simp) (by simp) (by simp)
      (by simp)
  · intro rest hr f hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
    obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
    · have hl : Esm.Units.parseLatex (Esm.Units.latex (factorsOf u)) = some (factorsOf u) := by
        simp only [unitsOK, Bool.and_eq_true, beq_iff_eq, hsf] at hu; exact hu.2
      have ht : qtyToks c.sf n (factorsOf u) =
          [.num n, .kw .thin, .rm (String.ofList (Esm.Units.latexBody (factorsOf u)))] := by
        simp [qtyToks, hsf]
      rw [ht]; simp only [List.cons_append, List.nil_append]
      rw [pPrim.eq_def]; simp only; rw [hsf]; simp only
      have hr : unitsOfRaw (String.ofList (Esm.Units.latexBody (factorsOf u))) = some (factorsOf u) := by
        unfold unitsOfRaw; rw [String.toList_ofList]; exact hl
      rw [hr]; simp [hq]
    · have ht : qtyToks c.sf n (factorsOf u) = [.num n, .units (factorsOf u)] := by
        simp [qtyToks, hsf]
      rw [ht]; simp only [List.cons_append, List.nil_append]
      rw [pPrim.eq_def]; simp only; rw [hsf]; simp [hq]

end Esm.Document.Math
