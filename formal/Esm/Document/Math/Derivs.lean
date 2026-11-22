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
  ⟨fun e => h1 (by cases e; rfl), fun e => absurd (by cases e; rfl) h2, by simp, by simp, by simp, Or.inl hk⟩

theorem hOK_tok (c : Ctx) (t : Tok) (r : List Tok) (hk : startA t = true)
    (h1 : t ≠ .kw .dif) (h2 : t ≠ .kw .pdiff) (h3 : ∀ s, t ≠ .rm s) (h4 : ∀ w, t ≠ .word w)
    (h5 : ∀ ch, t ≠ .letter ch) : HeadOK c (t :: r) :=
  ⟨h1, fun e => absurd e h2, h3 _, h4, fun e => absurd e (h5 _), Or.inl hk⟩

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

/-- A printed expression never starts with `_`. -/
theorem headA_us {c : Ctx} {a : Json} (ha : M c a) (L : Nat) :
    ∀ t r, (pr c a).at c.sf L = t :: r → t ≠ .kw .us := by
  intro t r he
  have h := headOK_at ha L
  rw [he] at h
  rintro rfl
  rcases h.2.2.2.2.2 with h | h <;> simp [startA, atomStart] at h

theorem derivNode_t (x : Json) : derivNode x "t" = dNode x "t" := by simp [derivNode]

theorem derivNode_ne {w : String} (hw : w ≠ "t") (x : Json) : derivNode x w = pNode x w := by
  simp [derivNode, hw]

theorem pPrim_frac (c : Ctx) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .frac :: .kw .lb :: r) = pFracL c f r := by
  rw [pPrim.eq_def]

theorem pPrim_dif {c : Ctx} (h : c.sf = .typst) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .lpg :: .kw .dif :: r) = pDT c f .dif r := by
  rw [pPrim.eq_def]; simp only; rw [h]

theorem pPrim_pdiff {c : Ctx} (h : c.sf = .typst) (f : Nat) (r : List Tok)
    (hr : ∀ r', r ≠ .kw .us :: r') :
    pPrim c (f + 1) (.kw .lpg :: .kw .pdiff :: r) = pDT c f .pdiff r := by
  rw [pPrim.eq_def]; simp only; rw [h]
  cases r with
  | nil => rfl
  | cons t r' =>
    have ht : t ≠ .kw .us := fun e => hr r' (by rw [e])
    cases t with
    | kw k => cases k <;> first | rfl | exact absurd rfl ht
    | _ => rfl

theorem pPrim_pdcall (c : Ctx) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .pdiff :: .kw .us :: r) = pDCall c f r := by
  rw [pPrim.eq_def]

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
      simp [isRp, derivNode]
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
      simp [derivNode]
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
      simp [isRp, derivNode]

/-! ## The spatial derivative `partial` -/

theorem M_dSpace (c : Ctx) (w : String) (a : Json) (hw : w ≠ "t") (hwn : nameOK w = true) (ha : M c a)
    (hpr : pr c (pNode a w) = dSpace c.sf (nameToks c w) (pr c a)) : M c (pNode a w) := by
  obtain ⟨t, tr, hA, hrb, hrp, hrp'⟩ := headA ha 1
  have hus := headA_us ha 1 t tr hA
  have hacc : addAcc (pNode a w) = [pNode a w] := rfl
  have hW := pName_nameToks c w hwn
  have hlw : 1 ≤ (nameToks c w).length := by
    obtain ⟨t, tr, he, -⟩ := nameToks_head c w; rw [he]; simp
  obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
  · by_cases hin : inlineD (pr c a) = true
    · have hpr' : pr c (pNode a w) = mkOut c.sf 10 ([.kw .frac, .kw .lb, .kw .pdiff] ++ (pr c a).at c.sf 1 ++
          [.kw .rb, .kw .lb, .kw .pdiff] ++ nameToks c w ++ [.kw .rb]) := by
        rw [hpr]; simp only [dSpace, hsf, hin, ↓reduceIte]
      refine M_of_toks c _ 10 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .frac _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; simp at hf; omega⟩
      have hp := pOr_at ha _ (fol1_rb c.sf (.kw .lb :: .kw .pdiff :: (nameToks c w ++ .kw .rb :: rest))) g
        (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append] at hp ⊢
      rw [pPrim_frac, pFracL.eq_6 _ _ _ (by intro r1 e; rw [hA] at e; simp at e; exact hrb e.1)
        (by intro r1 e; rw [hA] at e; simp at e; exact hus e.1)]
      rw [hp]
      simp only
      rw [hW _ (nameStop_kw c.sf .rb (by decide) (by decide) rest)]
      simp [derivNode_ne hw]
    · have hpr' : pr c (pNode a w) = mkOut c.sf 6 ([.kw .frac, .kw .lb, .kw .pdiff, .kw .rb, .kw .lb, .kw .pdiff] ++
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
      simp [isRp, derivNode_ne hw]
  · by_cases hin : inlineD (pr c a) = true
    · have hpr' : pr c (pNode a w) = mkOut c.sf 7 ([.kw .lpg, .kw .pdiff] ++ (pr c a).at c.sf 1 ++
          [.kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] ++ nameToks c w ++ [.kw .rp]) := by
        rw [hpr]; simp only [dSpace, hsf, hin, ↓reduceIte]
      refine M_of_toks c _ 7 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .lpg _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; simp at hf; omega⟩
      have hp := pOr_at ha _ (fol1_rp c.sf (.kw .slash :: .kw .lpg :: .kw .pdiff :: (nameToks c w ++ .kw .rp :: rest))) g
        (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append] at hp ⊢
      rw [pPrim_pdiff hsf _ _ (by intro r1 e; rw [hA] at e; simp at e; exact hus e.1),
        pDT.eq_3 _ _ _ _ (by intro k r1 e; rw [hA] at e; simp at e; exact hrp e.1)]
      rw [hp]
      simp only [↓reduceIte]
      rw [hW _ (nameStop_kw c.sf .rp (by decide) (by decide) rest)]
      simp [derivNode_ne hw]
    · have hpr' : pr c (pNode a w) = mkOut c.sf 6 ([.kw .lpg, .kw .pdiff, .kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] ++
          nameToks c w ++ [.kw .rp] ++ grp c.sf ((pr c a).at c.sf 1)) := by
        rw [hpr]; simp only [dSpace, hsf, hin, Bool.false_eq_true, ↓reduceIte]
      refine M_of_toks c _ 6 _ hpr' (by omega) (by omega) (by omega) hacc
        (hOK_kw c .lpg _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; simp at hf; omega⟩
      rw [grp_typst hsf] at hf ⊢
      have hp := pOr_at ha _ (fol1_rp c.sf rest) g (by unfold need at hf ⊢; simp at hf; omega)
      simp only [List.append_assoc, List.cons_append, List.nil_append]
      rw [pPrim_pdiff hsf _ _ (by intro r1 e; simp at e), pDT.eq_2]
      simp only [↓reduceIte]
      rw [hW _ (nameStop_kw c.sf .rp (by decide) (by decide) _)]
      simp only [show decide (Kw.pdiff = Kw.dif) = false from rfl, Bool.false_and, Bool.false_eq_true,
        ↓reduceIte]
      rw [pDApply.eq_2, hp]
      simp [isRp, derivNode_ne hw]

/-! ## `partial` with trailing operands: `\\partial_{x}(u, a, b)` -/

theorem M_dCall (c : Ctx) (w : String) (xs : List Json) (hwn : nameOK w = true)
    (hx : ∀ x ∈ xs, M c x)
    (hpr : pr c (dCallNode w xs) =
      mkOut c.sf 10 (dCall c.sf (nameToks c w) (xs.map fun x => (pr c x).at c.sf 4))) :
    M c (dCallNode w xs) := by
  have hacc : addAcc (dCallNode w xs) = [dCallNode w xs] := by unfold addAcc dCallNode; simp
  refine M_of_toks c _ 10 _ hpr (by omega) (by omega) (by omega) hacc ?_ ?_
  · unfold dCall
    split <;> (simp only [List.cons_append, HeadOK]
               refine ⟨?_, fun _ => ⟨_, rfl⟩, ?_, ?_, ?_, Or.inl (by decide)⟩ <;> simp)
  · intro rest hr f hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by
      unfold need at hf; unfold dCall at hf; split at hf <;> simp at hf <;> omega⟩
    have hca := pCallArgs_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart]))
      (Or.inl rfl) xs hx rest (g + 1) (by
        unfold need at hf ⊢; unfold dCall at hf; split at hf <;> simp [callToks] at hf <;> omega)
    obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
    · have hd : ∀ W args, dCall c.sf W args =
          [.kw .pdiff, .kw .us, .kw .lb] ++ W ++ [.kw .rb] ++ callToks c.sf [] args := by
        intro W args; simp only [dCall, hsf]
      rw [hd]
      simp only [callToks, lpC, List.nil_append, List.cons_append, List.append_assoc]
      generalize sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4) = X at hca ⊢
      rw [pPrim_pdcall]
      have hname : pName .latex (nameToks c w ++ .kw .rb :: .kw .lp :: (X ++ .kw .rp :: rest)) =
          some (w, .kw .rb :: .kw .lp :: (X ++ .kw .rp :: rest)) := by
        rw [← hsf]; exact pName_nameToks c w hwn _ (nameStop_kw _ .rb (by decide) (by decide) _)
      rw [pDCall.eq_def]; simp only; rw [hsf]; simp only; rw [hname]
      simp only [isLp, ↓reduceIte]
      rw [hca]; simp [allPos_map]
    · have hd : ∀ W args, dCall c.sf W args =
          [.kw .pdiff, .kw .us, .kw .lpg] ++ W ++ [.kw .rp] ++ callToks c.sf [] args := by
        intro W args; simp only [dCall, hsf]
      rw [hd]
      simp only [callToks, lpC, List.nil_append, List.cons_append, List.append_assoc]
      generalize sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4) = X at hca ⊢
      rw [pPrim_pdcall]
      have hname : pName .typst (nameToks c w ++ .kw .rp :: .kw .lp :: (X ++ .kw .rp :: rest)) =
          some (w, .kw .rp :: .kw .lp :: (X ++ .kw .rp :: rest)) := by
        rw [← hsf]; exact pName_nameToks c w hwn _ (nameStop_kw _ .rp (by decide) (by decide) _)
      rw [pDCall.eq_def]; simp only; rw [hsf]; simp only; rw [hname]
      simp only [isLp, ↓reduceIte]
      rw [hca]; simp [allPos_map]

/-! ## The `\nabla` forms -/

theorem nabTail_head (sf : Sf) (n : NabK) (X : List Tok)
    (hX : ∀ t r, X = t :: r → t ≠ .kw .cdot ∧ t ≠ .kw .times ∧ t ≠ .kw .caret) :
    nabTail sf ((nabHead sf n).tail ++ X) = (nabName n, X) := by
  cases n with
  | div => rfl
  | curl => rfl
  | lap => cases sf <;> rfl
  | grad =>
    simp only [nabHead, List.tail_cons, List.nil_append, nabName]
    cases X with
    | nil => cases sf <;> rfl
    | cons t r =>
      obtain ⟨h1, h2, h3⟩ := hX t r rfl
      cases sf <;> cases t <;> (try rfl) <;> (rename_i k; cases k <;>
        first | rfl | exact absurd rfl h1 | exact absurd rfl h2 | exact absurd rfl h3)

theorem nabHead_cons (sf : Sf) (n : NabK) : nabHead sf n = .kw .nabla :: (nabHead sf n).tail := by
  cases n <;> (try cases sf) <;> rfl

/-- An operand of a `\nabla` form that is not itself one reads back at level 9. -/
theorem nabArg9_read {c : Ctx} {a : Json} (ha : M c a) (n : NabK) (rest : List Tok) (hr : Fol c.sf 9 rest)
    (g : Nat) (hg : need 9 (nabArg9 c.sf n ((pr c a).at c.sf 9)).length ≤ g) :
    pPost c g (nabArg9 c.sf n ((pr c a).at c.sf 9) ++ rest) = some (a, rest) := by
  unfold nabArg9 at hg ⊢
  by_cases hn : n = .curl ∧ startsNum ((pr c a).at c.sf 9) = true
  · rw [ite_eq_left hn] at hg ⊢
    have hlvl : 9 ≤ (pr c a).lvl := by
      by_contra hc
      have h2 := hn.2
      rw [at_eq, iteF hc] at h2
      simp [grp, startsNum] at h2
    have heq : (pr c a).at c.sf 9 = (pr c a).toks := by rw [at_eq, iteT hlvl]
    rw [heq] at hg ⊢
    have := grp_child ha 9 (by omega) (by omega) rest hr g (by
      simp only [length_grp] at hg; unfold need at hg ⊢; omega)
    rwa [pLvl9] at this
  · rw [ite_eq_right hn] at hg ⊢
    have := PL_at ha 9 (by omega) (by omega) rest hr g hg
    rwa [pLvl9] at this

theorem nabArg9_head {c : Ctx} {a : Json} (ha : M c a) (n : NabK)
    (hno : ¬(startsNabla (pr c a).toks = true ∧ 6 ≤ (pr c a).lvl)) (rest : List Tok) :
    ∀ t r, nabArg9 c.sf n ((pr c a).at c.sf 9) ++ rest = t :: r →
      t ≠ .kw .cdot ∧ t ≠ .kw .times ∧ t ≠ .kw .caret ∧ t ≠ .kw .nabla := by
  intro t r he
  have hh : HeadOK c (nabArg9 c.sf n ((pr c a).at c.sf 9) ++ rest) := by
    apply headOK_append
    unfold nabArg9
    split
    · simp only [grp, List.cons_append, HeadOK]
      exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩
    · exact headOK_at ha 9
  have hnab : t ≠ .kw .nabla := by
    rintro rfl
    unfold nabArg9 at he
    by_cases hlv : 9 ≤ (pr c a).lvl
    · have heq : (pr c a).at c.sf 9 = (pr c a).toks := by rw [at_eq, iteT hlv]
      rw [heq] at he
      split at he
      · simp [grp] at he
      · cases ht : (pr c a).toks with
        | nil => have h0 := M_head ha; rw [ht] at h0; simp [HeadOK] at h0
        | cons u us =>
          rw [ht] at he
          simp only [List.cons_append, List.cons.injEq] at he
          apply hno
          rw [ht, he.1]
          exact ⟨rfl, by omega⟩
    · have heq : (pr c a).at c.sf 9 = grp c.sf (pr c a).toks := by rw [at_eq, iteF hlv]
      rw [heq] at he
      split at he <;> simp [grp] at he
  rw [he] at hh
  have h6 := hh.2.2.2.2.2
  refine ⟨?_, ?_, ?_, hnab⟩ <;> (rintro rfl; rcases h6 with h | h <;> simp [startA, atomStart] at h)

theorem M_nab (c : Ctx) (o : String) (n : NabK) (a : Json) (ho : kindOf o = .nab n) (ha : M c a)
    (hpr : pr c (node o [a]) = mkOut c.sf 6 (nabHead c.sf n ++ nabArg c.sf n (pr c a))) :
    M c (node o [a]) := by
  have hon : o = nabName n := by
    rcases kindOf_nab ho with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> rfl
  subst hon
  apply M_of
  · intro rest hr f hf
    simp only [hpr, mkOut] at hr hf ⊢
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; omega⟩
    have hlen : (nabHead c.sf n).length ≤ 5 := by cases n <;> (try cases c.sf) <;> simp [nabHead]
    have hlen1 : 1 ≤ (nabHead c.sf n).length := by cases n <;> (try cases c.sf) <;> simp [nabHead]
    rw [pLvl6, nabHead_cons]
    simp only [List.append_assoc, List.cons_append]
    rw [pNot.eq_3]
    unfold nabArg at hf ⊢
    by_cases hA : startsNabla (pr c a).toks = true ∧ 6 ≤ (pr c a).lvl
    · rw [ite_eq_left hA] at hf ⊢
      obtain ⟨tr, htr⟩ : ∃ tr, (pr c a).toks = .kw .nabla :: tr := by
        have h1 := hA.1
        cases ht : (pr c a).toks with
        | nil => rw [ht] at h1; simp [startsNabla] at h1
        | cons u us =>
          rw [ht] at h1
          cases u with
          | kw k => cases k <;> simp [startsNabla] at h1 ⊢
          | _ => simp [startsNabla] at h1
      have h6 := PL_at ha 6 (by omega) (by omega) rest hr g (by
        rw [at_eq, iteT hA.2]; simp only [List.length_append] at hf; unfold need at hf ⊢; omega)
      rw [pLvl6, at_eq, iteT hA.2] at h6
      rw [nabTail_head c.sf n _ (by
        intro t r he; rw [htr] at he; simp only [List.cons_append, List.cons.injEq] at he
        obtain ⟨rfl, -⟩ := he; refine ⟨?_, ?_, ?_⟩ <;> simp)]
      simp only
      rw [htr]
      simp only [List.cons_append]
      rw [pNabArg.eq_2, ← List.cons_append, ← htr, h6]
    · rw [ite_eq_right hA] at hf ⊢
      have hh := nabArg9_head ha n hA rest
      rw [nabTail_head c.sf n _ (fun t r he => ⟨(hh t r he).1, (hh t r he).2.1, (hh t r he).2.2.1⟩)]
      simp only
      rw [pNabArg.eq_3 _ _ _ (fun r he => (hh _ r he).2.2.2 rfl)]
      rw [nabArg9_read ha n rest (hr.mono (by omega)) g (by
        simp only [List.length_append] at hf; unfold need at hf ⊢; omega)]
  · rw [hpr, nabHead_cons]; exact headOK_kw c _ _ ⟨.nabla, rfl, rfl, by decide, by decide⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by cases n <;> decide)
  · rw [hpr]; rfl

/-! ## Quantities -/

theorem M_qty (c : Ctx) (u : String) (n : JNum) (hu : unitsOK c.sf u = true)
    (hpr : pr c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)]) =
      mkOut c.sf 7 (qtyToks n (factorsOf u))) :
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
    exact hOK_tok c _ _ (by simp [startA, atomStart]) (by simp) (by simp) (by simp) (by simp)
      (by simp)
  · intro rest hr f hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
    simp only [qtyToks, List.cons_append, List.nil_append]
    rw [pPrim.eq_def]; simp [hq]

end Esm.Document.Math
