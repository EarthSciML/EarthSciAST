import Esm.Document.Source.Equation
import Esm.Document.Math.Induct

/-!
# Multi-line equations (accepted input variants)

The printer writes one equation per display. On input, one display may hold several
equations, or one equation over several lines (`Notation.variants`):

* rows separated by a top-level line break (LaTeX `\\` inside `aligned`, Typst `\`);
* in a row, the first top-level `&` splits a left cell from the rest; a row with
  something before its `&` starts a new equation, a row with an empty left cell
  continues the previous one (`&\quad + k_{2} B`), and a continuation starting with its
  own `=` is refused (an equation has one top-level `=`);
* in `split` and `multline`, all rows are one equation;
* line breaks and `&` nested inside a delimiter (`cases`, a matrix, parentheses) never
  split anything.

The reader works on the math tokens (`Esm.Document.Math.Tok`), after the lexer, so the
rows and cells are found by token and depth, not by text. `cookRows_layout` is the
normalization lemma: an equation laid out over aligned rows, the pieces of its canonical
tokens separated by `&` and line breaks, reads back as the equation itself.
-/

namespace Esm.Document.Source

open Esm.Document Esm.Document.Math

/-! ## Depth and top-level cuts -/

/-- How a token changes the delimiter depth. -/
def delta : Tok → Int
  | .kw .lp | .kw .lpg | .kw .lb | .kw .lbk | .kw .bcases | .kw .bmat | .kw .lbkg => 1
  | .kw .rp | .kw .rpg | .kw .rb | .kw .rbk | .kw .ecases | .kw .emat | .kw .rbkg => -1
  | _ => 0

/-- The token is the keyword `k`. -/
def isKw (k : Kw) : Tok → Bool
  | .kw k' => k' == k
  | _ => false

/-- Cut at the first `k` at depth 0: the tokens before it and, if there is one, the
tokens after it. `d` is the depth at the start. -/
def cut (k : Kw) : Int → List Tok → List Tok × Option (List Tok)
  | _, [] => ([], none)
  | d, t :: ts =>
    if d == 0 && isKw k t then ([], some ts)
    else ((t :: (cut k (d + delta t) ts).1), (cut k (d + delta t) ts).2)

/-- No `k` at depth 0, and the depth comes back to 0 at the end: a piece of a row. -/
def noTop (k : Kw) : Int → List Tok → Bool
  | d, [] => d == 0
  | d, t :: ts => !(d == 0 && isKw k t) && noTop k (d + delta t) ts

theorem cut_noTop (k : Kw) : ∀ (d : Int) (x y : List Tok), noTop k d x = true →
    cut k d (x ++ .kw k :: y) = (x, some y)
  | d, [], y, h => by
    simp only [noTop, beq_iff_eq] at h
    subst h
    simp [cut, isKw]
  | d, t :: x, y, h => by
    simp only [noTop, Bool.and_eq_true, Bool.not_eq_true'] at h
    simp only [List.cons_append, cut, h.1, Bool.false_eq_true, ite_false]
    rw [cut_noTop k _ x y h.2]

theorem cut_none (k : Kw) : ∀ (d : Int) (x : List Tok), noTop k d x = true → cut k d x = (x, none)
  | d, [], _ => rfl
  | d, t :: x, h => by
    simp only [noTop, Bool.and_eq_true, Bool.not_eq_true'] at h
    simp only [cut, h.1, Bool.false_eq_true, ite_false]
    rw [cut_none k _ x h.2]

/-- All the pieces between top-level `k`s. -/
def splitAll (k : Kw) : Nat → List Tok → List (List Tok)
  | 0, ts => [ts]
  | f + 1, ts =>
    match (cut k 0 ts).2 with
    | some r => (cut k 0 ts).1 :: splitAll k f r
    | none => [ts]

theorem splitAll_rows (k : Kw) : ∀ (rows : List (List Tok)) (r : List Tok) (f : Nat),
    (∀ x ∈ r :: rows, noTop k 0 x = true) → rows.length ≤ f →
    splitAll k f (r ++ (rows.flatMap (fun x => .kw k :: x))) = r :: rows
  | [], r, f, h, _ => by
    cases f with
    | zero => simp [splitAll]
    | succ f => simp [splitAll, cut_none k 0 r (h r List.mem_cons_self)]
  | x :: rows, r, f, h, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    simp only [List.flatMap_cons, List.cons_append, splitAll]
    rw [cut_noTop k 0 r _ (h r List.mem_cons_self)]
    simp only
    rw [splitAll_rows k rows x g (fun y hy => h y (List.mem_cons_of_mem _ hy)) (by simp at hf; omega)]

/-! ## Rows into equations -/

/-- Rows into equations' tokens: a row with a left cell starts an equation (its `&`
dropped), a row with an empty left cell continues the last one; `split` and `multline`
(`one`) make all rows one equation. Refused: a continuation with no equation before it,
one that starts with `=`, and a second top-level `&` in a row. `acc` holds the equations
so far, the last first. -/
def group (one : Bool) : List (List Tok) → List (List Tok) → Option (List (List Tok))
  | acc, [] => some acc.reverse
  | acc, row :: rows =>
    match cut .amp 0 row with
    | (l, none) =>
      if l.isEmpty then group one acc rows
      else if one then
        match acc with
        | [] => group one [l] rows
        | cur :: done => group one ((cur ++ l) :: done) rows
      else group one (l :: acc) rows
    | (l, some r) =>
      if (cut .amp 0 r).2.isSome then none
      else if l.isEmpty && !one then
        match acc, r with
        | [], _ => none
        | _, .kw .eq :: _ => none
        | cur :: done, _ => group one ((cur ++ r) :: done) rows
      else if one then
        match acc with
        | [] => group one [l ++ r] rows
        | cur :: done => group one ((cur ++ l ++ r) :: done) rows
      else group one ((l ++ r) :: acc) rows

/-- **Read the rows of a multi-line display** (tokens) into equations. -/
def cookRows (sf : Sf) (S : Sym) (one : Bool) (ts : List Tok) : Option (List Eqn) :=
  (group one [] (splitAll .nl ts.length ts)).bind (fun eqs =>
    eqs.mapM (fun t => ((parseToks sf S t).bind eqSides).map (fun p => ⟨none, p.1, p.2⟩)))

/-! ## The normalization lemma -/

/-- An aligned layout of one equation's tokens: the left cell, then the right parts of
its first row and of each continuation row. -/
structure Layout where
  l : List Tok
  r : List Tok
  more : List (List Tok)

/-- The tokens the layout lays out. -/
def Layout.toks (L : Layout) : List Tok := L.l ++ L.r ++ L.more.flatten

/-- The layout's rows: `l & r`, then `& r'` for each continuation. -/
def Layout.rows (L : Layout) : List (List Tok) :=
  (L.l ++ .kw .amp :: L.r) :: L.more.map (fun m => .kw .amp :: m)

/-- A layout the reader splits back: every piece is free of top-level `&` and line
breaks, the left cell is not empty, and no continuation starts with `=`. -/
def Layout.OK (L : Layout) : Prop :=
  L.l ≠ [] ∧ noTop .amp 0 L.l ∧ noTop .nl 0 L.l ∧ noTop .amp 0 L.r ∧ noTop .nl 0 L.r ∧
    ∀ m ∈ L.more, noTop .amp 0 m ∧ noTop .nl 0 m ∧ (m.head?.map (isKw .eq)) ≠ some true

theorem noTop_append (k : Kw) : ∀ (x y : List Tok), noTop k 0 x = true → noTop k 0 y = true →
    noTop k 0 (x ++ y) = true := by
  suffices h : ∀ (d : Int) (x y : List Tok), noTop k d x = true → noTop k 0 y = true →
      noTop k d (x ++ y) = true from h 0
  intro d x y
  induction x generalizing d with
  | nil => intro h hy; simp only [noTop, beq_iff_eq] at h; subst h; simpa using hy
  | cons t x ih =>
    intro h hy
    simp only [noTop, Bool.and_eq_true, Bool.not_eq_true'] at h
    simp only [List.cons_append, noTop, h.1, Bool.not_false, Bool.true_and]
    exact ih _ h.2 hy

theorem noTop_cons_other (k k' : Kw) (h : k' ≠ k) (hd : delta (.kw k') = 0) (y : List Tok)
    (hy : noTop k 0 y = true) : noTop k 0 (.kw k' :: y) = true := by
  simp [noTop, isKw, h, hd, hy]

/-- The tokens of rows joined by line breaks. -/
def joinRows : List (List Tok) → List Tok
  | [] => []
  | r :: rs => r ++ rs.flatMap (fun x => .kw .nl :: x)

/-- The token stream of a display laid out over aligned rows. -/
def rowsToks (Ls : List Layout) : List Tok := joinRows (Ls.flatMap Layout.rows)

theorem group_more (rest : List (List Tok)) : ∀ (ms : List (List Tok)) (done : List (List Tok)) (cur : List Tok),
    (∀ m ∈ ms, noTop .amp 0 m = true ∧ (m.head?.map (isKw .eq)) ≠ some true) →
    group false (cur :: done) (ms.map (fun m => .kw .amp :: m) ++ rest) =
      group false ((cur ++ ms.flatten) :: done) rest
  | [], done, cur, _ => by simp
  | m :: ms, done, cur, hms => by
    obtain ⟨hma, hmeq⟩ := hms m List.mem_cons_self
    simp only [List.map_cons, List.cons_append]
    rw [group]
    have hc : cut .amp 0 (.kw .amp :: m) = ([], some m) := by simp [cut, isKw]
    rw [hc]
    simp only [cut_none .amp 0 m hma, Option.isSome_none, Bool.false_eq_true, ite_false,
      List.isEmpty_nil, Bool.not_false, Bool.and_self, ite_true]
    have ih := group_more rest ms done (cur ++ m) (fun m' hm' => hms m' (List.mem_cons_of_mem _ hm'))
    split
    · simp_all
    · simp_all [isKw]
    · obtain ⟨rfl, rfl⟩ := List.cons.inj ‹cur :: done = _ :: _›
      rw [ih]
      simp

theorem group_layout (L : Layout) (hL : L.OK) (acc rest : List (List Tok)) :
    group false acc (L.rows ++ rest) = group false (L.toks :: acc) rest := by
  obtain ⟨hl, hla, _, hra, _, hm⟩ := hL
  simp only [Layout.rows, List.cons_append]
  rw [group, cut_noTop .amp 0 L.l L.r hla]
  have hle : L.l.isEmpty = false := by simpa using hl
  simp only [cut_none .amp 0 L.r hra, Option.isSome_none, Bool.false_eq_true, ite_false, hle,
    Bool.false_and]
  rw [group_more rest L.more acc (L.l ++ L.r) (fun m hm' => ⟨(hm m hm').1, (hm m hm').2.2⟩)]
  simp [Layout.toks]

theorem group_layouts : ∀ (Ls : List Layout) (acc : List (List Tok)), (∀ L ∈ Ls, L.OK) →
    group false acc (Ls.flatMap Layout.rows) = some (acc.reverse ++ Ls.map Layout.toks)
  | [], acc, _ => by simp [group]
  | L :: Ls, acc, h => by
    simp only [List.flatMap_cons]
    rw [group_layout L (h L List.mem_cons_self), group_layouts Ls _ (fun L' hL' => h L' (List.mem_cons_of_mem _ hL'))]
    simp

theorem rows_noTop (L : Layout) (hL : L.OK) : ∀ x ∈ L.rows, noTop .nl 0 x = true := by
  obtain ⟨_, _, hln, _, hrn, hm⟩ := hL
  intro x hx
  simp only [Layout.rows, List.mem_cons, List.mem_map] at hx
  rcases hx with rfl | ⟨m, hmm, rfl⟩
  · exact noTop_append .nl _ _ hln (noTop_cons_other .nl .amp (by decide) rfl _ hrn)
  · exact noTop_cons_other .nl .amp (by decide) rfl _ (hm m hmm).2.1

/-- **Multi-line equations read as the equations they lay out.** If each equation's
canonical tokens are laid out over aligned rows (a left cell, `&`, the rest, then
continuation rows `& …`), with no top-level `&` or line break inside a piece, the rows
read back as exactly those equations. -/
theorem cookRows_layout (sf : Sf) (S : Sym) (Ls : List Layout) (es : List Eqn)
    (hL : ∀ L ∈ Ls, L.OK) (hne : Ls ≠ [])
    (h : List.Forall₂ (fun L e => L.toks = print sf S (eqExpr e) ∧ isE e.lhs = true ∧
      isE e.rhs = true) Ls es) :
    cookRows sf S false (rowsToks Ls) = some (es.map (fun e => ⟨none, e.lhs, e.rhs⟩)) := by
  unfold cookRows rowsToks
  have hrows : ∀ x ∈ Ls.flatMap Layout.rows, noTop .nl 0 x = true := by
    intro x hx
    simp only [List.mem_flatMap] at hx
    obtain ⟨L, hLm, hx⟩ := hx
    exact rows_noTop L (hL L hLm) x hx
  obtain ⟨r, rs, hrs⟩ : ∃ r rs, Ls.flatMap Layout.rows = r :: rs := by
    obtain ⟨L, Ls', rfl⟩ := List.exists_cons_of_ne_nil hne
    exact ⟨L.l ++ .kw .amp :: L.r, L.more.map (fun m => .kw .amp :: m) ++ Ls'.flatMap Layout.rows,
      by simp [Layout.rows]⟩
  rw [hrs] at hrows ⊢
  have hlen : rs.length ≤ (r ++ rs.flatMap (fun x => Tok.kw .nl :: x)).length := by
    simp only [List.length_append]
    have : rs.length ≤ (rs.flatMap (fun x => Tok.kw .nl :: x)).length := by
      clear hrows hrs
      induction rs with
      | nil => simp
      | cons y ys ih => simp [List.flatMap_cons] at ih ⊢; omega
    omega
  simp only [joinRows]
  rw [splitAll_rows .nl rs r _ hrows hlen, ← hrs, group_layouts Ls [] hL]
  simp only [List.reverse_nil, List.nil_append, Option.bind_some]
  clear hrs hrows hlen r rs hne
  induction h with
  | nil => rfl
  | @cons L e Ls' es' hLe _ ih =>
    obtain ⟨ht, hl, hr⟩ := hLe
    have ih' := ih (fun L' hL' => hL L' (List.mem_cons_of_mem _ hL'))
    simp only [List.map_cons, List.mapM_cons, ht,
      parseToks_print sf S _ (isE_eqExpr e hl hr), Option.bind_some, eqSides_eqExpr,
      Option.map_some, Option.bind_eq_bind, ih']
    rfl

/-- Every token of a layout's display is a token of an equation, `&`, or a line break. -/
theorem mem_rowsToks {Ls : List Layout} {t : Tok} (h : t ∈ rowsToks Ls) :
    t = .kw .amp ∨ t = .kw .nl ∨ ∃ L ∈ Ls, t ∈ L.toks := by
  unfold rowsToks at h
  have key : ∀ (rows : List (List Tok)), t ∈ joinRows rows → t = .kw .nl ∨ ∃ x ∈ rows, t ∈ x := by
    intro rows hr
    cases rows with
    | nil => cases hr
    | cons r rs =>
      simp only [joinRows, List.mem_append, List.mem_flatMap, List.mem_cons] at hr
      rcases hr with hr | ⟨x, hx, hr | hr⟩
      · exact Or.inr ⟨r, List.mem_cons_self, hr⟩
      · exact Or.inl hr
      · exact Or.inr ⟨x, List.mem_cons_of_mem _ hx, hr⟩
  rcases key _ h with h1 | ⟨x, hx, hxt⟩
  · exact Or.inr (Or.inl h1)
  · simp only [List.mem_flatMap] at hx
    obtain ⟨L, hL, hx⟩ := hx
    simp only [Layout.rows, List.mem_cons, List.mem_map] at hx
    rcases hx with rfl | ⟨m, hm, rfl⟩
    · simp only [List.mem_append, List.mem_cons] at hxt
      rcases hxt with hxt | hxt | hxt
      · exact Or.inr (Or.inr ⟨L, hL, by simp [Layout.toks, hxt]⟩)
      · exact Or.inl hxt
      · exact Or.inr (Or.inr ⟨L, hL, by simp [Layout.toks, hxt]⟩)
    · simp only [List.mem_cons] at hxt
      rcases hxt with hxt | hxt
      · exact Or.inl hxt
      · exact Or.inr (Or.inr ⟨L, hL, by simp only [Layout.toks, List.mem_append, List.mem_flatten]; exact Or.inr ⟨m, hm, hxt⟩⟩)

end Esm.Document.Source
