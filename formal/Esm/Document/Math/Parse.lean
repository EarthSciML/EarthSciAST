import Esm.Document.Math.Print

/-!
# The parser: tokens to expressions

Recursive descent with one function per precedence level (`Esm.Document.Math.Print`
lists the levels), each taking fuel. The `+`, `*`, `and` and `or` chains are read
into one n-ary node; binary `-`, the comparisons and the Typst fraction `/` group to
the left; unary `-` takes a whole product (`-a b` is `-(a b)`, spec §4.1.1); `^` takes
a postfix-level base and one exponent.

Accepted variants are read here too (the printer never writes them), each with a
lemma in `Esm.Document.Math.Variants`.
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## Small pieces -/

def expect (k : Kw) : List Tok → Option (List Tok)
  | .kw k' :: r => if k' = k then some r else none
  | _ => none

/-- Close an n-ary chain: one operand is itself, more make a node. -/
def close (o : String) : List Json → Json
  | [x] => x
  | xs => node o xs

/-- The comparison a token spells. -/
def cmpOf : Kw → Option String
  | .lt => some "<"
  | .le => some "<="
  | .gt => some ">"
  | .ge => some ">="
  | .eq => some "=="
  | .ne => some "!="
  | _ => none

/-- The unary function a keyword spells. -/
def fnOf : Kw → Option String
  | .exp => some "exp"
  | .ln => some "log"
  | .sin => some "sin"
  | .cos => some "cos"
  | .tan => some "tan"
  | .asin => some "asin"
  | .acos => some "acos"
  | .atan => some "atan"
  | .sinh => some "sinh"
  | .cosh => some "cosh"
  | .tanh => some "tanh"
  | _ => none

/-- Tokens that can start an operand of a product: juxtaposition continues a product
when the next token is one of these. -/
def atomStart : Tok → Bool
  | .num _ | .letter _ | .greek _ | .word _ | .it _ | .rm _ | .ups _ | .opn _ | .txt _
  | .esc _ => true
  | .kw k =>
    match k with
    | .lpg | .lp | .lbk | .lnot | .frac | .sqrt | .exp | .ln | .log | .sin | .cos | .tan
    | .asin | .acos | .atan | .sinh | .cosh | .tanh | .min | .max | .labs | .lfloor | .lceil
    | .abs | .floor | .ceil | .dotacc | .bcases | .cases | .esmnode => true
    | _ => false
  | _ => false

/-- An opening parenthesis: `(` or `\left(`; the parser reads them alike. -/
def isLp : Tok → Bool
  | .kw .lp | .kw .lpg => true
  | _ => false

/-- The closing token of a group: `)` or `\right)`. -/
def isRp : Tok → Bool
  | .kw .rp | .kw .rpg => true
  | _ => false

/-! ## Names -/

/-- The name a formula token spells, if it is formula-shaped. -/
def decodeFormula (raw : List Char) : List Char := raw.filter (fun c => c != '_' && c != '{' && c != '}')

def formulaOf (sf : Sf) : Tok → Option (List Char)
  | .rm raw =>
    if sf = .latex then
      let g := decodeFormula raw.toList
      if isFormula g && formulaRaw g == raw.toList then some g else none
    else none
  | .ups ps =>
    if sf = .typst then
      let g := ps.flatMap (fun p => p.1.toList ++ p.2.toList)
      if isFormula g && (pieces g).map (fun p => (String.ofList p.1, String.ofList p.2)) == ps
      then some g else none
    else none
  | _ => none

/-- A single letter or Greek base, then an optional upright name subscript. -/
def subOrPlain (sf : Sf) (b : List Char) (r : List Tok) : List Char × List Tok :=
  match sf, r with
  | .latex, .kw .us :: .kw .lb :: .rm raw :: .kw .rb :: r' => (b ++ '_' :: unescT raw.toList, r')
  | .typst, .kw .us :: .kw .lpg :: .ups [(t, "")] :: .kw .rp :: r' => (b ++ '_' :: t.toList, r')
  | _, _ => (b, r)

/-- One name segment. -/
def pSeg (sf : Sf) : List Tok → Option (List Char × List Tok)
  | .letter ch :: r => if isLetter ch then some (subOrPlain sf [ch] r) else none
  | .greek g :: r => if isGreek g.toList then some (subOrPlain sf g.toList r) else none
  | .it s :: r => some (s.toList, r)
  | t :: r => (formulaOf sf t).map (·, r)
  | [] => none

/-- A name: segments joined by the scope dot. -/
def pNameLoop (sf : Sf) : Nat → List Char → List Tok → Option (List Char × List Tok)
  | 0, _, _ => none
  | f + 1, acc, .kw .sdot :: r =>
    match pSeg sf r with
    | some (g, r') => pNameLoop sf f (acc ++ '.' :: g) r'
    | none => none
  | _ + 1, acc, r => some (acc, r)

def pName (sf : Sf) (ts : List Tok) : Option (String × List Tok) :=
  match pSeg sf ts with
  | some (g, r) => (pNameLoop sf (r.length + 1) g r).map fun p => (String.ofList p.1, p.2)
  | none => none

/-! ## JSON inside LaTeX escape nodes -/

mutual
def pJson : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | _ + 1, .word "null" :: r => some (.null, r)
  | _ + 1, .word "true" :: r => some (.bool true, r)
  | _ + 1, .word "false" :: r => some (.bool false, r)
  | _ + 1, .num n :: r => some (.num n, r)
  | _ + 1, .jstr s :: r => some (.str s, r)
  | _ + 1, .kw .lbk :: .kw .rbk :: r => some (.arr [], r)
  | f + 1, .kw .lbk :: r =>
    match pJsonItems f r with
    | some (xs, .kw .rbk :: r') => some (.arr xs, r')
    | _ => none
  | _ + 1, .kw .lb :: .kw .rb :: r => some (.obj [], r)
  | f + 1, .kw .lb :: r =>
    match pJsonEntries f r with
    | some (kvs, .kw .rb :: r') => some (.obj kvs, r')
    | _ => none
  | _ + 1, _ => none

def pJsonItems : Nat → List Tok → Option (List Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pJson f ts with
    | some (v, .kw .comma :: r) => (pJsonItems f r).map fun p => (v :: p.1, p.2)
    | some (v, r) => some ([v], r)
    | none => none

def pJsonEntries : Nat → List Tok → Option (List (String × Json) × List Tok)
  | 0, _ => none
  | f + 1, .jstr k :: .kw .colon :: ts =>
    match pJson f ts with
    | some (v, .kw .comma :: r) => (pJsonEntries f r).map fun p => ((k, v) :: p.1, p.2)
    | some (v, r) => some ([(k, v)], r)
    | none => none
  | _ + 1, _ => none
end

/-! ## Expressions -/

/-- Rebuild a node with fields: `op` and `args` go back to their sorted places. -/
def mkNodeP (o : String) (as : List Json) (fs : List (String × Json)) : Json := mkNode o as fs

/-- What `pCallArgs` read: positional arguments, or named ones. -/
inductive CallArg where
  | pos (v : Json)
  | named (k : String) (v : Json)

def allPos : List CallArg → Option (List Json)
  | [] => some []
  | .pos v :: r => (allPos r).map (v :: ·)
  | .named _ _ :: _ => none

def allNamed : List CallArg → Option (List (String × Json))
  | [] => some []
  | .named k v :: r => (allNamed r).map ((k, v) :: ·)
  | .pos _ :: _ => none

/-- Sort bindings by key (insertion). -/
def sortKV : List (String × Json) → List (String × Json)
  | [] => []
  | kv :: r => insKV kv (sortKV r)

/-- The unit a LaTeX `\mathrm{…}` after a number spells. -/
def unitsOfRaw (raw : String) : Option (List Esm.Units.Factor) :=
  Esm.Units.parseLatex (String.ofList (Esm.Units.mathrmOpen ++ raw.toList ++ ['}']))

/-- A quantity node. -/
def qty (n : JNum) (l : List Esm.Units.Factor) : Json :=
  .obj [("args", .arr []), ("op", .str "const"), ("units", .str (Esm.Units.spell l)), ("value", .num n)]

/-- A derivative node. -/
def dNode (x : Json) (w : String) : Json := .obj [("args", .arr [x]), ("op", .str "D"), ("wrt", .str w)]

/-- A template application node. -/
def tNode (n : String) (bs : List (String × Json)) : Json :=
  .obj [("args", .arr []), ("bindings", .obj bs), ("name", .str n), ("op", .str "apply_expression_template")]

/-- The `ic` tail `(t_{0})` / `(t_0)`. -/
def icTailP (sf : Sf) : List Tok → Option (List Tok)
  | .kw .lp :: .letter 't' :: .kw .us :: r =>
    match sf, r with
    | .latex, .kw .lb :: .num (.int 0) :: .kw .rb :: .kw .rp :: r' => some r'
    | .typst, .num (.int 0) :: .kw .rp :: r' => some r'
    | _, _ => none
  | _ => none

/-- A LaTeX field value that is JSON starts with `{`, `[`, a string or a word. -/
def jsonStart : List Tok → Bool
  | [] => false
  | t :: _ => (t matches .kw .lb) || (t matches .kw .lbk) || (t matches .jstr _) || (t matches .word _)

/-- A field key: LaTeX `\mathrm{key} =`, Typst `upright("key") =`. -/
def keyOf (c : Ctx) (ts : List Tok) : Option (String × List Tok) :=
  match c.sf, ts with
  | .latex, .rm raw :: .kw .eq :: r => some (String.ofList (unescT raw.toList), r)
  | .typst, .ups [(k, "")] :: .kw .eq :: r => some (k, r)
  | _, _ => none

/-- A spatial derivative with trailing operands. -/
def dCallNode (w : String) (xs : List Json) : Json :=
  .obj [("args", .arr xs), ("op", .str "D"), ("wrt", .str w)]

/-- The input starts with Euler's number raised to a power: an upright `e`, or an
italic `e` when no variable `e` is declared. -/
def eulerHead (c : Ctx) : List Tok → Bool
  | .rm raw :: .kw .caret :: _ => raw == "e"
  | .ups ps :: .kw .caret :: _ => ps == [("e", "")]
  | .letter ch :: .kw .caret :: _ => ch == 'e' && !(c.S.names.contains "e")
  | _ => false

/-- A name, or an initial condition `N(t_{0})`. -/
def pNamePrim (c : Ctx) (ts : List Tok) : Option (Json × List Tok) :=
  match pName c.sf ts with
  | some (n, r) =>
    match icTailP c.sf r with
    | some r' => some (node "ic" [.str n], r')
    | none => some (.str n, r)
  | none => none

/-- A bare run of letters (`RT`): the declared name when only it is declared, the
product of its letters when only they are, refused otherwise (ambiguous or unknown). -/
def pWord (c : Ctx) (w : String) (r : List Tok) : Option (Json × List Tok) :=
  let whole := c.S.names.contains w
  let letters := w.toList.all (fun ch => c.S.names.contains (String.ofList [ch]))
  if whole && !letters then some (.str w, r)
  else if letters && !whole then some (node "*" (w.toList.map fun ch => .str (String.ofList [ch])), r)
  else none

/-- `d` then a name, up to a closing token `k`: `dN}` (a run of letters) or `d N}`. -/
def dName (sf : Sf) (k : Kw) : List Tok → Option (String × List Tok)
  | .word w :: .kw k' :: r =>
    if k' = k then
      match w.toList with
      | 'd' :: x => some (String.ofList x, r)
      | _ => none
    else none
  | .letter 'd' :: r =>
    match pName sf r with
    | some (n, .kw k' :: r') => if k' = k then some (n, r') else none
    | _ => none
  | _ => none

/-- The italic-d derivative variant, when no variable `d` is declared: LaTeX
`\frac{dN}{dt}` after `\frac{`, Typst `(d N)/(d t)` after the first `(`. -/
def pItalicD (c : Ctx) (r : List Tok) : Option (Json × List Tok) :=
  if c.S.names.contains "d" then none
  else
    match c.sf with
    | .latex =>
      match dName c.sf .rb r with
      | some (n, .kw .lb :: r1) => (dName c.sf .rb r1).map fun p => (dNode (.str n) p.1, p.2)
      | _ => none
    | .typst =>
      match dName c.sf .rp r with
      | some (n, .kw .slash :: .kw .lpg :: r1) => (dName c.sf .rp r1).map fun p => (dNode (.str n) p.1, p.2)
      | _ => none

mutual
/-- Level 1: an `or` chain. -/
def pOr (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pAnd c f ts with
    | some (x, r) => orLoop c f [x] r
    | none => none

def orLoop (c : Ctx) : Nat → List Json → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, acc, .kw .lor :: r =>
    match pAnd c f r with
    | some (y, r') => orLoop c f (acc ++ [y]) r'
    | none => none
  | _ + 1, acc, r => some (close "or" acc, r)

/-- Level 2: an `and` chain. -/
def pAnd (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pCmp c f ts with
    | some (x, r) => andLoop c f [x] r
    | none => none

def andLoop (c : Ctx) : Nat → List Json → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, acc, .kw .land :: r =>
    match pCmp c f r with
    | some (y, r') => andLoop c f (acc ++ [y]) r'
    | none => none
  | _ + 1, acc, r => some (close "and" acc, r)

/-- Level 3: comparisons, grouping to the left. -/
def pCmp (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pAdd c f ts with
    | some (x, r) => cmpLoop c f x r
    | none => none

def cmpLoop (c : Ctx) : Nat → Json → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, x, .kw k :: r =>
    match cmpOf k with
    | some o =>
      match pAdd c f r with
      | some (y, r') => cmpLoop c f (node o [x, y]) r'
      | none => none
    | none => some (x, .kw k :: r)
  | _ + 1, x, r => some (x, r)

/-- Level 4: `+` chains and binary `-`. `x :: acc` is the pending `+` chain. -/
def pAdd (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pMul c f ts with
    | some (x, r) => addLoop c f [x] r
    | none => none

def addLoop (c : Ctx) : Nat → List Json → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, acc, .kw .plus :: r =>
    match pMul c f r with
    | some (y, r') => addLoop c f (acc ++ [y]) r'
    | none => none
  | f + 1, acc, .kw .minus :: r =>
    match pMul c f r with
    | some (y, r') => addLoop c f [node "-" [close "+" acc, y]] r'
    | none => none
  | _ + 1, acc, r => some (close "+" acc, r)

/-- Level 5: unary minus, and `*` chains (juxtaposition, `\cdot`, `\times`; LaTeX inline
`/` groups to the left). -/
def pMul (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, .kw .minus :: r =>
    match pMul c f r with
    | some (x, r') => some (node "-" [x], r')
    | none => none
  | f + 1, ts =>
    match pNot c f ts with
    | some (x, r) => mulLoop c f [x] r
    | none => none

def mulLoop (c : Ctx) : Nat → List Json → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, acc, .kw .cdot :: r =>
    match pNot c f r with
    | some (y, r') => mulLoop c f (acc ++ [y]) r'
    | none => none
  | f + 1, acc, .kw .times :: r =>
    match pNot c f r with
    | some (y, r') => mulLoop c f (acc ++ [y]) r'
    | none => none
  | f + 1, acc, .kw .slash :: r =>
    if c.sf = .latex then
      match pNot c f r with
      | some (y, r') => mulLoop c f [node "/" [close "*" acc, y]] r'
      | none => none
    else some (close "*" acc, .kw .slash :: r)
  | f + 1, acc, t :: r =>
    if atomStart t then
      match pNot c f (t :: r) with
      | some (y, r') => mulLoop c f (acc ++ [y]) r'
      | none => none
    else some (close "*" acc, t :: r)
  | _ + 1, acc, [] => some (close "*" acc, [])

/-- Level 6: `not`. -/
def pNot (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, .kw .lnot :: r =>
    match pNot c f r with
    | some (x, r') => some (node "not" [x], r')
    | none => none
  | f + 1, ts => pFrac c f ts

/-- Level 7: the Typst fraction, grouping to the left. -/
def pFrac (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pPow c f ts with
    | some (x, r) => fracLoop c f x r
    | none => none

def fracLoop (c : Ctx) : Nat → Json → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, x, .kw .slash :: r =>
    if c.sf = .typst then
      match pPow c f r with
      | some (y, r') => fracLoop c f (node "/" [x, y]) r'
      | none => none
    else some (x, .kw .slash :: r)
  | _ + 1, x, r => some (x, r)

/-- Level 8: a power. -/
def pPow (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pPost c f ts with
    | some (x, .kw .caret :: r) =>
      match pExpo c f r with
      | some (y, r') => some (node "^" [x, y], r')
      | none => none
    | some (x, r) => some (x, r)
    | none => none

/-- An exponent: LaTeX `{…}`; Typst `(…)` or one simple token. -/
def pExpo (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match c.sf, ts with
    | .latex, .kw .lb :: r =>
      match pOr c f r with
      | some (y, .kw .rb :: r') => some (y, r')
      | _ => none
    | .typst, .kw .lpg :: r =>
      match pOr c f r with
      | some (y, t :: r') => if isRp t then some (y, r') else none
      | _ => none
    | .typst, t :: r => if simpleTok t then pPrim c f [t] |>.bind fun p => if p.2 = [] then some (p.1, r) else none else none
    | _, _ => none

/-- Level 9: postfix index, `_{…}` or `[…]`. -/
def pPost (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pPrim c f ts with
    | some (x, r) => postLoop c f x r
    | none => none

def postLoop (c : Ctx) : Nat → Json → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, x, .kw .us :: r =>
    match c.sf, r with
    | .latex, .kw .lb :: r1 =>
      match pList c f 1 r1 with
      | some (is, .kw .rb :: r2) => if is = [] then none else postLoop c f (node "index" (x :: is)) r2
      | _ => none
    | .typst, .kw .lpg :: r1 =>
      match pList c f 1 r1 with
      | some (is, t :: r2) =>
        if isRp t && !is.isEmpty then postLoop c f (node "index" (x :: is)) r2 else none
      | _ => none
    | .typst, t :: r1 =>
      if simpleTok t then
        match pPrim c f [t] with
        | some (i, []) => postLoop c f (node "index" [x, i]) r1
        | _ => none
      else none
    | _, _ => none
  | f + 1, x, .kw .lbk :: r =>
    match pList c f 1 r with
    | some (is, .kw .rbk :: r2) => if is = [] then none else postLoop c f (node "index" (x :: is)) r2
    | _ => none
  | _ + 1, x, r => some (x, r)

/-- A comma-separated list of expressions at level `L` (1 or 4), possibly empty when
the next token closes it. -/
def pList (c : Ctx) : Nat → Nat → List Tok → Option (List Json × List Tok)
  | 0, _, _ => none
  | f + 1, L, ts =>
    match ts with
    | t :: _ =>
      if isRp t || t matches .kw .rb || t matches .kw .rbk then some ([], ts)
      else pItems c f L ts
    | [] => some ([], [])

def pItems (c : Ctx) : Nat → Nat → List Tok → Option (List Json × List Tok)
  | 0, _, _ => none
  | f + 1, L, ts =>
    match pLv c f L ts with
    | some (x, .kw .comma :: r) => (pItems c f L r).map fun p => (x :: p.1, p.2)
    | some (x, r) => some ([x], r)
    | none => none

/-- Parse at level 1 or level 4. -/
def pLv (c : Ctx) : Nat → Nat → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, L, ts => if L = 4 then pAdd c f ts else pOr c f ts

/-- Call arguments at level 4: each positional, or `name = value`. -/
def pCallArgs (c : Ctx) : Nat → List Tok → Option (List CallArg × List Tok)
  | 0, _ => none
  | _ + 1, .kw .rp :: r => some ([], .kw .rp :: r)
  | _ + 1, .kw .semi :: r => some ([], .kw .semi :: r)
  | f + 1, ts => pCallItems c f ts

def pCallItems (c : Ctx) : Nat → List Tok → Option (List CallArg × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pAdd c f ts with
    | some (.str k, .kw .eq :: r) =>
      match pAdd c f r with
      | some (v, .kw .comma :: r') => (pCallItems c f r').map fun p => (.named k v :: p.1, p.2)
      | some (v, r') => some ([.named k v], r')
      | none => none
    | some (x, .kw .comma :: r) => (pCallItems c f r).map fun p => (.pos x :: p.1, p.2)
    | some (x, r) => some ([.pos x], r)
    | none => none

/-- Open-operator fields after `;`: `key = value`, the value as math or as JSON. -/
def pFields (c : Ctx) : Nat → List Tok → Option (List (String × Json) × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match keyOf c ts with
    | some (k, r) =>
      match pVal c f r with
      | some (v, .kw .comma :: r') => (pFields c f r').map fun p => ((k, v) :: p.1, p.2)
      | some (v, r') => some ([(k, v)], r')
      | none => none
    | none => none

/-- A field value: JSON (LaTeX JSON tokens, Typst `#value`) or an expression. -/
def pVal (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, r =>
    match c.sf with
    | .typst =>
      match r with
      | .code v :: r' => some (v, r')
      | _ => pAdd c f r
    | .latex => if jsonStart r then pJson f r else pAdd c f r

/-- `\operatorname{n}(…)`: a call-form core operator, a deprecated one (rewritten), a
template (by the symbol table, positional or named), or an open operator. -/
def pOpn (c : Ctx) : Nat → String → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, n, t0 :: r =>
    if isLp t0 then
      match pCallArgs c f r with
      | some (args, .kw .rp :: r') =>
        if callOps.contains n then (allPos args).map (node n ·, r')
        else if n = "neg" then
          match allPos args with
          | some [x] => some (node "-" [x], r')
          | _ => none
        else if n = "pow" then
          match allPos args with
          | some [x, y] => some (node "^" [x, y], r')
          | _ => none
        else if removedOps.contains n || n = "D" then none
        else
          match tparams c.S n, allPos args, allNamed args with
          | some ps, some vs, _ =>
            if ps.length = vs.length then some (tNode n (sortKV (ps.zip vs)), r') else none
          | _, _, some (b :: bs) => some (tNode n (b :: bs), r')
          | none, some vs, _ => some (mkNode n vs [], r')
          | _, _, _ => none
      | some (args, .kw .semi :: r1) =>
        if removedOps.contains n || coreOps.contains n || (tparams c.S n).isSome then none
        else
          match allPos args, pFields c f r1 with
          | some vs, some (fs, .kw .rp :: r2) => some (mkNode n vs fs, r2)
          | _, _ => none
      | _ => none
    else if t0 matches .kw .us then
      if n = "D" then pDCall c f r else none
    else none
  | _ + 1, _, [] => none

/-- `\operatorname{D}_{x}(u, a, b)` after the `_`. -/
def pDCall (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, r =>
    let w : Option (String × List Tok) :=
      match c.sf, r with
      | .latex, .kw .lb :: r1 =>
        match pName c.sf r1 with
        | some (w, .kw .rb :: r2) => some (w, r2)
        | _ => none
      | .typst, .kw .lpg :: r1 =>
        match pName c.sf r1 with
        | some (w, .kw .rp :: r2) => some (w, r2)
        | _ => none
      | _, _ => none
    match w with
    | some (w, t3 :: r3) =>
      if isLp t3 then
        match pCallArgs c f r3 with
        | some (args, .kw .rp :: r4) => (allPos args).map (dCallNode w ·, r4)
        | _ => none
      else none
    | _ => none

/-- A primary. -/
def pPrim (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match ts with
    | .num n :: r =>
      match c.sf, r with
      | .latex, .kw .thin :: .rm raw :: r' => (unitsOfRaw raw).map (qty n ·, r')
      | .typst, .units l :: r' => some (qty n l, r')
      | _, _ => some (.num n, r)
    | .txt "true" :: r => some (node "true" [], r)
    | .txt "false" :: r => some (node "false" [], r)
    | .kw .lpg :: r | .kw .lp :: r =>
      match c.sf, r with
      | .typst, .kw .dif :: r1 => pDT c f .dif r1
      | .typst, .kw .pdiff :: r1 => pDT c f .pdiff r1
      | .typst, .letter 'd' :: _ =>
        match pItalicD c r with
        | some p => some p
        | none =>
          match pOr c f r with
          | some (x, t :: r') => if isRp t then some (x, r') else none
          | _ => none
      | _, _ =>
        match pOr c f r with
        | some (x, t :: r') => if isRp t then some (x, r') else none
        | _ => none
    | .kw .lbk :: r =>
      match pOr c f r with
      | some (x, .kw .rbk :: r') => some (x, r')
      | _ => none
    | .kw .frac :: .kw .lb :: r => pFracL c f r
    | .kw .sqrt :: r =>
      match c.sf, r with
      | .latex, .kw .lb :: r1 =>
        match pOr c f r1 with
        | some (x, .kw .rb :: r2) => some (node "sqrt" [x], r2)
        | _ => none
      | .typst, t :: r1 => if isLp t then pFn1 c f "sqrt" r1 else none
      | _, _ => none
    | .kw .log :: .kw .us :: r =>
      match c.sf, r with
      | .latex, .kw .lb :: .num (.int 10) :: .kw .rb :: t :: r1 =>
        if isLp t then pFn1 c f "log10" r1 else none
      | .typst, .num (.int 10) :: t :: r1 => if isLp t then pFn1 c f "log10" r1 else none
      | _, _ => none
    | .kw .labs :: r =>
      match pOr c f r with
      | some (x, .kw .rabs :: r') => some (node "abs" [x], r')
      | _ => none
    | .kw .lfloor :: r =>
      match pOr c f r with
      | some (x, .kw .rfloor :: r') => some (node "floor" [x], r')
      | _ => none
    | .kw .lceil :: r =>
      match pOr c f r with
      | some (x, .kw .rceil :: r') => some (node "ceil" [x], r')
      | _ => none
    | .kw .min :: t :: r =>
      if isLp t then
        match pList c f 1 r with
        | some (xs, .kw .rp :: r') => if 2 ≤ xs.length then some (node "min" xs, r') else none
        | _ => none
      else none
    | .kw .max :: t :: r =>
      if isLp t then
        match pList c f 1 r with
        | some (xs, .kw .rp :: r') => if 2 ≤ xs.length then some (node "max" xs, r') else none
        | _ => none
      else none
    | .opn n :: r => pOpn c f n r
    | .kw .bcases :: r => pCases c f r
    | .kw .cases :: t :: r => if isLp t then pCases c f r else none
    | .esc o :: .kw .lb :: r =>
      match pJson f r with
      | some (.obj fs, .kw .rb :: .kw .lb :: r1) =>
        match pList c f 1 r1 with
        | some (as, .kw .rb :: r2) =>
          if opOK o && !(removedOps.contains o) && !(deprecatedOps.contains o) then
            some (mkNode o as fs, r2)
          else none
        | _ => none
      | _ => none
    | .kw .esmnode :: t :: .txt o :: .kw .comma :: .code (.obj fs) :: r =>
      if isLp t then
        match pEscArgs c f r with
        | some (as, r') =>
          if opOK o && !(removedOps.contains o) && !(deprecatedOps.contains o) then
            some (mkNode o as fs, r')
          else none
        | none => none
      else none
    | .kw .dotacc :: .kw .lb :: r =>
      match pOr c f r with
      | some (x, .kw .rb :: r') => some (dNode x "t", r')
      | _ => none
    | .kw .cdot :: .kw .lp :: r =>
      match pOr c f r with
      | some (x, .kw .rp :: r') => some (dNode x "t", r')
      | _ => none
    | .kw k :: t :: r =>
      if isLp t then
        match k, fnOf k with
        | .log, _ => pFn1 c f "log" r
        | .abs, _ => pFn1 c f "abs" r
        | .floor, _ => pFn1 c f "floor" r
        | .ceil, _ => pFn1 c f "ceil" r
        | _, some o => pFn1 c f o r
        | _, none => none
      else none
    | .word w :: r => pWord c w r
    | _ =>
      -- a name: `\mathrm{e}^{x}` / `upright("e")^x` and an undeclared italic `e^{x}`
      -- read as `exp`; `N(t_{0})` is an initial condition
      if eulerHead c ts then pEulerExp c f (ts.drop 2) else pNamePrim c ts

/-- `\exp` written as a power of e. -/
def pEulerExp (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, r =>
    match pExpo c f r with
    | some (y, r') => some (node "exp" [y], r')
    | none => none

/-- `f(x)` after the opening parenthesis. -/
def pFn1 (c : Ctx) : Nat → String → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, o, r =>
    match pOr c f r with
    | some (x, .kw .rp :: r') => some (node o [x], r')
    | _ => none

/-- After `\frac{`: a time or spatial derivative, the italic-d variant, or a quotient. -/
def pFracL (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, .rm "d" :: .kw .rb :: .kw .lb :: .rm "d" :: .letter 't' :: .kw .rb :: r =>
    pDApply c f "t" r
  | f + 1, .rm "d" :: r =>
    match pOr c f r with
    | some (x, .kw .rb :: .kw .lb :: .rm "d" :: .letter 't' :: .kw .rb :: r') => some (dNode x "t", r')
    | _ => none
  | f + 1, .kw .pdiff :: .kw .rb :: .kw .lb :: .kw .pdiff :: r =>
    match pName c.sf r with
    | some (w, .kw .rb :: r') => pDApply c f w r'
    | _ => none
  | f + 1, .kw .pdiff :: r =>
    match pOr c f r with
    | some (x, .kw .rb :: .kw .lb :: .kw .pdiff :: r1) =>
      match pName c.sf r1 with
      | some (w, .kw .rb :: r') => some (dNode x w, r')
      | _ => none
    | _ => none
  | f + 1, r =>
    match pItalicD c r with
    | some p => some p
    | none =>
      match pOr c f r with
      | some (x, .kw .rb :: .kw .lb :: r1) =>
        match pOr c f r1 with
        | some (y, .kw .rb :: r2) => some (node "/" [x, y], r2)
        | _ => none
      | _ => none

/-- `(dif N)/(dif t)` and `(partial u)/(partial x)` after the first `(dif` / `(partial`. -/
def pDT (c : Ctx) : Nat → Kw → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, k, .kw .rp :: .kw .slash :: .kw .lpg :: .kw k' :: r =>
    if k' = k then
      match pName c.sf r with
      | some (w, .kw .rp :: r') =>
        if k = .dif && w != "t" then none else pDApply c f w r'
      | _ => none
    else none
  | f + 1, k, r =>
    match pOr c f r with
    | some (x, .kw .rp :: .kw .slash :: .kw .lpg :: .kw k' :: r1) =>
      if k' = k then
        match pName c.sf r1 with
        | some (w, .kw .rp :: r') => if k = .dif && w != "t" then none else some (dNode x w, r')
        | _ => none
      else none
    | _ => none

/-- A derivative operator applied to a parenthesized operand. -/
def pDApply (c : Ctx) : Nat → String → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, w, .kw .lpg :: r =>
    match pOr c f r with
    | some (x, t :: r') => if isRp t then some (dNode x w, r') else none
    | _ => none
  | _ + 1, _, _ => none

/-- `cases` rows: `value & if cond` then a row break, ending with `value & otherwise`;
a chain re-nests to the right. -/
def pCases (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pOr c f ts with
    | some (v, .kw .amp :: .txt "otherwise" :: r) =>
      match c.sf, r with
      | .latex, .kw .ecases :: r' => some (v, r')
      | .typst, .kw .rp :: r' => some (v, r')
      | _, _ => none
    | some (v, .kw .amp :: .txt "if " :: r) =>
      match pOr c f r with
      | some (cnd, .kw k :: r') =>
        if k = (if c.sf = .latex then .nl else .comma) then
          (pCases c f r').map fun p => (node "ifelse" [cnd, v, p.1], p.2)
        else none
      | _ => none
    | _ => none

/-- Typst escape arguments: `, a` repeated, then `)`. -/
def pEscArgs (c : Ctx) : Nat → List Tok → Option (List Json × List Tok)
  | 0, _ => none
  | _ + 1, .kw .rp :: r => some ([], r)
  | f + 1, .kw .comma :: r =>
    match pOr c f r with
    | some (x, r') => (pEscArgs c f r').map fun p => (x :: p.1, p.2)
    | none => none
  | _ + 1, _ => none
end

end Esm.Document.Math
