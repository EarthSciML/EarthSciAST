import Esm.Document.Math.View

/-!
# Names read back

`pName_nameToks`: the tokens of a name read back to the name, whatever symbol table
printed them, before anything that does not continue a name (`NameStop`: not the
scope dot, not an upright name subscript).
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## Splitting at dots -/

theorem splitDots_ne (l : List Char) : splitDots l ≠ [] := by
  cases l with
  | nil => simp [splitDots]
  | cons c cs =>
    simp only [splitDots]
    split
    · simp
    · split <;> simp

theorem joinDots_cons (s : List Char) (ss : List (List Char)) (h : ss ≠ []) :
    joinDots (s :: ss) = s ++ '.' :: joinDots ss := by
  cases ss with
  | nil => exact absurd rfl h
  | cons t ts => rfl

theorem joinDots_splitDots (l : List Char) : joinDots (splitDots l) = l := by
  induction l with
  | nil => rfl
  | cons c cs ih =>
    simp only [splitDots]
    split
    · rename_i hc
      subst hc
      rw [joinDots_cons _ _ (splitDots_ne cs), ih]; rfl
    · cases h : splitDots cs with
      | nil => exact absurd h (splitDots_ne cs)
      | cons s rs =>
        simp only
        rw [h] at ih
        cases rs with
        | nil => simp [joinDots] at ih ⊢; exact ih
        | cons t ts =>
          rw [joinDots_cons _ _ (by simp)] at ih ⊢
          rw [List.cons_append, ih]

/-- Every segment of a split has no dot. -/
theorem splitDots_noDot (l : List Char) : ∀ s ∈ splitDots l, '.' ∉ s := by
  induction l with
  | nil => simp [splitDots]
  | cons c cs ih =>
    simp only [splitDots]
    split
    · rename_i hc
      intro s hs
      simp only [List.mem_cons] at hs
      rcases hs with rfl | hs
      · simp
      · exact ih s hs
    · rename_i hc
      cases h : splitDots cs with
      | nil => exact absurd h (splitDots_ne cs)
      | cons t ts =>
        intro s hs
        rw [h] at ih
        simp only [List.mem_cons] at hs
        rcases hs with rfl | hs
        · simp only [List.mem_cons, not_or]
          exact ⟨fun e => hc e.symm, ih t (by simp)⟩
        · exact ih s (by simp [hs])

/-! ## Segments -/

theorem subOrPlain_stop (sf : Sf) (b : List Char) (rest : List Tok) (h : subPat sf rest = false) :
    subOrPlain sf b rest = (b, rest) := by
  unfold subOrPlain
  split
  · simp [subPat] at h
  · simp [subPat] at h
  · rfl

theorem subParts_spec {g b r : List Char} (h : subParts g = some (b, r)) :
    g = b ++ '_' :: r ∧ isSingle b = true ∧ r ≠ [] := by
  unfold subParts at h
  simp only at h
  split at h
  · rename_i rest hr
    split at h
    · rename_i hc
      simp only [Option.some.injEq, Prod.mk.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      refine ⟨?_, ?_, ?_⟩
      · have := List.takeWhile_append_dropWhile (p := (· != '_')) (l := g)
        rw [hr] at this; exact this.symm
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at hc; exact hc.1
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at hc; exact hc.2
    · simp at h
  · simp at h

theorem baseTok_seg (sf : Sf) (b : List Char) (hb : isSingle b = true) (rest : List Tok) :
    pSeg sf (baseTok b :: rest) = some (subOrPlain sf b rest) := by
  unfold isSingle at hb
  unfold baseTok
  split
  · rename_i c
    simp only at hb
    simp [pSeg, hb]
  · rename_i hne
    split at hb
    · rename_i c; exact absurd rfl (hne c)
    · simp [pSeg, String.toList_ofList, hb]

theorem pieces_cat {g : List Char} (hf : isFormula g = true) :
    (pieces g).flatMap (fun p => p.1 ++ p.2) = g := by
  have := hf; simp only [isFormula, Bool.and_eq_true, beq_iff_eq] at this; exact this.2.1.1

theorem decode_formulaRaw {g : List Char} (hf : isFormula g = true) :
    decodeFormula (formulaRaw g) = g := by
  have hall : g.all (fun c => isLetter c || isDig c) = true := by
    have := hf; simp only [isFormula, Bool.and_eq_true] at this; exact this.1.1
  have hcat := pieces_cat hf
  unfold decodeFormula formulaRaw
  have hok : ∀ c ∈ g, (c != '_' && c != '{' && c != '}') = true := by
    intro c hc
    have := List.all_eq_true.mp hall c hc
    simp only [Bool.or_eq_true, isLetter, isDig, Bool.and_eq_true, decide_eq_true_eq] at this
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq]
    refine ⟨⟨?_, ?_⟩, ?_⟩ <;> rintro rfl <;> simp at this
  conv_rhs => rw [← hcat]
  rw [List.filter_flatMap]
  apply List.flatMap_congr
  intro p hp
  have hsub : ∀ c ∈ p.1 ++ p.2, c ∈ g := by
    intro c hc; rw [← hcat]; exact List.mem_flatMap.mpr ⟨p, hp, hc⟩
  have h1 : p.1.filter (fun c => c != '_' && c != '{' && c != '}') = p.1 :=
    List.filter_eq_self.mpr fun c hc => hok c (hsub c (List.mem_append_left _ hc))
  have h2 : p.2.filter (fun c => c != '_' && c != '{' && c != '}') = p.2 :=
    List.filter_eq_self.mpr fun c hc => hok c (hsub c (List.mem_append_right _ hc))
  split <;> simp [List.filter_append, *]

theorem formula_seg (sf : Sf) (g : List Char) (hf : isFormula g = true) (rest : List Tok) :
    pSeg sf (formTok sf g :: rest) = some (g, rest) := by
  have hcat := pieces_cat hf
  cases sf with
  | latex =>
    simp [pSeg, formTok, formulaOf, String.toList_ofList, decode_formulaRaw hf, hf]
  | typst =>
    have hcat' : ((pieces g).map (fun p => (String.ofList p.1, String.ofList p.2))).flatMap
        (fun p => p.1.toList ++ p.2.toList) = g := by
      rw [List.flatMap_map]; simpa [String.toList_ofList] using hcat
    simp [pSeg, formTok, formulaOf, hcat', hf]

theorem seg_read (sf : Sf) (g : List Char) (hg : segOK g = true) (rest : List Tok)
    (hr : subPat sf rest = false) : pSeg sf (segToks sf g ++ rest) = some (g, rest) := by
  unfold segToks
  split
  · rename_i hs
    simp only [List.cons_append, List.nil_append]
    rw [baseTok_seg sf g hs, subOrPlain_stop sf g rest hr]
  · split
    · rename_i b r hsp
      obtain ⟨rfl, hb, hr0⟩ := subParts_spec hsp
      simp only [List.cons_append]
      rw [baseTok_seg sf b hb]
      cases sf with
      | latex => simp [subTxt, subOrPlain, String.toList_ofList, unescT_escT]
      | typst => simp [subTxt, subOrPlain, String.toList_ofList]
    · split
      · rename_i hf
        simp only [List.cons_append, List.nil_append]
        exact formula_seg sf g hf rest
      · simp [pSeg, String.toList_ofList]

theorem sepBy_cons (sep x : List Tok) (xs : List (List Tok)) :
    sepBy sep (x :: xs) = x ++ xs.flatMap (fun y => sep ++ y) := by
  induction xs generalizing x with
  | nil => simp [sepBy]
  | cons y ys ih => simp [sepBy, ih]

theorem joinDots_cons' (g : List Char) (gs : List (List Char)) :
    joinDots (g :: gs) = g ++ gs.flatMap (fun h => '.' :: h) := by
  induction gs generalizing g with
  | nil => simp [joinDots]
  | cons h hs ih => rw [joinDots_cons _ _ (by simp), ih]; simp

/-- What may follow a name: not the scope dot, not an upright name subscript. -/
def NameStop (sf : Sf) (rest : List Tok) : Prop :=
  (∀ r, rest ≠ .kw .sdot :: r) ∧ subPat sf rest = false

theorem pNameLoop_stop (sf : Sf) (f : Nat) (acc : List Char) (rest : List Tok)
    (hr : ∀ r, rest ≠ .kw .sdot :: r) : pNameLoop sf (f + 1) acc rest = some (acc, rest) := by
  match rest with
  | [] => rfl
  | .kw .sdot :: r => exact absurd rfl (hr r)
  | .kw .plus :: _ | .kw .minus :: _ | .kw .eq :: _ | .kw .ne :: _ | .kw .lt :: _ | .kw .gt :: _
  | .kw .le :: _ | .kw .ge :: _ | .kw .land :: _ | .kw .lor :: _ | .kw .lnot :: _ | .kw .cdot :: _
  | .kw .times :: _ | .kw .slash :: _ | .kw .caret :: _ | .kw .us :: _ | .kw .lp :: _
  | .kw .rp :: _ | .kw .lpg :: _ | .kw .rpg :: _ | .kw .lb :: _ | .kw .rb :: _ | .kw .lbk :: _
  | .kw .rbk :: _ | .kw .comma :: _ | .kw .semi :: _ | .kw .colon :: _ | .kw .amp :: _
  | .kw .nl :: _ | .kw .thin :: _ | .kw .frac :: _ | .kw .sqrt :: _ | .kw .exp :: _
  | .kw .ln :: _ | .kw .log :: _ | .kw .sin :: _ | .kw .cos :: _ | .kw .tan :: _ | .kw .asin :: _
  | .kw .acos :: _ | .kw .atan :: _ | .kw .sinh :: _ | .kw .cosh :: _ | .kw .tanh :: _
  | .kw .min :: _ | .kw .max :: _ | .kw .labs :: _ | .kw .rabs :: _ | .kw .lfloor :: _
  | .kw .rfloor :: _ | .kw .lceil :: _ | .kw .rceil :: _ | .kw .abs :: _ | .kw .floor :: _
  | .kw .ceil :: _ | .kw .pdiff :: _ | .kw .dif :: _ | .kw .dotacc :: _ | .kw .bcases :: _
  | .kw .ecases :: _ | .kw .cases :: _ | .kw .esmnode :: _
  | .num _ :: _ | .letter _ :: _ | .greek _ :: _ | .word _ :: _ | .it _ :: _ | .rm _ :: _
  | .ups _ :: _ | .opn _ :: _ | .txt _ :: _ | .jstr _ :: _ | .esc _ :: _ | .code _ :: _
  | .units _ :: _ => rfl

theorem nameLoop_read (sf : Sf) : ∀ (gs : List (List Char)), (∀ g ∈ gs, segOK g = true) →
    ∀ (acc : List Char) (rest : List Tok) (f : Nat), NameStop sf rest → gs.length < f →
    pNameLoop sf f acc ((gs.flatMap fun g => .kw .sdot :: segToks sf g) ++ rest) =
      some (acc ++ gs.flatMap (fun g => '.' :: g), rest)
  | [], _, acc, rest, f, hr, hf => by
    obtain ⟨f', rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hf; omega⟩
    simpa using pNameLoop_stop sf f' acc rest hr.1
  | g :: gs, hg, acc, rest, f, hr, hf => by
    obtain ⟨f', rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hf; omega⟩
    have hseg : pSeg sf (segToks sf g ++ ((gs.flatMap fun g => .kw .sdot :: segToks sf g) ++ rest)) =
        some (g, (gs.flatMap fun g => .kw .sdot :: segToks sf g) ++ rest) := by
      apply seg_read sf g (hg g (by simp))
      cases gs with
      | nil => simpa using hr.2
      | cons h hs => simp [subPat]
    simp only [List.flatMap_cons, List.cons_append, List.append_assoc]
    rw [pNameLoop, hseg]
    simp only
    rw [nameLoop_read sf gs (fun x hx => hg x (by simp [hx])) _ rest f' hr (by simp at hf; omega)]
    simp

theorem length_flatMap_sdot (sf : Sf) (gs : List (List Char)) :
    gs.length ≤ (gs.flatMap fun g => Tok.kw .sdot :: segToks sf g).length := by
  induction gs with
  | nil => simp
  | cons g gs ih => simp only [List.flatMap_cons, List.length_append, List.length_cons]; omega

/-- **Names read back.** -/
theorem pName_nameToks (c : Ctx) (s : String) (hs : nameOK s = true) (rest : List Tok)
    (hr : NameStop c.sf rest) : pName c.sf (nameToks c s ++ rest) = some (s, rest) := by
  unfold nameToks
  split
  · simp only [List.cons_append, List.nil_append, pName, pSeg]
    rw [pNameLoop_stop c.sf _ _ rest hr.1]
    simp
  · have hsegs := splitDots_ne s.toList
    have hall : ∀ g ∈ splitDots s.toList, segOK g = true := by
      intro g hg; unfold nameOK at hs; exact List.all_eq_true.mp hs g hg
    obtain ⟨g, gs, hgs⟩ := List.exists_cons_of_ne_nil hsegs
    rw [hgs] at hall ⊢
    simp only [List.map_cons, sepBy_cons, List.flatMap_map, List.append_assoc]
    unfold pName
    have h1 : pSeg c.sf (segToks c.sf g ++ ((gs.flatMap fun h => [Tok.kw .sdot] ++ segToks c.sf h) ++ rest)) =
        some (g, (gs.flatMap fun h => [Tok.kw .sdot] ++ segToks c.sf h) ++ rest) := by
      apply seg_read c.sf g (hall g (by simp))
      cases gs with
      | nil => simpa using hr.2
      | cons h hs => simp [subPat]
    rw [h1]
    simp only [List.singleton_append]
    rw [nameLoop_read c.sf gs (fun x hx => hall x (by simp [hx])) g rest _ hr
      (by have := length_flatMap_sdot c.sf gs; simp only [List.length_append]; omega)]
    simp only [Option.map_some]
    congr
    rw [← joinDots_cons', ← hgs, joinDots_splitDots, String.ofList_toList]

end Esm.Document.Math
