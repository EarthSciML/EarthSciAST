import Lean.Data.Json
import Adapter.Decimal
import Adapter.JsonString
import Esm.Expr.Canonical.Typed

/-! The discretization RFC §5.4 `canonical_json` expression format. Its typed
float tokens, signed zeros and algebraic rewrites are specific to this API.
The document reader, document writer and numerical evaluator have separate
entry points. -/

namespace Adapter.CanonicalExpr

open Esm.Expr.Canonical.Typed

private inductive Wire where
  | number (value : Option Literal)
  | string (value : String)
  | bool (value : Bool)
  | null
  | array (values : List Wire)
  | object (fields : List (String × Wire))

open Std.Internal.Parsec Std.Internal.Parsec.String

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

private def fieldPath (path key : String) : String :=
  path ++ "/" ++ ((key.replace "~" "~0").replace "/" "~1")

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
  | .number n => Literal.render n
  | .string s => quote s
  | .bool b => if b then "true" else "false"
  | .null => "null"
  | .array xs => renderArray (xs.map Payload.render)

private partial def Expression.render : Expression → String
  | .number n => Literal.render n
  | .reference s => quote s
  | .node op args fields =>
    let mandatory := [("args", renderArray (args.map Expression.render)), ("op", quote op)]
    let fields := mandatory ++ fields.map fun (key, value) => (key, Payload.render value)
    let fields := fields.mergeSort fun a b => a.1 ≤ b.1
    "{" ++ ",".intercalate (fields.map fun (key, value) => quote key ++ ":" ++ value) ++ "}"

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
            let _ ← canonicalize Expression.render roundFloat childPath (← decode childPath child)
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
  return Expression.render (← canonicalize Expression.render roundFloat "" (← decode "" expression))

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
