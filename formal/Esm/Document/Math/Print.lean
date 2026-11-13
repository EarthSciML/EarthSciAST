import Esm.Document.Math.Token

/-!
# The printer: expressions to tokens

`pa c L e` prints the expression `e` for a position that needs precedence level at
least `L`, adding grouping parentheses when `e`'s own level is lower. The levels,
loosest first (spec §4.1.1, `Notation.precedence`):

| level | construct |
|---|---|
| 1 | `or` chain |
| 2 | `and` chain |
| 3 | a comparison |
| 4 | `+` chain, binary `-` |
| 5 | `*` chain (juxtaposition, `\cdot` before a factor that starts with a digit or sign), unary `-` |
| 6 | `not`; a derivative applied to a parenthesized operand |
| 7 | Typst fraction `a/b` and Typst `(dif N)/(dif t)`; a negative literal and a quantity (as the base of a power or an index they are parenthesized, and as a Typst fraction operand) |
| 8 | power |
| 9 | index (subscript or brackets) |
| 10 | atoms: names, numbers, groups, function forms, LaTeX fractions, cases, calls, escapes |

Operands of an n-ary chain are printed one level tighter, so a nested chain of the
same operator keeps its parentheses and the JSON tree is kept exactly (the parser
flattens a chain into one node). Binary `-` takes its left operand at its own level
(`a + b - c`), its right operand one tighter.

Which notation a node gets is decided from its exact JSON shape; anything without a
native or call notation prints in the generic escape form, which every node has.
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## Text pieces -/

/-- The characters escaped by a backslash inside `\mathit{}`, `\operatorname{}`,
`\esm{}` and a name subscript's `\mathrm{}`. -/
def escSet (c : Char) : Bool := c = '_' || c = '^' || c = '\\' || c = '{' || c = '}'

/-- Escape the text of `\mathit{}` and the like. -/
def escT : List Char → List Char
  | [] => []
  | c :: cs => (if escSet c then ['\\', c] else [c]) ++ escT cs

/-- Undo `escT`. -/
def unescT : List Char → List Char
  | '\\' :: c :: cs => c :: unescT cs
  | c :: cs => c :: unescT cs
  | [] => []

theorem unescT_escT (s : List Char) : unescT (escT s) = s := by
  induction s with
  | nil => rfl
  | cons c cs ih =>
    by_cases h : escSet c = true
    · simp [escT, h, unescT, ih]
    · simp only [escT, h, Bool.false_eq_true, ite_false, List.singleton_append]
      have : c ≠ '\\' := fun e => h (by simp [escSet, e])
      cases hc : escT cs with
      | nil => simp [hc] at ih; subst ih; simp [unescT]
      | cons d ds =>
        rw [← hc]
        cases c; simp_all [unescT]

/-- The digits of a natural number. -/
def natChars (n : Nat) : List Char := Number.printNat n

/-! ## The printing context -/

structure Ctx where
  sf : Sf
  S : Sym

/-- Grouping parentheses. -/
def grp (sf : Sf) (ts : List Tok) : List Tok :=
  .kw .lpg :: ts ++ [.kw (if sf = .latex then .rpg else .rp)]

/-- The closing token of a grouping parenthesis. -/
def rpG (sf : Sf) : Tok := .kw (if sf = .latex then .rpg else .rp)

/-- Items joined by a separator. -/
def sepBy (sep : List Tok) : List (List Tok) → List Tok
  | [] => []
  | [x] => x
  | x :: xs => x ++ sep ++ sepBy sep xs

/-! ## Names -/

/-- A single letter or a Greek name as a token. -/
def baseTok (g : List Char) : Tok :=
  match g with
  | [c] => .letter c
  | _ => .greek (String.ofList g)

/-- The subscript text of a name: upright. -/
def subTxt (sf : Sf) (r : List Char) : List Tok :=
  match sf with
  | .latex => [.kw .us, .kw .lb, .rm (String.ofList (escT r)), .kw .rb]
  | .typst => [.kw .us, .kw .lpg, .ups [(String.ofList r, "")], .kw .rp]

/-- The raw `\mathrm{}` content of a formula: counts as `_{n}`. -/
def formulaRaw (g : List Char) : List Char :=
  (pieces g).flatMap (fun p => p.1 ++ (if p.2 = [] then [] else '_' :: '{' :: p.2 ++ ['}']))

/-- A formula name. -/
def formTok (sf : Sf) (g : List Char) : Tok :=
  match sf with
  | .latex => .rm (String.ofList (formulaRaw g))
  | .typst => .ups ((pieces g).map fun p => (String.ofList p.1, String.ofList p.2))

/-- One segment of a name, by its shape. -/
def segToks (sf : Sf) (g : List Char) : List Tok :=
  if isSingle g then [baseTok g]
  else match subParts g with
    | some (b, r) => baseTok b :: subTxt sf r
    | none => if isFormula g then [formTok sf g] else [.it (String.ofList g)]

/-- A name never prints bare where the parser would read it otherwise: an undeclared
`e` (bare `e^{x}` reads as `exp`) and an undeclared `d` (bare `\frac{d N}{d t}` reads
as a derivative) print in the explicit form. -/
def explicitName (S : Sym) (s : String) : Bool :=
  (s == "e" || s == "d") && !(S.names.contains s)

def nameToks (c : Ctx) (s : String) : List Tok :=
  if explicitName c.S s then [.it s]
  else sepBy [.kw .sdot] ((splitDots s.toList).map (segToks c.sf))

/-- The last segment of a name prints with no subscript, so an index subscript may
follow it. -/
def plainLast (s : String) : Bool :=
  match (splitDots s.toList).getLast? with
  | some g => isSingle g || (subParts g == none && !isFormula g)
  | none => false

/-! ## JSON inside escape nodes (LaTeX) -/

theorem sizeOf_snd_lt_obj {kv : String × Json} {kvs : List (String × Json)} (h : kv ∈ kvs) :
    sizeOf kv.2 < 1 + sizeOf kvs := by
  have := List.sizeOf_lt_of_mem h
  obtain ⟨k, v⟩ := kv
  simp only [Prod.mk.sizeOf_spec] at *; omega

mutual
def jsonToks : Json → List Tok
  | .null => [.word "null"]
  | .bool true => [.word "true"]
  | .bool false => [.word "false"]
  | .num n => [.num n]
  | .str s => [.jstr s]
  | .arr xs => .kw .lbk :: jsonItems xs ++ [.kw .rbk]
  | .obj kvs => .kw .lb :: jsonEntries kvs ++ [.kw .rb]

def jsonItems : List Json → List Tok
  | [] => []
  | [v] => jsonToks v
  | v :: vs => jsonToks v ++ .kw .comma :: jsonItems vs

def jsonEntries : List (String × Json) → List Tok
  | [] => []
  | [(k, v)] => .jstr k :: .kw .colon :: jsonToks v
  | (k, v) :: es => .jstr k :: .kw .colon :: jsonToks v ++ .kw .comma :: jsonEntries es
end

/-! ## Operator tables -/

/-- Unary functions with a native spelling, and their keyword. -/
def fnKw : List (String × Kw) :=
  [("exp", .exp), ("log", .ln), ("sin", .sin), ("cos", .cos), ("tan", .tan), ("asin", .asin),
    ("acos", .acos), ("atan", .atan), ("sinh", .sinh), ("cosh", .cosh), ("tanh", .tanh)]

/-- Comparisons and their token. -/
def cmpKw : List (String × Kw) :=
  [("<", .lt), ("<=", .le), (">", .gt), (">=", .ge), ("==", .eq), ("!=", .ne)]

/-- Core operators in the call form. -/
def callOps : List String := ["sign", "atan2", "asinh", "acosh", "atanh", "Pre", "enum"]

/-- Names `\operatorname{…}` never means a template or an open operator by. -/
def reservedOpn : List String := callOps ++ ["D", "neg", "pow"] ++ removedOps

/-- `coreOpNames` of `Notation`. -/
def coreOps : List String :=
  ["+", "-", "*", "/", "^", "pow", "neg",
  "<", "<=", ">", ">=", "==", "!=", "and", "or", "not", "true", "false", "ifelse",
  "exp", "log", "log10", "sqrt", "abs", "sign", "floor", "ceil",
  "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh",
  "asinh", "acosh", "atanh", "atan2", "min", "max",
  "D", "ic", "Pre", "enum", "const",
  "faq", "makearray", "index", "broadcast", "reshape", "transpose", "concat",
  "apply_expression_template"]

/-- A name `\operatorname{…}` can carry: identifier characters and dots. -/
def opnOK (s : String) : Bool :=
  match s.toList with
  | [] => false
  | c :: cs => isIdStart c && cs.all (fun d => isIdChar d || d == '.')

/-- A field key printed upright in a call: an identifier. -/
def keyOK (s : String) : Bool := segOK s.toList

/-- Sorted insertion by key. -/
def insKV (kv : String × Json) : List (String × Json) → List (String × Json)
  | [] => [kv]
  | e :: r => if kv.1 < e.1 then kv :: e :: r else e :: insKV kv r

/-- The fields of a node other than `op` and `args`. -/
def fieldsOf (kvs : List (String × Json)) : List (String × Json) :=
  kvs.filter (fun kv => kv.1 != "op" && kv.1 != "args")

/-- A node from its operator, operands and other fields (sorted keys). -/
def mkNode (o : String) (as : List Json) (fs : List (String × Json)) : Json :=
  .obj (insKV ("args", .arr as) (insKV ("op", .str o) fs))

/-- The plain two-field node. -/
def node (o : String) (as : List Json) : Json := .obj [("args", .arr as), ("op", .str o)]

def isNegNum : Json → Bool
  | .num (.int z) => decide (z < 0)
  | .num (.dec neg _ _) => neg
  | _ => false

/-- Typst exponent and subscript tokens that need no parentheses: a nonnegative number
in positional spelling, a letter, a Greek name. -/
def simpleTok : Tok → Bool
  | .num (.int z) => decide (0 ≤ z)
  | .num (.dec neg _ e10) => !neg && decide (-4 ≤ e10) && decide (e10 ≤ 5)
  | .letter _ => true
  | .greek _ => true
  | _ => false

def startsNum : List Tok → Bool
  | .num _ :: _ => true
  | _ => false

/-- The template parameter list, when the symbol table knows it. -/
def tparams (S : Sym) (n : String) : Option (List String) :=
  (S.templates.find? (·.1 == n)).map (·.2)

/-- Positional template arguments: the table knows the parameters, they are distinct,
and the bindings bind exactly them. -/
def positional (S : Sym) (n : String) (bs : List (String × Json)) : Option (List String) :=
  match tparams S n with
  | some ps =>
    if ps.Nodup ∧ ps.length = bs.length ∧ ps.all (fun p => (look p bs).isSome) then some ps
    else none
  | none => none

/-- Balanced text up to the `}` that closes depth 0; `\x` is one unit. -/
def rawB : Nat → List Char → Option (List Char × List Char)
  | d, '\\' :: c :: r => (rawB d r).map fun p => ('\\' :: c :: p.1, p.2)
  | 0, '}' :: r => some ([], r)
  | d + 1, '}' :: r => (rawB d r).map fun p => ('}' :: p.1, p.2)
  | d, '{' :: r => (rawB (d + 1) r).map fun p => ('{' :: p.1, p.2)
  | d, c :: r => (rawB d r).map fun p => (c :: p.1, p.2)
  | _, [] => none

/-- Raw text that `rawB` reads back whole (the LaTeX lexer reads `\mathrm{…}` and
`\text{…}` contents with `rawB`). -/
def balOK (raw : List Char) : Bool := rawB 0 (raw ++ ['}']) == some (raw, [])

/-- The two-sided factor list of a units string (`[]` when it does not parse). -/
def factorsOf (u : String) : List Esm.Units.Factor :=
  match Esm.Units.parseChars u.toList with
  | .ok t => Esm.Units.norm2 t.factors
  | .error _ => []

/-- The units of a quantity print typeset when the string is the canonical spelling of
a non-dimensionless unit whose typeset form reads back (Phase 1: every canonical unit
does). -/
def unitsOK (sf : Sf) (u : String) : Bool :=
  let l := factorsOf u
  l != [] && Esm.Units.spell l == u &&
    l.all (fun f => Esm.Units.symOK f.1 && f.2 != 0) &&
    (match sf with
     | .latex => Esm.Units.parseLatex (Esm.Units.latex l) == some l && balOK (Esm.Units.latexBody l)
     | .typst => Esm.Units.numFactors l ++ Esm.Units.denFactors l == l)

/-! ## The printer -/

/-- Wrap a printed form for a position needing level `L`. -/
def wrap (sf : Sf) (L : Nat) (p : Nat × List Tok) : List Tok :=
  if L ≤ p.1 then p.2 else grp sf p.2

/-- A `*` chain: juxtaposition, `\cdot` before a factor that starts with a number. -/
def mulToks : List (List Tok) → List Tok
  | [] => []
  | x :: xs => x ++ xs.flatMap (fun y => if startsNum y then .kw .cdot :: y else y)

/-- Size bookkeeping for the recursion. -/
theorem sizeOf_lt_arr {a : Json} {as : List Json} (h : a ∈ as) :
    sizeOf a < sizeOf (Json.arr as) := by
  have := List.sizeOf_lt_of_mem h
  simp only [Json.arr.sizeOf_spec]; omega

theorem sizeOf_lt_obj {kv : String × Json} {kvs : List (String × Json)} (h : kv ∈ kvs) :
    sizeOf kv.2 < sizeOf (Json.obj kvs) := by
  have := List.sizeOf_lt_of_mem h
  obtain ⟨k, v⟩ := kv
  simp only [Json.obj.sizeOf_spec, Prod.mk.sizeOf_spec] at *; omega

theorem look_mem {k : String} {kvs : List (String × Json)} {v : Json}
    (h : look k kvs = some v) : (k, v) ∈ kvs := by
  induction kvs with
  | nil => simp [look] at h
  | cons e r ih =>
    obtain ⟨k', v'⟩ := e
    simp only [look] at h
    split at h
    · cases h; subst_vars; simp
    · exact List.mem_cons_of_mem _ (ih h)

theorem look_arr_lt {k : String} {kvs : List (String × Json)} {as : List Json} {a : Json}
    (hk : look k kvs = some (.arr as)) (h : a ∈ as) : sizeOf a < 1 + sizeOf kvs := by
  have h1 := sizeOf_snd_lt_obj (look_mem hk)
  have h2 := List.sizeOf_lt_of_mem h
  simp only [Json.arr.sizeOf_spec] at h1; omega

theorem fields_lt {kv : String × Json} {kvs : List (String × Json)} (h : kv ∈ fieldsOf kvs) :
    sizeOf kv.2 < 1 + sizeOf kvs :=
  sizeOf_snd_lt_obj (List.mem_of_mem_filter h)

theorem snd_lt (kv : String × Json) : sizeOf kv.2 < sizeOf kv := by
  obtain ⟨k, v⟩ := kv; simp only [Prod.mk.sizeOf_spec]; omega

/-- How a plain node (`op` and `args` only) prints, by its operator. -/
inductive OpK where
  | minus | div | pow | lnot | tru | fls | ite | ic | index
  | cmp (k : Kw) | un (k : Kw) | plus | times | land | lor | mm (k : Kw) | call | other
  deriving DecidableEq

/-- Unary functions with a native spelling: their keyword (`log10` is `\log_{10}`). -/
def unKw : List (String × Kw) :=
  fnKw ++ [("log10", .log), ("sqrt", .sqrt), ("abs", .abs), ("floor", .floor), ("ceil", .ceil)]

/-- The plain-node operators with their own notation. -/
def kindTable : List (String × OpK) :=
  [("-", .minus), ("/", .div), ("^", .pow), ("not", .lnot), ("true", .tru), ("false", .fls),
    ("ifelse", .ite), ("ic", .ic), ("index", .index), ("+", .plus), ("*", .times),
    ("and", .land), ("or", .lor), ("min", .mm .min), ("max", .mm .max)]

def kindOf (o : String) : OpK :=
  match cmpKw.lookup o, unKw.lookup o, kindTable.lookup o with
  | some k, _, _ => .cmp k
  | none, some k, _ => .un k
  | none, none, some k => k
  | none, none, none => if callOps.contains o then .call else .other

/-- The printed form of an expression and its level. `crow` is the form as the last
rows of a `cases` block: an `ifelse` chain contributes its rows, anything else is the
`otherwise` row. -/
structure Out where
  lvl : Nat
  toks : List Tok
  crow : List Tok

def mkOut (_sf : Sf) (l : Nat) (t : List Tok) : Out :=
  ⟨l, t, t ++ [.kw .amp, .txt "otherwise"]⟩

def Out.at (sf : Sf) (L : Nat) (o : Out) : List Tok := wrap sf L (o.lvl, o.toks)

/-- The escape form: LaTeX `\esm{op}{fields}{args}` with the fields as JSON, Typst
`esm.node("op", #(fields), args)`. -/
def escToks (sf : Sf) (o : String) (fs : List (String × Json)) (args : List (List Tok)) :
    List Tok :=
  match sf with
  | .latex => [.esc o, .kw .lb] ++ jsonToks (.obj fs) ++ [.kw .rb, .kw .lb] ++
      sepBy [.kw .comma] args ++ [.kw .rb]
  | .typst => [.kw .esmnode, .kw .lp, .txt o, .kw .comma, .code (.obj fs)] ++
      args.flatMap (fun a => .kw .comma :: a) ++ [.kw .rp]

/-- The call parenthesis `(` (LaTeX `(`, Typst `(` right after a name). -/
def lpC (_sf : Sf) : Tok := .kw .lp

/-- A call: `name(args)` with call parentheses. -/
def callToks (sf : Sf) (head : List Tok) (args : List (List Tok)) : List Tok :=
  head ++ [lpC sf] ++ sepBy [.kw .comma] args ++ [.kw .rp]

/-- A unary function applied to the printed operand `t`. -/
def unToks (sf : Sf) (k : Kw) (t : List Tok) : List Tok :=
  match sf, k with
  | .latex, .sqrt => [.kw .sqrt, .kw .lb] ++ t ++ [.kw .rb]
  | .latex, .abs => [.kw .labs] ++ t ++ [.kw .rabs]
  | .latex, .floor => [.kw .lfloor] ++ t ++ [.kw .rfloor]
  | .latex, .ceil => [.kw .lceil] ++ t ++ [.kw .rceil]
  | .latex, .log => [.kw .log, .kw .us, .kw .lb, .num (.int 10), .kw .rb] ++ callToks sf [] [t]
  | .typst, .log => [.kw .log, .kw .us, .num (.int 10)] ++ callToks sf [] [t]
  | _, k => callToks sf [.kw k] [t]

/-- One cases row, `value & \text{if } condition`, then the row break. -/
def caseRow (sf : Sf) (v cnd : List Tok) : List Tok :=
  v ++ [.kw .amp, .txt "if "] ++ cnd ++ [.kw (if sf = .latex then .nl else .comma)]

def casesToks (sf : Sf) (rows : List Tok) : List Tok :=
  match sf with
  | .latex => .kw .bcases :: rows ++ [.kw .ecases]
  | .typst => [.kw .cases, .kw .lp] ++ rows ++ [.kw .rp]

/-- `t_{0}` in an initial condition `N(t_{0})`. -/
def icTail (sf : Sf) : List Tok :=
  match sf with
  | .latex => [.kw .lp, .letter 't', .kw .us, .kw .lb, .num (.int 0), .kw .rb, .kw .rp]
  | .typst => [.kw .lp, .letter 't', .kw .us, .num (.int 0), .kw .rp]

/-- A subscript list: LaTeX `_{a, b}`; Typst `_a` for one simple token, else `_(a, b)`. -/
def subList (sf : Sf) (simp : Option Tok) (args : List (List Tok)) : List Tok :=
  match sf with
  | .latex => [.kw .us, .kw .lb] ++ sepBy [.kw .comma] args ++ [.kw .rb]
  | .typst =>
    match simp with
    | some t => [.kw .us, t]
    | none => [.kw .us, .kw .lpg] ++ sepBy [.kw .comma] args ++ [.kw .rp]

/-- The one token a Typst exponent or subscript may be written as without
parentheses: a nonnegative number in positional spelling, or a one-letter or Greek
name. -/
def simpleE (c : Ctx) : Json → Option Tok
  | .num n => if simpleTok (.num n) then some (.num n) else none
  | .str s =>
    match nameToks c s with
    | [t] => if simpleTok t then some t else none
    | _ => none
  | _ => none

def simpleArg (c : Ctx) : List Json → Option Tok
  | [x] => simpleE c x
  | _ => none

/-- The index prints with a subscript unless the base is not a plain name, or the
subscript would collide with a name: one formula-shaped name (it would read as the
upright subscript of a name), or one digit literal `n` when `base_n` is declared
(`k_{1}` would look like the name `k_1`; decision 5). -/
def subOK (S : Sym) (base : Json) (is : List Json) : Bool :=
  match base with
  | .str b =>
    nameOK b && plainLast b && !explicitName S b &&
    (match is with
     | [.str x] => !((splitDots x.toList).length == 1 && isFormula x.toList)
     | [.num (.int n)] => !(decide (0 ≤ n) && S.names.contains (b ++ "_" ++ toString n))
     | _ => true)
  | _ => false

/-- Four tokens of an upright name subscript. -/
def subPat4 (sf : Sf) : Tok → Tok → Tok → Tok → Bool
  | .kw .us, .kw .lb, .rm _, .kw .rb => sf == .latex
  | .kw .us, .kw .lpg, .ups [(_, "")], .kw .rp => sf == .typst
  | _, _, _, _ => false

/-- An upright name subscript: a name before it would read it as part of the name. -/
def subPat (sf : Sf) : List Tok → Bool
  | t1 :: t2 :: t3 :: t4 :: _ => subPat4 sf t1 t2 t3 t4
  | _ => false

/-- Derivative operand printed inline (`\frac{\mathrm{d} N}{\mathrm{d} t}`) when it is
postfix-level or tighter, and not a negative literal. -/
def inlineD (o : Out) : Bool := decide (9 ≤ o.lvl)

/-- A field key, upright. -/
def keyToks (sf : Sf) (k : String) : List Tok :=
  match sf with
  | .latex => [.rm (String.ofList (escT k.toList))]
  | .typst => [.ups [(k, "")]]

/-- A field value that is not an expression, as JSON. -/
def jsonVal (sf : Sf) (v : Json) : List Tok :=
  match sf with
  | .latex => jsonToks v
  | .typst => [.code v]

/-- The open-operator call: positional operands, then `;` and the fields. -/
def openToks (sf : Sf) (o : String) (args fields : List (List Tok)) : List Tok :=
  [.opn o, lpC sf] ++ sepBy [.kw .comma] args ++
    (if fields = [] then [] else .kw .semi :: sepBy [.kw .comma] fields) ++ [.kw .rp]

/-- The time derivative. -/
def dTime (sf : Sf) (a : Out) : Out :=
  match sf with
  | .latex =>
    if inlineD a then
      mkOut sf 10 ([.kw .frac, .kw .lb, .rm "d"] ++ a.at sf 1 ++ [.kw .rb, .kw .lb, .rm "d", .letter 't', .kw .rb])
    else
      mkOut sf 6 ([.kw .frac, .kw .lb, .rm "d", .kw .rb, .kw .lb, .rm "d", .letter 't', .kw .rb] ++ grp sf (a.at sf 1))
  | .typst =>
    if inlineD a then
      mkOut sf 7 ([.kw .lpg, .kw .dif] ++ a.at sf 1 ++ [.kw .rp, .kw .slash, .kw .lpg, .kw .dif, .letter 't', .kw .rp])
    else
      mkOut sf 6 ([.kw .lpg, .kw .dif, .kw .rp, .kw .slash, .kw .lpg, .kw .dif, .letter 't', .kw .rp] ++ grp sf (a.at sf 1))

/-- The spatial derivative along the axis printed `w`. -/
def dSpace (sf : Sf) (w : List Tok) (a : Out) : Out :=
  match sf with
  | .latex =>
    if inlineD a then
      mkOut sf 10 ([.kw .frac, .kw .lb, .kw .pdiff] ++ a.at sf 1 ++ [.kw .rb, .kw .lb, .kw .pdiff] ++ w ++ [.kw .rb])
    else
      mkOut sf 6 ([.kw .frac, .kw .lb, .kw .pdiff, .kw .rb, .kw .lb, .kw .pdiff] ++ w ++ [.kw .rb] ++ grp sf (a.at sf 1))
  | .typst =>
    if inlineD a then
      mkOut sf 7 ([.kw .lpg, .kw .pdiff] ++ a.at sf 1 ++ [.kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] ++ w ++ [.kw .rp])
    else
      mkOut sf 6 ([.kw .lpg, .kw .pdiff, .kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] ++ w ++ [.kw .rp] ++ grp sf (a.at sf 1))

/-- A spatial derivative with trailing operands: `\operatorname{D}_{x}(u, a, b)`. -/
def dCall (sf : Sf) (w : List Tok) (args : List (List Tok)) : List Tok :=
  match sf with
  | .latex => [.opn "D", .kw .us, .kw .lb] ++ w ++ [.kw .rb] ++ callToks sf [] args
  | .typst => [.opn "D", .kw .us, .kw .lpg] ++ w ++ [.kw .rp] ++ callToks sf [] args

/-- The quantity `3\,\mathrm{m/s}` / `3 thin upright("m") thin upright("s")^(-1)`. -/
def qtyToks (sf : Sf) (n : JNum) (l : List Esm.Units.Factor) : List Tok :=
  match sf with
  | .latex => [.num n, .kw .thin, .rm (String.ofList (Esm.Units.latexBody l))]
  | .typst => [.num n, .units l]

/-! ## Constant arrays -/

/-- The entries of a list that are all well-formed numbers. -/
def numsOf : List Json → Option (List JNum)
  | [] => some []
  | .num n :: r => if numOK n then (numsOf r).map (n :: ·) else none
  | _ :: _ => none

/-- The rows of a list of number lists. -/
def rowsOf : List Json → Option (List (List JNum))
  | [] => some []
  | .arr ys :: r =>
    match numsOf ys, rowsOf r with
    | some ns, some rs => some (ns :: rs)
    | _, _ => none
  | _ :: _ => none

/-- The two array shapes with a native spelling. -/
inductive AForm where
  | col (ns : List JNum)
  | mat (rs : List (List JNum))

/-- A constant array printed natively: a column for rank 1, or a matrix of at least
two columns (a single-column matrix would print like a column), at most 16 entries,
every entry a well-formed number. -/
def arrForm : Json → Option AForm
  | .arr xs =>
    match numsOf xs with
    | some ns => if ns ≠ [] ∧ ns.length ≤ 16 then some (.col ns) else none
    | none =>
      match rowsOf xs with
      | some (r :: rs) =>
        if 2 ≤ r.length ∧ rs.all (fun q => q.length == r.length) ∧ (rs.length + 1) * r.length ≤ 16 then
          some (.mat (r :: rs))
        else none
      | _ => none
  | _ => none

def AForm.json : AForm → Json
  | .col ns => .arr (ns.map .num)
  | .mat rs => .arr (rs.map fun r => .arr (r.map .num))

def numToks (ns : List JNum) : List (List Tok) := ns.map fun n => [.num n]

/-- The array: LaTeX `bmatrix`, Typst `vec(…)` / `mat(…)`. -/
def arrToks (sf : Sf) : AForm → List Tok
  | .col ns =>
    match sf with
    | .latex => .kw .bmat :: sepBy [.kw .nl] (numToks ns) ++ [.kw .emat]
    | .typst => [.kw .vec, .kw .lp] ++ sepBy [.kw .comma] (numToks ns) ++ [.kw .rp]
  | .mat rs =>
    match sf with
    | .latex => .kw .bmat :: sepBy [.kw .nl] (rs.map fun r => sepBy [.kw .amp] (numToks r)) ++ [.kw .emat]
    | .typst => [.kw .mat, .kw .lp] ++ sepBy [.kw .semi] (rs.map fun r => sepBy [.kw .comma] (numToks r)) ++
        [.kw .rp]

/-- The unit after a number or an array. -/
def unitToks (sf : Sf) (l : List Esm.Units.Factor) : List Tok :=
  match sf with
  | .latex => [.kw .thin, .rm (String.ofList (Esm.Units.latexBody l))]
  | .typst => [.units l]

/-! ## Reductions (`faq`) -/

mutual
/-- Equality of JSON values as a check. -/
def jbeq : Json → Json → Bool
  | .null, .null => true
  | .bool a, .bool b => a == b
  | .num a, .num b => decide (a = b)
  | .str a, .str b => a == b
  | .arr a, .arr b => jbeqL a b
  | .obj a, .obj b => jbeqO a b
  | _, _ => false

def jbeqL : List Json → List Json → Bool
  | [], [] => true
  | x :: xs, y :: ys => jbeq x y && jbeqL xs ys
  | _, _ => false

def jbeqO : List (String × Json) → List (String × Json) → Bool
  | [], [] => true
  | (k, x) :: xs, (l, y) :: ys => k == l && jbeq x y && jbeqO xs ys
  | _, _ => false
end

/-- The array an `index` node reads, when it names one. -/
def idxBase (kvs : List (String × Json)) : Option String :=
  match look "op" kvs, look "args" kvs with
  | some (.str "index"), some (.arr (.str s :: _)) => some s
  | _, _ => none

mutual
/-- The arrays an expression indexes, in first-use order (appended to `acc`). -/
def basesJ : Json → List String → List String
  | .obj kvs, acc =>
    basesO kvs (match idxBase kvs with
      | some s => if acc.contains s then acc else acc ++ [s]
      | none => acc)
  | .arr xs, acc => basesL xs acc
  | _, acc => acc

def basesL : List Json → List String → List String
  | [], acc => acc
  | x :: xs, acc => basesL xs (basesJ x acc)

def basesO : List (String × Json) → List String → List String
  | [], acc => acc
  | (_, v) :: r, acc => basesO r (basesJ v acc)
end

def bases (e : Json) : List String := basesJ e []

/-- The reductions with a native spelling. -/
inductive RedK where
  | sum | prod | max | min
  deriving DecidableEq

def RedK.kw : RedK → Kw
  | .sum => .sum | .prod => .prod | .max => .max | .min => .min

def RedK.field : RedK → List (String × Json)
  | .sum => []
  | .prod => [("reduce", .str "*")]
  | .max => [("reduce", .str "max")]
  | .min => [("reduce", .str "min")]

/-- A `faq` node with a native spelling, by its parts. `marked`: `args` lists the arrays
the body indexes (otherwise it is empty). -/
structure FaqForm where
  red : RedK
  marked : Bool
  out : List Json
  ranges : List (String × Json)
  expr : Json
  filter : Option Json

def faqJson (F : FaqForm) : Json :=
  .obj ([("args", .arr (if F.marked then (bases F.expr).map .str else [])), ("expr", F.expr)] ++
    (match F.filter with | some x => [("filter", x)] | none => []) ++
    [("op", .str "faq"), ("output_idx", .arr F.out)] ++
    (if F.ranges = [] then [] else [("ranges", .obj F.ranges)]) ++ F.red.field)

/-- The parts a `faq` node would have. -/
def faqCand (kvs : List (String × Json)) : Option FaqForm :=
  match look "expr" kvs, look "output_idx" kvs, look "args" kvs with
  | some e, some (.arr out), some (.arr as) =>
    let red : Option RedK := match look "reduce" kvs with
      | none => some .sum
      | some (.str "*") => some .prod
      | some (.str "max") => some .max
      | some (.str "min") => some .min
      | _ => none
    let rs : Option (List (String × Json)) := match look "ranges" kvs with
      | some (.obj rs) => some rs
      | none => some []
      | _ => none
    match red, rs with
    | some red, some rs => some ⟨red, !as.isEmpty, out, rs, e, look "filter" kvs⟩
    | _, _ => none
  | _, _, _ => none

/-- The parts of a `faq` node, when it is exactly the node they rebuild: no semiring,
join, distinct or key, `reduce` absent or `*`, `max`, `min`, `ranges` absent or not
empty, `args` empty or the arrays the body indexes. -/
def faqForm (kvs : List (String × Json)) : Option FaqForm :=
  match faqCand kvs with
  | some F => if jbeq (faqJson F) (.obj kvs) then some F else none
  | none => none

/-- A range a row can spell: `[a, b]`, `{"from": S}` or `{"from": S, "of": [i, …]}`. -/
def rangeOK : Json → Bool
  | .arr [a, b] => isE a && isE b
  | .obj [("from", .str s)] => nameOK s
  | .obj [("from", .str s), ("of", .arr ps)] =>
    nameOK s && !ps.isEmpty && ps.all (fun p => match p with | .str q => nameOK q | _ => false)
  | _ => false

def outNames (out : List Json) : List String :=
  out.filterMap fun j => match j with | .str k => some k | _ => none

/-- An output entry: a name, or the singleton dimension `1`. -/
def outOK (j : Json) : Bool :=
  match j with
  | .str k => nameOK k
  | .num (.int 1) => true
  | _ => false

mutual
/-- A bare name occurs in an expression. -/
def occursJ (k : String) : Json → Bool
  | .str s => s == k
  | .arr xs => occursL k xs
  | .obj kvs => occursO k kvs
  | _ => false

def occursL (k : String) : List Json → Bool
  | [] => false
  | x :: xs => occursJ k x || occursL k xs

def occursO (k : String) : List (String × Json) → Bool
  | [] => false
  | (_, v) :: r => occursJ k v || occursO k r
end

/-- The conditions under which the native spelling reads back. -/
def faqOK (F : FaqForm) : Bool :=
  isE F.expr && (match F.filter with | some x => isE x | none => true) &&
  F.out.all outOK && decide (outNames F.out).Nodup &&
  keysSorted F.ranges && F.ranges.all (fun kv => nameOK kv.1 && rangeOK kv.2 &&
    ((outNames F.out).contains kv.1 || occursJ kv.1 F.expr ||
      (match F.filter with | some x => occursJ kv.1 x | none => false)))

/-- A range row: `a \le k \le b`, `k \in S`, `k \in S(i, j)`. -/
def rowToks (c : Ctx) (P : Json → Out) (kv : String × Json) : List Tok :=
  match kv.2 with
  | .arr [a, b] => (P a).at c.sf 4 ++ .kw .le :: nameToks c kv.1 ++ .kw .le :: (P b).at c.sf 4
  | .obj [("from", .str s)] => nameToks c kv.1 ++ .kw .inn :: nameToks c s
  | .obj [("from", .str s), ("of", .arr ps)] =>
    nameToks c kv.1 ++ .kw .inn :: nameToks c s ++ .kw .lp ::
      (sepBy [.kw .comma] (ps.map fun p => match p with | .str q => nameToks c q | _ => []) ++ [.kw .rp])
  | _ => []

/-- The reduced ranges: those of indices that are not output indices. -/
def redRanges (F : FaqForm) : List (String × Json) :=
  F.ranges.filter fun kv => !((outNames F.out).contains kv.1)

/-- The rows of the subscript: the reduced ranges, then the filter. -/
def subRows (c : Ctx) (P : Json → Out) (F : FaqForm) : List (List Tok) :=
  (redRanges F).map (rowToks c P) ++ (match F.filter with | some x => [(P x).at c.sf 1] | none => [])

/-- The operator, marked when `args` is listed. -/
def headToks (sf : Sf) (F : FaqForm) : List Tok :=
  match sf with
  | .latex => .kw F.red.kw :: (if F.marked then [.kw .limitsL] else [])
  | .typst => if F.marked then [.kw .limits, .kw .lp, .kw F.red.kw, .kw .rp] else [.kw F.red.kw]

/-- The LaTeX subscript: none, one row, a lone dense range `_{k=a}^{b}`, or `\substack`. -/
def subToksL (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok :=
  match redRanges F, F.filter with
  | [(k, .arr [a, b])], none =>
    [.kw .us, .kw .lb] ++ nameToks c k ++ .kw .eq :: (P a).at c.sf 4 ++
      [.kw .rb, .kw .caret, .kw .lb] ++ (P b).at c.sf 1 ++ [.kw .rb]
  | _, _ =>
    match subRows c P F with
    | [] => []
    | [r] => [.kw .us, .kw .lb] ++ r ++ [.kw .rb]
    | rs => [.kw .us, .kw .lb, .kw .substack, .kw .lb] ++ sepBy [.kw .nl] rs ++ [.kw .rb, .kw .rb]

/-- The Typst subscript: rows in `_( … )`, stacked with `\`. -/
def subToksT (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok :=
  match subRows c P F with
  | [] => []
  | rs => [.kw .us, .kw .lpg] ++ sepBy [.kw .nl] rs ++ [.kw .rp]

def subToks (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok :=
  match c.sf with
  | .latex => subToksL c P F
  | .typst => subToksT c P F

/-- The reduction: operator, subscript, body at level 5. -/
def redToks (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok :=
  headToks c.sf F ++ subToks c P F ++ (P F.expr).at c.sf 5

/-- An output entry: its range row when it has one. -/
def entryToks (c : Ctx) (P : Json → Out) (F : FaqForm) (j : Json) : List Tok :=
  match j with
  | .str k =>
    match look k F.ranges with
    | some v => rowToks c P (k, v)
    | none => nameToks c k
  | _ => [.num (.int 1)]

/-- The native `faq`: the reduction, wrapped with its output indices when it has some. -/
def faqOut (c : Ctx) (P : Json → Out) (F : FaqForm) : Out :=
  if F.out = [] then mkOut c.sf 5 (redToks c P F)
  else
    let es := sepBy [.kw .comma] (F.out.map (entryToks c P F))
    match c.sf with
    | .latex => mkOut c.sf 10 ([.kw .lbkg] ++ redToks c P F ++ [.kw .rbkg, .kw .us, .kw .lb] ++ es ++ [.kw .rb])
    | .typst => mkOut c.sf 10 ([.kw .lr, .kw .lp, .kw .lbk] ++ redToks c P F ++
        [.kw .rbk, .kw .rp, .kw .us, .kw .lpg] ++ es ++ [.kw .rp])

/-- The sub-expressions a native `faq` prints. -/
def faqSubs (F : FaqForm) : List Json :=
  [F.expr] ++ (match F.filter with | some x => [x] | none => []) ++
    F.ranges.flatMap (fun kv => match kv.2 with | .arr [a, b] => [a, b] | _ => [])

/-- A printer given by a table of printed sub-expressions. -/
def tableP (t : List (Json × Out)) (x : Json) : Out :=
  match t.find? (fun p => jbeq p.1 x) with
  | some p => p.2
  | none => ⟨0, [], []⟩

mutual
theorem jbeq_sound : ∀ a b : Json, jbeq a b = true → a = b
  | .null, .null, _ => rfl
  | .bool a, .bool b, h => by simp [jbeq] at h; rw [h]
  | .num a, .num b, h => by simp [jbeq] at h; rw [h]
  | .str a, .str b, h => by simp [jbeq] at h; rw [h]
  | .arr a, .arr b, h => by simp only [jbeq] at h; rw [jbeqL_sound a b h]
  | .obj a, .obj b, h => by simp only [jbeq] at h; rw [jbeqO_sound a b h]
  | .null, .bool _, h | .null, .num _, h | .null, .str _, h | .null, .arr _, h | .null, .obj _, h
  | .bool _, .null, h | .bool _, .num _, h | .bool _, .str _, h | .bool _, .arr _, h | .bool _, .obj _, h
  | .num _, .null, h | .num _, .bool _, h | .num _, .str _, h | .num _, .arr _, h | .num _, .obj _, h
  | .str _, .null, h | .str _, .bool _, h | .str _, .num _, h | .str _, .arr _, h | .str _, .obj _, h
  | .arr _, .null, h | .arr _, .bool _, h | .arr _, .num _, h | .arr _, .str _, h | .arr _, .obj _, h
  | .obj _, .null, h | .obj _, .bool _, h | .obj _, .num _, h | .obj _, .str _, h | .obj _, .arr _, h => by
    simp [jbeq] at h

theorem jbeqL_sound : ∀ a b : List Json, jbeqL a b = true → a = b
  | [], [], _ => rfl
  | x :: xs, y :: ys, h => by
    simp only [jbeqL, Bool.and_eq_true] at h
    rw [jbeq_sound x y h.1, jbeqL_sound xs ys h.2]
  | [], _ :: _, h => by simp [jbeqL] at h
  | _ :: _, [], h => by simp [jbeqL] at h

theorem jbeqO_sound : ∀ a b : List (String × Json), jbeqO a b = true → a = b
  | [], [], _ => rfl
  | (k, x) :: xs, (l, y) :: ys, h => by
    simp only [jbeqO, Bool.and_eq_true, beq_iff_eq] at h
    rw [h.1.1, jbeq_sound x y h.1.2, jbeqO_sound xs ys h.2]
  | [], _ :: _, h => by simp [jbeqO] at h
  | _ :: _, [], h => by simp [jbeqO] at h
end

mutual
theorem jbeq_refl : ∀ a : Json, jbeq a a = true
  | .null => rfl
  | .bool b => by simp [jbeq]
  | .num n => by simp [jbeq]
  | .str s => by simp [jbeq]
  | .arr xs => by simp only [jbeq]; exact jbeqL_refl xs
  | .obj kvs => by simp only [jbeq]; exact jbeqO_refl kvs

theorem jbeqL_refl : ∀ a : List Json, jbeqL a a = true
  | [] => rfl
  | x :: xs => by simp only [jbeqL, Bool.and_eq_true]; exact ⟨jbeq_refl x, jbeqL_refl xs⟩

theorem jbeqO_refl : ∀ a : List (String × Json), jbeqO a a = true
  | [] => rfl
  | (k, x) :: xs => by
    simp only [jbeqO, Bool.and_eq_true, beq_self_eq_true, true_and]; exact ⟨jbeq_refl x, jbeqO_refl xs⟩
end

theorem faqForm_json {kvs : List (String × Json)} {F : FaqForm} (h : faqForm kvs = some F) :
    faqJson F = .obj kvs := by
  unfold faqForm at h
  split at h
  · split at h
    · rename_i hj; cases h; exact jbeq_sound _ _ hj
    · cases h
  · cases h

theorem faqSubs_lt_json (F : FaqForm) : ∀ x ∈ faqSubs F, sizeOf x < sizeOf (faqJson F) := by
  intro x hx
  have key : ∀ (kv : String × Json), kv ∈ ([("args", Json.arr (if F.marked then (bases F.expr).map .str else [])),
      ("expr", F.expr)] ++ (match F.filter with | some x => [("filter", x)] | none => []) ++
      [("op", .str "faq"), ("output_idx", .arr F.out)] ++
      (if F.ranges = [] then [] else [("ranges", .obj F.ranges)]) ++ F.red.field) →
      sizeOf kv.2 < sizeOf (faqJson F) := by
    intro kv hkv
    have := List.sizeOf_lt_of_mem hkv
    obtain ⟨k, v⟩ := kv
    unfold faqJson
    simp only [Json.obj.sizeOf_spec, Prod.mk.sizeOf_spec] at this ⊢
    omega
  simp only [faqSubs, List.mem_append, List.mem_flatMap] at hx
  rcases hx with (hx | hx) | ⟨kv, hkv, hx⟩
  · simp at hx; subst hx; exact key ("expr", F.expr) (by simp)
  · split at hx
    · rename_i y hy; simp at hx; subst hx
      exact key ("filter", x) (by simp [hy])
    · simp at hx
  · obtain ⟨k, v⟩ := kv
    have h1 := List.sizeOf_lt_of_mem hkv
    split at hx
    · rename_i a b hab
      simp only at hab; subst hab
      simp only [List.mem_cons, List.not_mem_nil, or_false] at hx
      have hne : F.ranges ≠ [] := List.ne_nil_of_mem hkv
      have h2 := key ("ranges", .obj F.ranges) (by simp [hne])
      simp only [Json.obj.sizeOf_spec] at h2
      rcases hx with rfl | rfl <;> simp at h1 <;> omega
    · simp at hx

theorem faqSubs_lt {kvs : List (String × Json)} {F : FaqForm} (h : faqForm kvs = some F) {x : Json}
    (hx : x ∈ faqSubs F) : sizeOf x < sizeOf (Json.obj kvs) := by
  rw [← faqForm_json h]; exact faqSubs_lt_json F x hx

/-- A template the call form can name: an identifier that is not a reserved operator
name. -/
def tnameOK (n : String) : Bool := opnOK n && !(reservedOpn.contains n)

/-- The printer. -/
def pr (c : Ctx) (e : Json) : Out :=
  match e with
  | .num n => mkOut c.sf (if isNegNum (.num n) then 7 else 10) [.num n]
  | .str s => mkOut c.sf 10 (nameToks c s)
  | .obj kvs =>
    let sf := c.sf
    let esc : Unit → Out := fun _ =>
      match look "op" kvs, _hk : look "args" kvs with
      | some (.str o), some (.arr as) =>
        mkOut sf 10 (escToks sf o (fieldsOf kvs) (as.attach.map fun ⟨a, _⟩ => (pr c a).at sf 1))
      | _, _ => mkOut sf 10 []
    let fq : Unit → Option Out := fun _ =>
      match _hF : faqForm kvs with
      | some F =>
        if faqOK F then some (faqOut c (tableP ((faqSubs F).attach.map fun ⟨x, _⟩ => (x, pr c x))) F)
        else none
      | none => none
    let opn : Unit → Out := fun _ =>
      match look "op" kvs, _hk : look "args" kvs with
      | some (.str o), some (.arr as) =>
        if !(coreOps.contains o) && opnOK o && (tparams c.S o).isNone &&
            (fieldsOf kvs).all (fun kv => keyOK kv.1) then
          mkOut sf 10 (openToks sf o (as.attach.map fun ⟨a, _⟩ => (pr c a).at sf 4)
            ((fieldsOf kvs).attach.map fun ⟨kv, _⟩ =>
              keyToks sf kv.1 ++ .kw .eq :: (if isE kv.2 then (pr c kv.2).at sf 4 else jsonVal sf kv.2)))
        else esc ()
      | _, _ => esc ()
    match kvs with
    | [("args", .arr as), ("op", .str o)] =>
      match kindOf o, as with
      | .minus, [a] =>
        let t := (pr c a).at sf 5
        mkOut sf 5 (.kw .minus :: (if startsNum t then grp sf t else t))
      | .minus, [a, b] => mkOut sf 4 ((pr c a).at sf 4 ++ .kw .minus :: (pr c b).at sf 5)
      | .div, [a, b] =>
        match sf with
        | .latex => mkOut sf 10 ([.kw .frac, .kw .lb] ++ (pr c a).at sf 1 ++
            [.kw .rb, .kw .lb] ++ (pr c b).at sf 1 ++ [.kw .rb])
        | .typst => mkOut sf 7 ((pr c a).at sf 8 ++ .kw .slash :: (pr c b).at sf 8)
      | .pow, [a, b] =>
        let ex := match sf with
          | .latex => [.kw .lb] ++ (pr c b).at sf 1 ++ [.kw .rb]
          | .typst =>
            match simpleE c b with
            | some t => [t]
            | none => grp sf (pr c b).toks
        mkOut sf 8 ((pr c a).at sf 9 ++ .kw .caret :: ex)
      | .lnot, [a] => mkOut sf 6 (.kw .lnot :: (pr c a).at sf 6)
      | .tru, [] => mkOut sf 10 [.txt "true"]
      | .fls, [] => mkOut sf 10 [.txt "false"]
      | .ite, [cnd, a, b] =>
        let rows := caseRow sf ((pr c a).at sf 1) ((pr c cnd).at sf 1) ++ (pr c b).crow
        ⟨10, casesToks sf rows, rows⟩
      | .un k, [a] => mkOut sf 10 (unToks sf k ((pr c a).at sf 1))
      | .ic, [.str n] =>
        if nameOK n then mkOut sf 10 (nameToks c n ++ icTail sf) else esc ()
      | .index, base :: i :: is =>
        let subs := (i :: is).attach.map fun ⟨x, _⟩ => (pr c x).at sf 1
        if subOK c.S base (i :: is) && !(subPat sf (subList sf (simpleArg c (i :: is)) subs)) then
          mkOut sf 9 (nameToks c (match base with | .str s => s | _ => "") ++
            subList sf (simpleArg c (i :: is)) subs)
        else mkOut sf 9 ((pr c base).at sf 10 ++ [.kw .lbk] ++ sepBy [.kw .comma] subs ++ [.kw .rbk])
      | .cmp k, [a, b] => mkOut sf 3 ((pr c a).at sf 4 ++ .kw k :: (pr c b).at sf 4)
      | .plus, xs =>
        if 2 ≤ xs.length then
          mkOut sf 4 (sepBy [.kw .plus] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 5))
        else opn ()
      | .times, xs =>
        if 2 ≤ xs.length then mkOut sf 5 (mulToks (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 6))
        else opn ()
      | .land, xs =>
        if 2 ≤ xs.length then
          mkOut sf 2 (sepBy [.kw .land] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 3))
        else opn ()
      | .lor, xs =>
        if 2 ≤ xs.length then
          mkOut sf 1 (sepBy [.kw .lor] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 2))
        else opn ()
      | .mm k, xs =>
        if 2 ≤ xs.length then
          mkOut sf 10 (callToks sf [.kw k] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 1))
        else opn ()
      | .call, xs => mkOut sf 10 (callToks sf [.opn o] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 4))
      | _, _ => opn ()
    | [("args", .arr as), ("op", .str "D"), ("wrt", .str w)] =>
      match as with
      | [a] =>
        if w = "t" then dTime sf (pr c a)
        else if nameOK w then dSpace sf (nameToks c w) (pr c a)
        else esc ()
      | a :: b :: r =>
        if w ≠ "t" ∧ nameOK w then
          mkOut sf 10 (dCall sf (nameToks c w) ((a :: b :: r).attach.map fun ⟨x, _⟩ => (pr c x).at sf 4))
        else esc ()
      | [] => esc ()
    | [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)] =>
      if unitsOK sf u then mkOut sf 7 (qtyToks sf n (factorsOf u)) else esc ()
    | [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .arr xs)] =>
      match arrForm (.arr xs) with
      | some af => if unitsOK sf u then mkOut sf 7 (arrToks sf af ++ unitToks sf (factorsOf u)) else esc ()
      | none => esc ()
    | [("args", .arr []), ("op", .str "const"), ("value", .arr xs)] =>
      match arrForm (.arr xs) with
      | some af => mkOut sf 10 (arrToks sf af)
      | none => opn ()
    | [("args", .arr []), ("bindings", .obj bs), ("name", .str n), ("op", .str "apply_expression_template")] =>
      if tnameOK n && keysSorted bs && bs.all (fun kv => isE kv.2) then
        let vals := bs.attach.map fun ⟨kv, _⟩ => (kv.1, (pr c kv.2).at sf 4)
        match positional c.S n bs with
        | some ps => mkOut sf 10 (callToks sf [.opn n] (ps.map fun p => (vals.lookup p).getD []))
        | none =>
          if bs ≠ [] && bs.all (fun kv => nameOK kv.1) then
            mkOut sf 10 (callToks sf [.opn n] (vals.map fun kv => nameToks c kv.1 ++ .kw .eq :: kv.2))
          else esc ()
      else esc ()
    | _ =>
      match fq () with
      | some o => o
      | none => opn ()
  | _ => mkOut c.sf 10 []
termination_by sizeOf e
decreasing_by
  all_goals simp_wf
  all_goals first
    | omega
    | exact look_arr_lt ‹_› ‹_›
    | exact fields_lt ‹_›
    | (have := List.sizeOf_lt_of_mem ‹_ ∈ _›; omega)
    | (have := List.sizeOf_lt_of_mem ‹_ ∈ _›; simp only [List.cons.sizeOf_spec] at this; omega)
    | (have := List.sizeOf_lt_of_mem ‹_ ∈ _›; have := snd_lt ‹String × Json›; omega)
    | (have := faqSubs_lt ‹_› ‹_›; simp only [Json.obj.sizeOf_spec] at this; omega)

/-- The tokens of an expression for a position needing level `L`. -/
def pa (c : Ctx) (L : Nat) (e : Json) : List Tok := (pr c e).at c.sf L

/-- The tokens of a whole expression. -/
def print (sf : Sf) (S : Sym) (e : Json) : List Tok := pa ⟨sf, S⟩ 1 e

end Esm.Document.Math
