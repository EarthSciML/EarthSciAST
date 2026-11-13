import Esm.Document.Math.Derivs

/-!
# Round trip, case by case: constant arrays

A column for rank 1 and a matrix of at least two columns, LaTeX `bmatrix`, Typst
`vec(…)` / `mat(…)`, with units after them as for a scalar.
-/

namespace Esm.Document.Math

open Esm.Document

theorem numsOf_spec : ∀ (xs : List Json) (ns : List JNum), numsOf xs = some ns →
    xs = ns.map .num ∧ ∀ n ∈ ns, numOK n = true
  | [], ns, h => by simp [numsOf] at h; subst h; simp
  | .num m :: r, ns, h => by
    unfold numsOf at h
    split at h
    · rename_i hm
      obtain ⟨ms, hms, rfl⟩ := Option.map_eq_some_iff.1 h
      obtain ⟨h1, h2⟩ := numsOf_spec r ms hms
      refine ⟨by simp [h1], fun n hn => ?_⟩
      simp only [List.mem_cons] at hn
      rcases hn with rfl | hn
      · exact hm
      · exact h2 n hn
    · cases h
  | .null :: _, _, h => by simp [numsOf] at h
  | .bool _ :: _, _, h => by simp [numsOf] at h
  | .str _ :: _, _, h => by simp [numsOf] at h
  | .arr _ :: _, _, h => by simp [numsOf] at h
  | .obj _ :: _, _, h => by simp [numsOf] at h

theorem rowsOf_spec : ∀ (xs : List Json) (rs : List (List JNum)), rowsOf xs = some rs →
    xs = rs.map (fun r => .arr (r.map .num)) ∧ ∀ r ∈ rs, ∀ n ∈ r, numOK n = true
  | [], rs, h => by simp [rowsOf] at h; subst h; simp
  | .arr ys :: r, rs, h => by
    unfold rowsOf at h
    split at h
    · rename_i ns qs h1 h2
      cases h
      obtain ⟨e1, n1⟩ := numsOf_spec ys ns h1
      obtain ⟨e2, n2⟩ := rowsOf_spec r qs h2
      refine ⟨by simp [e1, e2], fun q hq => ?_⟩
      simp only [List.mem_cons] at hq
      rcases hq with rfl | hq
      · exact n1
      · exact n2 q hq
    · cases h
  | .null :: _, _, h => by simp [rowsOf] at h
  | .bool _ :: _, _, h => by simp [rowsOf] at h
  | .str _ :: _, _, h => by simp [rowsOf] at h
  | .num _ :: _, _, h => by simp [rowsOf] at h
  | .obj _ :: _, _, h => by simp [rowsOf] at h

/-- What a printed array shape guarantees. -/
def AOK : AForm → Prop
  | .col ns => ns ≠ [] ∧ ∀ n ∈ ns, numOK n = true
  | .mat rs => rs ≠ [] ∧ (∀ r ∈ rs, 2 ≤ r.length) ∧ ∀ r ∈ rs, ∀ n ∈ r, numOK n = true

theorem arrForm_spec {v : Json} {af : AForm} (h : arrForm v = some af) : af.json = v ∧ AOK af := by
  unfold arrForm at h
  split at h
  · rename_i xs
    split at h
    · rename_i ns hns
      split at h
      · rename_i hc
        cases h
        obtain ⟨e, hn⟩ := numsOf_spec xs ns hns
        exact ⟨by simp [AForm.json, e], hc.1, hn⟩
      · cases h
    · split at h
      · rename_i r rs hrs
        split at h
        · rename_i hc
          cases h
          obtain ⟨e, hn⟩ := rowsOf_spec xs (r :: rs) hrs
          obtain ⟨h2, hall, -⟩ := hc
          refine ⟨by simp [AForm.json, e], by simp, fun q hq => ?_, hn⟩
          simp only [List.mem_cons] at hq
          rcases hq with rfl | hq
          · exact h2
          · have := List.all_eq_true.1 hall q hq
            simp at this; omega
        · cases h
      · cases h
  · cases h

theorem pCells_read (sep k : Kw) (hk : k ≠ sep) (X : List Tok) :
    ∀ ns : List JNum, ns ≠ [] →
      pCells sep (sepBy [.kw sep] (numToks ns) ++ .kw k :: X) = some (ns, .kw k :: X)
  | [], h => absurd rfl h
  | [n], _ => by simp [numToks, sepBy, pCells, hk]
  | n :: m :: ns, _ => by
    simp only [numToks, List.map_cons, sepBy_cons2, List.cons_append, List.nil_append]
    have ih := pCells_read sep k hk X (m :: ns) (by simp)
    simp only [numToks, List.map_cons] at ih
    rw [pCells]; simp only [↓reduceIte]; rw [ih]; rfl

theorem pGrid_read (csep rsep close : Kw) (h1 : rsep ≠ csep) (h2 : close ≠ csep) (h3 : close ≠ rsep)
    (X : List Tok) : ∀ rows : List (List JNum), rows ≠ [] → (∀ r ∈ rows, r ≠ []) → ∀ f, rows.length ≤ f →
      pGrid csep rsep close (f + 1) (sepBy [.kw rsep] (rows.map fun r => sepBy [.kw csep] (numToks r)) ++
        .kw close :: X) = some (rows, X)
  | [], h, _, _, _ => absurd rfl h
  | [r], _, hr, f, _ => by
    simp only [List.map_cons, List.map_nil, sepBy]
    rw [pGrid, pCells_read csep close h2 X r (hr r (by simp))]
    simp [h3]
  | r :: q :: rs, _, hr, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    simp only [List.map_cons, sepBy_cons2, List.append_assoc, List.cons_append, List.nil_append]
    have ih := pGrid_read csep rsep close h1 h2 h3 X (q :: rs) (by simp)
      (fun z hz => hr z (by simp [hz])) g (by simp at hf ⊢; omega)
    simp only [List.map_cons] at ih
    rw [pGrid, pCells_read csep rsep h1 _ r (hr r (by simp))]
    simp only [↓reduceIte]
    rw [ih]; rfl

theorem constTail_none (c : Ctx) (v : Json) (X : List Tok) (hX : Fol c.sf 10 X) :
    constTail c v X = some (constNode v none, X) := by
  unfold constTail
  split
  · have := hX _ _ rfl; simp [conts] at this
  · have := hX _ _ rfl; simp [conts] at this
  · rfl

theorem length_le_sepBy (sep : List Tok) (hs : sep ≠ []) :
    ∀ (xs : List (List Tok)), (∀ x ∈ xs, x ≠ []) → xs.length ≤ (sepBy sep xs).length
  | [], _ => by simp [sepBy]
  | [x], h => by have := h x (by simp); simp [sepBy]; exact List.length_pos_of_ne_nil this
  | x :: y :: ys, h => by
    rw [sepBy_cons2]
    have := length_le_sepBy sep hs (y :: ys) (fun z hz => h z (by simp [hz]))
    have hx := List.length_pos_of_ne_nil (h x (by simp))
    simp only [List.length_append, List.length_cons] at this ⊢
    omega

theorem numToks_col (ns : List JNum) :
    numToks ns = (ns.map fun n => [n]).map fun r => sepBy [.kw .amp] (numToks r) := by
  induction ns with
  | nil => rfl
  | cons n ns ih => simp only [numToks, List.map_cons] at ih ⊢; rw [ih]; rfl

theorem gridJson_col (ns : List JNum) : gridJson (ns.map fun n => [n]) = .arr (ns.map .num) := by
  unfold gridJson; simp

theorem gridJson_mat (rs : List (List JNum)) (h : ∀ r ∈ rs, 2 ≤ r.length) (hne : rs ≠ []) :
    gridJson rs = .arr (rs.map fun r => .arr (r.map .num)) := by
  unfold gridJson
  obtain ⟨r, rs', rfl⟩ := List.exists_cons_of_ne_nil hne
  have := h r (by simp)
  have hn : (List.all (r :: rs') fun r => r.length == 1) = false := by
    simp only [List.all_cons, Bool.and_eq_false_iff]; left; simp; omega
  simp [hn]

theorem numToks_ne (ns : List JNum) : ∀ x ∈ numToks ns, x ≠ [] := by
  intro x hx; simp [numToks] at hx; obtain ⟨n, -, rfl⟩ := hx; simp

/-- The array tokens read back as the array, whatever follows them. -/
theorem pPrim_arr (c : Ctx) (af : AForm) (haf : AOK af) (rest : List Tok) (f : Nat) :
    pPrim c (f + 1) (arrToks c.sf af ++ rest) = constTail c af.json rest := by
  obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
  · cases af with
    | col ns =>
      obtain ⟨hne, -⟩ := haf
      have hS := length_le_sepBy [.kw .nl] (by simp) (numToks ns) (numToks_ne ns)
      have hrows : (ns.map fun n => [n]) ≠ [] := by simpa using hne
      have hrne : ∀ r ∈ (ns.map fun n => [n]), r ≠ [] := by simp
      simp only [arrToks, hsf, List.cons_append, List.append_assoc]
      rw [pPrim.eq_def]; simp only [List.nil_append]
      rw [numToks_col, pGrid_read .amp .nl .emat (by decide) (by decide) (by decide) rest _ hrows hrne _
        (by rw [← numToks_col]; simp [numToks] at hS ⊢; omega)]
      simp only [AForm.json, gridJson_col]
    | mat rs =>
      obtain ⟨hne, hlen, -⟩ := haf
      have hrne : ∀ r ∈ rs, r ≠ [] := fun r hr => by have := hlen r hr; intro e; subst e; simp at this
      have hS := length_le_sepBy [.kw .nl] (by simp) (rs.map fun r => sepBy [.kw .amp] (numToks r)) (by
        intro x hx; obtain ⟨r, hr, rfl⟩ := List.mem_map.1 hx
        obtain ⟨n, r', rfl⟩ := List.exists_cons_of_ne_nil (hrne r hr)
        cases r' <;> simp [numToks, sepBy])
      simp only [arrToks, hsf, List.cons_append, List.append_assoc]
      rw [pPrim.eq_def]; simp only [List.nil_append]
      rw [pGrid_read .amp .nl .emat (by decide) (by decide) (by decide) rest _ hne hrne _
        (by simp at hS ⊢; omega)]
      simp only [AForm.json, gridJson_mat rs hlen hne]
  · cases af with
    | col ns =>
      obtain ⟨hne, -⟩ := haf
      simp only [arrToks, hsf, List.cons_append, List.append_assoc, List.nil_append]
      rw [pPrim.eq_def]; simp only [isLp, ↓reduceIte]
      rw [pCells_read .comma .rp (by decide) rest ns hne]
      rfl
    | mat rs =>
      obtain ⟨hne, hlen, -⟩ := haf
      have hrne : ∀ r ∈ rs, r ≠ [] := fun r hr => by have := hlen r hr; intro e; subst e; simp at this
      have hS := length_le_sepBy [.kw .semi] (by simp) (rs.map fun r => sepBy [.kw .comma] (numToks r)) (by
        intro x hx; obtain ⟨r, hr, rfl⟩ := List.mem_map.1 hx
        obtain ⟨n, r', rfl⟩ := List.exists_cons_of_ne_nil (hrne r hr)
        cases r' <;> simp [numToks, sepBy])
      simp only [arrToks, hsf, List.cons_append, List.append_assoc, List.nil_append]
      rw [pPrim.eq_def]; simp only [isLp, ↓reduceIte]
      rw [pGrid_read .comma .semi .rp (by decide) (by decide) (by decide) rest _ hne hrne _
        (by simp at hS ⊢; omega)]
      rfl

theorem arrToks_head (sf : Sf) (af : AForm) :
    ∃ k r, arrToks sf af = .kw k :: r ∧ startA (.kw k) = true ∧ k ≠ .dif ∧ k ≠ .pdiff := by
  cases af <;> cases sf <;> exact ⟨_, _, rfl, rfl, by decide, by decide⟩

theorem M_arr (c : Ctx) (xs : List Json) (af : AForm) (haf : arrForm (.arr xs) = some af)
    (hpr : pr c (.obj [("args", .arr []), ("op", .str "const"), ("value", .arr xs)]) =
      mkOut c.sf 10 (arrToks c.sf af)) :
    M c (.obj [("args", .arr []), ("op", .str "const"), ("value", .arr xs)]) := by
  obtain ⟨hj, hok⟩ := arrForm_spec haf
  obtain ⟨k, r, he, hk1, hk2, hk3⟩ := arrToks_head c.sf af
  refine M_of_toks c _ 10 _ hpr (by omega) (by omega) (by omega) (by unfold addAcc; simp)
    (by rw [he]; exact hOK_kw c k r hk1 hk2 hk3) ?_
  intro rest hr f hf
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
  rw [pPrim_arr c af hok rest g, constTail_none c _ rest hr, hj]
  rfl

theorem M_arrU (c : Ctx) (u : String) (xs : List Json) (af : AForm) (haf : arrForm (.arr xs) = some af)
    (hu : unitsOK c.sf u = true)
    (hpr : pr c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .arr xs)]) =
      mkOut c.sf 7 (arrToks c.sf af ++ unitToks c.sf (factorsOf u))) :
    M c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .arr xs)]) := by
  obtain ⟨hj, hok⟩ := arrForm_spec haf
  obtain ⟨k, r, he, hk1, hk2, hk3⟩ := arrToks_head c.sf af
  have hsp : Esm.Units.spell (factorsOf u) = u := by
    simp only [unitsOK, Bool.and_eq_true, beq_iff_eq] at hu; exact hu.1.1.2
  refine M_of_toks c _ 7 _ hpr (by omega) (by omega) (by omega) (by unfold addAcc; simp)
    (by rw [he]; exact hOK_kw c k _ hk1 hk2 hk3) ?_
  intro rest hr f hf
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
  rw [List.append_assoc, pPrim_arr c af hok _ g, hj]
  obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
  · have hl : Esm.Units.parseLatex (Esm.Units.latex (factorsOf u)) = some (factorsOf u) := by
      simp only [unitsOK, Bool.and_eq_true, beq_iff_eq, hsf] at hu; exact hu.2.1
    have hr' : unitsOfRaw (String.ofList (Esm.Units.latexBody (factorsOf u))) = some (factorsOf u) := by
      unfold unitsOfRaw; rw [String.toList_ofList]; exact hl
    simp only [unitToks, hsf, List.cons_append, List.nil_append]
    unfold constTail; rw [hsf]; simp only
    rw [hr']; simp [constNode, hsp]
  · simp only [unitToks, hsf, List.cons_append, List.nil_append]
    unfold constTail; rw [hsf]; simp [constNode, hsp]

end Esm.Document.Math
