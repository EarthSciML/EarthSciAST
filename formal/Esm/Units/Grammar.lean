import Esm.Units.Registry

/-!
# The unit-string grammar (esm-spec §4.8.2)

A unit string is resolved in four steps, each a function here:

1. `normalize` — the mandatory Unicode rewrite, applied BEFORE parsing.
2. `lex` — tokens. A symbol is a maximal run of identifier characters
   (`[A-Za-z0-9_]`); a run of digits alone (optionally `digits.digits`) is a
   number; `%` is a one-character symbol; whitespace separates tokens and is
   otherwise dropped.
3. `parse` — the grammar, to a syntax tree `UExpr`:
   ```
   unit     := term (('*' | '/')? term)*
   term     := atom (('^' | '**') exponent)?
   exponent := integer | decimal | '(' integer '/' integer ')'
   atom     := '1' | symbol | '(' unit ')'
   ```
   `*`, `/` and juxtaposition are one precedence level, folded left to right.
   A numeric atom whose value is not 1 is a scaling factor and an error.
4. `UExpr.eval` — look each symbol up in the flat table and compose.

Readings chosen where §4.8.2 admits more than one are listed in the phase-1
report (the lexing of a run such as `s1`, a lone `%` inside a run, numeric atoms
spelled `1.0`, whitespace-only strings, whitespace inside a term).
-/

namespace Esm.Units

/-! ## Errors -/

inductive Err
  | unknownSymbol (s : String)
  | scalingFactor (lit : String)
  | badChar (c : Char)
  | syntax (msg : String)
  | fuel
  deriving DecidableEq, Repr

/-- The two phrases §4.8.2 requires in the scaling-factor diagnostic. -/
def scalingFactorText : String := "scaling factor"
def rationalExponentText : String := "^(p/q)"

def Err.message : Err → String
  | .unknownSymbol s => s!"unknown unit symbol '{s}': not a key of the §4.8.1 registry"
  | .scalingFactor n =>
    "the number " ++ n ++ " is a " ++ scalingFactorText ++
    ", not a unit: the only numeric atom a unit string admits is 1, and a rational exponent " ++
    "is spelled " ++ rationalExponentText
  | .badChar c => s!"unexpected character '{c}' in a unit string"
  | .syntax m => m
  | .fuel => "internal: parser fuel exhausted"

/-! ## Unicode normalisation -/

/-- The ASCII digit of a superscript digit. -/
def supDigit (c : Char) : Option Char :=
  if c = '\u2070' then some '0' else if c = '\u00B9' then some '1'
  else if c = '\u00B2' then some '2' else if c = '\u00B3' then some '3'
  else if c = '\u2074' then some '4' else if c = '\u2075' then some '5'
  else if c = '\u2076' then some '6' else if c = '\u2077' then some '7'
  else if c = '\u2078' then some '8' else if c = '\u2079' then some '9' else none

def isSup (c : Char) : Bool := (supDigit c).isSome

/-- The leading run of superscript digits, transliterated, and the rest. -/
def supRun (cs : List Char) : List Char × List Char :=
  let (run, rest) := cs.span isSup
  (run.filterMap supDigit, rest)

/-- The §4.8.2 rewrite table, applied left to right. -/
def normalizeAux : Nat → List Char → List Char
  | 0, cs => cs
  | _ + 1, [] => []
  | n + 1, c :: cs =>
    if c = '\u00B0' ∧ cs.head? = some 'C' then 'd' :: 'e' :: 'g' :: 'C' :: normalizeAux n cs.tail
    else if c = '\u00B0' ∧ cs.head? = some 'F' then 'd' :: 'e' :: 'g' :: 'F' :: normalizeAux n cs.tail
    else if c = '\u00B7' ∨ c = '\u22C5' then '*' :: normalizeAux n cs
    else if c = '\u00B5' ∨ c = '\u03BC' then 'u' :: normalizeAux n cs
    else if c = '\u2126' ∨ c = '\u03A9' then 'O' :: 'h' :: 'm' :: normalizeAux n cs
    else if c = '\u207B' ∧ (cs.head?.map isSup) = some true then
      let (ds, rest) := supRun cs
      '^' :: '-' :: ds ++ normalizeAux n rest
    else if isSup c then
      let (ds, rest) := supRun (c :: cs)
      '^' :: ds ++ normalizeAux n rest
    else c :: normalizeAux n cs

def normalize (cs : List Char) : List Char := normalizeAux cs.length cs

/-! ## Tokens -/

inductive Tok
  | sym (s : String)
  /-- A numeric literal: its spelling, its exact value, whether it is an integer. -/
  | num (lit : String) (v : ℚ) (isInt : Bool)
  | star | dstar | slash | caret | lp | rp | minus
  deriving DecidableEq, Repr

def isDigitC (c : Char) : Bool := '0' ≤ c && c ≤ '9'
def isAlphaC (c : Char) : Bool := ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z')
/-- Characters that may occur in a symbol run. -/
def isIdent (c : Char) : Bool := isAlphaC c || isDigitC c || c = '_'
def isSpace (c : Char) : Bool := c = ' ' || c = '\t' || c = '\n' || c = '\r'

def digitsVal (ds : List Char) : ℕ := ds.foldl (fun a d => 10 * a + (d.toNat - '0'.toNat)) 0

def lexAux : Nat → List Char → Except Err (List Tok)
  | 0, _ => .error .fuel
  | _ + 1, [] => .ok []
  | n + 1, c :: cs =>
    if isSpace c then lexAux n cs
    else if c = '*' then
      match cs with
      | '*' :: cs' => (Tok.dstar :: ·) <$> lexAux n cs'
      | _ => (Tok.star :: ·) <$> lexAux n cs
    else if c = '/' then (Tok.slash :: ·) <$> lexAux n cs
    else if c = '^' then (Tok.caret :: ·) <$> lexAux n cs
    else if c = '(' then (Tok.lp :: ·) <$> lexAux n cs
    else if c = ')' then (Tok.rp :: ·) <$> lexAux n cs
    else if c = '-' then (Tok.minus :: ·) <$> lexAux n cs
    else if c = '%' then (Tok.sym "%" :: ·) <$> lexAux n cs
    else if isIdent c then
      let (run, rest) := (c :: cs).span isIdent
      if run.all isDigitC then
        match rest with
        | '.' :: d :: rest' =>
          if isDigitC d then
            let (fr, rest'') := (d :: rest').span isIdent
            let lit := String.ofList (run ++ '.' :: fr)
            if fr.all isDigitC then
              (Tok.num lit ((digitsVal run : ℚ) + (digitsVal fr : ℚ) / 10 ^ fr.length) false :: ·)
                <$> lexAux n rest''
            else (Tok.sym lit :: ·) <$> lexAux n rest''
          else (Tok.num (String.ofList run) (digitsVal run) true :: ·) <$> lexAux n rest
        | _ => (Tok.num (String.ofList run) (digitsVal run) true :: ·) <$> lexAux n rest
      else (Tok.sym (String.ofList run) :: ·) <$> lexAux n rest
    else .error (.badChar c)

def lex (cs : List Char) : Except Err (List Tok) := lexAux (cs.length + 1) cs

/-! ## Syntax trees and the parser -/

inductive UExpr
  | one
  | sym (s : String)
  | mul (a b : UExpr)
  | div (a b : UExpr)
  | pow (a : UExpr) (q : ℚ)
  deriving DecidableEq, Repr

/-- `'-'? integer`. -/
def pInt : List Tok → Option (ℚ × List Tok)
  | .minus :: .num _ v true :: ts => some (-v, ts)
  | .num _ v true :: ts => some (v, ts)
  | _ => none

/-- `exponent := integer | decimal | '(' integer '/' integer ')'` (signs allowed). -/
def pExp : List Tok → Except Err (ℚ × List Tok)
  | .minus :: .num _ v _ :: ts => .ok (-v, ts)
  | .num _ v _ :: ts => .ok (v, ts)
  | .lp :: ts =>
    match pInt ts with
    | some (p, .slash :: ts') =>
      match pInt ts' with
      | some (q, .rp :: ts'') =>
        if q = 0 then .error (.syntax "zero denominator in a rational exponent")
        else .ok (p / q, ts'')
      | _ => .error (.syntax "a rational exponent is spelled ^(p/q) with integers p and q")
    | _ => .error (.syntax "a rational exponent is spelled ^(p/q) with integers p and q")
  | _ => .error (.syntax "expected an exponent after '^'")

/-- Does the token list begin a term (an atom)? -/
def startsTerm : List Tok → Bool
  | .num .. :: _ | .sym _ :: _ | .lp :: _ => true
  | _ => false

mutual
def pAtom : Nat → List Tok → Except Err (UExpr × List Tok)
  | 0, _ => .error .fuel
  | _ + 1, .num lit v _ :: ts => if lit = "1" then .ok (.one, ts) else .error (.scalingFactor lit)
  | _ + 1, .sym s :: ts => .ok (.sym s, ts)
  | n + 1, .lp :: ts =>
    match pUnit n ts with
    | .ok (e, .rp :: ts') => .ok (e, ts')
    | .ok _ => .error (.syntax "missing ')'")
    | .error err => .error err
  | _ + 1, _ => .error (.syntax "expected a unit symbol, 1, or '('")

def pTerm : Nat → List Tok → Except Err (UExpr × List Tok)
  | 0, _ => .error .fuel
  | n + 1, ts =>
    match pAtom n ts with
    | .ok (a, .caret :: ts') | .ok (a, .dstar :: ts') =>
      match pExp ts' with
      | .ok (q, ts'') => .ok (.pow a q, ts'')
      | .error err => .error err
    | r => r

/-- The left fold `acc (op term)*`. -/
def pTail : Nat → UExpr → List Tok → Except Err (UExpr × List Tok)
  | 0, _, _ => .error .fuel
  | n + 1, acc, .star :: ts =>
    match pTerm n ts with
    | .ok (b, ts') => pTail n (.mul acc b) ts'
    | .error err => .error err
  | n + 1, acc, .slash :: ts =>
    match pTerm n ts with
    | .ok (b, ts') => pTail n (.div acc b) ts'
    | .error err => .error err
  | _ + 1, _, .minus :: _ =>
    .error (.syntax "'-' is not an operator in a unit string (a negative exponent is ^-n)")
  | n + 1, acc, ts =>
    if startsTerm ts then
      match pTerm n ts with
      | .ok (b, ts') => pTail n (.mul acc b) ts'
      | .error err => .error err
    else .ok (acc, ts)

def pUnit : Nat → List Tok → Except Err (UExpr × List Tok)
  | 0, _ => .error .fuel
  | n + 1, ts =>
    match pTerm n ts with
    | .ok (a, ts') => pTail n a ts'
    | .error err => .error err
end

/-- Parse a whole token list. -/
def parse (ts : List Tok) : Except Err UExpr :=
  match pUnit (4 * ts.length + 8) ts with
  | .ok (e, []) => .ok e
  | .ok (_, .minus :: _) =>
    .error (.syntax "'-' is not an operator in a unit string (a negative exponent is ^-n)")
  | .ok (_, _) => .error (.syntax "unexpected token in a unit string")
  | .error err => .error err

/-! ## Evaluation and resolution -/

def UExpr.eval : UExpr → Except Err U
  | .one => .ok U.one
  | .sym s =>
    match lookup s with
    | some u => .ok u
    | none => .error (.unknownSymbol s)
  | .mul a b => do return U.mul (← a.eval) (← b.eval)
  | .div a b => do return U.div (← a.eval) (← b.eval)
  | .pow a q => do return U.rpow (← a.eval) q

/-- Resolve a unit string given as characters. The empty string is the
dimensionless key `""`. -/
def resolveChars (cs : List Char) : Except Err U :=
  if cs = [] then .ok (sym "")
  else do
    let ts ← lex (normalize cs)
    let e ← parse ts
    e.eval

/-- Resolve a unit string (§4.8.1 table + §4.8.2 grammar). -/
def resolve (s : String) : Except Err U := resolveChars s.toList

/-- Does the string resolve? -/
def Resolves (s : String) : Prop := ∃ u, resolve s = .ok u

end Esm.Units
