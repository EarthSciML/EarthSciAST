import Esm.Document.Math.Parse
import Esm.Document.Math.Surface
import Esm.Document.Strings

/-!
# LaTeX math: spelling and lexing of tokens

`render` spells a token list as LaTeX math; `lex` reads it back. Between two tokens
the renderer writes a space where the reader needs one (`needSpace`: a control word
or a letter before a letter, a number before a digit, `.` or `e`, a `-` before a
digit) and where it reads better (around binary operators, after commas, between
juxtaposed factors); the reader skips spaces. `lex_render` is the lexer lemma:
every token list whose tokens are LaTeX tokens (`tokOK`) reads back.

Spellings: numbers in the canonical spelling, scientific ones as
`1.8 \times 10^{-12}` (read back as one literal, with any spacing: `1.8\times10^{-12}`
too; `Esm.Document.Math.Surface`); a quantity's unit as `\,\mathrm{…}` right after the
number, one token; `\mathit{…}`, `\operatorname{…}` and
`\esm{…}` hold their text with `\`, `{`, `}`, `_`, `^` escaped by a backslash;
`\mathrm{…}` and `\text{…}` hold raw balanced text; a JSON string (inside an escape
node's fields) is double-quoted with JSON escapes, `_` written `\_`, and `%`, `$`, `#`, `{`, `}`
written `\uXXXX` so the text is safe inside a LaTeX argument and a Markdown math span.

Accepted on input and never written: `\leq`, `\geq`, `\neq`, `\times`, `\bigl(`,
`\bigr)`, the spacing commands `\;`, `\:`, `\!`, `\ `, `\quad`, `\qquad` and `\,` (skipped
like spaces; `\,` is the unit separator only right before a `\mathrm{…}` that spells a
unit), and JSON numbers with an `e` exponent.
-/

namespace Esm.Document.Math.Latex

open Esm.Document Esm.Document.Math

/-! ## Spelling -/

/-- Characters of a JSON string written as a hex escape in LaTeX. -/
def specials : List Char := ['%', '$', '#', '{', '}']

/-- The JSON escape of one character, with the specials as hex escapes. -/
def escCharB (c : Char) : List Char :=
  if specials.contains c then '\\' :: 'u' :: Strings.hex4 c.toNat else Strings.escChar false c

/-- The LaTeX spelling of one character of a JSON string: `_` as `\_` (so a renderer
that typesets the string does not read a subscript), otherwise `escCharB`. -/
def escCharL (c : Char) : List Char :=
  if c = '_' then ['\\', '_'] else escCharB c

/-- Undo the `\_` of `escCharL` up to the closing quote, leaving the other escapes and
everything after the quote alone. -/
def fixUs : List Char → List Char
  | '\\' :: '_' :: r => '_' :: fixUs r
  | '\\' :: c :: r => '\\' :: c :: fixUs r
  | '"' :: r => '"' :: r
  | c :: r => c :: fixUs r
  | [] => []

def quoteL (s : String) : List Char := '"' :: s.toList.flatMap escCharL ++ ['"']

def timesTen : List Char := " \\times 10^{".toList

def numChars (n : JNum) : List Char :=
  match sciSplit n with
  | some (m, e) => m ++ timesTen ++ Number.printInt e ++ ['}']
  | none => Number.print n

def kwChars : Kw → List Char
  | .plus => ['+'] | .minus => ['-'] | .eq => ['='] | .ne => "\\ne".toList
  | .lt => ['<'] | .gt => ['>'] | .le => "\\le".toList | .ge => "\\ge".toList
  | .land => "\\land".toList | .lor => "\\lor".toList | .lnot => "\\lnot".toList
  | .cdot => "\\cdot".toList | .times => "\\times".toList | .slash => ['/']
  | .caret => ['^'] | .us => ['_'] | .lp => ['('] | .rp => [')']
  | .lpg => "\\left(".toList | .rpg => "\\right)".toList | .lb => ['{'] | .rb => ['}']
  | .lbk => ['['] | .rbk => [']'] | .comma => [','] | .semi => [';'] | .colon => [':']
  | .amp => ['&'] | .nl => ['\\', '\\'] | .sdot => ['.']
  | .frac => "\\frac".toList | .sqrt => "\\sqrt".toList | .exp => "\\exp".toList
  | .ln => "\\ln".toList | .log => "\\log".toList | .sin => "\\sin".toList
  | .cos => "\\cos".toList | .tan => "\\tan".toList | .asin => "\\arcsin".toList
  | .acos => "\\arccos".toList | .atan => "\\arctan".toList | .sinh => "\\sinh".toList
  | .cosh => "\\cosh".toList | .tanh => "\\tanh".toList | .min => "\\min".toList
  | .max => "\\max".toList | .labs => "\\left|".toList | .rabs => "\\right|".toList
  | .lfloor => "\\lfloor".toList | .rfloor => "\\rfloor".toList
  | .lceil => "\\lceil".toList | .rceil => "\\rceil".toList
  | .pdiff => "\\partial".toList | .dotacc => "\\dot".toList
  | .bcases => "\\begin{cases}".toList | .ecases => "\\end{cases}".toList
  | .bmat => "\\begin{bmatrix}".toList | .emat => "\\end{bmatrix}".toList
  | .sum => "\\sum".toList | .prod => "\\prod".toList | .inn => "\\in".toList
  | .substack => "\\substack".toList | .limitsL => "\\limits".toList
  | .lbkg => "\\left[".toList | .rbkg => "\\right]".toList
  | .abs | .floor | .ceil | .dif | .cases | .esmnode | .vec | .mat | .lr | .limits => []

def tokChars : Tok → List Char
  | .num n => numChars n
  | .letter c => [c]
  | .greek g => '\\' :: g.toList
  | .word s => s.toList
  | .it s => "\\mathit{".toList ++ escT s.toList ++ ['}']
  | .rm raw => "\\mathrm{".toList ++ raw.toList ++ ['}']
  | .opn s => "\\operatorname{".toList ++ escT s.toList ++ ['}']
  | .txt s => "\\text{".toList ++ s.toList ++ ['}']
  | .jstr s => quoteL s
  | .esc o => "\\esm{".toList ++ escT o.toList ++ ['}']
  | .units l => "\\,\\mathrm{".toList ++ Esm.Units.latexBody l ++ ['}']
  | .kw k => kwChars k
  | .ups _ | .code _ => []

/-! ## Spacing -/

/-- `t` ends with letters a following letter would extend: a letter, a bare word, a
Greek name or a control word. -/
def endsAlpha : Tok → Bool
  | .letter _ | .word _ | .greek _ => true
  | .kw k => match (kwChars k).getLast? with
    | some c => isLetter c
    | none => false
  | _ => false

/-- A space is needed between `t` and a following token starting with `c`. -/
def merges (t : Tok) (c : Char) : Bool :=
  (endsAlpha t && isLetter c) ||
  (t matches .num _) && (isDig c || c == '.' || c == 'e') ||
  (t matches .kw .minus) && isDig c

def needSpace (t1 t2 : Tok) : Bool :=
  match (tokChars t2).head? with
  | some c => merges t1 c
  | none => false

/-- Tokens that end an operand. -/
def atomEnd : Tok → Bool
  | .num _ | .letter _ | .greek _ | .word _ | .it _ | .rm _ | .ups _ | .txt _ | .jstr _
  | .code _ | .units _ => true
  | .kw k => match k with
    | .rp | .rpg | .rb | .rbk | .rabs | .rfloor | .rceil | .ecases => true
    | _ => false
  | _ => false

/-- Spacing for reading: around binary operators (a `-` after an operand is binary),
after commas and colons, and between juxtaposed operands (not before a call
parenthesis). -/
def pretty (p : Option Tok) (t1 t2 : Tok) : Bool :=
  isBin t1 || isBin t2 || (t1 matches .kw .comma) || (t1 matches .kw .colon) ||
  ((t2 matches .kw .minus) && atomEnd t1) ||
  ((t1 matches .kw .minus) && (match p with | some q => atomEnd q | none => false)) ||
  (atomEnd t1 && atomStart t2 && !(t2 matches .kw .lp))

def sp (p : Option Tok) (t1 t2 : Tok) : Bool := needSpace t1 t2 || pretty p t1 t2

def renderAux : Option Tok → List Tok → List Char
  | _, [] => []
  | _, [t] => tokChars t
  | p, t1 :: t2 :: r => tokChars t1 ++ (if sp p t1 t2 then [' '] else []) ++ renderAux (some t1) (t2 :: r)

/-- The LaTeX spelling of a token list. -/
def render (ts : List Tok) : List Char := renderAux none ts

/-! ## Lexing -/

/-- Control words that are keywords, with the variants read on input. -/
def ctrlKw : List (String × Kw) :=
  [("ne", .ne), ("neq", .ne), ("le", .le), ("leq", .le), ("ge", .ge), ("geq", .ge),
    ("land", .land), ("lor", .lor), ("lnot", .lnot), ("cdot", .cdot), ("times", .times),
    ("frac", .frac), ("sqrt", .sqrt), ("exp", .exp), ("ln", .ln), ("log", .log),
    ("sin", .sin), ("cos", .cos), ("tan", .tan), ("arcsin", .asin), ("arccos", .acos),
    ("arctan", .atan), ("sinh", .sinh), ("cosh", .cosh), ("tanh", .tanh), ("min", .min),
    ("max", .max), ("lfloor", .lfloor), ("rfloor", .rfloor), ("lceil", .lceil),
    ("rceil", .rceil), ("partial", .pdiff), ("dot", .dotacc),
    ("sum", .sum), ("prod", .prod), ("in", .inn), ("substack", .substack), ("limits", .limitsL)]

/-- After a control word: its token. -/
def ctrlTok (w : String) (r : List Char) : Option (Tok × List Char) :=
  if w = "mathit" ∨ w = "mathrm" ∨ w = "operatorname" ∨ w = "text" ∨ w = "esm" then
    match r with
    | '{' :: r' =>
      (rawB 0 r').map fun p =>
        let s := String.ofList p.1
        let u := String.ofList (unescT p.1)
        (if w = "mathit" then .it u else if w = "mathrm" then .rm s
          else if w = "operatorname" then .opn u else if w = "text" then .txt s else .esc u, p.2)
    | _ => none
  else if w = "left" ∨ w = "bigl" ∨ w = "Bigl" then
    match r with
    | '(' :: r' => some (.kw .lpg, r')
    | '[' :: r' => some (if w = "left" then .kw .lbkg else .kw .lbk, r')
    | '|' :: r' => if w = "left" then some (.kw .labs, r') else none
    | _ => none
  else if w = "right" ∨ w = "bigr" ∨ w = "Bigr" then
    match r with
    | ')' :: r' => some (.kw .rpg, r')
    | ']' :: r' => some (if w = "right" then .kw .rbkg else .kw .rbk, r')
    | '|' :: r' => if w = "right" then some (.kw .rabs, r') else none
    | _ => none
  else if w = "begin" then
    match dropP "{cases}".toList r with
    | some r' => some (.kw .bcases, r')
    | none => (dropP "{bmatrix}".toList r).map (.kw .bmat, ·)
  else if w = "end" then
    match dropP "{cases}".toList r with
    | some r' => some (.kw .ecases, r')
    | none => (dropP "{bmatrix}".toList r).map (.kw .emat, ·)
  else if isGreek w.toList then some (.greek w, r)
  else (ctrlKw.lookup w).map (.kw ·, r)

/-- White space. -/
def isWsL (c : Char) : Bool := c == ' ' || c == '\n' || c == '\t' || c == '\r'

/-- Skip white space and the two-character spacing commands, inside a scientific tail. -/
def skipSp : List Char → List Char
  | [] => []
  | c :: r =>
    if isWsL c then skipSp r
    else if c = '\\' then
      match r with
      | d :: r' => if d = ';' ∨ d = ':' ∨ d = '!' ∨ d = ' ' ∨ d = ',' then skipSp r' else c :: r
      | [] => c :: r
    else c :: r

/-- The scientific tail `\times 10^{exponent}` after a mantissa, with any spacing (none
included) between its parts. -/
def sciExp (r : List Char) : Option (Int × List Char) :=
  match dropP "\\times".toList (skipSp r) with
  | some r1 =>
    if (r1.head?.map isLetter).getD false then none
    else
      match dropP "10".toList (skipSp r1) with
      | some r2 =>
        match skipSp r2 with
        | '^' :: r3 =>
          match skipSp r3 with
          | '{' :: r4 =>
            match Number.parseInt (skipSp r4) with
            | some (z, r5) =>
              match skipSp r5 with
              | '}' :: r6 => some (z, r6)
              | _ => none
            | none => none
          | _ => none
        | _ => none
      | none => none
  | none => none

/-- After `\,`: a unit `\mathrm{…}`, with white space between. -/
def unitTok (r : List Char) : Option (List Esm.Units.Factor × List Char) :=
  match dropP "\\mathrm{".toList (r.dropWhile isWsL) with
  | some r1 =>
    match rawB 0 r1 with
    | some (raw, r2) => (unitsOfRaw (String.ofList raw)).map (·, r2)
    | none => none
  | none => none

def punct : Char → Option Kw
  | '+' => some .plus | '-' => some .minus | '=' => some .eq | '<' => some .lt
  | '>' => some .gt | '/' => some .slash | '^' => some .caret | '_' => some .us
  | '(' => some .lp | ')' => some .rp | '{' => some .lb | '}' => some .rb
  | '[' => some .lbk | ']' => some .rbk | ',' => some .comma | ';' => some .semi
  | ':' => some .colon | '&' => some .amp | '.' => some .sdot
  | _ => none

/-- One token at the front of the input. -/
def lexOne (cs : List Char) : Option (Tok × List Char) :=
  match cs with
  | '\\' :: c :: r =>
    if isLetter c then
      let p := letRun (c :: r)
      ctrlTok (String.ofList p.1) p.2
    else if c = ',' then (unitTok r).map fun p => (.units p.1, p.2)
    else if c = '\\' then some (.kw .nl, r)
    else none
  | '"' :: r => (Strings.unquoteBody false (fixUs r)).map fun p => (.jstr (String.ofList p.1), p.2)
  | c :: r =>
    if isDig c || (c == '-' && (r.head?.map isDig).getD false) then lexSigned sciExp cs
    else if isLetter c then
      let p := letRun cs
      match p.1 with
      | [x] => some (.letter x, p.2)
      | w => some (.word (String.ofList w), p.2)
    else (punct c).map (.kw ·, r)
  | [] => none

/-- Skip spaces and the spacing commands (`\,` too, unless a unit follows it). -/
def skipWs : Nat → List Char → List Char
  | 0, cs => cs
  | f + 1, c :: r =>
    if c = ' ' ∨ c = '\n' ∨ c = '\t' ∨ c = '\r' then skipWs f r
    else if c = '\\' then
      match r with
      | d :: r' =>
        if d = ';' ∨ d = ':' ∨ d = '!' ∨ d = ' ' then skipWs f r'
        else if d = ',' then (if (unitTok r').isSome then c :: r else skipWs f r')
        else
          let p := letRun r
          if (p.1 = "quad".toList ∨ p.1 = "qquad".toList) then skipWs f p.2 else c :: r
      | [] => c :: r
    else c :: r
  | _ + 1, [] => []

def lexAux : Nat → List Char → Option (List Tok)
  | 0, _ => none
  | f + 1, cs =>
    match skipWs (f + 1) cs with
    | [] => some []
    | cs' =>
      match lexOne cs' with
      | some (t, r) => (lexAux f r).map (t :: ·)
      | none => none

/-- Read LaTeX math into tokens. -/
def lex (cs : List Char) : Option (List Tok) := lexAux (cs.length + 1) cs

end Esm.Document.Math.Latex
