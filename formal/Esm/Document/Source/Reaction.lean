import Esm.Document.Source.Text

/-!
# Reaction sides, shared by the containers

A reaction prints as one line in the chemistry notation of its container (mhchem
`\ce{…}` in Markdown, typsium `#ce[…]` in Typst), the rate over the arrow
(`Notation.reactionLatex`). The sides are spelled the same way in both, up to the math
surface (`RSurf`):

* an empty side (JSON `null`) is the empty-set symbol as math, `$\varnothing$` /
  `$emptyset$`;
* otherwise the terms, separated by ` + `; a term is its stoichiometric coefficient as
  math followed by a space, `$2$ `, left out when it is 1, then the species;
* a species whose name is formula-shaped (`NO2`) is written bare, for the package to
  set; any other species is its name as math under the empty symbol table,
  `$\mathit{SO4\_aer}$`.

`pSide_sideTxt` reads a side back from its text.
-/

namespace Esm.Document.Source

open Esm.Document Esm.Document.Math

/-- A math surface for the pieces of a reaction side: how a math piece prints and
reads back (under the empty symbol table), and the content of the empty-set piece. -/
structure RSurf where
  pm : String → Option Json
  prm : Json → List Char
  empty : List Char

/-- A surface whose pieces read back. -/
def RSurf.OK (R : RSurf) : Prop := ∀ j, isE j = true → R.pm (String.ofList (R.prm j)) = some j

def isAlnumC (c : Char) : Bool := isLetter c || isDig c

/-! ## Printing -/

/-- A species: bare when formula-shaped, else its name as math. -/
def speciesTxt (R : RSurf) (n : String) : List Char :=
  if isFormula n.toList then n.toList else '$' :: R.prm (.str n) ++ ['$']

/-- A term: the coefficient as math and a space, unless it is 1, then the species. -/
def termTxt (R : RSurf) (t : Term) : List Char :=
  (if t.coef = .int 1 then [] else '$' :: R.prm (.num t.coef) ++ ['$', ' ']) ++ speciesTxt R t.species

/-- The terms of a non-empty side, separated by ` + `. -/
def termsTxt (R : RSurf) : List Term → List Char
  | [] => []
  | t :: ts => termTxt R t ++ ts.flatMap (fun u => ' ' :: '+' :: ' ' :: termTxt R u)

/-- A side. -/
def sideTxt (R : RSurf) : Option (List Term) → List Char
  | none => '$' :: R.empty ++ ['$']
  | some ts => termsTxt R ts

/-- A term the side syntax holds: a species name and, unless it is 1, a coefficient,
whose math has no `$` and is not the empty-set piece. -/
def termOK (R : RSurf) (t : Term) : Bool :=
  nameOK t.species &&
  (isFormula t.species.toList ||
    (!(R.prm (.str t.species)).contains '$' && R.prm (.str t.species) != R.empty)) &&
  (t.coef == .int 1 ||
    (numOK t.coef && !(R.prm (.num t.coef)).contains '$' && R.prm (.num t.coef) != R.empty))

/-- The number of terms of a side. -/
def sideLen : Option (List Term) → Nat
  | some ts => ts.length
  | none => 0

/-- A side the syntax holds: empty, or non-empty terms that it holds. -/
def sideOK (R : RSurf) : Option (List Term) → Bool
  | none => true
  | some ts => !ts.isEmpty && ts.all (termOK R)

/-! ## Reading -/

/-- The text after the prefix `p`, when it is one. -/
def after (p s : List Char) : Option (List Char) := if pre p s then some (s.drop p.length) else none

theorem after_app (p t : List Char) : after p (p ++ t) = some t := by
  simp [after, pre_append]

/-- A character of a reaction id: the identifier characters, `-`, `.` and `:` (what a
Typst label and a Pandoc identifier both hold). -/
def idChar (c : Char) : Bool := Strings.isIdentChar c || c == '-' || c == '.' || c == ':'

/-- A reaction id the containers spell as a label. -/
def idOK (i : String) : Bool := !i.toList.isEmpty && i.toList.all idChar

theorem takeWhile_id (x r : List Char) (hx : x.all idChar = true) (c : Char) (hc : idChar c = false) :
    (x ++ c :: r).takeWhile idChar = x := by
  induction x with
  | nil => simp [hc]
  | cons d x ih =>
    simp only [List.all_cons, Bool.and_eq_true] at hx
    simp [hx.1, ih hx.2]

/-- A math piece after its opening `$`: its content and the text after the closing `$`. -/
def pPiece (t : List Char) : Option (List Char × List Char) :=
  match t.drop (t.takeWhile (· != '$')).length with
  | '$' :: r => some (t.takeWhile (· != '$'), r)
  | _ => none

/-- A species: a math piece holding a name, or a bare run of letters and digits. -/
def pSpecies (R : RSurf) : List Char → Option (String × List Char)
  | '$' :: t =>
    match pPiece t with
    | some (p, r) =>
      match R.pm (String.ofList p) with
      | some (.str n) => some (n, r)
      | _ => none
    | none => none
  | s =>
    if (s.takeWhile isAlnumC).isEmpty then none
    else some (String.ofList (s.takeWhile isAlnumC), s.drop (s.takeWhile isAlnumC).length)

/-- A term: a math piece holding a number is the coefficient, and a species follows
after a space; otherwise the term is a species with coefficient 1. -/
def pTerm (R : RSurf) : List Char → Option (Term × List Char)
  | '$' :: t =>
    match pPiece t with
    | some (p, r) =>
      match R.pm (String.ofList p) with
      | some (.num c) =>
        match r with
        | ' ' :: r' => (pSpecies R r').map (fun q => (⟨q.1, c⟩, q.2))
        | _ => none
      | some (.str n) => some (⟨n, .int 1⟩, r)
      | _ => none
    | none => none
  | s => (pSpecies R s).map (fun q => (⟨q.1, .int 1⟩, q.2))

/-- Terms separated by ` + `. -/
def pTerms (R : RSurf) : Nat → List Char → Option (List Term × List Char)
  | 0, _ => none
  | f + 1, s =>
    match pTerm R s with
    | some (t, r) =>
      if pre [' ', '+', ' '] r then (pTerms R f (r.drop 3)).map (fun q => (t :: q.1, q.2))
      else some ([t], r)
    | none => none

/-- A side: the empty-set piece, or terms. -/
def pSide (R : RSurf) (f : Nat) (s : List Char) : Option (Option (List Term) × List Char) :=
  match s with
  | '$' :: t =>
    match pPiece t with
    | some (p, r) => if p = R.empty then some (none, r) else (pTerms R f s).map (fun q => (some q.1, q.2))
    | none => none
  | _ => (pTerms R f s).map (fun q => (some q.1, q.2))

/-! ## Reading back -/

theorem takeWhile_noDollar' (x y : List Char) (hx : x.contains '$' = false) :
    (x ++ '$' :: y).takeWhile (· != '$') = x := by
  induction x with
  | nil => simp
  | cons c x ih =>
    simp only [List.contains_cons, Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq] at hx
    simp [Ne.symm hx.1, ih hx.2]

theorem pPiece_app (x y : List Char) (hx : x.contains '$' = false) :
    pPiece (x ++ '$' :: y) = some (x, y) := by
  unfold pPiece
  rw [takeWhile_noDollar' x y hx, List.drop_left]
  simp

/-- What may follow a side: a space, `}` or `]`, and not ` + `. -/
def StopOK (r : List Char) : Prop :=
  (r.head? = some ' ' ∨ r.head? = some '}' ∨ r.head? = some ']') ∧ pre [' ', '+', ' '] r = false

theorem takeWhile_alnum (x r : List Char) (hx : x.all isAlnumC = true)
    (hr : (r.head? = some ' ' ∨ r.head? = some '}' ∨ r.head? = some ']')) :
    (x ++ r).takeWhile isAlnumC = x := by
  induction x with
  | nil =>
    rcases hr with h | h | h <;>
      (obtain ⟨c, r', rfl⟩ : ∃ c r', r = c :: r' := by
        cases r with
        | nil => simp at h
        | cons c r' => exact ⟨c, r', rfl⟩) <;>
      simp at h <;> subst h <;> simp [isAlnumC, isLetter, isDig]
  | cons c x ih =>
    simp only [List.all_cons, Bool.and_eq_true] at hx
    simp [hx.1, ih hx.2]

theorem formula_alnum {n : String} (h : isFormula n.toList = true) :
    n.toList.all isAlnumC = true ∧ n.toList ≠ [] := by
  simp only [isFormula, Bool.and_eq_true] at h
  refine ⟨?_, ?_⟩
  · have := h.1.1
    simpa [isAlnumC] using this
  · intro he
    have := h.1.2
    rw [he] at this
    simp at this

theorem alnum_ne_dollar {c : Char} (h : isAlnumC c = true) : c ≠ '$' := by
  intro e; subst e; simp [isAlnumC, isLetter, isDig] at h

theorem pSpecies_txt (R : RSurf) (hR : R.OK) (n : String) (hn : nameOK n = true)
    (hq : isFormula n.toList = true ∨ (R.prm (.str n)).contains '$' = false) (r : List Char)
    (hr : r.head? = some ' ' ∨ r.head? = some '}' ∨ r.head? = some ']') :
    pSpecies R (speciesTxt R n ++ r) = some (n, r) := by
  unfold speciesTxt
  split
  · rename_i hf
    obtain ⟨ha, hne⟩ := formula_alnum hf
    obtain ⟨c, cs, hcs⟩ := List.exists_cons_of_ne_nil hne
    have hc : c ≠ '$' := by
      rw [hcs] at ha; simp only [List.all_cons, Bool.and_eq_true] at ha; exact alnum_ne_dollar ha.1
    have htw := takeWhile_alnum n.toList r ha hr
    rw [hcs] at htw ⊢
    have : pSpecies R (c :: cs ++ r) = if ((c :: cs ++ r).takeWhile isAlnumC).isEmpty then none
        else some (String.ofList ((c :: cs ++ r).takeWhile isAlnumC),
          (c :: cs ++ r).drop ((c :: cs ++ r).takeWhile isAlnumC).length) := by
      simp only [List.cons_append]
      unfold pSpecies
      split
      · rename_i t h; simp at h; exact absurd h.1 hc
      · rfl
    rw [this, htw]
    simp only [List.isEmpty_cons, Bool.false_eq_true, ite_false]
    rw [← hcs, String.ofList_toList, List.drop_left]
  · rename_i hf
    have hd : (R.prm (.str n)).contains '$' = false := by
      rcases hq with h | h
      · exact absurd h hf
      · exact h
    simp only [List.cons_append, List.append_assoc, pSpecies]
    rw [pPiece_app _ _ hd]
    simp only [hR (.str n) (by simpa [isE] using hn), List.nil_append]

theorem pTerm_txt (R : RSurf) (hR : R.OK) (t : Term) (ht : termOK R t = true) (r : List Char)
    (hr : r.head? = some ' ' ∨ r.head? = some '}' ∨ r.head? = some ']') :
    pTerm R (termTxt R t ++ r) = some (t, r) := by
  obtain ⟨n, c⟩ := t
  simp only [termOK, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true', bne_iff_ne, ne_eq,
    beq_iff_eq] at ht
  obtain ⟨⟨hn, hq⟩, hc⟩ := ht
  have hq' : isFormula n.toList = true ∨ (R.prm (.str n)).contains '$' = false := by
    rcases hq with h | h
    · exact Or.inl h
    · exact Or.inr h.1
  unfold termTxt
  simp only
  split
  · rename_i h1
    subst h1
    simp only [List.nil_append]
    unfold speciesTxt
    split
    · rename_i hf
      obtain ⟨ha, hne⟩ := formula_alnum hf
      obtain ⟨d, ds, hds⟩ := List.exists_cons_of_ne_nil hne
      have hd : d ≠ '$' := by
        rw [hds] at ha; simp only [List.all_cons, Bool.and_eq_true] at ha; exact alnum_ne_dollar ha.1
      have hsp := pSpecies_txt R hR n hn hq' r hr
      simp only [speciesTxt, hf, ite_true] at hsp
      rw [hds] at hsp ⊢
      have : pTerm R (d :: ds ++ r) = (pSpecies R (d :: ds ++ r)).map (fun q => (⟨q.1, .int 1⟩, q.2)) := by
        simp only [List.cons_append]
        unfold pTerm
        split
        · rename_i t h; simp at h; exact absurd h.1 hd
        · rfl
      rw [this, hsp]
      rfl
    · rename_i hf
      have hd : (R.prm (.str n)).contains '$' = false := by
        rcases hq with h | h
        · exact absurd h hf
        · exact h.1
      simp only [List.cons_append, List.append_assoc, pTerm]
      rw [pPiece_app _ _ hd]
      simp only [hR (.str n) (by simpa [isE] using hn), List.nil_append]
  · rename_i h1
    have hc' : numOK c = true ∧ (R.prm (.num c)).contains '$' = false := by
      rcases hc with h | h
      · exact absurd h h1
      · exact ⟨h.1.1, h.1.2⟩
    simp only [List.cons_append, List.append_assoc, pTerm]
    rw [pPiece_app _ _ hc'.2]
    simp only [hR (.num c) (by simpa [isE] using hc'.1), List.nil_append]
    rw [pSpecies_txt R hR n hn hq' r hr]
    rfl

/-! ## Accepted variants -/

/-- **A species written as math reads as that species**, formula-shaped or not (the
printer writes a formula-shaped one bare). -/
theorem pSpecies_math (R : RSurf) (hR : R.OK) (n : String) (hn : nameOK n = true)
    (hd : (R.prm (.str n)).contains '$' = false) (r : List Char) :
    pSpecies R ('$' :: R.prm (.str n) ++ '$' :: r) = some (n, r) := by
  simp only [List.cons_append, pSpecies]
  rw [pPiece_app _ _ hd]
  simp only [hR (.str n) (by simpa [isE] using hn)]

/-- **A coefficient written out reads as that coefficient**, 1 included (the printer
leaves 1 out). -/
theorem pTerm_coef (R : RSurf) (hR : R.OK) (c : JNum) (hc : numOK c = true)
    (hcd : (R.prm (.num c)).contains '$' = false) (n : String) (hn : nameOK n = true)
    (hq : isFormula n.toList = true ∨ (R.prm (.str n)).contains '$' = false) (r : List Char)
    (hr : r.head? = some ' ' ∨ r.head? = some '}' ∨ r.head? = some ']') :
    pTerm R ('$' :: R.prm (.num c) ++ '$' :: ' ' :: speciesTxt R n ++ r) = some (⟨n, c⟩, r) := by
  simp only [List.cons_append, List.append_assoc, pTerm]
  rw [pPiece_app _ _ hcd]
  simp only [hR (.num c) (by simpa [isE] using hc)]
  rw [pSpecies_txt R hR n hn hq r hr]
  rfl

theorem termTxt_ne (R : RSurf) (t : Term) : termTxt R t ≠ [] := by
  unfold termTxt speciesTxt
  split
  · split
    · rename_i _ hf
      have := (formula_alnum hf).2
      simpa using this
    · simp
  · simp

theorem pTerms_txt (R : RSurf) (hR : R.OK) (ts : List Term) (hne : ts ≠ [])
    (ht : ∀ t ∈ ts, termOK R t = true) (r : List Char) (hr : StopOK r) :
    ∀ f, ts.length < f → pTerms R f (termsTxt R ts ++ r) = some (ts, r) := by
  induction ts with
  | nil => exact absurd rfl hne
  | cons t ts ih =>
    intro f hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    cases ts with
    | nil =>
      simp only [termsTxt, List.flatMap_nil, List.append_nil]
      unfold pTerms
      rw [pTerm_txt R hR t (ht t List.mem_cons_self) r hr.1]
      simp [hr.2]
    | cons u us =>
      have hrest : termsTxt R (t :: u :: us) ++ r =
          termTxt R t ++ (' ' :: '+' :: ' ' :: (termsTxt R (u :: us) ++ r)) := by
        simp [termsTxt, List.flatMap_cons]
      rw [hrest]
      unfold pTerms
      rw [pTerm_txt R hR t (ht t List.mem_cons_self) _ (by simp)]
      simp only [pre, List.drop, beq_self_eq_true, Bool.and_self, ite_true]
      rw [ih (by simp) (fun x hx => ht x (List.mem_cons_of_mem _ hx)) g (by simp at hf ⊢; omega)]
      rfl

theorem pSide_txt (R : RSurf) (hR : R.OK) (s : Option (List Term)) (hs : sideOK R s = true)
    (hE : R.empty.contains '$' = false) (r : List Char) (hr : StopOK r) (f : Nat)
    (hf : sideLen s < f) :
    pSide R f (sideTxt R s ++ r) = some (s, r) := by
  cases s with
  | none =>
    simp only [sideTxt, List.cons_append, List.append_assoc, pSide]
    rw [pPiece_app _ _ hE]
    simp
  | some ts =>
    simp only [sideOK, Bool.and_eq_true, Bool.not_eq_true', List.isEmpty_eq_false_iff,
      List.all_eq_true] at hs
    obtain ⟨hne, ht⟩ := hs
    have hT := pTerms_txt R hR ts hne ht r hr f hf
    obtain ⟨t, us, rfl⟩ := List.exists_cons_of_ne_nil hne
    have htk := ht t List.mem_cons_self
    simp only [sideTxt]
    -- the first piece is not the empty-set piece
    have key : ∀ x, termsTxt R (t :: us) ++ r = '$' :: x →
        ∃ X Y, x = X ++ '$' :: Y ∧ X.contains '$' = false ∧ X ≠ R.empty := by
      intro x hx
      simp only [termsTxt, List.append_assoc] at hx
      unfold termTxt at hx
      simp only [termOK, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true', bne_iff_ne,
        ne_eq, beq_iff_eq] at htk
      split at hx
      · simp only [List.nil_append, speciesTxt] at hx
        split at hx
        · rename_i hf'
          obtain ⟨ha, hne'⟩ := formula_alnum hf'
          obtain ⟨d, ds, hds⟩ := List.exists_cons_of_ne_nil hne'
          rw [hds] at hx ha
          simp only [List.cons_append, List.cons.injEq] at hx
          simp only [List.all_cons, Bool.and_eq_true] at ha
          exact absurd hx.1 (alnum_ne_dollar ha.1)
        · rename_i hf'
          have hd : (R.prm (.str t.species)).contains '$' = false ∧ R.prm (.str t.species) ≠ R.empty := by
            rcases htk.1.2 with h | h
            · exact absurd h hf'
            · exact h
          simp only [List.cons_append, List.cons.injEq, List.append_assoc] at hx
          exact ⟨_, _, hx.2.symm, hd.1, hd.2⟩
      · rename_i hc1
        have hc' : (R.prm (.num t.coef)).contains '$' = false ∧ R.prm (.num t.coef) ≠ R.empty := by
          rcases htk.2 with h | h
          · exact absurd h hc1
          · exact ⟨h.1.2, h.2⟩
        simp only [List.cons_append, List.cons.injEq, List.append_assoc] at hx
        exact ⟨_, _, hx.2.symm, hc'.1, hc'.2⟩
    unfold pSide
    split
    · rename_i x hx
      obtain ⟨X, Y, rfl, hX, hXE⟩ := key _ hx
      rw [pPiece_app _ _ hX]
      simp only [hXE, ite_false]
      rw [hT]; rfl
    · rw [hT]; rfl

end Esm.Document.Source
