import Esm.Document.Number
import Esm.Document.Strings

/-!
# The strict YAML subset codec

The YAML spelling of a `Json` value, used for `esm:<path>` blocks and front matter in
Markdown documents. The printed text is block-style YAML 1.2:

* A non-empty object is one `key: value` line per entry at the current indentation.
* A non-empty array is one `- item` line per element at the current indentation.
* A scalar, `[]` or `{}` value follows its `key: ` or `- ` on the same line.
* A non-empty object or array under a key starts on the next line, indented two
  spaces deeper (`key:` then the block).
* A non-empty object as an array element starts on the `- ` line (`- key: v`), its
  other entries indented to align with the first key (two spaces past the `-`).
* A non-empty array as an array element starts on the next line, indented two
  spaces deeper (`-` alone, then the block).
* A top-level scalar, `[]` or `{}` is one line.

Scalars: `null`, `true`, `false`, numbers in the canonical spelling (`Number.print`),
and strings ALWAYS double-quoted with JSON-style escapes (`\uXXXX` for the characters
of `Strings.needsHex`), which avoids YAML's implicit typing. A key is bare when it
matches `[A-Za-z_][A-Za-z0-9_]*` and is not, in any letter case, one of YAML's
special plain scalars (`true false null yes no on off y n`); otherwise it is quoted
like a string.

Every line ends with a newline. The reader only accepts this layout (it is the
canonical form; other YAML is out of scope). `decode_encode` is the round trip.
-/

namespace Esm.Document.Yaml

open Strings

/-! ## Printer -/

/-- Plain scalars YAML 1.1 or 1.2 reads as something other than a string; a key
equal to one of them (in any letter case) is quoted. -/
def specialWords : List String := ["true", "false", "null", "yes", "no", "on", "off", "y", "n"]

/-- A key prints bare when it is an identifier and not a special plain scalar. -/
def bareKey (k : String) : Bool :=
  isIdent k.toList && !(specialWords.contains (String.ofList (k.toList.map Char.toLower)))

def printKey (k : String) : List Char := if bareKey k then k.toList else quote false k

/-- The one-line spelling of a scalar or an empty container. (A non-empty container
is never printed inline; it gets `[]`/`{}` here only to keep the function total.) -/
def inline : Json → List Char
  | .null => ['n', 'u', 'l', 'l']
  | .bool true => ['t', 'r', 'u', 'e']
  | .bool false => ['f', 'a', 'l', 's', 'e']
  | .num n => Number.print n
  | .str s => quote false s
  | .arr _ => ['[', ']']
  | .obj _ => ['{', '}']

mutual
/-- The lines of a non-empty array at indentation `m`. -/
def encItems (m : Nat) : List Json → List Char
  | [] => []
  | v :: vs => spaces m ++ '-' :: itemBody m v ++ encItems m vs

/-- What follows the `-` of an array element at indentation `m`. -/
def itemBody (m : Nat) : Json → List Char
  | .arr (v :: vs) => '\n' :: encItems (m + 2) (v :: vs)
  | .obj ((k, v) :: es) => ' ' :: printKey k ++ ':' :: valBody (m + 2) v ++ encEntries (m + 2) es
  | .null => ' ' :: inline .null ++ ['\n']
  | .bool b => ' ' :: inline (.bool b) ++ ['\n']
  | .num n => ' ' :: inline (.num n) ++ ['\n']
  | .str s => ' ' :: inline (.str s) ++ ['\n']
  | .arr [] => ' ' :: inline (.arr []) ++ ['\n']
  | .obj [] => ' ' :: inline (.obj []) ++ ['\n']

/-- The lines of a non-empty object at indentation `m`. -/
def encEntries (m : Nat) : List (String × Json) → List Char
  | [] => []
  | (k, v) :: es => spaces m ++ printKey k ++ ':' :: valBody m v ++ encEntries m es

/-- What follows the `:` of an entry whose key is at indentation `m`. -/
def valBody (m : Nat) : Json → List Char
  | .arr (v :: vs) => '\n' :: encItems (m + 2) (v :: vs)
  | .obj (e :: es) => '\n' :: encEntries (m + 2) (e :: es)
  | .null => ' ' :: inline .null ++ ['\n']
  | .bool b => ' ' :: inline (.bool b) ++ ['\n']
  | .num n => ' ' :: inline (.num n) ++ ['\n']
  | .str s => ' ' :: inline (.str s) ++ ['\n']
  | .arr [] => ' ' :: inline (.arr []) ++ ['\n']
  | .obj [] => ' ' :: inline (.obj []) ++ ['\n']
end

/-- The canonical YAML spelling of a value. -/
def encode : Json → List Char
  | .arr (v :: vs) => encItems 0 (v :: vs)
  | .obj (e :: es) => encEntries 0 (e :: es)
  | v => inline v ++ ['\n']

/-! ## Reader -/

/-- Drop exactly `n` leading spaces. -/
def dropSp : Nat → List Char → Option (List Char)
  | 0, l => some l
  | n + 1, ' ' :: l => dropSp n l
  | _ + 1, _ => none

/-- A key: quoted, or an identifier. -/
def parseKey : List Char → Option (String × List Char)
  | [] => none
  | c :: r =>
    if c = '"' then parseQuoted false (c :: r)
    else if isIdentStart c then
      let p := readIdent (c :: r)
      some (String.ofList p.1, p.2)
    else none

/-- A scalar or an empty container. -/
def pInline : List Char → Option (Json × List Char)
  | [] => none
  | c :: r =>
    if c = 'n' then
      match r with
      | 'u' :: 'l' :: 'l' :: r' => some (.null, r')
      | _ => none
    else if c = 't' then
      match r with
      | 'r' :: 'u' :: 'e' :: r' => some (.bool true, r')
      | _ => none
    else if c = 'f' then
      match r with
      | 'a' :: 'l' :: 's' :: 'e' :: r' => some (.bool false, r')
      | _ => none
    else if c = '[' then
      match r with
      | ']' :: r' => some (.arr [], r')
      | _ => none
    else if c = '{' then
      match r with
      | '}' :: r' => some (.obj [], r')
      | _ => none
    else if c = '"' then (parseQuoted false (c :: r)).map fun p => (.str p.1, p.2)
    else (Number.parse (c :: r)).map fun p => (.num p.1, p.2)

/-- A scalar and the end of its line. -/
def pScalarLine (input : List Char) : Option (Json × List Char) :=
  match pInline input with
  | some (v, '\n' :: r) => some (v, r)
  | _ => none

/-- A line at indentation `m` that starts an array element. -/
def isItemLine (m : Nat) (input : List Char) : Bool :=
  match dropSp m input with
  | some ('-' :: _) => true
  | _ => false

/-- A line at indentation `m` that starts an object entry. -/
def isEntryLine (m : Nat) (input : List Char) : Bool :=
  match dropSp m input with
  | some (c :: _) => c == '"' || isIdentStart c
  | _ => false

mutual
/-- Array elements at indentation `m`, as long as lines start with `-` there. -/
def pItems : Nat → Nat → List Char → Option (List Json × List Char)
  | 0, _, _ => none
  | f + 1, m, input =>
    if isItemLine m input then
      match pItemBody f m ((input.drop m).drop 1) with
      | none => none
      | some (v, r) => (pItems f m r).map fun p => (v :: p.1, p.2)
    else some ([], input)

/-- After the `-` of an element at indentation `m`. -/
def pItemBody : Nat → Nat → List Char → Option (Json × List Char)
  | 0, _, _ => none
  | _, _, [] => none
  | f + 1, m, c :: r =>
    if c = '\n' then (pItems f (m + 2) r).map fun p => (.arr p.1, p.2)
    else if c = ' ' then
      match pEntry f (m + 2) r with
      | some (e, r') => (pEntries f (m + 2) r').map fun p => (.obj (e :: p.1), p.2)
      | none => pScalarLine r
    else none

/-- Object entries at indentation `m`, as long as lines start with a key there. -/
def pEntries : Nat → Nat → List Char → Option (List (String × Json) × List Char)
  | 0, _, _ => none
  | f + 1, m, input =>
    if isEntryLine m input then
      match pEntry f m (input.drop m) with
      | none => none
      | some (e, r) => (pEntries f m r).map fun p => (e :: p.1, p.2)
    else some ([], input)

/-- One entry, at its key, whose key is at indentation `m`. -/
def pEntry : Nat → Nat → List Char → Option ((String × Json) × List Char)
  | 0, _, _ => none
  | f + 1, m, input =>
    match parseKey input with
    | some (k, ':' :: r) => (pValBody f m r).map fun p => ((k, p.1), p.2)
    | _ => none

/-- After the `:` of an entry whose key is at indentation `m`. -/
def pValBody : Nat → Nat → List Char → Option (Json × List Char)
  | 0, _, _ => none
  | _, _, [] => none
  | f + 1, m, c :: r =>
    if c = ' ' then pScalarLine r
    else if c = '\n' then
      if isItemLine (m + 2) r then (pItems f (m + 2) r).map fun p => (.arr p.1, p.2)
      else (pEntries f (m + 2) r).map fun p => (.obj p.1, p.2)
    else none
end

/-- A whole document: an array, an object, or one scalar line. -/
def pTop (f : Nat) (input : List Char) : Option (Json × List Char) :=
  if isItemLine 0 input && (match input with
      | _ :: d :: _ => d == ' ' || d == '\n'
      | _ => false) then
    (pItems f 0 input).map fun p => (.arr p.1, p.2)
  else
    match pEntry f 0 input with
    | some (e, r) => (pEntries f 0 r).map fun p => (.obj (e :: p.1), p.2)
    | none => pScalarLine input

/-- Read a document; all of the input must be consumed. -/
def decode (s : List Char) : Option Json :=
  match pTop (4 * s.length + 4) s with
  | some (v, []) => some v
  | _ => none

/-! ## The round trip -/

/-! ### Characters -/

/-- What a number never starts with. -/
theorem numHead_facts {c : Char} (h : Number.NumHead c) :
    c ≠ 'n' ∧ c ≠ 't' ∧ c ≠ 'f' ∧ c ≠ '[' ∧ c ≠ '{' ∧ c ≠ '"' ∧ isIdentStart c = false :=
  Number.NumHead.of_fin (P := fun c => c ≠ 'n' ∧ c ≠ 't' ∧ c ≠ 'f' ∧ c ≠ '[' ∧ c ≠ '{' ∧
    c ≠ '"' ∧ isIdentStart c = false) (by decide) (by decide) h

theorem printKey_head (k : String) :
    ∃ c t, printKey k = c :: t ∧ (c = '"' ∨ isIdentStart c = true) := by
  unfold printKey
  split
  · rename_i h
    simp only [bareKey, Bool.and_eq_true] at h
    have := h.1
    cases hk : k.toList with
    | nil => rw [hk] at this; simp [isIdent] at this
    | cons c t =>
      rw [hk] at this
      simp only [isIdent, Bool.and_eq_true] at this
      exact ⟨c, t, rfl, Or.inr this.1⟩
  · exact ⟨_, _, rfl, Or.inl rfl⟩

/-- A key never starts with a space or `-`. -/
theorem keyHead_facts {c : Char} (h : c = '"' ∨ isIdentStart c = true) :
    c ≠ ' ' ∧ c ≠ '-' ∧ (c == '"' || isIdentStart c) = true := by
  rcases h with rfl | h
  · decide
  · refine ⟨?_, ?_, by simp [h]⟩
    · intro e; rw [e] at h; exact absurd h (by decide)
    · intro e; rw [e] at h; exact absurd h (by decide)

theorem parseKey_quoteChar (r : List Char) :
    parseKey ('"' :: r) = parseQuoted false ('"' :: r) := by
  simp [parseKey]

theorem parseKey_quote (k : String) (rest : List Char) :
    parseKey (quote false k ++ rest) = some (k, rest) := by
  have h : quote false k ++ rest = '"' :: (escape false k.toList ++ ['"'] ++ rest) := by
    simp [quote]
  rw [h, parseKey_quoteChar, ← h, parseQuoted_quote]

/-- A printed key reads back, when what follows is not an identifier character. -/
theorem parseKey_printKey (k : String) (rest : List Char)
    (hr : ∀ c ∈ rest.head?, isIdentChar c = false) :
    parseKey (printKey k ++ rest) = some (k, rest) := by
  unfold printKey
  split
  · rename_i h
    simp only [bareKey, Bool.and_eq_true] at h
    have hid := h.1
    have hall := isIdent_all hid
    cases hk : k.toList with
    | nil => rw [hk] at hid; simp [isIdent] at hid
    | cons c t =>
      rw [hk] at hid hall
      simp only [isIdent, Bool.and_eq_true] at hid
      have hc : c ≠ '"' := by intro e; rw [e] at hid; exact absurd hid.1 (by decide)
      have hp : parseKey (c :: (t ++ rest)) =
          some (String.ofList (readIdent (c :: (t ++ rest))).1, (readIdent (c :: (t ++ rest))).2) := by
        simp [parseKey, hc, hid.1]
      rw [List.cons_append, hp, ← List.cons_append, readIdent_append _ _ hall hr, ← hk,
        String.ofList_toList]
  · exact parseKey_quote k rest

/-! ### Indentation -/

theorem dropSp_spaces (m : Nat) (r : List Char) : dropSp m (spaces m ++ r) = some r := by
  induction m with
  | zero => rfl
  | succ m ih => simpa [spaces, List.replicate_succ, dropSp] using ih

theorem drop_spaces (m : Nat) (r : List Char) : (spaces m ++ r).drop m = r := by
  simp [spaces]

/-- What may follow a block at indentation `m`: nothing, or a line indented less. -/
def Ends (m : Nat) (rest : List Char) : Prop :=
  rest = [] ∨ ∃ i c t, i < m ∧ c ≠ ' ' ∧ rest = spaces i ++ c :: t

theorem Ends.mono {m : Nat} {rest : List Char} (h : Ends m rest) : Ends (m + 2) rest := by
  rcases h with h | ⟨i, c, t, hi, hc, h⟩
  · exact Or.inl h
  · exact Or.inr ⟨i, c, t, by omega, hc, h⟩

theorem Ends.line (m : Nat) {c : Char} (t : List Char) (hc : c ≠ ' ') :
    Ends (m + 2) (spaces m ++ c :: t) :=
  Or.inr ⟨m, c, t, by omega, hc, rfl⟩

theorem Ends.nil (m : Nat) : Ends m [] := Or.inl rfl

theorem dropSp_short (i m : Nat) (c : Char) (t : List Char) (hi : i < m) (hc : c ≠ ' ') :
    dropSp m (spaces i ++ c :: t) = none := by
  induction i generalizing m with
  | zero =>
    obtain ⟨m, rfl⟩ : ∃ m', m = m' + 1 := ⟨m - 1, by omega⟩
    cases c; simp_all [dropSp, spaces]
  | succ i ih =>
    obtain ⟨m, rfl⟩ : ∃ m', m = m' + 1 := ⟨m - 1, by omega⟩
    simpa [spaces, List.replicate_succ, dropSp] using ih m (by omega)

theorem dropSp_nil (m : Nat) : dropSp m [] = none ∨ dropSp m [] = some [] := by
  cases m <;> simp [dropSp]

theorem isItemLine_ends {m : Nat} {rest : List Char} (h : Ends m rest) :
    isItemLine m rest = false := by
  rcases h with rfl | ⟨i, c, t, hi, hc, rfl⟩
  · rcases dropSp_nil m with h | h <;> simp [isItemLine, h]
  · simp [isItemLine, dropSp_short i m c t hi hc]

theorem isEntryLine_ends {m : Nat} {rest : List Char} (h : Ends m rest) :
    isEntryLine m rest = false := by
  rcases h with rfl | ⟨i, c, t, hi, hc, rfl⟩
  · rcases dropSp_nil m with h | h <;> simp [isEntryLine, h]
  · simp [isEntryLine, dropSp_short i m c t hi hc]

theorem isItemLine_dash (m : Nat) (t : List Char) : isItemLine m (spaces m ++ '-' :: t) = true := by
  simp [isItemLine, dropSp_spaces]

theorem isItemLine_key (m : Nat) (k : String) (t : List Char) :
    isItemLine m (spaces m ++ printKey k ++ t) = false := by
  obtain ⟨c, u, h, hc⟩ := printKey_head k
  have := (keyHead_facts hc).2.1
  simp [isItemLine, h, List.append_assoc, dropSp_spaces, this]

theorem isEntryLine_key (m : Nat) (k : String) (t : List Char) :
    isEntryLine m (spaces m ++ printKey k ++ t) = true := by
  obtain ⟨c, u, h, hc⟩ := printKey_head k
  have := (keyHead_facts hc).2.2
  simp only [isEntryLine, h, List.append_assoc, List.cons_append, dropSp_spaces]
  exact this

/-! ### Scalars -/

/-- Scalars and empty containers. -/
def isInl : Json → Bool
  | .arr (_ :: _) => false
  | .obj (_ :: _) => false
  | _ => true

theorem pInline_inline (v : Json) (hi : isInl v = true) (hv : v.WF) (rest : List Char) :
    pInline (inline v ++ '\n' :: rest) = some (v, '\n' :: rest) := by
  match v with
  | .null => rfl
  | .bool true => rfl
  | .bool false => rfl
  | .arr [] => rfl
  | .obj [] => rfl
  | .str s =>
    have h : inline (.str s) ++ '\n' :: rest =
        '"' :: (escape false s.toList ++ ['"'] ++ '\n' :: rest) := by simp [inline, quote]
    rw [h]
    simp only [pInline, (by decide : ('"' = 'n') = False), (by decide : ('"' = 't') = False),
      (by decide : ('"' = 'f') = False), (by decide : ('"' = '[') = False),
      (by decide : ('"' = '{') = False), ite_false, ite_true]
    rw [← h]
    simp [inline, parseQuoted_quote]
  | .num n =>
    obtain ⟨c, t, h, hc⟩ := Number.print_head n hv
    have f := numHead_facts hc
    have hp := Number.parse_print n ('\n' :: rest) hv (fun c hc => by cases hc; decide)
    simp only [inline, h, List.cons_append] at hp ⊢
    simp only [pInline, f.1, f.2.1, f.2.2.1, f.2.2.2.1, f.2.2.2.2.1, f.2.2.2.2.2.1, ite_false, hp]
    rfl

theorem pScalarLine_inline (v : Json) (hi : isInl v = true) (hv : v.WF) (rest : List Char) :
    pScalarLine (inline v ++ '\n' :: rest) = some (v, rest) := by
  simp [pScalarLine, pInline_inline v hi hv rest]

theorem pEntry_inline (f m : Nat) (v : Json) (hi : isInl v = true) (hv : v.WF) (rest : List Char) :
    pEntry f m (inline v ++ '\n' :: rest) = none := by
  cases f with
  | zero => simp [pEntry]
  | succ f =>
    match v with
    | .null | .bool true | .bool false | .arr [] | .obj [] =>
      simp (config := { decide := true }) [pEntry, inline, parseKey, readIdent]
    | .str s =>
      simp only [pEntry, inline, parseKey_quote]
      rfl
    | .num n =>
      obtain ⟨c, t, h, hc⟩ := Number.print_head n hv
      have f := numHead_facts hc
      simp [pEntry, inline, h, parseKey, f.2.2.2.2.2.1, f.2.2.2.2.2.2]

/-! ### Line structure -/

theorem itemBody_inl (m : Nat) (v : Json) (hi : isInl v = true) :
    itemBody m v = ' ' :: inline v ++ ['\n'] := by
  match v with
  | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] => rfl

theorem valBody_inl (m : Nat) (v : Json) (hi : isInl v = true) :
    valBody m v = ' ' :: inline v ++ ['\n'] := by
  match v with
  | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] => rfl

theorem itemBody_head (m : Nat) (v : Json) :
    ∃ c t, itemBody m v = c :: t ∧ (c = ' ' ∨ c = '\n') := by
  match v with
  | .arr (_ :: _) => exact ⟨_, _, rfl, Or.inr rfl⟩
  | .obj ((_, _) :: _) => exact ⟨_, _, rfl, Or.inl rfl⟩
  | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] => exact ⟨_, _, rfl, Or.inl rfl⟩

theorem items_ends (m : Nat) (vs : List Json) (rest : List Char) (h : Ends m rest) :
    Ends (m + 2) (encItems m vs ++ rest) := by
  cases vs with
  | nil => simpa [encItems] using h.mono
  | cons w ws =>
    have : encItems m (w :: ws) ++ rest = spaces m ++ '-' :: (itemBody m w ++ encItems m ws ++ rest) := by
      simp [encItems]
    rw [this]; exact Ends.line m _ (by decide)

theorem entries_ends (m : Nat) (es : List (String × Json)) (rest : List Char) (h : Ends m rest) :
    Ends (m + 2) (encEntries m es ++ rest) := by
  cases es with
  | nil => simpa [encEntries] using h.mono
  | cons e es =>
    obtain ⟨k, w⟩ := e
    obtain ⟨c, t, hct, hc⟩ := printKey_head k
    have : encEntries m ((k, w) :: es) ++ rest =
        spaces m ++ c :: (t ++ ':' :: (valBody m w ++ encEntries m es ++ rest)) := by
      simp [encEntries, hct]
    rw [this]; exact Ends.line m _ (keyHead_facts hc).1

/-- An entry reads back once its value does. -/
theorem pEntry_enc (f m : Nat) (k : String) (v : Json) (rest : List Char)
    (h : pValBody f m (valBody m v ++ rest) = some (v, rest)) :
    pEntry (f + 1) m (printKey k ++ ':' :: (valBody m v ++ rest)) = some ((k, v), rest) := by
  rw [pEntry, parseKey_printKey k (':' :: (valBody m v ++ rest)) (fun c hc => by cases hc; decide)]
  simp only [h, Option.map_some]

theorem size_pos (v : Json) : 1 ≤ v.size := by
  cases v <;> simp [Json.size]

theorem sizeList_pos (l : List Json) : 1 ≤ Json.sizeList l := by
  cases l <;> simp [Json.sizeList]

theorem sizeObj_pos (l : List (String × Json)) : 1 ≤ Json.sizeObj l := by
  cases l with
  | nil => simp [Json.sizeObj]
  | cons e es => obtain ⟨k, v⟩ := e; simp [Json.sizeObj]

theorem pValBody_scalar (f m : Nat) (v : Json) (hi : isInl v = true) (hv : v.WF) (rest : List Char) :
    pValBody (f + 1) m (valBody m v ++ rest) = some (v, rest) := by
  have h : valBody m v ++ rest = ' ' :: (inline v ++ '\n' :: rest) := by
    simp [valBody_inl m v hi]
  rw [h]
  simp only [pValBody, ite_true]
  exact pScalarLine_inline v hi hv rest

theorem pItemBody_scalar (f m : Nat) (v : Json) (hi : isInl v = true) (hv : v.WF) (rest : List Char) :
    pItemBody (f + 1) m (itemBody m v ++ rest) = some (v, rest) := by
  have h : itemBody m v ++ rest = ' ' :: (inline v ++ '\n' :: rest) := by
    simp [itemBody_inl m v hi]
  rw [h]
  simp only [pItemBody, (by decide : (' ' = '\n') = False), ite_false, ite_true]
  rw [pEntry_inline f (m + 2) v hi hv rest]
  exact pScalarLine_inline v hi hv rest

mutual
theorem pValBody_enc : ∀ (v : Json) (f m : Nat) (rest : List Char), v.WF → Ends (m + 2) rest →
    2 * v.size ≤ f → pValBody f m (valBody m v ++ rest) = some (v, rest)
  | v, 0, _, _, _, _, hf => absurd hf (by have := size_pos v; omega)
  | .null, f + 1, m, rest, hv, _, _ => pValBody_scalar f m .null rfl hv rest
  | .bool b, f + 1, m, rest, hv, _, _ => pValBody_scalar f m (.bool b) rfl hv rest
  | .num n, f + 1, m, rest, hv, _, _ => pValBody_scalar f m (.num n) rfl hv rest
  | .str s, f + 1, m, rest, hv, _, _ => pValBody_scalar f m (.str s) rfl hv rest
  | .arr [], f + 1, m, rest, hv, _, _ => pValBody_scalar f m (.arr []) rfl hv rest
  | .obj [], f + 1, m, rest, hv, _, _ => pValBody_scalar f m (.obj []) rfl hv rest
  | .arr (w :: ws), f + 1, m, rest, hv, hr, hf => by
    have hs : 2 * (Json.sizeList (w :: ws) + 1) ≤ f + 1 := by simpa [Json.size] using hf
    have hit := pItems_enc (w :: ws) f (m + 2) rest hv hr (by omega)
    have hl : isItemLine (m + 2) (encItems (m + 2) (w :: ws) ++ rest) = true := by
      simp only [encItems, List.append_assoc, List.cons_append]
      exact isItemLine_dash _ _
    simp only [valBody, List.cons_append, pValBody, (by decide : ('\n' = ' ') = False),
      ite_false, ite_true, hl, hit, Option.map_some]
  | .obj (e :: es), f + 1, m, rest, hv, hr, hf => by
    obtain ⟨k, w⟩ := e
    have hs : 2 * (Json.sizeObj ((k, w) :: es) + 1) ≤ f + 1 := by simpa [Json.size] using hf
    have hen := pEntries_enc ((k, w) :: es) f (m + 2) rest hv.2 hr (by omega)
    have hl : isItemLine (m + 2) (encEntries (m + 2) ((k, w) :: es) ++ rest) = false := by
      simp only [encEntries, List.append_assoc]
      rw [← List.append_assoc]
      exact isItemLine_key _ _ _
    simp only [valBody, List.cons_append, pValBody, (by decide : ('\n' = ' ') = False),
      ite_false, ite_true, hl, hen, Option.map_some, Bool.false_eq_true]

theorem pItemBody_enc : ∀ (v : Json) (f m : Nat) (rest : List Char), v.WF → Ends (m + 2) rest →
    2 * v.size ≤ f → pItemBody f m (itemBody m v ++ rest) = some (v, rest)
  | v, 0, _, _, _, _, hf => absurd hf (by have := size_pos v; omega)
  | .null, f + 1, m, rest, hv, _, _ => pItemBody_scalar f m .null rfl hv rest
  | .bool b, f + 1, m, rest, hv, _, _ => pItemBody_scalar f m (.bool b) rfl hv rest
  | .num n, f + 1, m, rest, hv, _, _ => pItemBody_scalar f m (.num n) rfl hv rest
  | .str s, f + 1, m, rest, hv, _, _ => pItemBody_scalar f m (.str s) rfl hv rest
  | .arr [], f + 1, m, rest, hv, _, _ => pItemBody_scalar f m (.arr []) rfl hv rest
  | .obj [], f + 1, m, rest, hv, _, _ => pItemBody_scalar f m (.obj []) rfl hv rest
  | .arr (w :: ws), f + 1, m, rest, hv, hr, hf => by
    have hs : 2 * (Json.sizeList (w :: ws) + 1) ≤ f + 1 := by simpa [Json.size] using hf
    have hit := pItems_enc (w :: ws) f (m + 2) rest hv hr (by omega)
    simp only [itemBody, List.cons_append, pItemBody, ite_true, hit, Option.map_some]
  | .obj ((k, w) :: es), f + 1, m, rest, hv, hr, hf => by
    have hw : Json.WFObj ((k, w) :: es) := hv.2
    have hw' : w.WF ∧ Json.WFObj es := hw
    have hs : 2 * (w.size + Json.sizeObj es + 1 + 1) ≤ f + 1 := by
      simpa [Json.size, Json.sizeObj] using hf
    have hes := sizeObj_pos es
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    have hvb := pValBody_enc w g (m + 2) (encEntries (m + 2) es ++ rest) hw'.1
      (entries_ends (m + 2) es rest hr) (by omega)
    have hen := pEntries_enc es (g + 1) (m + 2) rest hw'.2 hr (by omega)
    have hent := pEntry_enc g (m + 2) k w _ hvb
    simp only [itemBody, List.cons_append, List.append_assoc, pItemBody,
      (by decide : (' ' = '\n') = False), ite_false, ite_true]
    rw [hent]
    simp only [hen, Option.map_some]

theorem pItems_enc : ∀ (l : List Json) (f m : Nat) (rest : List Char), Json.WFList l →
    Ends m rest → 2 * Json.sizeList l ≤ f → pItems f m (encItems m l ++ rest) = some (l, rest)
  | l, 0, _, _, _, _, hf => absurd hf (by have := sizeList_pos l; omega)
  | [], f + 1, m, rest, _, hr, _ => by
    simp [encItems, pItems, isItemLine_ends hr]
  | v :: vs, f + 1, m, rest, hw, hr, hf => by
    have hw' : v.WF ∧ Json.WFList vs := hw
    have hs : 2 * (v.size + Json.sizeList vs + 1) ≤ f + 1 := by simpa [Json.sizeList] using hf
    have hib := pItemBody_enc v f m (encItems m vs ++ rest) hw'.1 (items_ends m vs rest hr) (by omega)
    have hit := pItems_enc vs f m rest hw'.2 hr (by omega)
    have h : encItems m (v :: vs) ++ rest = spaces m ++ '-' :: (itemBody m v ++ (encItems m vs ++ rest)) := by
      simp [encItems]
    rw [h, pItems, ite_eq_left (isItemLine_dash _ _), drop_spaces]
    simp only [List.drop_succ_cons, List.drop_zero, hib, hit, Option.map_some]

theorem pEntries_enc : ∀ (l : List (String × Json)) (f m : Nat) (rest : List Char), Json.WFObj l →
    Ends m rest → 2 * Json.sizeObj l ≤ f → pEntries f m (encEntries m l ++ rest) = some (l, rest)
  | l, 0, _, _, _, _, hf => absurd hf (by have := sizeObj_pos l; omega)
  | [], f + 1, m, rest, _, hr, _ => by
    simp [encEntries, pEntries, isEntryLine_ends hr]
  | (k, v) :: es, f + 1, m, rest, hw, hr, hf => by
    have hw' : v.WF ∧ Json.WFObj es := hw
    have hs : 2 * (v.size + Json.sizeObj es + 1) ≤ f + 1 := by simpa [Json.sizeObj] using hf
    have hes := sizeObj_pos es
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    have hvb := pValBody_enc v g m (encEntries m es ++ rest) hw'.1
      (entries_ends m es rest hr) (by omega)
    have hent := pEntry_enc g m k v _ hvb
    have hen := pEntries_enc es (g + 1) m rest hw'.2 hr (by omega)
    have h : encEntries m ((k, v) :: es) ++ rest =
        spaces m ++ printKey k ++ ':' :: (valBody m v ++ (encEntries m es ++ rest)) := by
      simp [encEntries]
    rw [h, pEntries, ite_eq_left (isEntryLine_key _ _ _), List.append_assoc, drop_spaces, hent]
    simp only [hen, Option.map_some]
end

/-! ### Whole documents -/

mutual
theorem size_le_valBody (m : Nat) : ∀ v : Json, v.size ≤ 2 * (valBody m v).length
  | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] => by
    simp only [Json.size, Json.sizeList, Json.sizeObj, valBody, List.length_cons,
      List.length_append]
    omega
  | .arr (w :: ws) => by
    have := sizeList_le (m + 2) (w :: ws)
    simp only [Json.size, valBody, List.length_cons] at this ⊢
    omega
  | .obj (e :: es) => by
    have := sizeObj_le (m + 2) (e :: es)
    simp only [Json.size, valBody, List.length_cons] at this ⊢
    omega

theorem size_le_itemBody (m : Nat) : ∀ v : Json, v.size ≤ 2 * (itemBody m v).length
  | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] => by
    simp only [Json.size, Json.sizeList, Json.sizeObj, itemBody, List.length_cons,
      List.length_append]
    omega
  | .arr (w :: ws) => by
    have := sizeList_le (m + 2) (w :: ws)
    simp only [Json.size, itemBody, List.length_cons] at this ⊢
    omega
  | .obj ((k, w) :: es) => by
    have h1 := size_le_valBody (m + 2) w
    have h2 := sizeObj_le (m + 2) es
    simp only [Json.size, Json.sizeObj, itemBody, List.length_cons, List.length_append] at h2 ⊢
    omega

theorem sizeList_le (m : Nat) : ∀ l : List Json, Json.sizeList l ≤ 2 * (encItems m l).length + 1
  | [] => by simp [Json.sizeList]
  | v :: vs => by
    have h1 := size_le_itemBody m v
    have h2 := sizeList_le m vs
    simp only [Json.sizeList, encItems, List.length_cons, List.length_append] at h2 ⊢
    omega

theorem sizeObj_le (m : Nat) : ∀ l : List (String × Json),
    Json.sizeObj l ≤ 2 * (encEntries m l).length + 1
  | [] => by simp [Json.sizeObj]
  | (k, v) :: es => by
    have h1 := size_le_valBody m v
    have h2 := sizeObj_le m es
    simp only [Json.sizeObj, encEntries, List.length_cons, List.length_append] at h2 ⊢
    omega
end

theorem size_le_encode (v : Json) : v.size ≤ 2 * (encode v).length + 2 := by
  match v with
  | .null | .bool _ | .num _ | .str _ | .arr [] | .obj [] =>
    simp only [Json.size, Json.sizeList, Json.sizeObj]
    omega
  | .arr (w :: ws) =>
    have := sizeList_le 0 (w :: ws)
    simp only [Json.size, encode] at this ⊢
    omega
  | .obj (e :: es) =>
    have := sizeObj_le 0 (e :: es)
    simp only [Json.size, encode] at this ⊢
    omega

/-- The array test of `pTop`. -/
def topIsArray (input : List Char) : Bool :=
  isItemLine 0 input && (match input with
      | _ :: d :: _ => d == ' ' || d == '\n'
      | _ => false)

theorem pTop_eq (f : Nat) (input : List Char) :
    pTop f input = if topIsArray input then (pItems f 0 input).map fun p => (.arr p.1, p.2)
      else match pEntry f 0 input with
        | some (e, r) => (pEntries f 0 r).map fun p => (.obj (e :: p.1), p.2)
        | none => pScalarLine input := rfl

theorem topIsArray_scalar (v : Json) (hi : isInl v = true) (hv : v.WF) (rest : List Char) :
    topIsArray (inline v ++ '\n' :: rest) = false := by
  match v with
  | .null | .bool true | .bool false | .str _ | .arr [] | .obj [] =>
    simp [topIsArray, isItemLine, dropSp, inline, quote]
  | .num n =>
    obtain ⟨c, t, h, hc⟩ := Number.print_head n hv
    by_cases hm : c = '-'
    · subst hm
      obtain ⟨d, t', hd, ht⟩ := Number.print_neg_head n hv t h
      have : (Number.digitChar d == ' ' || Number.digitChar d == '\n') = false :=
        (by decide : ∀ d : Fin 10, (Number.digitChar d.val == ' ' ||
          Number.digitChar d.val == '\n') = false) ⟨d, hd⟩
      simp [topIsArray, inline, h, ht, this]
    · simp [topIsArray, isItemLine, dropSp, inline, h, hm]

theorem pTop_scalar (f : Nat) (v : Json) (hi : isInl v = true) (hv : v.WF) :
    pTop f (inline v ++ ['\n']) = some (v, []) := by
  rw [pTop_eq, topIsArray_scalar v hi hv [], pEntry_inline f 0 v hi hv []]
  exact pScalarLine_inline v hi hv []

/-- **The YAML round trip.** Reading the canonical YAML spelling of a well-formed value
gives the value back. -/
theorem decode_encode (v : Json) (hv : v.WF) : decode (encode v) = some v := by
  have hlen := size_le_encode v
  suffices h : pTop (4 * (encode v).length + 4) (encode v) = some (v, []) by
    unfold decode; rw [h]
  generalize hF : 4 * (encode v).length + 4 = F
  have hf : 2 * v.size ≤ F := by omega
  clear hF hlen
  match v with
  | .null => exact pTop_scalar _ .null rfl hv
  | .bool b => exact pTop_scalar _ (.bool b) rfl hv
  | .num n => exact pTop_scalar _ (.num n) rfl hv
  | .str s => exact pTop_scalar _ (.str s) rfl hv
  | .arr [] => exact pTop_scalar _ (.arr []) rfl hv
  | .obj [] => exact pTop_scalar _ (.obj []) rfl hv
  | .arr (w :: ws) =>
    obtain ⟨c, t, hct, hc⟩ := itemBody_head 0 w
    have h : encode (.arr (w :: ws)) = '-' :: c :: (t ++ encItems 0 ws) := by
      simp [encode, encItems, spaces, hct]
    have harr : topIsArray (encode (.arr (w :: ws))) = true := by
      rw [h]
      rcases hc with rfl | rfl <;> simp [topIsArray, isItemLine, dropSp]
    have hit := pItems_enc (w :: ws) F 0 [] hv (Ends.nil 0)
      (by simp only [Json.size] at hf; omega)
    rw [List.append_nil] at hit
    rw [pTop_eq, harr, ite_eq_left rfl]
    simp only [encode] at hit ⊢
    rw [hit]
    rfl
  | .obj ((k, w) :: es) =>
    have hw : w.WF ∧ Json.WFObj es := hv.2
    have hs : 2 * (w.size + Json.sizeObj es + 1 + 1) ≤ F := by
      simpa [Json.size, Json.sizeObj] using hf
    have hes := sizeObj_pos es
    have h : encode (.obj ((k, w) :: es)) =
        spaces 0 ++ printKey k ++ ':' :: (valBody 0 w ++ (encEntries 0 es ++ [])) := by
      simp [encode, encEntries]
    have hno : topIsArray (encode (.obj ((k, w) :: es))) = false := by
      rw [h]; unfold topIsArray; rw [isItemLine_key]; rfl
    obtain ⟨g, rfl⟩ : ∃ g, F = g + 1 := ⟨F - 1, by omega⟩
    have hvb := pValBody_enc w g 0 (encEntries 0 es ++ []) hw.1
      (entries_ends 0 es [] (Ends.nil 0)) (by omega)
    have hent := pEntry_enc g 0 k w _ hvb
    have hen := pEntries_enc es (g + 1) 0 [] hw.2 (Ends.nil 0) (by omega)
    rw [pTop_eq, hno, ite_eq_right (by decide)]
    rw [h, show spaces 0 ++ printKey k = printKey k from rfl, hent]
    simp only [hen, Option.map_some]

end Esm.Document.Yaml
