import Esm.Document.Yaml
import Esm.Document.Source.Lines

/-!
# Line heads of the YAML spelling

Facts about which characters start a line of `Yaml.encode v`, used to show a YAML block
can sit inside a Markdown code fence (`yaml_heads_tick`) or between front-matter `---`
delimiters (`yaml_heads_dash`), and that it ends at the start of a line (`yaml_ends`).
-/

namespace Esm.Document.Source

open Esm.Document
open Esm.Document.Strings
open Esm.Document.Yaml

/-! ## No raw newlines in scalars and keys -/

theorem ofNat_ne_nl (n : Nat) (h : n ≠ 10) : '\n' ≠ Char.ofNat n := by
  intro e
  have h10 : ('\n').toNat = 10 := rfl
  rw [e] at h10
  unfold Char.ofNat at h10
  split at h10
  · exact h (by simpa [Char.ofNatAux, Char.toNat, UInt32.toNat_ofNatLT] using h10)
  · exact absurd h10 (by decide)

theorem digitChar_ne_nl (d : Nat) : '\n' ≠ digitChar d := ofNat_ne_nl _ (by omega)

theorem hexChar_ne_nl (d : Nat) : '\n' ≠ hexChar d := by
  unfold hexChar
  split <;> exact ofNat_ne_nl _ (by omega)

theorem escChar_noNL (b : Bool) (c : Char) : '\n' ∉ escChar b c := by
  unfold escChar
  split_ifs with h1 h2 h3 h4 h5 h6
  all_goals simp [hex4, hexChar_ne_nl]
  exact fun e => h3 e.symm

theorem quote_noNL (s : String) : '\n' ∉ (quote false s).tail := by
  simp [quote, escape, escChar_noNL]

theorem digits_noNL (l : List Nat) : '\n' ∉ l.map digitChar := by
  simp only [List.mem_map, not_exists, not_and]
  exact fun d _ e => digitChar_ne_nl d e.symm

theorem printInt_noNL (z : Int) : '\n' ∉ Number.printInt z := by
  unfold Number.printInt Number.printNat
  split <;> simp [digits_noNL]

theorem print_noNL (n : JNum) : '\n' ∉ Number.print n := by
  unfold Number.print Number.decBody
  split
  · exact printInt_noNL _
  · rename_i neg ds e10
    have hneg : '\n' ∉ (if neg = true then ['-'] else []) := by split <;> simp
    simp only [List.mem_append, not_or]
    refine ⟨hneg, ?_⟩
    split
    · split
      · simp
      · simp [digits_noNL, printInt_noNL, digitChar_ne_nl]
    · split
      · simp [digits_noNL, digitChar_ne_nl]
      · simp only [List.mem_append, List.mem_cons, not_or]
        exact ⟨digits_noNL _, by decide, digits_noNL _⟩

theorem inline_noNL (v : Json) : '\n' ∉ Yaml.inline v := by
  match v with
  | .null | .bool true | .bool false | .arr _ | .obj _ => simp [Yaml.inline]
  | .num n => exact print_noNL n
  | .str s => simp [Yaml.inline, quote, escape, escChar_noNL]

/-! ## Line heads -/

/-- Every character that starts a line of `l`, wherever `l` starts, satisfies `p`. -/
def HeadsP (p : Char → Prop) (l : List Char) : Prop := ∀ b, ∀ c ∈ heads b l, p c

theorem HeadsP.nil (p : Char → Prop) : HeadsP p [] := fun _ _ h => by simp [heads] at h

theorem HeadsP.append {p : Char → Prop} {x y : List Char} (hx : HeadsP p x) (hy : HeadsP p y) :
    HeadsP p (x ++ y) := by
  intro b c hc
  rw [heads_append, List.mem_append] at hc
  exact hc.elim (hx _ c) (hy _ c)

theorem HeadsP.cons {p : Char → Prop} {x : Char} {r : List Char} (hx : p x) (hr : HeadsP p r) :
    HeadsP p (x :: r) := by
  intro b c hc
  simp only [heads, List.mem_append] at hc
  rcases hc with hc | hc
  · split at hc <;> simp_all
  · exact hr _ c hc

/-- A first character that is not a newline: what follows is read mid-line. -/
theorem HeadsP.cons_mid {p : Char → Prop} {x : Char} {r : List Char} (hx : p x) (hn : x ≠ '\n')
    (hr : ∀ c ∈ heads false r, p c) : HeadsP p (x :: r) := by
  intro b c hc
  simp only [heads, List.mem_append, beq_eq_false_iff_ne.mpr hn] at hc
  rcases hc with hc | hc
  · split at hc <;> simp_all
  · exact hr c hc

theorem HeadsP.mono {p q : Char → Prop} {l : List Char} (h : ∀ c, p c → q c) (hl : HeadsP p l) :
    HeadsP q l := fun b c hc => h c (hl b c hc)

theorem heads_false_noNL {l : List Char} (h : '\n' ∉ l) : heads false l = [] := by
  induction l with
  | nil => rfl
  | cons c r ih =>
    simp only [List.mem_cons, not_or] at h
    have hc : (c == '\n') = false := beq_eq_false_iff_ne.mpr (Ne.symm h.1)
    simp [heads, hc, ih h.2]

theorem heads_false_spaces (m : Nat) (r : List Char) : heads false (spaces m ++ r) = heads false r := by
  induction m with
  | zero => rfl
  | succ m ih => simpa [spaces, List.replicate_succ, heads] using ih

/-- One line `x :: t` ending in a newline. -/
theorem HeadsP.line {p : Char → Prop} {x : Char} (hx : p x) (hxn : x ≠ '\n') (hn : p '\n')
    {t : List Char} (ht : '\n' ∉ t) : HeadsP p (x :: (t ++ ['\n'])) := by
  refine HeadsP.cons_mid hx hxn fun c hc => ?_
  rw [heads_append, heads_false_noNL ht, List.nil_append] at hc
  exact HeadsP.cons hn (HeadsP.nil p) _ c hc

/-- A line ` x` ending in a newline, where `x` has no newline. -/
theorem HeadsP.scalarLine {p : Char → Prop} (hs : p ' ') (hn : p '\n') {x : List Char}
    (hx : '\n' ∉ x) : HeadsP p (' ' :: (x ++ ['\n'])) :=
  HeadsP.line hs (by decide) hn hx

/-- Not a backtick and not a dash. -/
abbrev Good (c : Char) : Prop := c ≠ '`' ∧ c ≠ '-'

theorem good_space : Good ' ' := by decide
theorem good_nl : Good '\n' := by decide

theorem good_keyHead {c : Char} (h : c = '"' ∨ isIdentStart c = true) : Good c ∧ c ≠ '\n' := by
  rcases h with rfl | h
  · decide
  · refine ⟨⟨?_, ?_⟩, ?_⟩ <;> (intro e; rw [e] at h; exact absurd h (by decide))

theorem spaces_good (m : Nat) : HeadsP Good (spaces m) := by
  induction m with
  | zero => exact HeadsP.nil _
  | succ m ih => simpa [spaces, List.replicate_succ] using HeadsP.cons good_space ih

theorem quote_good (s : String) : HeadsP Good (quote false s) := by
  have h : quote false s = '"' :: (escape false s.toList ++ ['"']) := rfl
  have hn : '\n' ∉ escape false s.toList ++ ['"'] := quote_noNL s
  rw [h]
  refine HeadsP.cons_mid (by decide) (by decide) fun c hc => ?_
  rw [heads_false_noNL hn] at hc
  simp at hc

theorem printKey_good (k : String) : HeadsP Good (printKey false reserved k) := by
  obtain ⟨c, t, h, hc⟩ := printKey_head false reserved k
  have hg := good_keyHead hc
  rw [h]
  refine HeadsP.cons_mid hg.1 hg.2 fun d hd => ?_
  have ht : '\n' ∉ t := by
    unfold printKey at h
    split at h
    · rename_i hb
      simp only [bareKey, Bool.and_eq_true] at hb
      have hi := hb.1
      rw [h] at hi
      simp only [isIdent, Bool.and_eq_true, List.all_eq_true] at hi
      exact fun hm => absurd (hi.2 _ hm) (by decide)
    · have := quote_noNL k
      rw [h] at this
      exact this
  rw [heads_false_noNL ht] at hd
  simp at hd

theorem keyPart_good (m : Nat) (k : String) : HeadsP Good (keyPart m k) := by
  unfold keyPart
  split
  · exact HeadsP.cons (by decide) (HeadsP.cons good_space
      ((quote_good k).append (HeadsP.cons good_nl (spaces_good m))))
  · exact printKey_good k

mutual
theorem valBody_good (m : Nat) : ∀ v : Json, HeadsP Good (valBody m v)
  | .arr (w :: ws) => HeadsP.cons good_nl (items_good (m + 1) (w :: ws))
  | .obj (e :: es) => HeadsP.cons good_nl (entries_good (m + 2) (e :: es))
  | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] =>
    HeadsP.scalarLine good_space good_nl (inline_noNL _)

theorem itemBody_good (m : Nat) : ∀ v : Json, HeadsP Good (itemBody m v)
  | .arr (w :: ws) => HeadsP.cons good_nl (items_good (m + 1) (w :: ws))
  | .obj ((k, w) :: es) => by
    simp only [itemBody, List.append_assoc]
    exact HeadsP.cons good_space ((keyPart_good (m + 2) k).append
      (HeadsP.cons (x := ':') (by decide) ((valBody_good (m + 2) w).append (entries_good (m + 2) es))))
  | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] =>
    HeadsP.scalarLine good_space good_nl (inline_noNL _)

/-- At a positive indentation every item line starts with a space. -/
theorem items_good (m : Nat) : ∀ l : List Json, HeadsP Good (encItems (m + 1) l)
  | [] => HeadsP.nil _
  | v :: vs => by
    have h : encItems (m + 1) (v :: vs) =
        ' ' :: (spaces m ++ '-' :: (itemBody (m + 1) v ++ encItems (m + 1) vs)) := by
      simp [encItems, spaces, List.replicate_succ]
    rw [h]
    refine HeadsP.cons_mid good_space (by decide) fun c hc => ?_
    rw [heads_false_spaces] at hc
    simp only [heads] at hc
    exact (itemBody_good (m + 1) v).append (items_good m vs) _ c hc

theorem entries_good (m : Nat) : ∀ l : List (String × Json), HeadsP Good (encEntries m l)
  | [] => HeadsP.nil _
  | (k, v) :: es => by
    simp only [encEntries, List.append_assoc]
    exact (spaces_good m).append ((keyPart_good m k).append
      (HeadsP.cons (by decide) ((valBody_good m v).append (entries_good m es))))
end

/-- At indentation 0 an item line starts with `-`, never a backtick. -/
theorem items_tick : ∀ l : List Json, HeadsP (· ≠ '`') (encItems 0 l)
  | [] => HeadsP.nil _
  | v :: vs => by
    simp only [encItems, spaces, List.replicate_zero, List.nil_append]
    exact HeadsP.cons (by decide) (((itemBody_good 0 v).mono fun _ h => h.1).append (items_tick vs))

/-- A scalar or empty container starts with a character that is neither a backtick nor
a newline. (A number needs `WF`: an out-of-range digit could print as a backtick.) -/
theorem inline_head (v : Json) (hv : v.WF) (hi : isInl v = true) :
    ∃ c t, Yaml.inline v = c :: t ∧ c ≠ '`' ∧ c ≠ '\n' := by
  match v with
  | .null | .bool true | .bool false | .arr [] | .obj [] => exact ⟨_, _, rfl, by decide, by decide⟩
  | .str s => exact ⟨_, _, rfl, by decide, by decide⟩
  | .num n =>
    obtain ⟨c, t, h, hc⟩ := Number.print_head n hv
    exact ⟨c, t, h, Number.NumHead.of_fin (P := fun c => c ≠ '`' ∧ c ≠ '\n')
      (by decide) (by decide +kernel) hc⟩

theorem scalar_tick (v : Json) (hv : v.WF) (hi : isInl v = true) :
    HeadsP (· ≠ '`') (Yaml.inline v ++ ['\n']) := by
  obtain ⟨c, t, h, hc, hcn⟩ := inline_head v hv hi
  have ht : '\n' ∉ t := fun hm => inline_noNL v (by rw [h]; exact List.mem_cons_of_mem c hm)
  rw [h, List.cons_append]
  exact HeadsP.line (p := (· ≠ '`')) hc hcn (by decide) ht

/-! ## Line ends -/

theorem endBol_ne_nil {x : List Char} (h : x ≠ []) (b b' : Bool) : endBol b x = endBol b' x := by
  unfold endBol
  cases hx : x.getLast? with
  | none => exact absurd (List.getLast?_eq_none_iff.mp hx) h
  | some c => rfl

mutual
theorem valBody_end (m : Nat) : ∀ (v : Json) (b : Bool), endBol b (valBody m v) = true
  | .arr (w :: ws), b => by rw [valBody, endBol_cons]; exact items_end _ _
  | .obj (e :: es), b => by rw [valBody, endBol_cons]; exact entries_end _ _
  | .null, b | .bool _, b | .num _, b | .str _, b | .arr [], b | .obj [], b => by
    rw [valBody_inl m _ rfl, endBol_newline]

theorem itemBody_end (m : Nat) : ∀ (v : Json) (b : Bool), endBol b (itemBody m v) = true
  | .arr (w :: ws), b => by rw [itemBody, endBol_cons]; exact items_end _ _
  | .obj ((k, w) :: es), b => by
    simp only [itemBody, endBol_append, endBol_cons, valBody_end, entries_end]
  | .null, b | .bool _, b | .num _, b | .str _, b | .arr [], b | .obj [], b => by
    rw [itemBody_inl m _ rfl, endBol_newline]

theorem items_end (m : Nat) : ∀ l : List Json, endBol true (encItems m l) = true
  | [] => rfl
  | v :: vs => by
    simp only [encItems, endBol_append, endBol_cons, itemBody_end, items_end]

theorem entries_end (m : Nat) : ∀ l : List (String × Json), endBol true (encEntries m l) = true
  | [] => rfl
  | (k, v) :: es => by
    simp only [encEntries, endBol_append, endBol_cons, valBody_end, entries_end]
end

/-! ## The YAML spelling -/

/-- No line of the YAML spelling of a well-formed value starts with a backtick, so a
YAML block never closes a Markdown code fence. -/
theorem yaml_heads_tick (v : Json) (hv : v.WF) : '`' ∉ heads true (Yaml.encode v) := by
  have h : HeadsP (· ≠ '`') (Yaml.encode v) := by
    match v with
    | .arr (w :: ws) => exact items_tick (w :: ws)
    | .obj (e :: es) => exact (entries_good 0 (e :: es)).mono fun _ h => h.1
    | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] => exact scalar_tick _ hv rfl
  exact fun hm => h true '`' hm rfl

/-- No line of the YAML spelling of a well-formed object starts with `-`, so front
matter never contains the `---` delimiter line. -/
theorem yaml_heads_dash (kvs : List (String × Json)) (hv : (Json.obj kvs).WF) :
    '-' ∉ heads true (Yaml.encode (.obj kvs)) := by
  match kvs with
  | [] => decide
  | e :: es => exact fun hm => (entries_good 0 (e :: es) true '-' hm).2 rfl

/-- The YAML spelling ends with a newline. -/
theorem yaml_ends (v : Json) : endBol false (Yaml.encode v) = true := by
  match v with
  | .arr (w :: ws) =>
    rw [Yaml.encode, endBol_ne_nil (by simp [encItems]) false true, items_end]
  | .obj (e :: es) =>
    rw [Yaml.encode, endBol_ne_nil (by obtain ⟨k, w⟩ := e; simp [encEntries]) false true,
      entries_end]
  | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] => exact endBol_newline _ _

end Esm.Document.Source
