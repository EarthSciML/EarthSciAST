import Mathlib.Data.List.Basic

/-!
# Lines of text

Containers are line-oriented: a fenced block ends at the first line that starts with
its closing fence. `heads` lists the characters that start a line, so "no line of `s`
starts with a backtick" is `'`' ∉ heads true s`.
-/

namespace Esm.Document.Source

/-- The characters that start a line of `s`: the first character when `s` starts at the
beginning of a line (`bol`), and every character right after a newline. -/
def heads : Bool → List Char → List Char
  | _, [] => []
  | bol, c :: r => (if bol then [c] else []) ++ heads (c == '\n') r

/-- Whether the text after `s` starts at the beginning of a line. -/
def endBol (bol : Bool) (s : List Char) : Bool :=
  match s.getLast? with
  | none => bol
  | some c => c == '\n'

theorem endBol_cons (bol : Bool) (c : Char) (x : List Char) :
    endBol bol (c :: x) = endBol (c == '\n') x := by
  unfold endBol
  rw [List.getLast?_cons]
  cases x.getLast? <;> rfl

theorem endBol_append (bol : Bool) (x y : List Char) :
    endBol bol (x ++ y) = endBol (endBol bol x) y := by
  unfold endBol
  rw [List.getLast?_append]
  cases y.getLast? <;> cases x.getLast? <;> rfl

theorem endBol_newline (bol : Bool) (x : List Char) : endBol bol (x ++ ['\n']) = true := by
  rw [endBol_append]; rfl

theorem heads_append (bol : Bool) (x y : List Char) :
    heads bol (x ++ y) = heads bol x ++ heads (endBol bol x) y := by
  induction x generalizing bol with
  | nil => rfl
  | cons c x ih =>
    simp only [List.cons_append, heads, ih, endBol_cons, List.append_assoc]

/-! ## Decoding the input

A source file may start with a UTF-8 byte-order mark and may use CRLF line endings, as
editors on some systems write them. `decodeText` normalizes both before a reader lexes
the text: a leading U+FEFF is dropped, and when the first line ends in CRLF every CRLF
becomes LF. A text whose first line ends in a bare LF (everything the printers write) is
read as it is (`decodeText_line`), so a carriage return inside, say, a description still
reads back. -/

/-- The text with a leading byte-order mark removed. -/
def dropBOM : List Char → List Char
  | [] => []
  | c :: r => if c == '\uFEFF' then r else c :: r

/-- Whether the first line ends in CRLF. -/
def firstCRLF : List Char → Bool
  | [] => false
  | c :: r => if c == '\n' then false else if c == '\r' && r.head? == some '\n' then true else firstCRLF r

/-- Every CRLF as LF. -/
def unCRLF : List Char → List Char
  | [] => []
  | c :: r =>
    if c == '\r' && r.head? == some '\n' then unCRLF r else c :: unCRLF r

/-- **The input decoding**: no byte-order mark, and LF line endings when the first line
ends in CRLF. -/
def decodeText (s : List Char) : List Char :=
  if firstCRLF (dropBOM s) then unCRLF (dropBOM s) else dropBOM s

theorem firstCRLF_line : ∀ (l t : List Char), '\n' ∉ l → '\r' ∉ l →
    firstCRLF (l ++ '\n' :: t) = false
  | [], t, _, _ => by simp [firstCRLF]
  | c :: l, t, hn, hr => by
    simp only [List.mem_cons, not_or] at hn hr
    simp [firstCRLF, Ne.symm hn.1, Ne.symm hr.1, firstCRLF_line l t hn.2 hr.2]

/-- A text whose first line has no carriage return and does not start with a byte-order
mark is read as written. -/
theorem decodeText_line (l t : List Char) (hn : '\n' ∉ l) (hr : '\r' ∉ l)
    (hb : l.head? ≠ some '\uFEFF') : decodeText (l ++ '\n' :: t) = l ++ '\n' :: t := by
  have hd : dropBOM (l ++ '\n' :: t) = l ++ '\n' :: t := by
    cases l with
    | nil => simp [dropBOM]
    | cons c l =>
      simp only [List.head?_cons, ne_eq, Option.some.injEq] at hb
      simp [dropBOM, hb]
  unfold decodeText
  rw [hd, firstCRLF_line l t hn hr]
  rfl

end Esm.Document.Source
