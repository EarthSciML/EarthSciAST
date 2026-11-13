import Esm.Document.Json

/-!
# Lexical pieces shared by the YAML and Typst codecs

* Double-quoted strings with JSON-style escapes: `\"`, `\\`, `\n`, `\t`, `\r`, and a
  four-digit hex escape for the other characters a reader might not take literally
  (`needsHex`). YAML writes the hex escape `\uXXXX`, Typst `\u{XXXX}`; everything
  else is literal. `parseQuoted_quote` is the round trip, for both spellings at once.
* Bare identifiers `[A-Za-z_][A-Za-z0-9_]*` (keys) and the reader of a maximal run
  of identifier characters.
* Runs of spaces (indentation).
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

end Esm.Document.Strings
