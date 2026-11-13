import Esm.Document.Number
import Esm.Document.Strings

/-!
# The Typst value codec

A `Json` value prints as a Typst code-mode value:

* `none`, `true`, `false`; numbers in the canonical spelling (`Number.print`), except
  `-2^63`, printed `(-9223372036854775807 - 1)` because Typst reads the literal
  `-9223372036854775808` as a float;
* strings `"…"` with Typst escapes (`\\`, `\"`, `\n`, `\r`, `\t`, `\u{XXXX}`);
* arrays `(a, b)`, `()` empty; dictionaries `(key: v, "quoted key": v)`, `(:)` empty.
  A key is bare when it matches `[A-Za-z_][A-Za-z0-9_]*` and is not a Typst keyword,
  otherwise quoted.

The canonical layout is one element per line: `(`, a newline, then each element on
its own line indented two spaces deeper than the opening line, each followed by `,`
(so a one-element array is `(a,)`), then `)` at the opening line's indentation.

The reader skips whitespace between tokens, so it accepts any layout of the same
tokens (including the `-2^63` expression), with or without a trailing comma, except
that a one-element array needs its comma: Typst reads `(x)` as the value `x`, not an
array, so the reader rejects it. It accepts a bare key only when it would print bare
(Typst rejects a keyword as a key), and only well-formed values (`decode_wf`): it
rejects a repeated key, and numbers are read by `Number.parse` (canonical form; no
leading zero; integers in `Int64`). `decode_encode` is the round trip.
-/

namespace Esm.Document.TypstDict

open Strings

/-! ## Printer -/

/-- Typst keywords, which cannot be bare dictionary keys. -/
def keywords : List String :=
  ["none", "auto", "true", "false", "not", "and", "or", "let", "set", "show", "if", "else",
    "for", "in", "while", "break", "continue", "return", "import", "include", "context", "as", "_"]

/-- A keyword: never a bare key. -/
def reserved (k : String) : Bool := keywords.contains k

/-- The `Int64` minimum, `-2^63`. -/
def int64Min : Int := -9223372036854775808

/-- After `(`: the rest of `(-9223372036854775807 - 1)`. Typst reads the literal
`9223372036854775808` as a float (it overflows `Int64` before the minus applies), so
`-2^63` is printed as this integer expression instead. -/
def minTail : List Char :=
  ['-', '9', '2', '2', '3', '3', '7', '2', '0', '3', '6', '8', '5', '4', '7', '7', '5', '8',
    '0', '7', ' ', '-', ' ', '1', ')']

/-- `-9223372036854775807`, the first operand of the `-2^63` expression. -/
def minLit : List Char :=
  ['-', '9', '2', '2', '3', '3', '7', '2', '0', '3', '6', '8', '5', '4', '7', '7', '5', '8',
    '0', '7']

theorem minTail_eq : minTail = minLit ++ [' ', '-', ' ', '1', ')'] := rfl

/-- A number: the canonical spelling, except `-2^63` (see `minTail`). -/
def printNum (n : JNum) : List Char :=
  if n = .int int64Min then '(' :: minTail else Number.print n

mutual
/-- The canonical print of a value whose first line is indented by `m` spaces (the
indentation itself is not printed). -/
def enc (m : Nat) : Json → List Char
  | .null => ['n', 'o', 'n', 'e']
  | .bool true => ['t', 'r', 'u', 'e']
  | .bool false => ['f', 'a', 'l', 's', 'e']
  | .num n => printNum n
  | .str s => quote true s
  | .arr [] => ['(', ')']
  | .arr (v :: vs) => '(' :: '\n' :: encItems (m + 2) (v :: vs) ++ spaces m ++ [')']
  | .obj [] => ['(', ':', ')']
  | .obj (e :: es) => '(' :: '\n' :: encEntries (m + 2) (e :: es) ++ spaces m ++ [')']

def encItems (m : Nat) : List Json → List Char
  | [] => []
  | v :: vs => spaces m ++ enc m v ++ ',' :: '\n' :: encItems m vs

def encEntries (m : Nat) : List (String × Json) → List Char
  | [] => []
  | (k, v) :: es =>
    spaces m ++ printKey true reserved k ++ ':' :: ' ' :: enc m v ++ ',' :: '\n' :: encEntries m es
end

/-- The canonical Typst spelling of a value. -/
def encode (v : Json) : List Char := enc 0 v

/-! ## Reader -/

def isWs (c : Char) : Bool := c == ' ' || c == '\n' || c == '\t' || c == '\r'

def skipWs : List Char → List Char
  | [] => []
  | c :: r => if isWs c then skipWs r else c :: r

/-- The input starts with a key and a colon: the first element of a dictionary. -/
def isEntry (input : List Char) : Bool :=
  match parseKey true reserved input with
  | some (_, r) =>
    match skipWs r with
    | ':' :: _ => true
    | _ => false
  | none => false

/-- What follows one element. -/
inductive Next where
  /-- `,` and another element. -/
  | more
  /-- `)`, after a `,` (`comma`) or directly. -/
  | close (comma : Bool)

/-- After one element: `,` then either `)` or the next element, or `)` directly. -/
def pNext (r : List Char) : Option (Next × List Char) :=
    match skipWs r with
    | ',' :: r' =>
      match skipWs r' with
      | ')' :: r'' => some (.close true, r'')
      | r'' => some (.more, r'')
    | ')' :: r' => some (.close false, r')
    | _ => none

/-- After `(` and any whitespace: the rest of the `-2^63` expression
`(-9223372036854775807 - 1)`, with any whitespace between its tokens. -/
def pMin (r : List Char) : Option (List Char) :=
  match r.dropPrefix? minLit with
  | some r1 =>
    match skipWs r1 with
    | '-' :: r2 =>
      match skipWs r2 with
      | '1' :: r3 =>
        match skipWs r3 with
        | ')' :: r4 => some r4
        | _ => none
      | _ => none
    | _ => none
  | none => none

mutual
/-- A value, at its first character. -/
def pVal : Nat → List Char → Option (Json × List Char)
  | 0, _ => none
  | _, [] => none
  | f + 1, c :: r =>
    if c = '(' then
      match pMin (skipWs r) with
      | some r' => some (.num (.int int64Min), r')
      | none => pParen f (skipWs r)
    else if c = '"' then (parseQuoted true (c :: r)).map fun p => (.str p.1, p.2)
    else if c = 'n' then
      match r with
      | 'o' :: 'n' :: 'e' :: r' => some (.null, r')
      | _ => none
    else if c = 't' then
      match r with
      | 'r' :: 'u' :: 'e' :: r' => some (.bool true, r')
      | _ => none
    else if c = 'f' then
      match r with
      | 'a' :: 'l' :: 's' :: 'e' :: r' => some (.bool false, r')
      | _ => none
    else (Number.parse (c :: r)).map fun p => (.num p.1, p.2)

/-- After `(` and any whitespace. -/
def pParen : Nat → List Char → Option (Json × List Char)
  | 0, _ => none
  | _, [] => none
  | f + 1, c :: r =>
    if c = ')' then some (.arr [], r)
    else if c = ':' then
      match skipWs r with
      | ')' :: r' => some (.obj [], r')
      | _ => none
    else if isEntry (c :: r) then (pEntries f (c :: r)).map fun p => (.obj p.1, p.2)
    else (pItems f true (c :: r)).map fun p => (.arr p.1, p.2)

/-- Array elements, at one of them (`first`: the first, which needs a `,` after it even
when it is the last). -/
def pItems : Nat → Bool → List Char → Option (List Json × List Char)
  | 0, _, _ => none
  | f + 1, first, input =>
    match pVal f input with
    | none => none
    | some (v, r) =>
      match pNext r with
      | none => none
      | some (.close comma, r') => if first && !comma then none else some ([v], r')
      | some (.more, r') => (pItems f false r').map fun p => (v :: p.1, p.2)

/-- Dictionary entries, at the first key. -/
def pEntries : Nat → List Char → Option (List (String × Json) × List Char)
  | 0, _ => none
  | f + 1, input =>
    match parseKey true reserved input with
    | none => none
    | some (k, r) =>
      match skipWs r with
      | ':' :: r1 =>
        match pVal f (skipWs r1) with
        | none => none
        | some (v, r2) =>
          match pNext r2 with
          | none => none
          | some (.close _, r') => some ([(k, v)], r')
          | some (.more, r') => (pEntries f r').map fun p => ((k, v) :: p.1, p.2)
      | _ => none
end

/-- Read a value: whitespace, the value, whitespace, end of input. The value must be
well formed. -/
def decode (s : List Char) : Option Json :=
  match pVal (3 * s.length + 3) (skipWs s) with
  | some (v, r) => if skipWs r = [] then (if v.wfb then some v else none) else none
  | none => none

/-- **What `decode` reads is well formed.** -/
theorem decode_wf {s : List Char} {v : Json} (h : decode s = some v) : v.WF := by
  unfold decode at h
  split at h
  · split at h
    · split at h
      · cases h; exact (Json.wfb_iff _).mp ‹_›
      · cases h
    · cases h
  · cases h

/-! ## The round trip -/

/-! ### Characters -/

theorem isWs_false {c : Char} (h1 : c ≠ ' ') (h2 : c ≠ '\n') (h3 : c ≠ '\t') (h4 : c ≠ '\r') :
    isWs c = false := by
  simp [isWs, h1, h2, h3, h4]

theorem numHead_ws {c : Char} (h : Number.NumHead c) : isWs c = false :=
  isWs_false (numHead_ne h ' ') (numHead_ne h '\n') (numHead_ne h '\t') (numHead_ne h '\r')

theorem keyHead_ws {c : Char} (h : c = '"' ∨ isIdentStart c = true) : isWs c = false :=
  isWs_false (keyHead_ne h ' ') (keyHead_ne h '\n') (keyHead_ne h '\t') (keyHead_ne h '\r')

theorem skipWs_spaces (k : Nat) (r : List Char) : skipWs (spaces k ++ r) = skipWs r := by
  induction k with
  | zero => rfl
  | succ k ih => simpa [spaces, List.replicate_succ, skipWs, isWs] using ih

theorem skipWs_nonWs {c : Char} (r : List Char) (h : isWs c = false) :
    skipWs (c :: r) = c :: r := by simp [skipWs, h]

theorem skipWs_ws {c : Char} (r : List Char) (h : isWs c = true) :
    skipWs (c :: r) = skipWs r := by simp [skipWs, h]

/-- What a printed value starts with. -/
theorem enc_head (m : Nat) (v : Json) (hv : v.WF) :
    ∃ c t, enc m v = c :: t ∧ isWs c = false ∧ c ≠ ')' ∧ c ≠ ':' := by
  match v with
  | .null => exact ⟨_, _, rfl, by decide, by decide, by decide⟩
  | .bool true => exact ⟨_, _, rfl, by decide, by decide, by decide⟩
  | .bool false => exact ⟨_, _, rfl, by decide, by decide, by decide⟩
  | .str s => exact ⟨_, _, rfl, by decide, by decide, by decide⟩
  | .arr [] => exact ⟨_, _, rfl, by decide, by decide, by decide⟩
  | .arr (_ :: _) => exact ⟨_, _, rfl, by decide, by decide, by decide⟩
  | .obj [] => exact ⟨_, _, rfl, by decide, by decide, by decide⟩
  | .obj (_ :: _) => exact ⟨_, _, rfl, by decide, by decide, by decide⟩
  | .num n =>
    by_cases hm : n = .int int64Min
    · exact ⟨'(', minTail, by simp [enc, printNum, hm], by decide, by decide, by decide⟩
    obtain ⟨c, t, h, hc⟩ := Number.print_head n hv
    exact ⟨c, t, by simp [enc, printNum, hm, h], numHead_ws hc, numHead_ne hc ')',
      numHead_ne hc ':'⟩

theorem skipWs_enc (m : Nat) (v : Json) (r : List Char) (hv : v.WF) :
    skipWs (enc m v ++ r) = enc m v ++ r := by
  obtain ⟨c, t, h, hc, -⟩ := enc_head m v hv
  rw [h, List.cons_append, skipWs_nonWs _ hc]

/-! ### Keys -/

/-- A key starts with `"` or an identifier start: never whitespace, `)`, `:` or `-`. -/
theorem keyHead_facts {c : Char} (h : c = '"' ∨ isIdentStart c = true) :
    c ≠ ')' ∧ c ≠ ':' ∧ isWs c = false ∧ c ≠ '-' :=
  ⟨keyHead_ne h ')', keyHead_ne h ':', keyHead_ws h, keyHead_ne h '-'⟩

/-! ### Reader steps -/

theorem pNext_more (k : Nat) (c : Char) (t : List Char) (hc : isWs c = false) (hc' : c ≠ ')') :
    pNext (',' :: '\n' :: (spaces k ++ c :: t)) = some (.more, c :: t) := by
  simp only [pNext, skipWs_nonWs _ (by decide : isWs ',' = false)]
  rw [skipWs_ws _ (by decide : isWs '\n' = true), skipWs_spaces, skipWs_nonWs _ hc]
  split
  · rename_i h; simp at h; exact absurd h.1 hc'
  · rfl

theorem pNext_last (k : Nat) (rest : List Char) :
    pNext (',' :: '\n' :: (spaces k ++ ')' :: rest)) = some (.close true, rest) := by
  simp only [pNext, skipWs_nonWs _ (by decide : isWs ',' = false)]
  rw [skipWs_ws _ (by decide : isWs '\n' = true), skipWs_spaces,
    skipWs_nonWs _ (by decide : isWs ')' = false)]
  rfl

theorem pVal_paren (f : Nat) (r : List Char) (h : pMin (skipWs r) = none) :
    pVal (f + 1) ('(' :: r) = pParen f (skipWs r) := by
  simp [pVal, h]

theorem pVal_min (f : Nat) (rest : List Char) :
    pVal (f + 1) ('(' :: (minTail ++ rest)) = some (.num (.int int64Min), rest) := by
  have hs : skipWs (minTail ++ rest) = minTail ++ rest := skipWs_nonWs _ (by decide)
  have hm : pMin (minTail ++ rest) = some rest := by
    rw [minTail_eq, List.append_assoc, pMin, List.dropPrefix?_append_of_beq _ (by simp)]
    simp [skipWs, isWs]
  simp [pVal, hs, hm]

/-! ### The `-2^63` expression is never mistaken for another value -/

theorem pMin_head {c : Char} (t : List Char) (hc : c ≠ '-') : pMin (c :: t) = none := by
  simp [pMin, minLit, List.dropPrefix?, hc]

/-- `-9223372036854775807` prints as the first operand of the `-2^63` expression. -/
theorem print_minLit : Number.print (.int (-9223372036854775807)) = minLit := by decide +kernel

/-- A printed number followed by `,` is not the `-2^63` expression, even when it is its
first operand `-9223372036854775807`. -/
theorem pMin_num (n : JNum) (hn : n.WF) (t : List Char) :
    pMin (Number.print n ++ ',' :: t) = none := by
  unfold pMin
  cases hd : (Number.print n ++ ',' :: t).dropPrefix? minLit with
  | none => rfl
  | some r1 =>
    obtain ⟨p', hp, hb⟩ := List.dropPrefix?_eq_some_iff.mp hd
    have hp' : p' = minLit := by simpa using hb
    subst hp'
    simp only
    -- `r1` is what follows `-9223372036854775807`: either part of the same number token
    -- (then it does not start with `-` or whitespace), or the `,` that follows `n`.
    cases r1 with
    | nil => rfl
    | cons c r =>
      by_cases hc : c.isDigit = false ∧ c ≠ '.' ∧ c ≠ 'e'
      · have hstop : Number.NumStop (c :: r) := fun x hx => by cases hx; exact hc
        have h0 : JNum.WF (.int (-9223372036854775807)) := (JNum.wfb_iff _).mp (by decide)
        have e1 := Number.parse_print _ _ h0 hstop
        have e2 := Number.parse_print n (',' :: t) hn (fun x hx => by cases hx; decide)
        rw [print_minLit, ← hp, e2] at e1
        simp only [Option.some.injEq, Prod.mk.injEq] at e1
        obtain ⟨-, he⟩ := e1
        rw [← he]
        rfl
      · have hws : isWs c = false := by
          cases hw : isWs c
          · rfl
          · exfalso; apply hc
            simp only [isWs, Bool.or_eq_true, beq_iff_eq] at hw
            rcases hw with ((e | e) | e) | e <;> subst e <;> decide
        have hm : c ≠ '-' := by
          rintro rfl; exact hc (by decide)
        rw [skipWs_nonWs _ hws]
        split
        · rename_i h; simp only [List.cons.injEq] at h; exact absurd h.1 hm
        · rfl

/-- A printed value followed by `,` is not the `-2^63` expression. -/
theorem pMin_enc (m : Nat) (v : Json) (hv : v.WF) (t : List Char) :
    pMin (enc m v ++ ',' :: t) = none := by
  match v with
  | .null => rfl
  | .bool true => rfl
  | .bool false => rfl
  | .str s => simp [enc, quote, pMin_head]
  | .arr [] => rfl
  | .arr (_ :: _) => rfl
  | .obj [] => rfl
  | .obj (_ :: _) => rfl
  | .num n =>
    by_cases hm : n = .int int64Min
    · simp [enc, printNum, hm, pMin_head]
    · simp only [enc, printNum, hm, ite_false]
      exact pMin_num n hv t

theorem pVal_quote (f : Nat) (r : List Char) :
    pVal (f + 1) ('"' :: r) = (parseQuoted true ('"' :: r)).map fun p => (.str p.1, p.2) := by
  simp [pVal]

theorem pVal_num (f : Nat) (c : Char) (r : List Char) (hc : Number.NumHead c) :
    pVal (f + 1) (c :: r) = (Number.parse (c :: r)).map fun p => (.num p.1, p.2) := by
  simp [pVal, numHead_ne hc '(', numHead_ne hc '"', numHead_ne hc 'n', numHead_ne hc 't',
    numHead_ne hc 'f']

theorem pParen_items (f : Nat) (c : Char) (r : List Char) (hc : c ≠ ')') (hc' : c ≠ ':')
    (he : isEntry (c :: r) = false) :
    pParen (f + 1) (c :: r) = (pItems f true (c :: r)).map fun p => (.arr p.1, p.2) := by
  simp [pParen, hc, hc', he]

theorem pParen_entries (f : Nat) (c : Char) (r : List Char) (hc : c ≠ ')') (hc' : c ≠ ':')
    (he : isEntry (c :: r) = true) :
    pParen (f + 1) (c :: r) = (pEntries f (c :: r)).map fun p => (.obj p.1, p.2) := by
  simp [pParen, hc, hc', he]

theorem isEntry_enc (m : Nat) (v : Json) (r : List Char) (hv : v.WF) :
    isEntry (enc m v ++ ',' :: r) = false := by
  match v with
  | .null => rfl
  | .bool true => rfl
  | .bool false => rfl
  | .arr [] => rfl
  | .arr (_ :: _) => rfl
  | .obj [] => rfl
  | .obj (_ :: _) => rfl
  | .str s =>
    simp only [isEntry, enc, parseKey_quote]
    rw [skipWs_nonWs _ (by decide : isWs ',' = false)]
    rfl
  | .num n =>
    by_cases hm : n = .int int64Min
    · simp (config := { decide := true }) [isEntry, enc, printNum, hm, parseKey]
    obtain ⟨c, t, h, hc⟩ := Number.print_head n hv
    simp [isEntry, enc, printNum, hm, h, parseKey, numHead_ne hc '"', numHead_ident hc]

theorem isEntry_printKey (k : String) (r : List Char) :
    isEntry (printKey true reserved k ++ ':' :: r) = true := by
  simp only [isEntry, parseKey_printKey true reserved k (':' :: r) (fun c hc => by cases hc; decide)]
  rw [skipWs_nonWs _ (by decide : isWs ':' = false)]
  rfl

/-- The elements of a non-empty array after the first one's indentation. -/
def itemsTail (m : Nat) : List Json → List Char
  | [] => []
  | v :: vs => enc m v ++ ',' :: '\n' :: encItems m vs

/-- The entries of a non-empty dictionary after the first one's indentation. -/
def entriesTail (m : Nat) : List (String × Json) → List Char
  | [] => []
  | (k, v) :: es =>
    printKey true reserved k ++ ':' :: ' ' :: enc m v ++ ',' :: '\n' :: encEntries m es

theorem size_pos (v : Json) : 1 ≤ v.size := by
  cases v <;> simp [Json.size]

theorem sizeList_pos (l : List Json) : 1 ≤ Json.sizeList l := by
  cases l <;> simp [Json.sizeList]

theorem sizeObj_pos (l : List (String × Json)) : 1 ≤ Json.sizeObj l := by
  cases l with
  | nil => simp [Json.sizeObj]
  | cons e es => obtain ⟨k, v⟩ := e; simp [Json.sizeObj]

mutual
theorem pVal_enc (m : Nat) : ∀ (v : Json) (f : Nat) (rest : List Char), v.WF →
    Number.NumStop rest → 3 * v.size ≤ f → pVal f (enc m v ++ rest) = some (v, rest)
  | v, 0, rest, _, _, hf => absurd hf (by have := size_pos v; omega)
  | .null, f + 1, rest, _, _, _ => rfl
  | .bool true, f + 1, rest, _, _, _ => rfl
  | .bool false, f + 1, rest, _, _, _ => rfl
  | .str s, f + 1, rest, _, _, _ => by
    have h : enc m (.str s) ++ rest = '"' :: (escape true s.toList ++ ['"'] ++ rest) := by
      simp [enc, quote]
    rw [h, pVal_quote, ← h]
    simp only [enc, parseQuoted_quote, Option.map_some]
  | .num n, f + 1, rest, hv, hr, _ => by
    by_cases hm : n = .int int64Min
    · subst hm
      simp only [enc, printNum, ite_true, List.cons_append]
      exact pVal_min f rest
    obtain ⟨c, t, h, hc⟩ := Number.print_head n hv
    have hp := Number.parse_print n rest hv hr
    simp only [enc, printNum, hm, ite_false, h, List.cons_append] at hp ⊢
    rw [pVal_num _ _ _ hc, hp]
    rfl
  | .arr [], f + 1, rest, _, _, _ => by
    simp only [enc, List.cons_append, List.nil_append]
    rw [pVal_paren _ _ (by rw [skipWs_nonWs _ (by decide)]; exact pMin_head _ (by decide))]
    rw [skipWs_nonWs _ (by decide : isWs ')' = false)]
    cases f with
    | zero => simp [Json.size, Json.sizeList] at *
    | succ f => simp [pParen]
  | .obj [], f + 1, rest, _, _, hf => by
    simp only [enc, List.cons_append, List.nil_append]
    rw [pVal_paren _ _ (by rw [skipWs_nonWs _ (by decide)]; exact pMin_head _ (by decide))]
    rw [skipWs_nonWs _ (by decide : isWs ':' = false)]
    cases f with
    | zero => simp [Json.size, Json.sizeObj] at hf
    | succ f =>
      simp only [pParen, (by decide : (':' = ')') = False), ite_false, ite_true]
      rw [skipWs_nonWs _ (by decide : isWs ')' = false)]
      rfl
  | .arr (v :: vs), f + 1, rest, hv, hr, hf => by
    have hv' : Json.WFList (v :: vs) := hv
    have hvv : v.WF := hv'.1
    have h : enc m (.arr (v :: vs)) ++ rest =
        '(' :: '\n' :: (spaces (m + 2) ++ (itemsTail (m + 2) (v :: vs) ++ (spaces m ++ ')' :: rest))) := by
      simp [enc, encItems, itemsTail]
    obtain ⟨c, t, hct, hc1, hc2, hc3⟩ := enc_head (m + 2) v hvv
    have hit : itemsTail (m + 2) (v :: vs) ++ (spaces m ++ ')' :: rest) =
        c :: (t ++ ',' :: '\n' :: (encItems (m + 2) vs ++ (spaces m ++ ')' :: rest))) := by
      simp [itemsTail, hct]
    have hsk : skipWs ('\n' :: (spaces (m + 2) ++
        (itemsTail (m + 2) (v :: vs) ++ (spaces m ++ ')' :: rest)))) =
        itemsTail (m + 2) (v :: vs) ++ (spaces m ++ ')' :: rest) := by
      rw [skipWs_ws _ (by decide : isWs '\n' = true), skipWs_spaces, hit, skipWs_nonWs _ hc1]
    have hmin : pMin (itemsTail (m + 2) (v :: vs) ++ (spaces m ++ ')' :: rest)) = none := by
      simpa [itemsTail] using pMin_enc (m + 2) v hvv
        (('\n' :: encItems (m + 2) vs) ++ (spaces m ++ ')' :: rest))
    rw [h, pVal_paren _ _ (by rw [hsk]; exact hmin), hsk]
    have hs : 3 * (Json.sizeList (v :: vs) + 1) ≤ f + 1 := by simpa [Json.size] using hf
    have hl1 := sizeList_pos (v :: vs)
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    rw [hit, pParen_items _ _ _ hc2 hc3, ← hit,
      pItems_enc (m + 2) (v :: vs) g true m rest hv' (by simp) (by omega)]
    · rfl
    · rw [← List.cons_append, ← hct]
      exact isEntry_enc _ _ _ hvv
  | .obj (e :: es), f + 1, rest, hv, hr, hf => by
    obtain ⟨k, v⟩ := e
    have hv' : Json.WFObj ((k, v) :: es) := hv.2
    have h : enc m (.obj ((k, v) :: es)) ++ rest =
        '(' :: '\n' :: (spaces (m + 2) ++
          (entriesTail (m + 2) ((k, v) :: es) ++ (spaces m ++ ')' :: rest))) := by
      simp [enc, encEntries, entriesTail]
    obtain ⟨c, t, hct, hc⟩ := printKey_head true reserved k
    have hsk : skipWs ('\n' :: (spaces (m + 2) ++
        (entriesTail (m + 2) ((k, v) :: es) ++ (spaces m ++ ')' :: rest)))) =
        entriesTail (m + 2) ((k, v) :: es) ++ (spaces m ++ ')' :: rest) := by
      rw [skipWs_ws _ (by decide : isWs '\n' = true), skipWs_spaces]
      simp only [entriesTail, hct, List.cons_append, List.append_assoc]
      exact skipWs_nonWs _ (keyHead_facts hc).2.2.1
    have hmin : pMin (entriesTail (m + 2) ((k, v) :: es) ++ (spaces m ++ ')' :: rest)) = none := by
      simp only [entriesTail, hct, List.cons_append, List.append_assoc]
      exact pMin_head _ (keyHead_facts hc).2.2.2
    rw [h, pVal_paren _ _ (by rw [hsk]; exact hmin), hsk]
    have hs : 3 * (Json.sizeObj ((k, v) :: es) + 1) ≤ f + 1 := by simpa [Json.size] using hf
    have hl1 := sizeObj_pos ((k, v) :: es)
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    have hc1 : c ≠ ')' ∧ c ≠ ':' ∧ isWs c = false :=
      ⟨(keyHead_facts hc).1, (keyHead_facts hc).2.1, (keyHead_facts hc).2.2.1⟩
    have hit : entriesTail (m + 2) ((k, v) :: es) ++ (spaces m ++ ')' :: rest) =
        c :: (t ++ ':' :: ' ' :: (enc (m + 2) v ++ ',' :: '\n' ::
          (encEntries (m + 2) es ++ (spaces m ++ ')' :: rest)))) := by
      simp [entriesTail, hct]
    rw [hit, pParen_entries _ _ _ hc1.1 hc1.2.1, ← hit,
      pEntries_enc (m + 2) ((k, v) :: es) g m rest hv' (by simp) (by omega)]
    · rfl
    · rw [← List.cons_append, ← hct]
      exact isEntry_printKey _ _

theorem pItems_enc (m : Nat) : ∀ (l : List Json) (f : Nat) (first : Bool) (k : Nat)
    (rest : List Char), Json.WFList l → l ≠ [] → 3 * Json.sizeList l ≤ f →
      pItems f first (itemsTail m l ++ (spaces k ++ ')' :: rest)) = some (l, rest)
  | [], _, _, _, _, _, hne, _ => absurd rfl hne
  | v :: vs, f, first, k, rest, hw, _, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by have := sizeList_pos (v :: vs); omega⟩
    have hs : 3 * (v.size + Json.sizeList vs + 1) ≤ g + 1 := by simpa [Json.sizeList] using hf
    have hvs := sizeList_pos vs
    have hw' : v.WF ∧ Json.WFList vs := hw
    simp only [itemsTail, List.append_assoc, List.cons_append]
    rw [pItems, pVal_enc m v g _ hw'.1 (fun c hc => by cases hc; decide) (by omega)]
    simp only
    cases vs with
    | nil =>
      simp [encItems, List.nil_append, pNext_last]
    | cons w ws =>
      obtain ⟨c, t, hct, hc1, hc2, -⟩ := enc_head m w hw'.2.1
      have h : encItems m (w :: ws) ++ (spaces k ++ ')' :: rest) =
          spaces m ++ (c :: (t ++ ',' :: '\n' :: (encItems m ws ++ (spaces k ++ ')' :: rest)))) := by
        simp [encItems, hct]
      rw [h, pNext_more _ _ _ hc1 hc2]
      simp only
      have h2 : c :: (t ++ ',' :: '\n' :: (encItems m ws ++ (spaces k ++ ')' :: rest))) =
          itemsTail m (w :: ws) ++ (spaces k ++ ')' :: rest) := by
        simp [itemsTail, hct]
      rw [h2, pItems_enc m (w :: ws) g false k rest hw'.2 (by simp) (by omega)]
      rfl

theorem pEntries_enc (m : Nat) : ∀ (l : List (String × Json)) (f k : Nat) (rest : List Char),
    Json.WFObj l → l ≠ [] → 3 * Json.sizeObj l ≤ f →
      pEntries f (entriesTail m l ++ (spaces k ++ ')' :: rest)) = some (l, rest)
  | [], _, _, _, _, hne, _ => absurd rfl hne
  | (key, v) :: es, f, k, rest, hw, _, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by have := sizeObj_pos ((key, v) :: es); omega⟩
    have hs : 3 * (v.size + Json.sizeObj es + 1) ≤ g + 1 := by simpa [Json.sizeObj] using hf
    have hes := sizeObj_pos es
    have hw' : v.WF ∧ Json.WFObj es := hw
    simp only [entriesTail, List.append_assoc, List.cons_append]
    rw [pEntries, parseKey_printKey _ _ _ _ (fun c hc => by cases hc; decide)]
    simp only
    rw [skipWs_nonWs _ (by decide : isWs ':' = false)]
    simp only
    rw [skipWs_ws _ (by decide : isWs ' ' = true), skipWs_enc _ _ _ hw'.1,
      pVal_enc m v g _ hw'.1 (fun c hc => by cases hc; decide) (by omega)]
    simp only
    cases es with
    | nil =>
      simp only [encEntries, List.nil_append, pNext_last]
    | cons e2 es2 =>
      obtain ⟨key2, w⟩ := e2
      obtain ⟨c, t, hct, hc⟩ := printKey_head true reserved key2
      have hc1 : c ≠ ')' ∧ isWs c = false := ⟨(keyHead_facts hc).1, (keyHead_facts hc).2.2.1⟩
      have h : encEntries m ((key2, w) :: es2) ++ (spaces k ++ ')' :: rest) =
          spaces m ++ (c :: (t ++ ':' :: ' ' :: (enc m w ++ ',' :: '\n' ::
            (encEntries m es2 ++ (spaces k ++ ')' :: rest))))) := by
        simp [encEntries, hct]
      rw [h, pNext_more _ _ _ hc1.2 hc1.1]
      simp only
      have h2 : c :: (t ++ ':' :: ' ' :: (enc m w ++ ',' :: '\n' ::
            (encEntries m es2 ++ (spaces k ++ ')' :: rest)))) =
          entriesTail m ((key2, w) :: es2) ++ (spaces k ++ ')' :: rest) := by
        simp [entriesTail, hct]
      rw [h2, pEntries_enc m ((key2, w) :: es2) g k rest hw'.2 (by simp) (by omega)]
      rfl
end

mutual
theorem size_le (m : Nat) : ∀ v : Json, v.size ≤ (enc m v).length + 1
  | .null => by simp [Json.size]
  | .bool _ => by simp [Json.size]
  | .num _ => by simp [Json.size]
  | .str _ => by simp [Json.size]
  | .arr [] => by simp [Json.size, Json.sizeList, enc]
  | .obj [] => by simp [Json.size, Json.sizeObj, enc]
  | .arr (v :: vs) => by
    have := sizeList_le (m + 2) (v :: vs)
    simp only [Json.size, enc, List.length_cons, List.length_append] at this ⊢
    omega
  | .obj (e :: es) => by
    have := sizeObj_le (m + 2) (e :: es)
    simp only [Json.size, enc, List.length_cons, List.length_append] at this ⊢
    omega

theorem sizeList_le (m : Nat) : ∀ l : List Json, Json.sizeList l ≤ (encItems m l).length + 1
  | [] => by simp [Json.sizeList]
  | v :: vs => by
    have h1 := size_le m v
    have h2 := sizeList_le m vs
    simp only [Json.sizeList, encItems, List.length_cons, List.length_append] at h2 ⊢
    omega

theorem sizeObj_le (m : Nat) : ∀ l : List (String × Json), Json.sizeObj l ≤ (encEntries m l).length + 1
  | [] => by simp [Json.sizeObj]
  | (k, v) :: es => by
    have h1 := size_le m v
    have h2 := sizeObj_le m es
    simp only [Json.sizeObj, encEntries, List.length_cons, List.length_append] at h2 ⊢
    omega
end

/-- **The Typst round trip.** Reading the canonical Typst spelling of a well-formed
value gives the value back. -/
theorem decode_encode (v : Json) (hv : v.WF) : decode (encode v) = some v := by
  have hp := pVal_enc 0 v (3 * (encode v).length + 3) [] hv (fun c hc => by cases hc)
    (by have := size_le 0 v; simp only [encode]; omega)
  rw [List.append_nil] at hp
  unfold decode
  rw [show skipWs (encode v) = encode v by
    simpa [encode] using skipWs_enc 0 v [] hv]
  simp only [encode] at hp ⊢
  rw [hp]
  simp [skipWs, (Json.wfb_iff v).mpr hv]

/-! ## What the reader rejects or accepts -/

example : (decode "(1)".toList).isNone = true := by decide +kernel
example : (decode "(1,)".toList).map encode = some "(\n  1,\n)".toList := by decide +kernel
example : (decode "(1, 2)".toList).map encode = some "(\n  1,\n  2,\n)".toList := by
  decide +kernel
example : (decode "(a: 1)".toList).map encode = some "(\n  a: 1,\n)".toList := by decide +kernel
example : (decode "(none: 1)".toList).isNone = true := by decide +kernel
example : (decode "(a: 1, a: 2)".toList).isNone = true := by decide +kernel
example : (decode "(a: 007)".toList).isNone = true := by decide +kernel
example : (decode "( -9223372036854775807 - 1 )".toList).map encode =
    some "(-9223372036854775807 - 1)".toList := by decide +kernel
example : (decode "(-9223372036854775807-1)".toList).map encode =
    some "(-9223372036854775807 - 1)".toList := by decide +kernel
example : (decode "(-9223372036854775807,)".toList).map encode =
    some "(\n  -9223372036854775807,\n)".toList := by decide +kernel

end Esm.Document.TypstDict
