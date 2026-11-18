import Esm.Document.Math.Faq

/-!
# Round trip, case by case: block assembly (`makearray`) and a bare template

A native `makearray` is a bracketed two-column table, one row per region (the value,
then the region as bound pairs joined by `\times`), with its output indices as the
bracket's subscript. A template applied with no bindings, unless the symbol table knows
it with no parameters, is its bare name, `\operatorname{n}`.
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## A bare template -/

theorem bareOK_of (S : Sym) (n : String) (hn : tnameOK n = true) (hps : positional S n [] = none) :
    bareOK S n = true := by
  unfold bareOK
  rw [hn, Bool.true_and]
  cases ht : tparams S n with
  | none => rfl
  | some ps =>
    cases ps with
    | nil => simp [positional, ht] at hps
    | cons p ps => rfl

theorem M_tbare (c : Ctx) (n : String) (hn : tnameOK n = true) (hps : positional c.S n [] = none)
    (hpr : pr c (tNode n []) = mkOut c.sf 5 [.opn n]) : M c (tNode n []) := by
  have hb := bareOK_of c.S n hn hps
  refine M_of_toksL c _ 5 _ hpr (by omega) (by omega) (by omega) (by unfold addAcc tNode; simp)
    (⟨by simp, by simp, by simp, by simp, by simp, Or.inl rfl⟩) ?_
  intro rest hr f hf
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; simp at hf; omega⟩
  rw [pPrim.eq_def]; simp only [List.cons_append, List.nil_append]
  rw [pOpn.eq_def]
  cases rest with
  | nil => simp [hb]
  | cons t r =>
    have ht := hr _ _ rfl
    have h1 : isLp t = false := by
      cases t <;> try rfl
      rename_i k; cases k <;> first | rfl | simp [conts, atomStart] at ht
    simp only [h1, Bool.false_eq_true, ↓reduceIte, hb]
    split
    · exfalso; simp [conts] at ht
    · rfl

/-! ## Block assembly -/

/-- What the round trip of a native `makearray` knows of a sub-expression. -/
def GoodX (c : Ctx) (P : Json → Out) (x : Json) : Prop := M c x ∧ P x = pr c x

theorem pPair_read (c : Ctx) (P : Json → Out) (p : Json × Json) (h1 : GoodX c P p.1) (h2 : GoodX c P p.2)
    (X : List Tok) (f : Nat) (hf : 30 * (pairToks c P p).length + 15 ≤ f) :
    pPair c (f + 1) (pairToks c P p ++ .kw .rbk :: X) = some (p, X) := by
  obtain ⟨a, b⟩ := p
  simp only at h1 h2
  obtain ⟨ha, hPa⟩ := h1
  obtain ⟨hb, hPb⟩ := h2
  simp only [pairToks, hPa, hPb] at hf ⊢
  simp only [List.length_append, List.length_cons] at hf
  simp only [List.append_assoc, List.cons_append]
  rw [pPair, pOr_at ha _ (fol1_kw _ .comma (by simp) _) f (by unfold need; omega)]
  simp only
  rw [pOr_at hb _ (fol1_kw _ .rbk (by simp) _) f (by unfold need; omega)]

def tailToks (c : Ctx) (P : Json → Out) (ps : List (Json × Json)) : List Tok :=
  ps.flatMap (fun q => .kw .times :: .kw .lbk :: pairToks c P q ++ [.kw .rbk])

theorem pRegTail_read (c : Ctx) (P : Json → Out) (X : List Tok) (hX : ∀ r, X ≠ .kw .times :: .kw .lbk :: r) :
    ∀ (ps : List (Json × Json)), (∀ p ∈ ps, GoodX c P p.1 ∧ GoodX c P p.2) → ∀ f,
      30 * (tailToks c P ps).length + 15 ≤ f →
      pRegTail c (f + 1) (tailToks c P ps ++ X) = some (ps, X)
  | [], _, f, _ => by
    simp only [tailToks, List.flatMap_nil, List.nil_append]
    rw [pRegTail.eq_def]
    split <;> first | (exfalso; simp_all; done) | rfl
  | q :: ps, hg, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    have hq := hg q (by simp)
    have ih := pRegTail_read c P X hX ps (fun p hp => hg p (by simp [hp]))
    have e : tailToks c P (q :: ps) ++ X =
        .kw .times :: .kw .lbk :: (pairToks c P q ++ .kw .rbk :: (tailToks c P ps ++ X)) := by
      simp [tailToks]
    have hl : (tailToks c P (q :: ps)).length = (pairToks c P q).length + 3 + (tailToks c P ps).length := by
      simp [tailToks]; omega
    rw [e, pRegTail.eq_def]; simp only
    rw [pPair_read c P q hq.1 hq.2 _ g (by omega)]
    simp only
    rw [ih g (by omega)]; rfl

theorem regToks_eq (c : Ctx) (P : Json → Out) (p : Json × Json) (ps : List (Json × Json)) :
    regToks c P (p :: ps) = .kw .lbk :: pairToks c P p ++ .kw .rbk :: tailToks c P ps := rfl

/-- The rows of a table, as printed. -/
def rowsToksM (c : Ctx) (P : Json → Out) (rows : List (Json × List (Json × Json))) : List Tok :=
  sepBy [.kw (rowSep c.sf)] (rows.map (mkRow c P))

theorem cellSep_fol (sf : Sf) (r : List Tok) : Fol sf 1 (.kw (cellSep sf) :: r) := by
  cases sf
  · exact fol1_kw _ .amp (by simp) r
  · exact fol1_kw _ .comma (by simp) r

theorem length_mkRow (c : Ctx) (P : Json → Out) (vr : Json × List (Json × Json)) :
    1 ≤ (mkRow c P vr).length := by
  simp [mkRow]; omega

theorem pMkRows_read (c : Ctx) (P : Json → Out) (close : Kw) (hcl : close ≠ rowSep c.sf)
    (hct : close ≠ .times) (hrt : rowSep c.sf ≠ .times) (X : List Tok) :
    ∀ (rows : List (Json × List (Json × Json))), rows ≠ [] →
      (∀ vr ∈ rows, GoodX c P vr.1 ∧ vr.2 ≠ [] ∧ ∀ p ∈ vr.2, GoodX c P p.1 ∧ GoodX c P p.2) → ∀ f,
      30 * (rowsToksM c P rows).length + 20 ≤ f →
      pMkRows c (f + 1) (cellSep c.sf) (rowSep c.sf) close (rowsToksM c P rows ++ .kw close :: X) =
        some (rows, X)
  | [], h, _, _, _ => absurd rfl h
  | vr :: rows, _, hg, f, hf => by
    obtain ⟨v, reg⟩ := vr
    obtain ⟨⟨hv, hPv⟩, hne, hps⟩ := hg (v, reg) (by simp)
    dsimp only at hv hPv hne hps
    obtain ⟨p, ps, rfl⟩ := List.exists_cons_of_ne_nil hne
    have hp := hps p (by simp)
    have hps' : ∀ q ∈ ps, GoodX c P q.1 ∧ GoodX c P q.2 := fun q hq => hps q (by simp [hq])
    -- the row's tokens, then what follows it
    have hrow : ∀ (Y : List Tok) (k : Kw), (k = rowSep c.sf ∨ k = close) → ∀ g,
        30 * (mkRow c P (v, p :: ps)).length + 15 ≤ g →
        (pOr c g ((P v).at c.sf 1 ++ .kw (cellSep c.sf) :: .kw .lbk :: (pairToks c P p ++ .kw .rbk ::
          (tailToks c P ps ++ .kw k :: Y))) = some (v, .kw (cellSep c.sf) :: .kw .lbk :: (pairToks c P p ++
            .kw .rbk :: (tailToks c P ps ++ .kw k :: Y)))) ∧
        pPair c g (pairToks c P p ++ .kw .rbk :: (tailToks c P ps ++ .kw k :: Y)) =
          some (p, tailToks c P ps ++ .kw k :: Y) ∧
        pRegTail c g (tailToks c P ps ++ .kw k :: Y) = some (ps, .kw k :: Y) := by
      intro Y k hk g hg
      simp only [mkRow, regToks_eq, List.length_append, List.length_cons] at hg
      obtain ⟨g', rfl⟩ : ∃ g', g = g' + 1 := ⟨g - 1, by omega⟩
      have hkt : k ≠ .times := by rcases hk with rfl | rfl <;> assumption
      refine ⟨?_, pPair_read c P p hp.1 hp.2 _ g' (by omega),
        pRegTail_read c P _ (fun _ e => hkt (by cases e; rfl)) ps hps' g' (by omega)⟩
      rw [hPv]
      exact pOr_at hv _ (cellSep_fol _ _) _ (by rw [← hPv]; unfold need; omega)
    cases rows with
    | nil =>
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
      simp only [rowsToksM, List.map_cons, List.map_nil, sepBy] at hf ⊢
      obtain ⟨h1, h2, h3⟩ := hrow X close (Or.inr rfl) (g + 1) (by omega)
      simp only [mkRow, regToks_eq, List.append_assoc, List.cons_append]
      rw [pMkRows.eq_def]; simp only
      rw [h1]; simp only [↓reduceIte]
      rw [h2]; simp only
      rw [h3]; simp only [hcl, ↓reduceIte]
    | cons vr2 rows =>
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
      have ih := pMkRows_read c P close hcl hct hrt X (vr2 :: rows) (by simp)
        (fun q hq => hg q (by simp [hq])) g
      simp only [rowsToksM, List.map_cons, sepBy_cons2, List.length_append, List.length_cons] at hf ih ⊢
      obtain ⟨h1, h2, h3⟩ := hrow (sepBy [.kw (rowSep c.sf)] (mkRow c P vr2 :: rows.map (mkRow c P)) ++
        .kw close :: X) (rowSep c.sf) (Or.inl rfl) (g + 1) (by omega)
      have e1 : mkRow c P (v, p :: ps) = (P v).at c.sf 1 ++ .kw (cellSep c.sf) :: .kw .lbk ::
          (pairToks c P p ++ .kw .rbk :: tailToks c P ps) := by simp [mkRow, regToks_eq]
      rw [e1]
      simp only [List.append_assoc, List.cons_append, List.nil_append] at h1 h2 h3 ⊢
      rw [pMkRows.eq_def]; simp only
      rw [h1]; simp only [↓reduceIte]
      rw [h2]; simp only
      rw [h3]; simp only [↓reduceIte]
      have := length_mkRow c P vr2
      rw [e1] at hf
      simp only [List.length_append, List.length_cons] at hf
      rw [ih (by omega)]
      rfl

theorem mkTail_read (c : Ctx) (rows : List (Json × List (Json × Json))) (out : List String)
    (ho : ∀ n ∈ out, nameOK n = true) (rest : List Tok) (hr : ∀ r, rest ≠ .kw .us :: r) :
    mkTail c.sf rows (mkSub c out ++ rest) = some (mkJson ⟨out, rows.map Prod.snd, rows.map Prod.fst⟩, rest) := by
  unfold mkSub
  split
  · rename_i he; subst he
    simp only [List.nil_append]
    unfold mkTail
    split <;> first | (exfalso; simp_all; done) | rfl
  · rename_i hne
    have hl := names_len c out
    obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
    · simp only [hsf, List.cons_append, List.append_assoc, List.nil_append]
      unfold mkTail
      simp only
      rw [← hsf, pNames_read c (.kw .rb :: rest) (nameStop_kw _ _ (by decide) (by decide) _)
        (fun _ e => by cases e) out hne ho _ (by simp; omega)]
    · simp only [hsf, List.cons_append, List.append_assoc, List.nil_append]
      unfold mkTail
      simp only
      rw [← hsf, pNames_read c (.kw .rp :: rest) (nameStop_kw _ _ (by decide) (by decide) _)
        (fun _ e => by cases e) out hne ho _ (by simp; omega)]

theorem mkOK_parts {A : MkForm} (h : mkOK A = true) :
    A.values ≠ [] ∧ A.regions.length = A.values.length ∧ (∀ v ∈ A.values, isE v = true) ∧
      (∀ r ∈ A.regions, r ≠ [] ∧ ∀ p ∈ r, isE p.1 = true ∧ isE p.2 = true) ∧
      ∀ n ∈ A.out, nameOK n = true := by
  simp only [mkOK, Bool.and_eq_true, Bool.not_eq_true', List.isEmpty_eq_false_iff, beq_iff_eq,
    List.all_eq_true] at h
  obtain ⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩ := h
  exact ⟨h1, h2, h3, fun r hr => ⟨(h4 r hr).1, fun p hp => (h4 r hr).2 p hp⟩, h5⟩

theorem mkSubs_isE {A : MkForm} (h : mkOK A = true) : ∀ x ∈ mkSubs A, isE x = true := by
  obtain ⟨-, -, hv, hr, -⟩ := mkOK_parts h
  intro x hx
  simp only [mkSubs, List.mem_append, List.mem_flatMap] at hx
  rcases hx with hx | ⟨r, hrm, p, hp, hx⟩
  · exact hv x hx
  · have := (hr r hrm).2 p hp
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hx
    rcases hx with rfl | rfl
    · exact this.1
    · exact this.2

theorem addAcc_mk (A : MkForm) : addAcc (mkJson A) = [mkJson A] := by
  unfold addAcc mkJson
  split
  · rename_i xs heq
    simp only [Json.obj.injEq, List.cons_append, List.cons.injEq, Prod.mk.injEq] at heq
    obtain ⟨-, h2⟩ := heq
    simp at h2
  · rfl

/-- A native `makearray` reads back. -/
theorem M_mk (c : Ctx) (kvs : List (String × Json)) (A : MkForm) (hA : mkForm kvs = some A)
    (hok : mkOK A = true) (P : Json → Out) (hP : ∀ x ∈ mkSubs A, P x = pr c x)
    (hpr : pr c (.obj kvs) = mkOutT c P A) (hM : ∀ x ∈ mkSubs A, M c x) : M c (.obj kvs) := by
  have hj := mkForm_json hA
  obtain ⟨hvne, hlen, -, hrg, ho⟩ := mkOK_parts hok
  have hG : ∀ x ∈ mkSubs A, GoodX c P x := fun x hx => ⟨hM x hx, hP x hx⟩
  let rows := A.values.zip A.regions
  have hfst : rows.map Prod.fst = A.values := List.map_fst_zip (by omega)
  have hsnd : rows.map Prod.snd = A.regions := List.map_snd_zip (by omega)
  have hrowsne : rows ≠ [] := by
    intro e; have := congrArg (List.map Prod.fst) e; rw [hfst] at this; exact hvne this
  have hgood : ∀ vr ∈ rows, GoodX c P vr.1 ∧ vr.2 ≠ [] ∧ ∀ p ∈ vr.2, GoodX c P p.1 ∧ GoodX c P p.2 := by
    intro vr hvr
    have h1 : vr.1 ∈ A.values := by rw [← hfst]; exact List.mem_map_of_mem hvr
    have h2 : vr.2 ∈ A.regions := by rw [← hsnd]; exact List.mem_map_of_mem hvr
    refine ⟨hG _ (by simp [mkSubs, h1]), (hrg _ h2).1, fun p hp => ⟨hG _ ?_, hG _ ?_⟩⟩ <;>
      · simp only [mkSubs, List.mem_append, List.mem_flatMap]
        right; exact ⟨vr.2, h2, p, hp, by simp⟩
  have hnode : mkJson ⟨A.out, rows.map Prod.snd, rows.map Prod.fst⟩ = .obj kvs := by
    rw [hfst, hsnd, ← hj]
  have hacc : addAcc (.obj kvs) = [.obj kvs] := by rw [← hj]; exact addAcc_mk A
  have hrl := length_le_sepBy [.kw (rowSep c.sf)] (by simp) (rows.map (mkRow c P))
    (fun x hx => by obtain ⟨vr, -, rfl⟩ := List.mem_map.1 hx; simp [mkRow])
  obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
  · have hpr' : pr c (.obj kvs) = mkOut c.sf 10 ([.kw .lbkg, .kw .barr] ++ rowsToksM c P rows ++
        [.kw .earr, .kw .rbkg] ++ mkSub c A.out) := by
      rw [hpr]; unfold mkOutT rowsToksM; simp only; rw [hsf]
    refine M_of_toks c _ 10 _ hpr' (by omega) (by omega) (by omega) hacc
      (hOK_kw c .lbkg _ (by decide) (by decide) (by decide)) ?_
    intro rest hr f hf
    simp only [List.length_append, List.length_cons, List.length_nil] at hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; omega⟩
    have hR := pMkRows_read c P .earr (by rw [hsf]; decide) (by decide) (by rw [hsf]; decide)
      (.kw .rbkg :: (mkSub c A.out ++ rest)) rows hrowsne hgood g (by unfold need at hf; omega)
    simp only [List.append_assoc, List.cons_append, List.nil_append]
    rw [pPrim.eq_def]; simp only
    have e1 : cellSep c.sf = .amp := by rw [hsf]; rfl
    have e2 : rowSep c.sf = .nl := by rw [hsf]; rfl
    rw [e1, e2] at hR
    rw [hR]; simp only
    rw [mkTail_read c rows A.out ho rest (fun r e => by have := hr _ _ e; simp [conts] at this), hnode]
  · have hpr' : pr c (.obj kvs) = mkOut c.sf 10 (matHead ++ rowsToksM c P rows ++ [.kw .rp] ++ mkSub c A.out) := by
      rw [hpr]; unfold mkOutT rowsToksM; simp only; rw [hsf]
    refine M_of_toks c _ 10 _ hpr' (by omega) (by omega) (by omega) hacc
      (hOK_kw c .mat _ (by decide) (by decide) (by decide)) ?_
    intro rest hr f hf
    simp only [matHead, List.length_append, List.length_cons, List.length_nil] at hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; omega⟩
    have hR := pMkRows_read c P .rp (by rw [hsf]; decide) (by decide) (by rw [hsf]; decide)
      (mkSub c A.out ++ rest) rows hrowsne hgood g (by unfold need at hf; omega)
    have e1 : cellSep c.sf = .comma := by rw [hsf]; rfl
    have e2 : rowSep c.sf = .semi := by rw [hsf]; rfl
    rw [e1, e2] at hR
    simp only [matHead, List.append_assoc, List.cons_append, List.nil_append]
    rw [pPrim.eq_def]; simp only
    rw [hR]; simp only
    rw [mkTail_read c rows A.out ho rest (fun r e => by have := hr _ _ e; simp [conts] at this), hnode]

end Esm.Document.Math
