import Lean.Data.Json
import Esm.Document.Source.TypstDoc

/-! `esm-lean canon|print-md|parse-md|print-typ|parse-typ <file>`: the document source formats.

* `canon <doc.esm>`: the document in canonical form, as compact JSON: sorted keys,
  canonical numbers (CONFORMANCE §5.5.3.1), every `units` and `default_units` string in
  the canonical unit spelling (`Esm.Units.canon`, as `canonicalize_document` does), and
  the deprecated `neg` and `pow` rewritten to unary `-` and `^` (a `broadcast` `fn` of
  `neg` too), and a `const` node in the dimensionless unit without its `units` (a scalar
  one becomes the bare number).
* `print-typ <doc.esm>`, `parse-typ <doc.typ>`: the same for Typst.
* `print-md <doc.esm>`: the Markdown spelling (`Esm.Document.Source.Md.printMd`).
* `parse-md <doc.md>`: the document a Markdown source holds, as canonical JSON; exit 1
  when it does not parse.

JSON goes through `Lean.Json` (whose objects are sorted by key) and is converted to the
document value type with numbers in the canonical form of CONFORMANCE §5.5.3.1. -/

namespace Adapter.Doc

open Esm.Document

/-! ### Numbers

A JSON number token is read as a reader in any binding reads it: an integer token in `Int64`
is that integer; any other token is rounded to the nearest binary64 (ties to even), and
that double is written in the form of CONFORMANCE §5.5.3.1: an integer when it is integral
and in `Int64`, else its shortest round-trip decimal digits. All arithmetic is exact, on
natural-number fractions (`Float.ofScientific` truncates before it rounds, so it is not
correctly rounded). Unproved adapter code, pinned by the golden files. -/

/-- `n / d` rounded to a natural number, ties to even (`d > 0`). -/
def roundHalfEven (n d : Nat) : Nat :=
  let q := n / d
  let r := n % d
  if 2 * r > d then q + 1 else if 2 * r < d then q else if q % 2 = 0 then q else q + 1

/-- The fraction `n / d` times `2^k`. -/
def scale2 (n d : Nat) (k : Int) : Nat × Nat :=
  if 0 ≤ k then (n * 2 ^ k.toNat, d) else (n, d * 2 ^ (-k).toNat)

/-- The fraction `n / d` times `10^k`. -/
def scale10 (n d : Nat) (k : Int) : Nat × Nat :=
  if 0 ≤ k then (n * 10 ^ k.toNat, d) else (n, d * 10 ^ (-k).toNat)

/-- `⌊log_b (n / d)⌋` for `n, d > 0`: the first guess `g`, moved one step at a time
(`fuel` bounds the steps). `le e` decides `b^e ≤ n / d`. -/
def floorLog (le : Int → Bool) (g : Int) : Nat → Int
  | 0 => g
  | fuel + 1 =>
    if !le g then floorLog le (g - 1) fuel
    else if le (g + 1) then floorLog le (g + 1) fuel
    else g

/-- `2^e ≤ n / d`. -/
def pow2Le (n d : Nat) (e : Int) : Bool := let (a, b) := scale2 d 1 e; decide (a ≤ n * b)

/-- `10^e ≤ n / d`. -/
def pow10Le (n d : Nat) (e : Int) : Bool := let (a, b) := scale10 d 1 e; decide (a ≤ n * b)

/-- The positive fraction `n / d` rounded to binary64, ties to even: `(M, k)` with value
`M × 2^k`, `M < 2^53`, and `2^52 ≤ M` unless `k = -1074` (a subnormal). `none` when it
overflows. -/
def toBinary64 (n d : Nat) : Option (Nat × Int) :=
  let t := floorLog (pow2Le n d) ((Nat.log2 n : Int) - Nat.log2 d) 4
  let k := max (t - 52) (-1074)
  let (a, b) := scale2 n d (-k)
  let m := roundHalfEven a b
  let (m, k) := if m = 2 ^ 53 then (2 ^ 52, k + 1) else (m, k)
  if k > 971 then none else some (m, k)

/-- The digits of a positive natural number, most significant first. -/
def natDigits (c : Nat) : List Nat := (Nat.toDigits 10 c).map (fun ch => ch.toNat - 48)

/-- The shortest decimal `c × 10^s` that rounds back to the double `(m, k)` (`m > 0`),
as its digits and the decimal exponent of the first: for each digit count `p` from 1, the
two `p`-digit decimals around the value; of those that round back, the nearer, and on a
tie the one with the even last digit (CONFORMANCE §5.5.3.1 rule 2, which writes the other
one at a power of two when the even one does not round back). -/
def shortest (m : Nat) (k : Int) : List Nat × Int :=
  let (vn, vd) := scale2 m 1 k
  let e10 := floorLog (pow10Le vn vd) ((((natDigits vn).length : Int) - (natDigits vd).length)) 4
  let back (c : Nat) (s : Int) : Bool :=
    c > 0 && (let (a, b) := scale10 c 1 s; toBinary64 a b == some (m, k))
  let out (c : Nat) (s : Int) : List Nat × Int :=
    let ds := natDigits c
    ((ds.reverse.dropWhile (· == 0)).reverse, (ds.length : Int) - 1 + s)
  let rec go : Nat → List Nat × Int
    | 0 => out (roundHalfEven vn vd) 0
    | fuel + 1 =>
      let p := 18 - (fuel + 1)
      let s := e10 - p + 1
      let (a, b) := scale10 vn vd (-s)
      let lo := a / b
      let hi := if a % b = 0 then lo else lo + 1
      let dLo := a - lo * b
      let dHi := hi * b - a
      match back lo s, back hi s with
      | true, true =>
        if dLo < dHi then out lo s else if dHi < dLo then out hi s
        else if lo % 2 = 0 then out lo s else out hi s
      | true, false => out lo s
      | false, true => out hi s
      | false, false => go fuel
  go 17

/-- The canonical number a JSON number token `m × 10^-e` is. -/
def toJNum (m : Int) (e : Nat) : JNum :=
  if m = 0 then .int 0
  else if e = 0 ∧ -(2 ^ 63 : Int) ≤ m ∧ m < 2 ^ 63 then .int m
  else
    let neg := decide (m < 0)
    match toBinary64 m.natAbs (10 ^ e) with
    | none => Number.mkDec neg (natDigits m.natAbs) (((natDigits m.natAbs).length : Int) - 1 - e)
    | some (bm, bk) =>
      let z : Int := (if neg then -1 else 1) * (bm * 2 ^ bk.toNat : Nat)
      if 0 ≤ bk ∧ -(2 ^ 63 : Int) ≤ z ∧ z < 2 ^ 63 then .int z
      else if bk < 0 ∧ bm % 2 ^ (-bk).toNat = 0 then
        .int ((if neg then -1 else 1) * (bm / 2 ^ (-bk).toNat : Nat))
      else
        let (ds, e10) := shortest bm bk
        .dec neg ds e10

instance : Inhabited Json := ⟨.null⟩

/-- A parsed JSON value as a document value. -/
partial def conv : Lean.Json → Json
  | .null => .null
  | .bool b => .bool b
  | .num n => .num (toJNum n.mantissa n.exponent)
  | .str s => .str s
  | .arr a => .arr (a.toList.map conv)
  | .obj o => .obj (o.toList.map fun (k, v) => (k, conv v))

/-- Compact canonical JSON text. -/
partial def render : Json → String
  | .null => "null"
  | .bool true => "true"
  | .bool false => "false"
  | .num n => String.ofList (Number.print n)
  | .str s => String.ofList (Strings.quote false s)
  -- never reached: a document read back holds no math leaf (`Json.WF`)
  | .math s => String.ofList (Strings.quote false s)
  | .arr xs => "[" ++ ",".intercalate (xs.map render) ++ "]"
  | .obj kvs => "{" ++ ",".intercalate (kvs.map fun (k, v) =>
      String.ofList (Strings.quote false k) ++ ":" ++ render v) ++ "}"

/-- Object properties whose value is a name-keyed map (esm-schema.json): its keys are
names, never fields, so a variable named `units` is not a units string. The list every
binding's `canonicalize_document` uses. -/
def mapKeys : List String :=
  ["bind", "bindings", "coordinates", "coords", "coupling_roles", "data_sources", "enums",
   "expression_template_imports", "expression_templates", "guesses", "index_set_rename",
   "index_sets", "initial_conditions", "map", "metaparameters", "models", "operator_imports",
   "operators", "parameter_overrides",
   "parameters", "pinned_coords", "ranges", "reaction_systems", "rebind", "rename", "species",
   "subsystems", "translate", "url_substitutions", "variables", "where"]

/-- Free-form objects (schema `additionalProperties: true`), never descended. -/
def freeKeys : List String := ["attrs", "config", "metadata", "reader_options", "x_esd"]

/-- Old field names read as the new ones (esm-spec §9.6.12, "Old names"): emit writes only
the new names. -/
def renameKey : String → String
  | "expression_templates" => "operators"
  | "expression_template_imports" => "operator_imports"
  | k => k

/-- The blocks whose entries are operator definitions (esm-spec §9.6.1), old name included. -/
def defsKeys : List String := ["operators", "expression_templates"]

/-- The string parameter names of a definition entry. -/
def paramsOf (kvs : List (String × Json)) : List String :=
  match Math.look "params" kvs with
  | some (.arr ps) => ps.filterMap fun p => match p with | .str s => some s | _ => none
  | _ => []

/-- The op an earlier document's spelling is read as (esm-spec §4.2 "Reading earlier
documents", §9.6.12): `apply_expression_template` is `apply_operator`; a `D` whose `wrt` is
present and not `"t"` is `partial` (unless the `wrt` is a parameter of the enclosing
definition, which is decided per instance and kept as written); `δ` and `∂` are `partial`. -/
def renameOp (ps : List String) (o : String) (kvs : List (String × Json)) : String :=
  if o = "apply_expression_template" then "apply_operator"
  else if o = "δ" ∨ o = "∂" then "partial"
  else if o = "D" then
    match Math.look "wrt" kvs with
    | some (.str w) => if w ≠ "t" ∧ !(ps.contains w) then "partial" else o
    | _ => o
  else o

/-- The deprecated operators and what they are rewritten to, with their arity. -/
def deprecatedTo : String → Option (String × Nat)
  | "neg" => some ("-", 1)
  | "pow" => some ("^", 2)
  | _ => none

/-- How `spellRules` reads an object: an ordinary object, a name-keyed map, a block of
operator definitions (a map whose entries are definitions), or one definition (whose
`units` is a unit expression, not a units string, esm-spec §9.6.1). -/
inductive Walk where
  | plain | map | defs | defn

/-- The spelling rules of the canonical form: units strings respelled, a dimensionless
`const` dropping its units, `neg` and `pow` rewritten (and a `broadcast` of `neg`), and the
old names of esm-spec §9.6.12 and §4.2 read as the new ones (`renameKey`, `renameOp`).
`ps`: the parameters of the enclosing definition. Unproved adapter code, pinned by the
golden files (`Esm.Document.Notation`). -/
partial def spellWalk (w : Walk) (ps : List String) : Json → Json
  | .arr xs => .arr (xs.map (spellWalk .plain ps))
  | .obj kvs =>
    match w with
    | .map => .obj (kvs.map fun (k, v) => (k, spellWalk .plain ps v))
    | .defs => .obj (kvs.map fun (k, v) =>
        (k, match v with
          | .obj ekvs => spellWalk .defn (paramsOf ekvs) v
          | _ => spellWalk .plain ps v))
    | _ =>
      let kvs' := Source.sortKeys (kvs.map fun (k, v) =>
        let k := renameKey k
        match k, v with
        | "units", .str u =>
          match w with
          | .defn => (k, v)
          | _ => (k, .str (Esm.Units.canon u))
        | "units", _ =>
          match w with
          | .defn => (k, spellWalk .plain ps v)
          | _ => (k, v)
        | "default_units", .str u => (k, .str (Esm.Units.canon u))
        | _, _ =>
          if freeKeys.contains k then (k, v)
          else if defsKeys.contains k then (k, spellWalk .defs ps v)
          else (k, spellWalk (if mapKeys.contains k then .map else .plain) ps v))
      let kvs' := match Math.look "op" kvs' with
        | some (.str o) =>
          let o' := renameOp ps o kvs'
          if o' = o then kvs' else kvs'.map fun (k, v) => if k = "op" then (k, .str o') else (k, v)
        | _ => kvs'
      match Math.look "op" kvs', Math.look "args" kvs' with
      | some (.str "const"), _ =>
        -- A const in the dimensionless unit drops it: one with a number value becomes
        -- that bare literal, whatever else it carries (`id`, `shape`, `attrs`, no
        -- `args`); any other keeps its other fields. The rule every binding's
        -- `canonicalize_document` applies.
        match Math.look "units" kvs', Math.look "value" kvs' with
        | some (.str "1"), some (.num n) => .num n
        | some (.str "1"), _ => .obj (kvs'.filter (fun kv => kv.1 != "units"))
        | _, _ => .obj kvs'
      | some (.str o), some (.arr as) =>
        match deprecatedTo o with
        | some (o', n) =>
          if as.length = n then .obj (kvs'.map fun (k, v) => if k = "op" then (k, .str o') else (k, v))
          else .obj kvs'
        | none =>
          -- A `broadcast` of the deprecated `neg` maps unary `-` (esm-spec §4.2).
          match o, Math.look "fn" kvs' with
          | "broadcast", some (.str "neg") =>
            if as.length = 1 then
              .obj (kvs'.map fun (k, v) => if k = "fn" then (k, .str "-") else (k, v))
            else .obj kvs'
          | _, _ => .obj kvs'
      | _, _ => .obj kvs'
  | j => j

/-- The spelling rules from the root (`isMap`: the value is a name-keyed map). -/
def spellRules (isMap : Bool) (j : Json) : Json := spellWalk (if isMap then .map else .plain) [] j

/-- A number token with an exponent, respelled so `Lean.Json.parse` still sees a decimal.
`Lean.Json.parse` folds a positive exponent into the mantissa, so `1.999999999999999e16`
and the integer token `19999999999999990` parse alike; padding the fraction with zeros past
the exponent (`1.9999999999999990e16`) keeps the value and keeps a fraction digit, so
`toJNum` reads it as the decimal token it is. Exponents above 400 are left alone (such a
value is outside `Int64`, so it is rounded either way). -/
def padExponent (t : List Char) : List Char :=
  match t.span (fun c => c != 'e' && c != 'E') with
  | (mant, ec :: expDigits) =>
    let x : Int := match expDigits with
      | '+' :: ds => (String.ofList ds).toInt?.getD 0
      | ds => (String.ofList ds).toInt?.getD 0
    if 0 < x ∧ x ≤ 400 then
      let (ip, fp) := mant.span (· != '.')
      let fp := fp.drop 1
      ip ++ '.' :: (fp ++ List.replicate (x.toNat + 1 - fp.length) '0') ++ ec :: expDigits
    else t
  | _ => t

/-- The JSON text with every number token's exponent padded (`padExponent`); string
contents are copied unchanged. -/
partial def padExponents (cs : List Char) (inStr : Bool) (acc : Array Char) : Array Char :=
  match cs, inStr with
  | [], _ => acc
  | '\\' :: c :: r, true => padExponents r true (acc.push '\\' |>.push c)
  | '"' :: r, b => padExponents r (!b) (acc.push '"')
  | c :: r, true => padExponents r true (acc.push c)
  | c :: r, false =>
    if c == '-' || c.isDigit then
      let (tok, rest) := (c :: r).span (fun d => d.isDigit || d ∈ ['.', 'e', 'E', '+', '-'])
      padExponents rest false (acc ++ (padExponent tok).toArray)
    else padExponents r false (acc.push c)

def readDoc (path : String) : IO Json := do
  let text ← IO.FS.readFile path
  let text := String.ofList (padExponents text.toList false #[]).toList
  match Lean.Json.parse text with
  | .ok j => pure (conv j)
  | .error e => throw (IO.userError s!"{path}: not JSON: {e}")

def main (mode : String) (args : List String) : IO UInt32 := do
  let [path] := args | IO.eprintln s!"usage: esm-lean {mode} <file>"; return 2
  match mode with
  | "canon" =>
    let d ← readDoc path
    IO.println (render (spellRules false d))
    return 0
  | "print-md" =>
    let d ← readDoc path
    unless Source.canonDoc d do
      IO.eprintln s!"{path}: not a document in canonical form (a JSON object)"; return 1
    IO.print (Source.Md.printMd d)
    return 0
  | "parse-md" =>
    let text ← IO.FS.readFile path
    match Source.Md.parseMd text with
    | some d => IO.println (render d); return 0
    | none => IO.eprintln s!"{path}: not an ESM Markdown document"; return 1
  | "print-typ" =>
    let d ← readDoc path
    unless Source.canonDoc d do
      IO.eprintln s!"{path}: not a document in canonical form (a JSON object)"; return 1
    IO.print (Source.Typ.printTyp d)
    return 0
  | "parse-typ" =>
    let text ← IO.FS.readFile path
    match Source.Typ.parseTyp text with
    | some d => IO.println (render d); return 0
    | none => IO.eprintln s!"{path}: not an ESM Typst document"; return 1
  | _ => IO.eprintln s!"unknown mode {mode}"; return 2

end Adapter.Doc
