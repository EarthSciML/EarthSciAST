import Esm.Document.Source.Facts
import Esm.Document.Source.Lines
import Esm.Document.Yaml
import Esm.Document.TypstDict
import Esm.Document.Math.RoundTripLatex
import Esm.Document.Math.RoundTripTypst

/-!
# Text scanning shared by the containers

Prefixes, lines, fenced bodies ended by a closing line, and the facts the containers'
round trips use about them.
-/

namespace Esm.Document.Source

open Esm.Document Esm.Document.Math

/-! ## Prefixes -/

/-- `p` is a prefix of `s`. -/
def pre : List Char → List Char → Bool
  | [], _ => true
  | _ :: _, [] => false
  | a :: p, b :: s => a == b && pre p s

theorem pre_append (p t : List Char) : pre p (p ++ t) = true := by
  induction p with
  | nil => rfl
  | cons a p ih => simp [pre, ih]

/-- A prefix no longer than `x` is decided within `x`. -/
theorem pre_app_long : ∀ (p x t : List Char), p.length ≤ x.length → pre p (x ++ t) = pre p x
  | [], _, _, _ => rfl
  | _ :: _, [], _, h => by simp at h
  | a :: p, b :: x, t, h => by
    simp only [List.cons_append, pre]
    rw [pre_app_long p x t (by simp at h; omega)]

theorem pre_app_of_pre : ∀ (p x t : List Char), pre p x = true → pre p (x ++ t) = true
  | [], _, _, _ => rfl
  | _ :: _, [], _, h => by simp [pre] at h
  | a :: p, b :: x, t, h => by
    simp only [pre, Bool.and_eq_true, beq_iff_eq] at h
    simp only [List.cons_append, pre, h.1, beq_self_eq_true, Bool.true_and]
    exact pre_app_of_pre p x t h.2

/-- Two texts neither of which starts the other differ before either ends. -/
theorem pre_app_false : ∀ (p x t : List Char), pre p x = false → pre x p = false →
    pre p (x ++ t) = false
  | [], _, _, h, _ => by simp [pre] at h
  | _ :: _, [], _, _, h => by simp [pre] at h
  | a :: p, b :: x, t, h1, h2 => by
    simp only [List.cons_append, pre]
    by_cases hab : a = b
    · subst hab
      simp only [pre, beq_self_eq_true, Bool.true_and] at h1 h2 ⊢
      exact pre_app_false p x t h1 h2
    · simp [hab]

theorem pre_cons_ne {a b : Char} (p s : List Char) (h : a ≠ b) : pre (a :: p) (b :: s) = false := by
  simp [pre, h]

theorem pre_head {a : Char} {p s : List Char} (h : pre (a :: p) s = true) : s.head? = some a := by
  cases s with
  | nil => simp [pre] at h
  | cons b s =>
    simp only [pre, Bool.and_eq_true, beq_iff_eq] at h
    rw [h.1]; rfl

/-- A prefix without a newline is decided within the first line. -/
theorem pre_line {stop x : List Char} (hn : '\n' ∉ stop) (hx : '\n' ∈ x) (y : List Char) :
    pre stop (x ++ y) = pre stop x := by
  induction stop generalizing x with
  | nil => rfl
  | cons a p ih =>
    cases x with
    | nil => cases hx
    | cons b x =>
      simp only [List.cons_append, pre]
      by_cases hb : b = '\n'
      · subst hb
        have : a ≠ '\n' := fun h => hn (h ▸ List.mem_cons_self)
        rw [beq_false_of_ne this]; rfl
      · have hx' : '\n' ∈ x := by
          rcases List.mem_cons.mp hx with h | h
          · exact absurd h.symm hb
          · exact h
        rw [ih (fun h => hn (List.mem_cons_of_mem _ h)) hx']

/-! ## Lines -/

/-- The rest of the current line, and what follows its newline. -/
def splitLine : List Char → List Char × List Char
  | [] => ([], [])
  | c :: r => if c = '\n' then ([], r) else ((c :: (splitLine r).1), (splitLine r).2)

theorem splitLine_line (l t : List Char) (hl : '\n' ∉ l) : splitLine (l ++ '\n' :: t) = (l, t) := by
  induction l with
  | nil => simp [splitLine]
  | cons c l ih =>
    have hc : c ≠ '\n' := fun h => hl (h ▸ List.mem_cons_self)
    simp only [List.cons_append, splitLine, hc, ite_false]
    rw [ih (fun h => hl (List.mem_cons_of_mem _ h))]

theorem splitLine_noNl (l : List Char) (hl : '\n' ∉ l) : splitLine l = (l, []) := by
  induction l with
  | nil => rfl
  | cons c l ih =>
    have hc : c ≠ '\n' := fun h => hl (h ▸ List.mem_cons_self)
    simp only [splitLine, hc, ite_false]
    rw [ih (fun h => hl (List.mem_cons_of_mem _ h))]

theorem splitLine_snd_le : ∀ s : List Char, (splitLine s).2.length ≤ s.length
  | [] => le_refl _
  | c :: r => by
    unfold splitLine
    split
    · simp
    · have := splitLine_snd_le r; simp; omega

theorem splitLine_snd_lt (c : Char) (r : List Char) : (splitLine (c :: r)).2.length < (c :: r).length := by
  have := splitLine_snd_le r
  unfold splitLine
  split
  · simp
  · simp; omega

/-- No line of `s` starts with `stop`. -/
def noStop (stop : List Char) (s : List Char) : Bool :=
  match s with
  | [] => true
  | c :: r => !pre stop (c :: r) && noStop stop (splitLine (c :: r)).2
termination_by s.length
decreasing_by exact splitLine_snd_lt c r

/-- Lines up to the first one that starts with `stop`: the lines before it (each with
its newline), the rest of the closing line, and the text after the closing line. -/
def untilStop (stop : List Char) : Nat → List Char → Option (List Char × List Char × List Char)
  | 0, _ => none
  | _ + 1, [] => none
  | f + 1, c :: r =>
    if pre stop (c :: r) then
      some ([], (splitLine ((c :: r).drop stop.length)).1, (splitLine ((c :: r).drop stop.length)).2)
    else
      (untilStop stop f (splitLine (c :: r)).2).map
        (fun b => ((splitLine (c :: r)).1 ++ '\n' :: b.1, b.2.1, b.2.2))

/-- Complete lines: empty, or ending with a newline. -/
def Lines (body : List Char) : Prop := body = [] ∨ body.getLast? = some '\n'

theorem exists_line : ∀ {body : List Char}, '\n' ∈ body →
    ∃ l t, body = l ++ '\n' :: t ∧ '\n' ∉ l
  | [], h => by cases h
  | c :: r, h => by
    by_cases hc : c = '\n'
    · exact ⟨[], r, by rw [hc]; rfl, by simp⟩
    · have hr : '\n' ∈ r := by
        rcases List.mem_cons.mp h with h' | h'
        · exact absurd h'.symm hc
        · exact h'
      obtain ⟨l, t, h1, h2⟩ := exists_line hr
      exact ⟨c :: l, t, by rw [h1]; rfl, by simp [h2]; exact fun e => hc e.symm⟩

theorem lines_split {body : List Char} (h : Lines body) (hne : body ≠ []) :
    ∃ l t, body = l ++ '\n' :: t ∧ '\n' ∉ l ∧ Lines t := by
  rcases h with h | h
  · exact absurd h hne
  · obtain ⟨l, t, hlt, hl⟩ := exists_line (List.mem_of_getLast? h)
    refine ⟨l, t, hlt, hl, ?_⟩
    by_cases ht : t = []
    · exact Or.inl ht
    · right
      rw [hlt, List.getLast?_append, List.getLast?_cons] at h
      cases ht' : t.getLast? with
      | none => simp [List.getLast?_eq_none_iff] at ht'; exact absurd ht' ht
      | some x => rw [ht'] at h; simpa using h

theorem untilStop_stop (stop X : List Char) (hs : stop ≠ []) (g : Nat) :
    untilStop stop (g + 1) (stop ++ X) = some ([], (splitLine X).1, (splitLine X).2) := by
  obtain ⟨a, p, rfl⟩ := List.exists_cons_of_ne_nil hs
  simp only [List.cons_append, untilStop]
  rw [← List.cons_append, pre_append, List.drop_left]
  rfl

theorem noStop_cons {stop l t : List Char} (hn : '\n' ∉ stop) (hl : '\n' ∉ l)
    (h : noStop stop (l ++ '\n' :: t) = true) : pre stop (l ++ ['\n']) = false ∧ noStop stop t = true := by
  cases hlc : l ++ '\n' :: t with
  | nil => simp at hlc
  | cons c r =>
    rw [hlc, noStop] at h
    simp only [Bool.and_eq_true, Bool.not_eq_true'] at h
    rw [← hlc, splitLine_line l t hl] at h
    refine ⟨?_, h.2⟩
    have := h.1
    rw [show l ++ '\n' :: t = (l ++ ['\n']) ++ t by simp, pre_line hn (by simp) t] at this
    exact this

/-- **A fenced body is read back** up to its closing line. -/
theorem untilStop_body (stop : List Char) (hs : stop ≠ []) (hn : '\n' ∉ stop) :
    ∀ (body sl t : List Char), Lines body → noStop stop body = true → '\n' ∉ sl →
      ∀ f, body.length + stop.length < f →
        untilStop stop f (body ++ stop ++ sl ++ '\n' :: t) = some (body, sl, t) := by
  intro body
  induction hlen : body.length using Nat.strong_induction_on generalizing body with
  | _ n ih =>
  intro sl t hb hns hsl f hf
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  by_cases he : body = []
  · subst he
    rw [List.nil_append, List.append_assoc, untilStop_stop _ _ hs, splitLine_line sl t hsl]
  · obtain ⟨l, b', rfl, hl, hb'⟩ := lines_split hb he
    have ⟨hpre, hns'⟩ := noStop_cons hn hl hns
    have hfirst : (l ++ '\n' :: b') ++ stop ++ sl ++ '\n' :: t =
        l ++ '\n' :: (b' ++ stop ++ sl ++ '\n' :: t) := by simp
    rw [hfirst]
    cases hlc : l ++ '\n' :: (b' ++ stop ++ sl ++ '\n' :: t) with
    | nil => simp at hlc
    | cons c r =>
      simp only [untilStop]
      rw [← hlc]
      have hp : pre stop (l ++ '\n' :: (b' ++ stop ++ sl ++ '\n' :: t)) = false := by
        rw [show l ++ '\n' :: (b' ++ stop ++ sl ++ '\n' :: t) =
          (l ++ ['\n']) ++ (b' ++ stop ++ sl ++ '\n' :: t) by simp,
          pre_line hn (by simp)]
        exact hpre
      rw [hp, splitLine_line l _ hl]
      simp only [Bool.false_eq_true, ite_false]
      have hlen' : b'.length < n := by rw [← hlen]; simp; omega
      rw [ih b'.length hlen' b' rfl sl t hb' hns' hsl g (by simp at hf; omega)]
      rfl

theorem heads_line (l t : List Char) (bol : Bool) :
    heads bol (l ++ '\n' :: t) = heads bol (l ++ ['\n']) ++ heads true t := by
  rw [show l ++ '\n' :: t = (l ++ ['\n']) ++ t by simp, heads_append, endBol_newline]

theorem heads_head {c : Char} {r : List Char} : c ∈ heads true (c :: r) := by
  simp [heads]

/-- A line never starts with `stop` when no line starts with its first character. -/
theorem noStop_of_heads {c : Char} (p : List Char) (s : List Char) (h : c ∉ heads true s) :
    noStop (c :: p) s = true := by
  induction hlen : s.length using Nat.strong_induction_on generalizing s with
  | _ n ih =>
  cases s with
  | nil => rw [noStop]
  | cons d r =>
    rw [noStop]
    have hd : d ≠ c := fun e => h (e ▸ heads_head)
    simp only [pre_cons_ne p r (Ne.symm hd), Bool.not_false, Bool.true_and]
    by_cases hm : '\n' ∈ d :: r
    · obtain ⟨l, t, hlt, hl⟩ := exists_line hm
      rw [hlt, splitLine_line l t hl]
      apply ih t.length (by rw [← hlen, hlt]; simp; omega) t _ rfl
      intro ht
      rw [hlt, heads_line] at h
      exact h (List.mem_append_right _ ht)
    · rw [splitLine_noNl _ hm, noStop]

theorem heads_noNl (bol : Bool) : ∀ (x : List Char), '\n' ∉ x →
    heads bol x = (if bol then x.take 1 else [])
  | [], _ => by cases bol <;> rfl
  | c :: r, h => by
    have hc : c ≠ '\n' := fun e => h (e ▸ List.mem_cons_self)
    simp only [heads, beq_false_of_ne hc]
    rw [heads_noNl false r (fun e => h (List.mem_cons_of_mem _ e))]
    cases bol <;> simp

theorem endBol_noNl (bol : Bool) : ∀ (x : List Char), '\n' ∉ x → x ≠ [] → endBol bol x = false
  | [], _, h => absurd rfl h
  | [c], h, _ => by
    have hc : c ≠ '\n' := fun e => h (e ▸ List.mem_cons_self)
    simp [endBol, hc]
  | c :: d :: r, h, _ => by
    rw [endBol_cons]
    exact endBol_noNl _ (d :: r) (fun e => h (List.mem_cons_of_mem _ e)) (by simp)

end Esm.Document.Source
