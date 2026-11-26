import Lean.Data.Json
import Adapter.Decimal
import Adapter.JsonString
import Esm.Expr.Canonical
import Esm.Units.Canonical

/-! The discretization RFC §5.4 `canonical_json` expression format. Its typed
float tokens, signed zeros and algebraic rewrites are specific to this API.
The document reader, document writer and numerical evaluator have separate
entry points. -/

namespace Adapter.CanonicalExpr

open Esm.Expr.Canonical

private inductive Literal where
  | int (value : Int)
  | float (negative : Bool) (significand : Nat) (exponent : Int)

private inductive Wire where
  | number (value : Option Literal)
  | string (value : String)
  | bool (value : Bool)
  | null
  | array (values : List Wire)
  | object (fields : List (String × Wire))

open Std.Internal.Parsec Std.Internal.Parsec.String

private def floatZero (negative : Bool) : Literal := .float negative 0 (-1074)

private def roundFloat (negative : Bool) (coefficient : Nat) (shift : Int) : Option Literal :=
  if coefficient == 0 then some (floatZero negative)
  else
    let scientific : Int := (Doc.natDigits coefficient).length - 1 + shift
    if scientific > 308 then none
    else if scientific < -324 then some (floatZero negative)
    else
      let (n, d) := Doc.scale10 coefficient 1 shift
      (Doc.toBinary64 n d).map fun (m, k) => .float negative m k

/-! ### Typed wire reader -/

private def signedExponent : Parser Int := do
  let c ← peek!
  if c == '-' || c == '+' then skip
  let n ← Lean.Json.Parser.natMaybeZero
  return if c == '-' then -(n : Int) else n

private def readNumber : Parser Wire := do
  let negative ← (· == '-') <$> peek!
  if negative then skip
  let whole ← Lean.Json.Parser.nat
  let fraction ← if (← peek?) == some '.' then
    skip *> (some <$> Lean.Json.Parser.natNumDigits)
  else pure none
  let exponent ← match ← peek? with
    | some 'e' | some 'E' => skip *> (some <$> signedExponent)
    | _ => pure none
  if fraction.isNone && exponent.isNone then
    if negative && whole == 0 then fail "negative zero requires a float token"
    return .number (some (.int (if negative then -(whole : Int) else whole)))
  let (fraction, digits) := fraction.getD (0, 0)
  return .number (roundFloat negative (whole * 10 ^ digits + fraction)
    (exponent.getD 0 - digits))

private def delimited {α : Type} (closing : Char) (element : Parser α) : Parser (List α) := do
  ws
  if (← peek!) == closing then skip; return []
  let first ← element
  let rest ← many (skipChar ',' *> ws *> element)
  skipChar closing
  return first :: rest.toList

private partial def readWire : Parser Wire := do
  let value ← match ← peek! with
    | '[' => skip *> (Wire.array <$> delimited ']' readWire)
    | '{' => do
      skip
      let fields ← delimited '}' do
        skipChar '"'
        let key ← Lean.Json.Parser.str
        ws; skipChar ':'; ws
        return (key, ← readWire)
      unless (fields.map Prod.fst).Nodup do fail "duplicate object key"
      pure (Wire.object fields)
    | '"' => skip *> (Wire.string <$> Lean.Json.Parser.str)
    | 't' => skipString "true" *> pure (Wire.bool true)
    | 'f' => skipString "false" *> pure (Wire.bool false)
    | 'n' => skipString "null" *> pure Wire.null
    | _ => readNumber
  ws
  return value

/-! ### AST and rendering -/

private inductive Payload where
  | number (value : Literal)
  | string (value : String)
  | bool (value : Bool)
  | null
  | array (values : List Payload)

private inductive Expression where
  | number (value : Literal)
  | reference (name : String)
  | node (op : String) (args : List Expression) (fields : List (String × Payload))

private structure Failure where
  code : String
  path : String
  message : String
  deriving Inhabited

private def invalid (path message : String) : Failure :=
  ⟨"E_CANONICAL_INVALID_EXPRESSION", path, message⟩

private def nonFinite (path : String) : Failure :=
  ⟨"E_CANONICAL_NONFINITE", path, "float is outside the finite binary64 range"⟩

private def fieldPath (path key : String) : String :=
  path ++ "/" ++ ((key.replace "~" "~0").replace "/" "~1")

private def look {α : Type} (fields : List (String × α)) (key : String) : Option α :=
  (fields.find? (fun field => field.1 == key)).map Prod.snd

private partial def decodePayload (path : String) : Wire → Except Failure Payload
  | .number (some n) => .ok (.number n)
  | .number none => .error (nonFinite path)
  | .string s => .ok (.string s)
  | .bool b => .ok (.bool b)
  | .null => .ok .null
  | .array xs => .array <$> xs.zipIdx.mapM (fun (x, i) => decodePayload (fieldPath path (toString i)) x)
  | .object _ => .error (invalid path "canonical value payloads must be literal data")

private def printFloat (negative : Bool) (m : Nat) (k : Int) : String :=
  let sign := if negative then "-" else ""
  if m == 0 then sign ++ "0.0"
  else
    let (digits, scientific) := Doc.shortest m k
    let digits := digits.map Esm.digitChar
    let spelling :=
      if scientific < -6 || scientific ≥ 21 then
        let mantissa := String.ofList <| match digits with
          | d :: t@(_ :: _) => d :: '.' :: t
          | ds => ds
        mantissa ++ "e" ++ toString scientific
      else if scientific < 0 then
        "0." ++ String.ofList (List.replicate (-scientific - 1).toNat '0' ++ digits)
      else
        let pos := (scientific + 1).toNat
        let (whole, fraction) := digits.splitAt pos
        String.ofList (whole ++ List.replicate (pos - whole.length) '0') ++ "." ++
          (if fraction.isEmpty then "0" else String.ofList fraction)
    sign ++ spelling

private def Literal.render : Literal → String
  | .int n => toString n
  | .float sign m k => printFloat sign m k

private abbrev quote := JsonString.quote

private def renderArray (items : List String) : String := "[" ++ ",".intercalate items ++ "]"

private partial def Payload.render : Payload → String
  | .number n => n.render
  | .string s => quote s
  | .bool b => if b then "true" else "false"
  | .null => "null"
  | .array xs => renderArray (xs.map Payload.render)

private partial def Expression.render : Expression → String
  | .number n => n.render
  | .reference s => quote s
  | .node op args fields =>
    let mandatory := [("args", renderArray (args.map Expression.render)), ("op", quote op)]
    let fields := mandatory ++ fields.map fun (key, value) => (key, value.render)
    let fields := fields.mergeSort fun a b => a.1 ≤ b.1
    "{" ++ ",".intercalate (fields.map fun (key, value) => quote key ++ ":" ++ value) ++ "}"

/-! ### Canonical form -/

private def Literal.ratio : Literal → Int × Nat
  | .int n => (n, 1)
  | .float neg m k =>
    let a : Int := m * (2 ^ k.toNat : Nat)
    (if neg then -a else a, 2 ^ (-k).toNat)

private def Literal.isFloat : Literal → Bool
  | .int _ => false
  | .float .. => true

private def Literal.is (literal : Literal) (n : Int) : Bool :=
  let (a, b) := literal.ratio
  a == n * (b : Int)

private def Literal.negate : Literal → Literal
  | .int n => .int (-n)
  | .float negative m k => .float (!negative) m k

private def Literal.negativeZero : Literal → Bool
  | .float true 0 _ => true
  | _ => false

private inductive SortKey where
  | number (n : Literal)
  | reference (name : String)
  | node (canonical : String)

private def sortKey : Expression → SortKey
  | .number n => .number n
  | .reference s => .reference s
  | e@(.node ..) => .node e.render

private def before : SortKey → SortKey → Bool
  | .number a, .number b =>
    let (na, da) := a.ratio
    let (nb, db) := b.ratio
    match compare (na * (db : Int)) (nb * (da : Int)) with
    | .lt => true
    | .gt => false
    | .eq => !a.isFloat || b.isFloat
  | .number _, _ => true
  | _, .number _ => false
  | .reference a, .reference b => a ≤ b
  | .reference _, .node _ => true
  | .node _, .reference _ => false
  | .node a, .node b => a ≤ b

private def withSortedArgs (op : String) (args : List Expression) (fields : List (String × Payload)) :
    Expression :=
  .node op (orderArgs sortKey before args) fields

private def flatten (op : String) (args : List Expression) : List Expression :=
  flattenArgs (fun a => match a with
    | .node child children [] => if op == child then some children else none
    | _ => none) args

private def retainFloatIdentity (identity : Int) (neutral rest : List Expression) :
    Option Expression :=
  let floating := neutral.any fun a => match a with
    | .number n => n.isFloat
    | _ => false
  let knownFloats := rest.all fun a => match a with
    | .number n => n.isFloat
    | _ => false
  let floatIdentity := if identity == 0 then
    floatZero (neutral.all fun a => match a with
      | .number n => n.negativeZero
      | _ => false)
    else .float false (2 ^ 52) (-52)
  if floating && (!knownFloats || rest.isEmpty) then some (.number floatIdentity) else none

private def eraseIdentity (op : String) (identity : Int) (args : List Expression)
    (fields : List (String × Payload)) : Expression :=
  let rest := identityArgs (fun a => match a with
    | .number n => n.is identity
    | _ => false) (retainFloatIdentity identity) args
  match rest, fields with
  | [], [] => .number (.int identity)
  | [a], [] => a
  | _, _ => withSortedArgs op rest fields

private def promoteInt (path : String) (n : Literal) : Except Failure Literal :=
  match n with
  | .int n =>
    match roundFloat (n < 0) n.natAbs 0 with
    | some v => .ok v
    | none => .error (nonFinite path)
  | v => .ok v

private def canonicalConst (args : List Expression) (fields : List (String × Payload)) :
    Expression :=
  match look fields "units" with
  | some (.string u) =>
    let canonical := Esm.Units.canon u
    if canonical == "1" then
      match look fields "value" with
      | some (.number n) => .number n
      | _ => .node "const" args (fields.filter (fun entry => entry.1 != "units"))
    else .node "const" args (fields.map fun (k, v) => (k, if k == "units" then .string canonical else v))
  | _ => .node "const" args fields

private def negate : Expression → Expression
  | .number n => .number n.negate
  | .node "-" [x] [] => x
  | x => .node "-" [x] []

private partial def canonicalize (path : String) : Expression → Except Failure Expression
  | .node op args fields => do
    let args ← args.zipIdx.mapM fun (a, i) => canonicalize (s!"{path}/args/{i}") a
    let original := Expression.node op args fields
    match op, args, fields with
    | "const", _, _ => return canonicalConst args fields
    | "+", _, _ => return eraseIdentity op 0 (flatten op args) fields
    | "*", _, _ =>
      let flattened := flatten op args
      if fields.isEmpty then
        let zero := flattened.findSome? fun a => match a with
          | .number n => if n.is 0 then some n else none
          | _ => none
        if let some n := zero then return .number n
      return eraseIdentity op 1 flattened fields
    | "-", [a], [] | "neg", [a], [] => return negate a
    | "neg", [_], _ => return .node "-" args fields
    | "pow", [_, _], _ => return .node "^" args fields
    | "-", [.number a, .number b], [] =>
      if a.is 0 then
        if b.is 0 && (a.isFloat || b.isFloat) then
          return .number (floatZero (a.negativeZero && !b.negativeZero))
        if a.isFloat then return .number (← promoteInt path b.negate)
        return .number b.negate
      if b.is 0 then return .number (← if b.isFloat then promoteInt path a else pure a)
      return original
    | "-", [a, .number b], [] => return if b.is 0 then a else original
    | "/", [.number a, .number b], [] =>
      if a.is 0 && b.is 0 then throw ⟨"E_CANONICAL_DIVBY_ZERO", path, "literal zero divided by zero"⟩
      if b.is 1 then return .number (← if b.isFloat then promoteInt path a else pure a)
      if a.is 0 then return .number a
      return original
    | "/", [a, .number b], [] => return if b.is 1 then a else original
    | "/", [.number a, _], [] => return if a.is 0 then .number a else original
    | _, _, _ => return original
  | e => .ok e

private partial def decode (path : String) : Wire → Except Failure Expression
  | .number (some n) => .ok (.number n)
  | .number none => .error (nonFinite path)
  | .string s => .ok (.reference s)
  | .object fields => do
    let some (.string op) := look fields "op" | throw (invalid path "expected string op")
    let some (.array args) := look fields "args" | throw (invalid path "expected array args")
    let extras ← fields.filterMapM fun (key, value) => do
      if ["op", "args", "arg"].contains key then return none
      let pointer := fieldPath path key
      if key == "bindings" then
        match value with
        | .null => return none
        | .object bindings =>
          for (name, child) in bindings do
            let childPath := fieldPath pointer name
            let _ ← canonicalize childPath (← decode childPath child)
          return none
        | _ => throw (invalid pointer "expected an object")
      if key == "value" then
        if let .null := value then return none
        return some (key, ← decodePayload pointer value)
      if ["wrt", "dim", "fn", "name", "units"].contains key then
        match value with
        | .null => return none
        | .string s => return some (key, .string s)
        | _ => throw (invalid pointer "expected a string")
      throw ⟨"E_CANONICAL_UNSUPPORTED_FIELD", pointer, s!"no canonical slot for {key}"⟩
    let args ← args.zipIdx.mapM fun (a, i) => decode (s!"{path}/args/{i}") a
    return .node op args extras
  | _ => .error (invalid path "expected a number, reference, or operator node")

private def run (input : String) (fixture : Bool) : Except Failure String := do
  let wire ← (Parser.run (ws *> readWire <* eof) input).mapError (invalid "")
  let expression ← if fixture then
    match wire with
    | .object fields =>
      match look fields "input" with
      | some input => pure input
      | none => throw (invalid "" "expected input field")
    | _ => throw (invalid "" "expected fixture object")
  else pure wire
  return (← canonicalize "" (← decode "" expression)).render

def main (args : List String) : IO UInt32 := do
  let options := match args with
    | [path] => some (path, false)
    | ["--fixture", path] => some (path, true)
    | _ => none
  let some (path, fixture) := options
    | IO.eprintln "usage: esm-lean canonical-json [--fixture] <file|->"; return 2
  let contents ← if path == "-" then (← IO.getStdin).readToEnd else IO.FS.readFile path
  match run contents fixture with
  | .ok rendered => IO.print rendered; return 0
  | .error error =>
    IO.eprintln (Lean.Json.mkObj [("code", .str error.code), ("path", .str error.path),
      ("message", .str error.message)]).compress
    return 1

end Adapter.CanonicalExpr
