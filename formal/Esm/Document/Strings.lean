import Esm.Document.Number

/-!
# Lexical pieces shared by the YAML and Typst codecs

* Double-quoted strings with JSON-style escapes: `\"`, `\\`, `\n`, `\t`, `\r`, and a
  four-digit hex escape for the other characters a reader might not take literally
  (`needsHex`). YAML writes the hex escape `\uXXXX`, Typst `\u{XXXX}`; everything
  else is literal. `parseQuoted_quote` is the round trip, for both spellings at once.
* Bare identifiers `[A-Za-z_][A-Za-z0-9_]*` (keys) and the reader of a maximal run
  of identifier characters.
* Runs of spaces (indentation).
* Object keys, bare or quoted, with the codec's reserved words (which a reader would
  not take as a key string) always quoted, and never accepted bare.
  `parseKey_printKey` is the round trip.
* What a number or a key never starts with, which the codecs' readers use to tell
  them apart from other tokens.
-/

namespace Esm.Document.Strings

/-! ## Hex escapes -/

/-- A lowercase hex digit. -/
def hexChar (d : Nat) : Char := if d < 10 then Char.ofNat (48 + d) else Char.ofNat (87 + d)

/-- The value of a hex digit (either case). -/
def hexVal (c : Char) : Option Nat :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - 48)
  else if 'a' ≤ c ∧ c ≤ 'f' then some (c.toNat - 87)
  else if 'A' ≤ c ∧ c ≤ 'F' then some (c.toNat - 55)
  else none

theorem hexVal_hexChar_fin : ∀ d : Fin 16, hexVal (hexChar d.val) = some d.val := by
  decide +kernel

theorem hexVal_hexChar {d : Nat} (h : d < 16) : hexVal (hexChar d) = some d :=
  hexVal_hexChar_fin ⟨d, h⟩

/-- Four hex digits, most significant first. -/
def hex4 (n : Nat) : List Char :=
  [hexChar (n / 4096 % 16), hexChar (n / 256 % 16), hexChar (n / 16 % 16), hexChar (n % 16)]

/-- The value of four hex digits. -/
def hex4Val (a b c d : Char) : Option Nat := do
  let a ← hexVal a
  let b ← hexVal b
  let c ← hexVal c
  let d ← hexVal d
  return a * 4096 + b * 256 + c * 16 + d

theorem hex4Val_hex4 (n : Nat) (h : n < 65536) :
    hex4Val (hexChar (n / 4096 % 16)) (hexChar (n / 256 % 16)) (hexChar (n / 16 % 16))
      (hexChar (n % 16)) = some n := by
  simp only [hex4Val, hexVal_hexChar (Nat.mod_lt _ (by decide : 16 > 0)), Option.bind_eq_bind,
    Option.bind_some, Option.pure_def]
  congr 1; omega

/-- Characters written as a hex escape: the C0 controls, DEL, the C1 controls, the
Unicode line and paragraph separators, the byte-order mark, and the two BMP
noncharacters `U+FFFE`, `U+FFFF`. (YAML does not allow the controls literally, and
YAML 1.1 readers treat `U+0085`, `U+2028`, `U+2029` as line breaks.) -/
def needsHex (c : Char) : Bool :=
  let n := c.toNat
  n < 0x20 || n == 0x7F || (0x80 ≤ n && n ≤ 0x9F) || n == 0x2028 || n == 0x2029 ||
    n == 0xFEFF || n == 0xFFFE || n == 0xFFFF

theorem needsHex_lt {c : Char} (h : needsHex c = true) : c.toNat < 65536 := by
  simp only [needsHex, Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq, Bool.and_eq_true] at h
  omega

/-! ## Quoted strings -/

/-- The escape of one character. `braces` selects Typst's `\u{XXXX}` over YAML's
`\uXXXX`. -/
def escChar (braces : Bool) (c : Char) : List Char :=
  if c = '"' then ['\\', '"']
  else if c = '\\' then ['\\', '\\']
  else if c = '\n' then ['\\', 'n']
  else if c = '\t' then ['\\', 't']
  else if c = '\r' then ['\\', 'r']
  else if needsHex c then
    '\\' :: 'u' :: (if braces then '{' :: hex4 c.toNat ++ ['}'] else hex4 c.toNat)
  else [c]

/-- The escaped characters of a string, without the quotes. -/
def escape (braces : Bool) (cs : List Char) : List Char := cs.flatMap (escChar braces)

/-- A double-quoted string literal. -/
def quote (braces : Bool) (s : String) : List Char := '"' :: escape braces s.toList ++ ['"']

/-- The body of a quoted string after the opening quote: the characters up to the
closing quote, and what follows it. -/
def unquoteBody (braces : Bool) : List Char → Option (List Char × List Char)
  | [] => none
  | '"' :: r => some ([], r)
  | '\\' :: '"' :: r => (unquoteBody braces r).map fun p => ('"' :: p.1, p.2)
  | '\\' :: '\\' :: r => (unquoteBody braces r).map fun p => ('\\' :: p.1, p.2)
  | '\\' :: 'n' :: r => (unquoteBody braces r).map fun p => ('\n' :: p.1, p.2)
  | '\\' :: 't' :: r => (unquoteBody braces r).map fun p => ('\t' :: p.1, p.2)
  | '\\' :: 'r' :: r => (unquoteBody braces r).map fun p => ('\r' :: p.1, p.2)
  | '\\' :: 'u' :: '{' :: a :: b :: c :: d :: '}' :: r =>
    if braces then
      (hex4Val a b c d).bind fun n =>
        (unquoteBody braces r).map fun p => (Char.ofNat n :: p.1, p.2)
    else none
  | '\\' :: 'u' :: a :: b :: c :: d :: r =>
    if braces then none
    else
      (hex4Val a b c d).bind fun n =>
        (unquoteBody braces r).map fun p => (Char.ofNat n :: p.1, p.2)
  | '\\' :: _ => none
  | c :: r => (unquoteBody braces r).map fun p => (c :: p.1, p.2)

/-- A quoted string literal. -/
def parseQuoted (braces : Bool) : List Char → Option (String × List Char)
  | '"' :: r => (unquoteBody braces r).map fun p => (String.ofList p.1, p.2)
  | _ => none

theorem unquoteBody_escChar (braces : Bool) (c : Char) (r : List Char) :
    unquoteBody braces (escChar braces c ++ r) =
      (unquoteBody braces r).map fun p => (c :: p.1, p.2) := by
  unfold escChar
  by_cases h1 : c = '"'
  · subst h1; rfl
  by_cases h2 : c = '\\'
  · subst h2; rfl
  by_cases h3 : c = '\n'
  · subst h3; rfl
  by_cases h4 : c = '\t'
  · subst h4; rfl
  by_cases h5 : c = '\r'
  · subst h5; rfl
  simp only [h1, h2, h3, h4, h5, ite_false]
  by_cases h6 : needsHex c = true
  · simp only [h6, ite_true]
    have hlt := needsHex_lt h6
    cases braces
    · simp only [hex4, Bool.false_eq_true, ite_false, List.cons_append, List.nil_append]
      rw [unquoteBody]
      · simp only [Bool.false_eq_true, ite_false, hex4Val_hex4 _ hlt, Option.bind_some,
          Char.ofNat_toNat]
      · -- the first digit is a hex digit, never `{`
        intro _ _ h _
        have := hexVal_hexChar (Nat.mod_lt (c.toNat / 4096) (by decide : 16 > 0))
        rw [h] at this; simp [hexVal] at this
    · simp only [hex4, ite_true, List.cons_append, List.nil_append]
      rw [unquoteBody]
      simp only [ite_true, hex4Val_hex4 _ hlt, Option.bind_some, Char.ofNat_toNat]
  · simp only [h6, Bool.false_eq_true, ite_false, List.cons_append, List.nil_append]
    have h7 : c ≠ '"' := h1
    have h8 : c ≠ '\\' := h2
    rw [unquoteBody] <;> simp_all

theorem unquoteBody_escape (braces : Bool) (cs rest : List Char) :
    unquoteBody braces (escape braces cs ++ '"' :: rest) = some (cs, rest) := by
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    simp only [escape, List.flatMap_cons, List.append_assoc] at ih ⊢
    rw [unquoteBody_escChar, ih]
    rfl

/-- The string round trip, for both escape spellings: reading a quoted literal gives
the string back, whatever follows it. -/
theorem parseQuoted_quote (braces : Bool) (s : String) (rest : List Char) :
    parseQuoted braces (quote braces s ++ rest) = some (s, rest) := by
  simp only [quote, List.cons_append, List.append_assoc, List.nil_append, parseQuoted,
    unquoteBody_escape, Option.map_some, String.ofList_toList]

/-! ## Identifiers and spaces -/

def isIdentStart (c : Char) : Bool := c.isAlpha || c == '_'

def isIdentChar (c : Char) : Bool := c.isAlphanum || c == '_'

/-- `[A-Za-z_][A-Za-z0-9_]*`. -/
def isIdent (cs : List Char) : Bool :=
  match cs with
  | [] => false
  | c :: r => isIdentStart c && r.all isIdentChar

/-- The maximal run of identifier characters at the front. -/
def readIdent : List Char → List Char × List Char
  | [] => ([], [])
  | c :: r =>
    if isIdentChar c then
      let p := readIdent r
      (c :: p.1, p.2)
    else ([], c :: r)

theorem readIdent_append (cs rest : List Char) (hc : cs.all isIdentChar = true)
    (hr : ∀ c ∈ rest.head?, isIdentChar c = false) : readIdent (cs ++ rest) = (cs, rest) := by
  induction cs with
  | nil =>
    cases rest with
    | nil => rfl
    | cons c r => simp [readIdent, hr c rfl]
  | cons c cs ih =>
    simp only [List.all_cons, Bool.and_eq_true] at hc
    simp [readIdent, hc.1, ih hc.2]

theorem isIdent_all {cs : List Char} (h : isIdent cs = true) : cs.all isIdentChar = true := by
  cases cs with
  | nil => simp [isIdent] at h
  | cons c r =>
    simp only [isIdent, Bool.and_eq_true] at h
    simp only [List.all_cons, h.2, Bool.and_true]
    have := h.1
    simp only [isIdentStart, isIdentChar, Bool.or_eq_true, beq_iff_eq] at this ⊢
    rcases this with h' | h'
    · left; simp [Char.isAlphanum, h']
    · right; exact h'

/-- `n` spaces. -/
def spaces (n : Nat) : List Char := List.replicate n ' '

/-! ## Keys -/

/-- A key prints bare when it is an identifier and not one of the codec's `reserved`
words. -/
def bareKey (reserved : String → Bool) (k : String) : Bool := isIdent k.toList && !reserved k

/-- A key: bare when it can be, otherwise quoted (`braces` as in `quote`). -/
def printKey (braces : Bool) (reserved : String → Bool) (k : String) : List Char :=
  if bareKey reserved k then k.toList else quote braces k

/-- A key: quoted, or an identifier that is not a reserved word. -/
def parseKey (braces : Bool) (reserved : String → Bool) : List Char → Option (String × List Char)
  | [] => none
  | c :: r =>
    if c = '"' then parseQuoted braces (c :: r)
    else if isIdentStart c then
      let p := readIdent (c :: r)
      if reserved (String.ofList p.1) then none else some (String.ofList p.1, p.2)
    else none

theorem printKey_head (braces : Bool) (reserved : String → Bool) (k : String) :
    ∃ c t, printKey braces reserved k = c :: t ∧ (c = '"' ∨ isIdentStart c = true) := by
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

theorem parseKey_quote (braces : Bool) (reserved : String → Bool) (k : String)
    (rest : List Char) : parseKey braces reserved (quote braces k ++ rest) = some (k, rest) := by
  have h : quote braces k ++ rest = '"' :: (escape braces k.toList ++ ['"'] ++ rest) := by
    simp [quote]
  rw [h]
  simp only [parseKey, ite_true]
  rw [← h, parseQuoted_quote]

/-- A printed key reads back, when what follows is not an identifier character. -/
theorem parseKey_printKey (braces : Bool) (reserved : String → Bool) (k : String)
    (rest : List Char) (hr : ∀ c ∈ rest.head?, isIdentChar c = false) :
    parseKey braces reserved (printKey braces reserved k ++ rest) = some (k, rest) := by
  unfold printKey
  split
  · rename_i h
    simp only [bareKey, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true] at h
    have hid := h.1
    have hall := isIdent_all hid
    cases hk : k.toList with
    | nil => rw [hk] at hid; simp [isIdent] at hid
    | cons c t =>
      rw [hk] at hid hall
      simp only [isIdent, Bool.and_eq_true] at hid
      have hc : c ≠ '"' := by intro e; rw [e] at hid; exact absurd hid.1 (by decide)
      have hread : readIdent (c :: (t ++ rest)) = (c :: t, rest) := by
        rw [← List.cons_append]; exact readIdent_append _ _ hall hr
      have hkey : String.ofList (c :: t) = k := by rw [← hk, String.ofList_toList]
      simp only [List.cons_append, parseKey, hc, ite_false, hid.1, ite_true, hread, hkey, h.2,
        Bool.false_eq_true]
  · exact parseKey_quote braces reserved k rest

/-- Characters a printed key never starts with. -/
def nonKeyHeads : List Char := [')', ':', '-', '?', ' ', '\n', '\t', '\r']

/-- A key starts with `"` or an identifier start, so not with any of `nonKeyHeads`. -/
theorem keyHead_ne {c : Char} (h : c = '"' ∨ isIdentStart c = true) (x : Char)
    (hx : x ∈ nonKeyHeads := by decide) : c ≠ x := by
  rcases h with rfl | h
  · revert hx; revert x; decide
  · rintro rfl
    have : ∀ y ∈ nonKeyHeads, isIdentStart y = false := by decide
    rw [this c hx] at h
    exact Bool.noConfusion h

/-! ## Number heads -/

/-- Characters a printed number never starts with. -/
def nonNumHeads : List Char :=
  ['(', ')', '"', 'n', 't', 'f', ':', '[', '{', '?', ' ', '\n', '\t', '\r']

theorem numHead_ne {c : Char} (h : Number.NumHead c) (x : Char)
    (hx : x ∈ nonNumHeads := by decide) : c ≠ x :=
  Number.NumHead.of_fin (P := fun c => ∀ x ∈ nonNumHeads, c ≠ x) (by decide) (by decide) h x hx

theorem numHead_ident {c : Char} (h : Number.NumHead c) : isIdentStart c = false :=
  Number.NumHead.of_fin (P := fun c => isIdentStart c = false) (by decide) (by decide) h

end Esm.Document.Strings
