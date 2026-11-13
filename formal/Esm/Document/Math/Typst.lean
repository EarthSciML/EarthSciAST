import Esm.Document.Math.Parse
import Esm.Document.Strings
import Esm.Document.TypstDict

/-!
# Typst math: spelling and lexing of tokens

`render` spells a token list as Typst math; `lex` reads it back. Typst has one
parenthesis: the printer uses the grouping token `lpg` for every `(`, and the
renderer writes no space between a function name and its `(` (Typst calls a function
only then) and a space between an operand and a following `(` (juxtaposition).

Spellings: numbers in the canonical spelling, scientific ones as
`1.8 times 10^(-12)` (read back as one literal); names as `italic("…")`, formulas and
name subscripts as runs of adjacent `upright("…")` pieces each with an optional digit
subscript (`upright("CH")_2upright("O")`; a space between two pieces separates two
names); the scope dot as `"."` (a bare `.` after a Greek name is a symbol modifier in
Typst); call-form operators `op("…")`; text `"…"`; JSON values of an escape node as
`#` and the Typst value (`Esm.Document.TypstDict`); a unit block
`thin upright("m") thin upright("s")^(-1)` after a number (`Esm.Units.Typeset`).

Accepted on input and never written: a bare `.` as the scope dot.
-/

namespace Esm.Document.Math.Typst

open Esm.Document Esm.Document.Math

/-! ## Spelling -/

def sciSplit : JNum → Option (List Char × Int)
  | .dec neg (d :: fp) e10 =>
    if e10 < -4 ∨ 5 < e10 then
      some ((if neg then ['-'] else []) ++ Number.digitChar d :: '.' :: (Number.fracDigits fp).map Number.digitChar, e10)
    else none
  | _ => none

def timesTen : List Char := " times 10^".toList

def numChars (n : JNum) : List Char :=
  match sciSplit n with
  | some (m, e) =>
    m ++ timesTen ++ (if e < 0 then '(' :: Number.printInt e ++ [')'] else Number.printInt e)
  | none => Number.print n

def kwChars : Kw → List Char
  | .plus => ['+'] | .minus => ['-'] | .eq => ['='] | .ne => ['!', '=']
  | .lt => ['<'] | .gt => ['>'] | .le => ['<', '='] | .ge => ['>', '=']
  | .land => "and".toList | .lor => "or".toList | .lnot => "not".toList
  | .cdot => "dot".toList | .times => "times".toList | .slash => ['/']
  | .caret => ['^'] | .us => ['_'] | .lp => ['('] | .lpg => ['('] | .rp => [')']
  | .lbk => ['['] | .rbk => [']'] | .comma => [','] | .semi => [';'] | .colon => [':']
  | .amp => ['&'] | .sdot => ['"', '.', '"']
  | .sqrt => "sqrt".toList | .exp => "exp".toList | .ln => "ln".toList | .log => "log".toList
  | .sin => "sin".toList | .cos => "cos".toList | .tan => "tan".toList
  | .asin => "arcsin".toList | .acos => "arccos".toList | .atan => "arctan".toList
  | .sinh => "sinh".toList | .cosh => "cosh".toList | .tanh => "tanh".toList
  | .min => "min".toList | .max => "max".toList | .abs => "abs".toList
  | .floor => "floor".toList | .ceil => "ceil".toList | .pdiff => "partial".toList
  | .dif => "dif".toList | .cases => "cases".toList | .esmnode => "esm.node".toList
  | .rpg | .lb | .rb | .nl | .thin | .frac | .labs | .rabs | .lfloor | .rfloor
  | .lceil | .rceil | .dotacc | .bcases | .ecases => []

def pieceChars (p : String × String) : List Char :=
  "upright(".toList ++ Strings.quote true p.1 ++ [')'] ++
    (if p.2 = "" then [] else '_' :: p.2.toList)

def unitChars (l : List Esm.Units.Factor) : List Char :=
  "thin ".toList ++ Esm.Units.joinWith Esm.Units.typstFactor Esm.Units.thinSep l

def tokChars : Tok → List Char
  | .num n => numChars n
  | .letter c => [c]
  | .greek g => g.toList
  | .word s => s.toList
  | .it s => "italic(".toList ++ Strings.quote true s ++ [')']
  | .ups ps => ps.flatMap pieceChars
  | .opn s => "op(".toList ++ Strings.quote true s ++ [')']
  | .txt s => Strings.quote true s
  | .code j => '#' :: TypstDict.encode j
  | .units l => unitChars l
  | .kw k => kwChars k
  | .rm _ | .jstr _ | .esc _ => []

/-! ## Spacing -/

def isIdC (c : Char) : Bool := isLetter c || isDig c

/-- A space is needed between `t` and a following token starting with `c`. -/
def merges (t : Tok) (c : Char) : Bool :=
  (match (tokChars t).getLast? with
   | some d => isLetter d && isIdC c
   | none => false) ||
  (t matches .num _) && (isIdC c || c == '.') ||
  (t matches .kw .minus) && isDig c ||
  (t matches .ups _) && (isDig c || c == 'u' || c == '_') ||
  (t matches .code _) && isIdC c ||
  (t matches .units _) && (isDig c || c == '^') ||
  ((t matches .kw .lt) || (t matches .kw .gt)) && c == '=' ||
  (t matches .kw .slash) && c == '/'

/-- `t` ends with a character after which `(` is a call parenthesis. -/
def callEnd (t : Tok) : Bool :=
  match (tokChars t).getLast? with
  | some d => isIdC d || d == ')' || d == '"'
  | none => false

def needSpace (t1 t2 : Tok) : Bool :=
  match t2 with
  | .kw .lpg => callEnd t1
  | .kw .lp => false
  | _ =>
    match (tokChars t2).head? with
    | some c => merges t1 c
    | none => false

def isBin : Tok → Bool
  | .kw k => match k with
    | .plus | .eq | .ne | .lt | .gt | .le | .ge | .land | .lor | .cdot | .times | .amp => true
    | _ => false
  | _ => false

def atomEnd : Tok → Bool
  | .num _ | .letter _ | .greek _ | .word _ | .it _ | .ups _ | .txt _ | .code _
  | .units _ => true
  | .kw k => match k with
    | .rp | .rbk => true
    | _ => false
  | _ => false

/-- Function names: no space before their `(`. -/
def isHead : Tok → Bool
  | .opn _ => true
  | .kw k => match k with
    | .sqrt | .exp | .ln | .log | .sin | .cos | .tan | .asin | .acos | .atan | .sinh | .cosh
    | .tanh | .min | .max | .abs | .floor | .ceil | .cases | .esmnode | .cdot => true
    | _ => false
  | _ => false

def pretty (p : Option Tok) (t1 t2 : Tok) : Bool :=
  isBin t1 || isBin t2 || (t1 matches .kw .comma) || (t1 matches .kw .colon) ||
  (t1 matches .kw .semi) ||
  ((t2 matches .kw .minus) && atomEnd t1) ||
  ((t1 matches .kw .minus) && (match p with | some q => atomEnd q | none => false)) ||
  (atomEnd t1 && atomStart t2) || ((t2 matches .units _))

def sp (p : Option Tok) (t1 t2 : Tok) : Bool :=
  needSpace t1 t2 || (pretty p t1 t2 && !(t2 matches .kw .lp))

def renderAux : Option Tok → List Tok → List Char
  | _, [] => []
  | _, [t] => tokChars t
  | p, t1 :: t2 :: r => tokChars t1 ++ (if sp p t1 t2 then [' '] else []) ++ renderAux (some t1) (t2 :: r)

def render (ts : List Tok) : List Char := renderAux none ts

/-! ## Lexing -/

def dropP : List Char → List Char → Option (List Char)
  | [], cs => some cs
  | p :: ps, c :: cs => if p = c then dropP ps cs else none
  | _ :: _, [] => none

/-- The maximal run of identifier characters. -/
def idRun : List Char → List Char × List Char
  | [] => ([], [])
  | c :: cs => if isIdC c then let p := idRun cs; (c :: p.1, p.2) else ([], c :: cs)

def identKw : List (String × Kw) :=
  [("and", .land), ("or", .lor), ("not", .lnot), ("dot", .cdot), ("times", .times),
    ("sqrt", .sqrt), ("exp", .exp), ("ln", .ln), ("log", .log), ("sin", .sin), ("cos", .cos),
    ("tan", .tan), ("arcsin", .asin), ("arccos", .acos), ("arctan", .atan), ("sinh", .sinh),
    ("cosh", .cosh), ("tanh", .tanh), ("min", .min), ("max", .max), ("abs", .abs),
    ("floor", .floor), ("ceil", .ceil), ("partial", .pdiff), ("dif", .dif), ("cases", .cases)]

/-- `("…")` after a function name. -/
def quotedArg (r : List Char) : Option (String × List Char) :=
  match r with
  | '(' :: r1 =>
    match Strings.parseQuoted true r1 with
    | some (s, ')' :: r2) => some (s, r2)
    | _ => none
  | _ => none

/-- Adjacent `upright("…")` pieces, each with an optional digit subscript. -/
def pieces : Nat → List Char → List (String × String) × List Char
  | 0, cs => ([], cs)
  | f + 1, cs =>
    match dropP "upright".toList cs with
    | some r =>
      match quotedArg r with
      | some (s, r1) =>
        let d : List Char × List Char :=
          match r1 with
          | '_' :: r2 => let q := digRun r2; if q.1 = [] then ([], r1) else q
          | _ => ([], r1)
        let rest := pieces f d.2
        ((s, String.ofList d.1) :: rest.1, rest.2)
      | none => ([], cs)
    | none => ([], cs)

/-- A number: the canonical spelling, or `mantissa times 10^exponent`. -/
def lexNum (cs : List Char) : Option (Tok × List Char) :=
  match Number.parse cs with
  | none => none
  | some (n, r) =>
    match dropP timesTen r with
    | some r2 =>
      let ez : Option (Int × List Char) :=
        match r2 with
        | '(' :: r3 =>
          match Number.parseInt r3 with
          | some (z, ')' :: r4) => some (z, r4)
          | _ => none
        | _ => Number.parseInt r2
      match ez with
      | some (z, r5) =>
        match Number.parse (cs.take (cs.length - r.length) ++ 'e' :: Number.printInt z) with
        | some (m, []) => some (.num m, r5)
        | _ => none
      | none => none
    | none => some (.num n, r)

def punct : Char → Option Kw
  | '+' => some .plus | '-' => some .minus | '=' => some .eq | '<' => some .lt
  | '>' => some .gt | '/' => some .slash | '^' => some .caret | '_' => some .us
  | ')' => some .rp | '[' => some .lbk | ']' => some .rbk
  | ',' => some .comma | ';' => some .semi | ':' => some .colon | '&' => some .amp
  | '.' => some .sdot
  | _ => none

/-- One identifier-started token. -/
def lexIdent (cs : List Char) : Option (Tok × List Char) :=
  let p := idRun cs
  let w := String.ofList p.1
  if w = "upright" then
    match pieces cs.length cs with
    | ([], _) => none
    | (ps, r) => some (.ups ps, r)
  else if w = "italic" then (quotedArg p.2).map fun q => (.it q.1, q.2)
  else if w = "op" then (quotedArg p.2).map fun q => (.opn q.1, q.2)
  else if w = "thin" then
    match p.2 with
    | ' ' :: r =>
      match Esm.Units.pSepBy Esm.Units.pTFactor Esm.Units.thinSep r.length r with
      | some (l, r') => some (.units l, r')
      | none => none
    | _ => none
  else if w = "esm" then (dropP ".node".toList p.2).map (.kw .esmnode, ·)
  else
    match identKw.lookup w with
    | some k => some (.kw k, p.2)
    | none =>
      if isGreek p.1 then some (.greek w, p.2)
      else match p.1 with
        | [c] => some (.letter c, p.2)
        | _ => some (.word w, p.2)

/-- One token at the front of the input; `prev` is the character just before it, if no
space came between (`(` right after a name, a digit, `)` or `"` is a call
parenthesis). -/
def lexOne (prev : Option Char) (cs : List Char) : Option (Tok × List Char) :=
  match cs with
  | '(' :: r =>
    match prev with
    | some d => if isIdC d || d == ')' || d == '"' then some (.kw .lp, r) else some (.kw .lpg, r)
    | none => some (.kw .lpg, r)
  | '"' :: _ =>
    (Strings.parseQuoted true cs).map fun p => (if p.1 = "." then .kw .sdot else .txt p.1, p.2)
  | '#' :: r =>
    (TypstDict.pVal (3 * (r.length + 1)) r).map fun p => (.code p.1, p.2)
  | '<' :: '=' :: r => some (.kw .le, r)
  | '>' :: '=' :: r => some (.kw .ge, r)
  | '!' :: '=' :: r => some (.kw .ne, r)
  | c :: r =>
    if isDig c || (c == '-' && (r.head?.map isDig).getD false) then lexNum cs
    else if isLetter c then lexIdent cs
    else (punct c).map (.kw ·, r)
  | [] => none

def isWsT (c : Char) : Bool := c = ' ' || c = '\n' || c = '\t' || c = '\r'

def lexAux : Nat → Option Char → List Char → Option (List Tok)
  | 0, _, _ => none
  | f + 1, prev, cs =>
    let cs' := cs.dropWhile isWsT
    let prev' := if cs'.length = cs.length then prev else none
    match cs' with
    | [] => some []
    | _ =>
      match lexOne prev' cs' with
      | some (t, r) => (lexAux f (cs'.take (cs'.length - r.length)).getLast? r).map (t :: ·)
      | none => none

/-- Read Typst math into tokens. -/
def lex (cs : List Char) : Option (List Tok) := lexAux (cs.length + 1) none cs

end Esm.Document.Math.Typst
