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
    | .abs | .floor | .ceil | .dotacc | .bcases | .cases | .esmnode | .bmat | .vec | .mat
    | .sum | .prod | .limits | .lbkg | .lr | .nabla | .pdiff => true
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

/-! ## Negative literals after an operand -/

/-- A negative literal token. -/
def negTok : Tok → Bool
  | .num n => negNum n
  | _ => false

/-- The number with the opposite sign. -/
def negate : JNum → JNum
  | .int z => .int (-z)
  | .dec neg ds e => .dec (!neg) ds e

/-- A negative literal right after an operand (`k-1`, `k -1`) is a binary minus and a
positive number: the tokens with the sign moved off the number, when the number without
its sign has a canonical form (the negation of `-2^63` has none, so that spelling is
refused after an operand). -/
def negTail : List Tok → Option (List Tok)
  | .num n :: r => if negNum n && (negate n).wfb then some (.num (negate n) :: r) else none
  | _ => none

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

/-- A time-derivative node (`dNode x "t"`). -/
def dNode (x : Json) (w : String) : Json := .obj [("args", .arr [x]), ("op", .str "D"), ("wrt", .str w)]

/-- A `partial` node: the spatial derivative (spec §4.2). -/
def pNode (x : Json) (w : String) : Json := .obj [("args", .arr [x]), ("op", .str "partial"), ("wrt", .str w)]

/-- The derivative a fraction of differentials reads as: the time derivative `D` along `t`,
`partial` along any other axis (spec §4.2: `partial`'s `wrt` is never `t`, and a `D` with
a spatial `wrt` reads as `partial`). -/
def derivNode (x : Json) (w : String) : Json := if w = "t" then dNode x "t" else pNode x w

/-- A reference node (`apply_operator`, spec §9.6.2). -/
def tNode (n : String) (bs : List (String × Json)) : Json :=
  .obj [("args", .arr []), ("bindings", .obj bs), ("name", .str n), ("op", .str "apply_operator")]

/-- A constant node: the value, and the units when there are some. -/
def constNode (v : Json) : Option String → Json
  | none => .obj [("args", .arr []), ("op", .str "const"), ("value", v)]
  | some u => .obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", v)]

/-- Numbers separated by `sep`, up to the first other token. -/
def pCells (sep : Kw) : List Tok → Option (List JNum × List Tok)
  | .num n :: .kw k :: r => if k = sep then (pCells sep r).map fun p => (n :: p.1, p.2) else some ([n], .kw k :: r)
  | .num n :: r => some ([n], r)
  | _ => none

/-- Rows of numbers: cells separated by `csep`, rows by `rsep`, closed by `close`. -/
def pGrid (csep rsep close : Kw) : Nat → List Tok → Option (List (List JNum) × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pCells csep ts with
    | some (row, .kw k :: r) =>
      if k = rsep then (pGrid csep rsep close f r).map fun p => (row :: p.1, p.2)
      else if k = close then some ([row], r) else none
    | _ => none

/-- A LaTeX `bmatrix`: one cell per row is a column (rank 1). -/
def gridJson (rows : List (List JNum)) : Json :=
  if rows.all (fun r => r.length == 1) then .arr (rows.map fun r => .num (r.headD (.int 0)))
  else .arr (rows.map fun r => .arr (r.map .num))

/-- The unit after an array, if any. -/
def constTail (v : Json) (r : List Tok) : Option (Json × List Tok) :=
  match r with
  | .units l :: r' => some (constNode v (some (Esm.Units.spell l)), r')
  | _ => some (constNode v none, r)

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
  | .latex, .rm raw :: .kw .eq :: r => some (String.ofList (unescK raw.toList), r)
  | .typst, .ups [(k, "")] :: .kw .eq :: r => some (k, r)
  | _, _ => none

/-- `partial` with trailing operands. -/
def dCallNode (w : String) (xs : List Json) : Json :=
  .obj [("args", .arr xs), ("op", .str "partial"), ("wrt", .str w)]

/-- After `\nabla`: which form it is (`\cdot` div, `\times` curl, `^{2}` laplacian,
nothing grad), and the tokens of its operand. -/
def nabTail (sf : Sf) (r : List Tok) : String × List Tok :=
  match sf, r with
  | _, .kw .cdot :: r' => ("div", r')
  | _, .kw .times :: r' => ("curl", r')
  | .latex, .kw .caret :: .kw .lb :: .num (.int 2) :: .kw .rb :: r' => ("laplacian", r')
  | .typst, .kw .caret :: .num (.int 2) :: r' => ("laplacian", r')
  | _, r' => ("grad", r')

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

/-- `d` then a name, up to a closing token `k`: `dN}` (a run of letters that is not
itself a declared name) or `d N}`. -/
def dName (c : Ctx) (k : Kw) : List Tok → Option (String × List Tok)
  | .word w :: .kw k' :: r =>
    if k' = k && !(c.S.names.contains w) then
      match w.toList with
      | 'd' :: x => some (String.ofList x, r)
      | _ => none
    else none
  | .letter 'd' :: r =>
    match pName c.sf r with
    | some (n, .kw k' :: r') => if k' = k then some (n, r') else none
    | _ => none
  | _ => none

/-- The italic-d derivative variant, when no variable `d` is declared and neither
`dN` nor `dt` written as one word is a declared name (a declared whole word wins, as in
`pWord`: `\frac{dx}{dt}` with `dx` and `dt` declared is their quotient): LaTeX
`\frac{dN}{dt}` after `\frac{`, Typst `(d N)/(d t)` after the first `(`. -/
def pItalicD (c : Ctx) (r : List Tok) : Option (Json × List Tok) :=
  if c.S.names.contains "d" then none
  else
    match c.sf with
    | .latex =>
      match dName c .rb r with
      | some (n, .kw .lb :: r1) => (dName c .rb r1).map fun p => (derivNode (.str n) p.1, p.2)
      | _ => none
    | .typst =>
      match dName c .rp r with
      | some (n, .kw .slash :: .kw .lpg :: r1) => (dName c .rp r1).map fun p => (derivNode (.str n) p.1, p.2)
      | _ => none

/-- The token is the keyword `k`. -/
def isKw (k : Kw) : Tok → Bool
  | .kw k' => k' == k
  | _ => false

/-- A row of a reduction's subscript, or an output entry: a range, or an expression
(the filter, or a bare output entry). -/
inductive Row where
  | rng (k : String) (v : Json)
  | filt (x : Json)

def redOf : Kw → Option RedK
  | .sum => some .sum
  | .prod => some .prod
  | .max => some .max
  | .min => some .min
  | _ => none

/-- The operator of a reduction and whether it is marked (`args` listed): LaTeX
`\sum\limits`, Typst `limits(sum)`. -/
def pRedHead (sf : Sf) : List Tok → Option (RedK × Bool × List Tok)
  | .kw .limits :: .kw .lp :: .kw k :: .kw .rp :: r =>
    if sf = .typst then (redOf k).map fun red => (red, true, r) else none
  | .kw k :: .kw .limitsL :: r =>
    if sf = .latex then (redOf k).map fun red => (red, true, r) else (redOf k).map fun red => (red, false, .kw .limitsL :: r)
  | .kw k :: r => (redOf k).map fun red => (red, false, r)
  | _ => none

/-- Names separated by commas. -/
def pNames (sf : Sf) : Nat → List Tok → Option (List String × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pName sf ts with
    | some (n, .kw .comma :: r) => (pNames sf f r).map fun p => (n :: p.1, p.2)
    | some (n, r) => some ([n], r)
    | none => none

/-- The ranges and the filter of a list of rows: ranges, then at most one filter, last. -/
def rowParts : List Row → Option (List (String × Json) × Option Json)
  | [] => some ([], none)
  | [.filt x] => some ([], some x)
  | .filt _ :: _ :: _ => none
  | .rng k v :: r => (rowParts r).map fun p => ((k, v) :: p.1, p.2)

/-- The output entries of a list of entry rows, with their ranges. -/
def entryParts : List Row → Option (List Json × List (String × Json))
  | [] => some ([], [])
  | .rng k v :: r => (entryParts r).map fun p => (.str k :: p.1, (k, v) :: p.2)
  | .filt (.str k) :: r => (entryParts r).map fun p => (.str k :: p.1, p.2)
  | .filt (.num (.int 1)) :: r => (entryParts r).map fun p => (.num (.int 1) :: p.1, p.2)
  | .filt _ :: _ => none

/-- The node an output form reads: the reduction's parts with the output entries. -/
def withOut (F : FaqForm) (outs : List Json) (ors : List (String × Json)) : FaqForm :=
  { F with out := outs, ranges := sortKV (ors ++ F.ranges) }

/-- The superscript set read after the output entries (the reduction inside the bracket
carries none, `bracketSetOK`). -/
def withSup (F : FaqForm) (st : List String) : FaqForm :=
  if st.isEmpty then F else { F with set := st }

/-- The sets of an output form as the printer writes them: none on the reduction inside
the bracket (the printer writes the set on the bracket), and none at all when the
operator is marked (`args` lists the body's arrays). -/
def bracketSetOK (F : FaqForm) (st : List String) : Bool :=
  F.set.isEmpty && !(F.marked && !st.isEmpty)

/-- The superscript set of a reduction or of an output form, if there is one: LaTeX
`^{\{f, g\}}`, Typst `^({f, g})`. -/
def pSup (sf : Sf) (r : List Tok) : Option (List String × List Tok) :=
  match sf, r with
  | .latex, .kw .caret :: .kw .lb :: .kw .lset :: r1 =>
    match pNames sf (r1.length + 1) r1 with
    | some (ns, .kw .rset :: .kw .rb :: r2) => some (ns, r2)
    | _ => none
  | .typst, .kw .caret :: .kw .lpg :: .kw .lset :: r1 =>
    match pNames sf (r1.length + 1) r1 with
    | some (ns, .kw .rset :: .kw .rp :: r2) => some (ns, r2)
    | _ => none
  | _, _ => some ([], r)

/-- The `makearray` node of a table read back, with its subscript of output indices if
one follows. -/
def mkTail (sf : Sf) (rows : List (Json × List (Json × Json))) (r : List Tok) : Option (Json × List Tok) :=
  let nodeOf := fun (out : List String) => mkJson ⟨out, rows.map Prod.snd, rows.map Prod.fst⟩
  match sf, r with
  | .latex, .kw .us :: .kw .lb :: r1 =>
    match pNames sf (r1.length + 1) r1 with
    | some (ns, .kw .rb :: r2) => some (nodeOf ns, r2)
    | _ => none
  | .typst, .kw .us :: .kw .lpg :: r1 =>
    match pNames sf (r1.length + 1) r1 with
    | some (ns, .kw .rp :: r2) => some (nodeOf ns, r2)
    | _ => none
  | _, _ => some (nodeOf [], r)

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

/-- Level 3: one comparison (comparisons do not chain: `a \le k \le b` is a range row of a
reduction, never an expression). -/
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
      | some (y, r') => some (node o [x, y], r')
      | none => none
    | none => some (x, .kw k :: r)
  | _ + 1, x, r => some (x, r)

/-- Level 4: `+` chains and binary `-`, including a negative literal right after an
operand (`negTail`). `x :: acc` is the pending `+` chain. -/
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
  | f + 1, acc, r =>
    match negTail r with
    | some r1 =>
      match pMul c f r1 with
      | some (y, r') => addLoop c f [node "-" [close "+" acc, y]] r'
      | none => none
    | none => some (close "+" acc, r)

/-- Level 5: unary minus, and `*` chains (juxtaposition, `\cdot`, `\times`; LaTeX inline
`/` groups to the left). A negative literal never continues a product by juxtaposition
(`k -1` is `k - 1`); after `\cdot` it is a factor (`k \cdot -1`). -/
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
    if atomStart t && !negTok t then
      match pNot c f (t :: r) with
      | some (y, r') => mulLoop c f (acc ++ [y]) r'
      | none => none
    else some (close "*" acc, t :: r)
  | _ + 1, acc, [] => some (close "*" acc, [])

/-- Level 6: `not`, and the `\nabla` forms, whose operand is read at level 9. -/
def pNot (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, .kw .lnot :: r =>
    match pNot c f r with
    | some (x, r') => some (node "not" [x], r')
    | none => none
  | f + 1, .kw .nabla :: r =>
    match pNabArg c f (nabTail c.sf r).2 with
    | some (x, r') => some (node (nabTail c.sf r).1 [x], r')
    | none => none
  | f + 1, ts => pFrac c f ts

/-- The operand of a `\nabla` form: another `\nabla` form, or a postfix-level operand. -/
def pNabArg (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, .kw .nabla :: r => pNot c f (.kw .nabla :: r)
  | f + 1, r => pPost c f r

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
          | _, _, some (b :: bs) =>
            if ((b :: bs).map Prod.fst).Nodup then some (tNode n (sortKV (b :: bs)), r') else none
          | none, some vs, _ => some (mkNode n vs [], r')
          | _, _, _ => none
      | some (args, .kw .semi :: r1) =>
        if removedOps.contains n || (coreOps.contains n && !(fieldCallOps.contains n)) ||
            (tparams c.S n).isSome then none
        else
          match allPos args, pFields c f r1 with
          | some vs, some (fs, .kw .rp :: r2) =>
            if fieldsOK fs && callCond c n (insKV ("args", .arr vs) (insKV ("op", .str n) fs)) then
              some (mkNode n vs fs, r2)
            else none
          | _, _ => none
      | _ => none
    else if t0 matches .kw .us then
      if n = "D" then pDCall c f r else none
    else if bareOK c.S n then some (tNode n [], t0 :: r)
    else none
  | _ + 1, n, [] => if bareOK c.S n then some (tNode n [], []) else none

/-- `\partial_{x}(u, a, b)`, and the earlier `\operatorname{D}_{x}(u, a, b)` (read, never
printed), after the `_`: `partial` with trailing operands. -/
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
      match r with
      | .units l :: r' => some (qty n l, r')
      | _ => some (.num n, r)
    | .kw .bmat :: r =>
      match pGrid .amp .nl .emat (r.length + 1) r with
      | some (rows, r') => if rows.all (·.length ≤ bmatCols) then constTail (gridJson rows) r' else none
      | none => none
    | .kw .lbkg :: .kw (.barrC n) :: r =>
      match pGrid .amp .nl .earr (r.length + 1) r with
      | some (rows, .kw .rbkg :: r') =>
        if bmatCols < n && rows.all (·.length == n) then
          constTail (.arr (rows.map fun q => .arr (q.map .num))) r'
        else none
      | _ => none
    | .kw .vec :: t :: r =>
      if isLp t then
        match pCells .comma r with
        | some (ns, .kw .rp :: r') => constTail (.arr (ns.map .num)) r'
        | _ => none
      else none
    | .kw .mat :: .kw .lp :: .word "delim" :: .kw .colon :: .txt "[" :: .kw .comma :: .word "augment" ::
        .kw .colon :: .code (.num (.int 1)) :: .kw .comma :: r =>
      match pMkRows c f .comma .semi .rp r with
      | some (rows, r') => mkTail c.sf rows r'
      | none => none
    | .kw .mat :: t :: r =>
      if isLp t then
        match pGrid .comma .semi .rp (r.length + 1) r with
        | some (rows, r') => constTail (.arr (rows.map fun q => .arr (q.map .num))) r'
        | none => none
      else none
    | .txt "true" :: r => some (node "true" [], r)
    | .txt "false" :: r => some (node "false" [], r)
    | .kw .lpg :: r | .kw .lp :: r =>
      match c.sf, r with
      | .typst, .kw .dif :: r1 => pDT c f .dif r1
      | .typst, .kw .pdiff :: .kw .us :: _ =>
        match pOr c f r with
        | some (x, t :: r') => if isRp t then some (x, r') else none
        | _ => none
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
    | .kw .pdiff :: .kw .us :: r => pDCall c f r
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
      if t matches .kw .lp then
        match pList c f 1 r with
        | some (xs, .kw .rp :: r') => if 2 ≤ xs.length then some (node "min" xs, r') else none
        | _ => none
      else pRed c f ts
    | .kw .max :: t :: r =>
      if t matches .kw .lp then
        match pList c f 1 r with
        | some (xs, .kw .rp :: r') => if 2 ≤ xs.length then some (node "max" xs, r') else none
        | _ => none
      else pRed c f ts
    | .kw .lbkg :: .kw .barr :: r =>
      match pMkRows c f .amp .nl .earr r with
      | some (rows, .kw .rbkg :: r') => mkTail c.sf rows r'
      | _ => none
    | .kw .sum :: _ | .kw .prod :: _ | .kw .limits :: _ | .kw .lbkg :: _ => pRed c f ts
    | .kw .lr :: .kw .lp :: .kw .lbk :: _ => pRed c f ts
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

/-- One segment of an index set's name: an upright word that `upSet` sets upright, or a
name segment. The two never overlap: `pSeg` reads an upright token only as a formula, and
`upSet` excludes formulas. -/
def pSetSeg (sf : Sf) (ts : List Tok) : Option (List Char × List Tok) :=
  match ts with
  | .ups [(g, "")] :: r => if upSet sf g.toList then some (g.toList, r) else pSeg sf ts
  | _ => pSeg sf ts

/-- The segments of an index set's name after the first, joined by the scope dot. -/
def pSetLoop (sf : Sf) : Nat → List Char → List Tok → Option (List Char × List Tok)
  | 0, _, _ => none
  | f + 1, acc, ts =>
    match ts with
    | .kw .sdot :: r =>
      match pSetSeg sf r with
      | some (g, r') => pSetLoop sf f (acc ++ '.' :: g) r'
      | none => none
    | _ => some (acc, ts)

/-- An index set's name (see `setToks`): a name whose segments may also be upright words
in Typst (`upright("lev")`, `upright("lev")"."upright("top")`). -/
def pSet (sf : Sf) (ts : List Tok) : Option (String × List Tok) :=
  match pSetSeg sf ts with
  | some (g, r) => (pSetLoop sf (r.length + 1) g r).map fun p => (String.ofList p.1, p.2)
  | none => none

/-- A range row: `k \in S`, `k \in S(i, j)`, `a \le k \le b`. -/
def pRange (c : Ctx) : Nat → List Tok → Option (Row × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pAdd c f ts with
    | some (.str k, .kw .inn :: r) =>
      match pSet c.sf r with
      | some (s, .kw .lp :: r2) =>
        match pNames c.sf (r2.length + 1) r2 with
        | some (ps, .kw .rp :: r3) => some (.rng k (.obj [("from", .str s), ("of", .arr (ps.map .str))]), r3)
        | _ => none
      | some (s, r2) => some (.rng k (.obj [("from", .str s)]), r2)
      | none => none
    | some (a, .kw .le :: r) =>
      match pAdd c f r with
      | some (.str k, .kw .le :: r2) =>
        match pAdd c f r2 with
        | some (b, r3) => some (.rng k (.arr [a, b]), r3)
        | none => none
      | _ => none
    | _ => none

/-- A row ending at a token `isEnd` accepts: an expression read whole first (it never
reads a range row whole: a range row has `\in` or a second `\le`), else a range. -/
def pRow (c : Ctx) : Nat → (Tok → Bool) → List Tok → Option (Row × List Tok)
  | 0, _, _ => none
  | f + 1, isEnd, ts =>
    match pOr c f ts with
    | some (x, t :: r) => if isEnd t then some (.filt x, t :: r) else pRange c f ts
    | _ => pRange c f ts

/-- Rows separated by `sep`, up to `close` (consumed). -/
def pRows (c : Ctx) : Nat → Kw → Kw → List Tok → Option (List Row × List Tok)
  | 0, _, _, _ => none
  | f + 1, sep, close, ts =>
    match pRow c f (fun t => isKw sep t || isKw close t) ts with
    | some (row, .kw k :: r) =>
      if k = sep then (pRows c f sep close r).map fun p => (row :: p.1, p.2)
      else if k = close then some ([row], r) else none
    | _ => none

/-- A reduction after its operator: the subscript rows (LaTeX: one row, a lone dense
range `k=a` with `^{b}`, or `\substack`; Typst: rows in `_( … )`), then the body. -/
def pRedBody (c : Ctx) : Nat → RedK → Bool → List Tok → Option (FaqForm × List Tok)
  | 0, _, _, _ => none
  | f + 1, red, marked, ts =>
    let rows : Option (List Row × List Tok) :=
      match c.sf with
      | .latex =>
        match ts with
        | .kw .us :: .kw .lb :: .kw .substack :: .kw .lb :: r =>
          match pRows c f .nl .rb r with
          | some (rs, .kw .rb :: r') => some (rs, r')
          | _ => none
        | .kw .us :: .kw .lb :: r =>
          match pRow c f (isKw .rb) r with
          | some (.filt (.obj [("args", .arr [.str k, a]), ("op", .str "==")]), .kw .rb :: .kw .caret :: .kw .lb :: r2) =>
            match r2 with
            | .kw .lset :: r3 =>
              some ([.filt (.obj [("args", .arr [.str k, a]), ("op", .str "==")])],
                .kw .caret :: .kw .lb :: .kw .lset :: r3)
            | _ =>
              match pOr c f r2 with
              | some (b, .kw .rb :: r3) => some ([.rng k (.arr [a, b])], r3)
              | _ => none
          | some (row, .kw .rb :: r2) => some ([row], r2)
          | _ => none
        | r => some ([], r)
      | .typst =>
        match ts with
        | .kw .us :: .kw .lpg :: r => pRows c f .nl .rp r
        | r => some ([], r)
    match rows with
    | some (rs, r) =>
      match rowParts rs, pSup c.sf r with
      | some (rg, fl), some (st, r1) =>
        if marked && !st.isEmpty then none
        else
          match pMul c f r1 with
          | some (body, r') => some (⟨red, marked, [], rg, body, fl, st⟩, r')
          | none => none
      | _, _ => none
    | none => none

/-- A rank-0 reduction, or a reduction wrapped with its output entries. -/
def pRed (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match ts with
    | .kw .lbkg :: r =>
      match pRedHead c.sf r with
      | some (red, marked, r1) =>
        match pRedBody c f red marked r1 with
        | some (F, .kw .rbkg :: r1) =>
          match pSup c.sf r1 with
          | some (st, .kw .us :: .kw .lb :: r2) =>
            match pRows c f .comma .rb r2 with
            | some (es, r3) =>
              if bracketSetOK F st then
                (entryParts es).map fun p => (faqJson (withSup (withOut F p.1 p.2) st), r3)
              else none
            | none => none
          | _ => none
        | _ => none
      | none => none
    | .kw .lr :: .kw .lp :: .kw .lbk :: r =>
      match pRedHead c.sf r with
      | some (red, marked, r1) =>
        match pRedBody c f red marked r1 with
        | some (F, .kw .rbk :: .kw .rp :: r1) =>
          match pSup c.sf r1 with
          | some (st, .kw .us :: .kw .lpg :: r2) =>
            match pRows c f .comma .rp r2 with
            | some (es, r3) =>
              if bracketSetOK F st then
                (entryParts es).map fun p => (faqJson (withSup (withOut F p.1 p.2) st), r3)
              else none
            | none => none
          | _ => none
        | _ => none
      | none => none
    | _ =>
      match pRedHead c.sf ts with
      | some (red, marked, r1) => (pRedBody c f red marked r1).map fun p => (faqJson p.1, p.2)
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
  | f + 1, .kw .pdiff :: .kw .us :: r =>
    match pOr c f (.kw .pdiff :: .kw .us :: r) with
    | some (x, .kw .rb :: .kw .lb :: r1) =>
      match pOr c f r1 with
      | some (y, .kw .rb :: r2) => some (node "/" [x, y], r2)
      | _ => none
    | _ => none
  | f + 1, .kw .pdiff :: r =>
    match pOr c f r with
    | some (x, .kw .rb :: .kw .lb :: .kw .pdiff :: r1) =>
      match pName c.sf r1 with
      | some (w, .kw .rb :: r') => some (derivNode x w, r')
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
        | some (w, .kw .rp :: r') => if k = .dif && w != "t" then none else some (derivNode x w, r')
        | _ => none
      else none
    | _ => none

/-- A derivative operator applied to a parenthesized operand. -/
def pDApply (c : Ctx) : Nat → String → List Tok → Option (Json × List Tok)
  | 0, _, _ => none
  | f + 1, w, .kw .lpg :: r =>
    match pOr c f r with
    | some (x, t :: r') => if isRp t then some (derivNode x w, r') else none
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

/-- A bound pair after its `[`: `a, b]`. -/
def pPair (c : Ctx) : Nat → List Tok → Option ((Json × Json) × List Tok)
  | 0, _ => none
  | f + 1, ts =>
    match pOr c f ts with
    | some (a, .kw .comma :: r) =>
      match pOr c f r with
      | some (b, .kw .rbk :: r') => some ((a, b), r')
      | _ => none
    | _ => none

/-- The further bound pairs of a region, each after `\times [`. -/
def pRegTail (c : Ctx) : Nat → List Tok → Option (List (Json × Json) × List Tok)
  | 0, _ => none
  | f + 1, .kw .times :: .kw .lbk :: r =>
    match pPair c f r with
    | some (p, r') => (pRegTail c f r').map fun q => (p :: q.1, q.2)
    | none => none
  | _ + 1, r => some ([], r)

/-- The rows of a `makearray` table: a value, the cell separator `csep`, a region; rows
separated by `rsep`, up to `close` (consumed). -/
def pMkRows (c : Ctx) : Nat → Kw → Kw → Kw → List Tok → Option (List (Json × List (Json × Json)) × List Tok)
  | 0, _, _, _, _ => none
  | f + 1, csep, rsep, close, ts =>
    match pOr c f ts with
    | some (v, .kw k :: .kw .lbk :: r) =>
      if k = csep then
        match pPair c f r with
        | some (p, r1) =>
          match pRegTail c f r1 with
          | some (ps, .kw k2 :: r2) =>
            if k2 = rsep then (pMkRows c f csep rsep close r2).map fun q => ((v, p :: ps) :: q.1, q.2)
            else if k2 = close then some ([(v, p :: ps)], r2) else none
          | _ => none
        | none => none
      else none
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
