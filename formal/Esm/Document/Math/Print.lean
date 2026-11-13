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

def jsonToks : Json → List Tok
  | .null => [.word "null"]
  | .bool true => [.word "true"]
  | .bool false => [.word "false"]
  | .num n => [.num n]
  | .str s => [.jstr s]
  | .arr xs => .kw .lbk :: sepBy [.kw .comma] (xs.map jsonToks) ++ [.kw .rbk]
  | .obj kvs => .kw .lb :: sepBy [.kw .comma] (kvs.map fun kv => .jstr kv.1 :: .kw .colon :: jsonToks kv.2) ++ [.kw .rb]
termination_by j => sizeOf j
decreasing_by
  all_goals simp_wf
  · have := List.sizeOf_lt_of_mem ‹_ ∈ xs›; omega
  · rename_i h; exact sizeOf_snd_lt_obj h

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
     | .latex => Esm.Units.parseLatex (Esm.Units.latex l) == some l
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
def subList (sf : Sf) (args : List (List Tok)) : List Tok :=
  match sf with
  | .latex => [.kw .us, .kw .lb] ++ sepBy [.kw .comma] args ++ [.kw .rb]
  | .typst =>
    match args with
    | [[t]] => if simpleTok t then [.kw .us, t] else [.kw .us, .kw .lpg] ++ [t] ++ [.kw .rp]
    | _ => [.kw .us, .kw .lpg] ++ sepBy [.kw .comma] args ++ [.kw .rp]

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

/-- An upright name subscript: a name before it would read it as part of the name. -/
def subPat (sf : Sf) : List Tok → Bool
  | .kw .us :: .kw .lb :: .rm _ :: .kw .rb :: _ => sf == .latex
  | .kw .us :: .kw .lpg :: .ups [(_, "")] :: .kw .rp :: _ => sf == .typst
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
    let esc : Out :=
      match look "op" kvs, _hk : look "args" kvs with
      | some (.str o), some (.arr as) =>
        mkOut sf 10 (escToks sf o (fieldsOf kvs) (as.attach.map fun ⟨a, _⟩ => (pr c a).at sf 1))
      | _, _ => mkOut sf 10 []
    let opn : Out :=
      match look "op" kvs, _hk : look "args" kvs with
      | some (.str o), some (.arr as) =>
        if !(coreOps.contains o) && opnOK o && (tparams c.S o).isNone &&
            (fieldsOf kvs).all (fun kv => keyOK kv.1) then
          mkOut sf 10 (openToks sf o (as.attach.map fun ⟨a, _⟩ => (pr c a).at sf 4)
            ((fieldsOf kvs).attach.map fun ⟨kv, _⟩ =>
              keyToks sf kv.1 ++ .kw .eq :: (if isE kv.2 then (pr c kv.2).at sf 4 else jsonVal sf kv.2)))
        else esc
      | _, _ => esc
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
            match (pr c b).toks with
            | [t] => if simpleTok t then [t] else grp sf [t]
            | t => grp sf t
        mkOut sf 8 ((pr c a).at sf 9 ++ .kw .caret :: ex)
      | .lnot, [a] => mkOut sf 6 (.kw .lnot :: (pr c a).at sf 6)
      | .tru, [] => mkOut sf 10 [.txt "true"]
      | .fls, [] => mkOut sf 10 [.txt "false"]
      | .ite, [cnd, a, b] =>
        let rows := caseRow sf ((pr c a).at sf 1) ((pr c cnd).at sf 1) ++ (pr c b).crow
        ⟨10, casesToks sf rows, rows⟩
      | .un k, [a] => mkOut sf 10 (unToks sf k ((pr c a).at sf 1))
      | .ic, [.str n] =>
        if nameOK n then mkOut sf 10 (nameToks c n ++ icTail sf) else esc
      | .index, base :: i :: is =>
        let subs := (i :: is).attach.map fun ⟨x, _⟩ => (pr c x).at sf 1
        if subOK c.S base (i :: is) && !(subPat sf (subList sf subs)) then
          mkOut sf 9 (nameToks c (match base with | .str s => s | _ => "") ++ subList sf subs)
        else mkOut sf 9 ((pr c base).at sf 10 ++ [.kw .lbk] ++ sepBy [.kw .comma] subs ++ [.kw .rbk])
      | .cmp k, [a, b] => mkOut sf 3 ((pr c a).at sf 4 ++ .kw k :: (pr c b).at sf 4)
      | .plus, xs =>
        if 2 ≤ xs.length then
          mkOut sf 4 (sepBy [.kw .plus] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 5))
        else opn
      | .times, xs =>
        if 2 ≤ xs.length then mkOut sf 5 (mulToks (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 6))
        else opn
      | .land, xs =>
        if 2 ≤ xs.length then
          mkOut sf 2 (sepBy [.kw .land] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 3))
        else opn
      | .lor, xs =>
        if 2 ≤ xs.length then
          mkOut sf 1 (sepBy [.kw .lor] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 2))
        else opn
      | .mm k, xs =>
        if 2 ≤ xs.length then
          mkOut sf 10 (callToks sf [.kw k] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 1))
        else opn
      | .call, xs => mkOut sf 10 (callToks sf [.opn o] (xs.attach.map fun ⟨x, _⟩ => (pr c x).at sf 4))
      | _, _ => opn
    | [("args", .arr as), ("op", .str "D"), ("wrt", .str w)] =>
      match as with
      | [a] =>
        if w = "t" then dTime sf (pr c a)
        else if nameOK w then dSpace sf (nameToks c w) (pr c a)
        else esc
      | a :: b :: r =>
        if w ≠ "t" ∧ nameOK w then
          mkOut sf 10 (dCall sf (nameToks c w) ((a :: b :: r).attach.map fun ⟨x, _⟩ => (pr c x).at sf 4))
        else esc
      | [] => esc
    | [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)] =>
      if unitsOK sf u then mkOut sf 7 (qtyToks sf n (factorsOf u)) else esc
    | [("args", .arr []), ("bindings", .obj bs), ("name", .str n), ("op", .str "apply_expression_template")] =>
      if tnameOK n && keysSorted bs && bs.all (fun kv => isE kv.2) then
        let vals := bs.attach.map fun ⟨kv, _⟩ => (kv.1, (pr c kv.2).at sf 4)
        match positional c.S n bs with
        | some ps => mkOut sf 10 (callToks sf [.opn n] (ps.map fun p => (vals.lookup p).getD []))
        | none =>
          if bs ≠ [] && bs.all (fun kv => nameOK kv.1) then
            mkOut sf 10 (callToks sf [.opn n] (vals.map fun kv => nameToks c kv.1 ++ .kw .eq :: kv.2))
          else esc
      else esc
    | _ => opn
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

/-- The tokens of an expression for a position needing level `L`. -/
def pa (c : Ctx) (L : Nat) (e : Json) : List Tok := (pr c e).at c.sf L

/-- The tokens of a whole expression. -/
def print (sf : Sf) (S : Sym) (e : Json) : List Tok := pa ⟨sf, S⟩ 1 e

end Esm.Document.Math
