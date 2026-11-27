import Adapter.Doc

/-! Read a document without losing the declaration order of its `operators` maps.
The scalar reader and canonical number conversion are shared with the document codec. -/

namespace Adapter.OrderedJson

open Esm.Document
open Std.Internal.Parsec Std.Internal.Parsec.String

private def members {α : Type} (closing : Char) (item : Parser α) : Parser (List α) := do
  ws
  if (← peek!) == closing then
    skip
    return []
  let first ← item
  let rest ← many (skipChar ',' *> ws *> item)
  skipChar closing
  return first :: rest.toList

private partial def value : Parser Json := do
  let json ← match ← peek! with
    | '[' => skip *> (Json.arr <$> members ']' value)
    | '{' => do
      skip
      let fields ← members '}' do
        skipChar '"'
        let key ← Lean.Json.Parser.str
        ws
        skipChar ':'
        ws
        return (key, ← value)
      unless (fields.map Prod.fst).Nodup do fail "duplicate object key"
      pure (.obj fields)
    | _ =>
      match Doc.conv true (← Lean.Json.Parser.anyCore) with
      | .ok json => pure json
      | .error error => fail error
  ws
  return json

def parse (input : String) : Except String Json :=
  let padded := String.ofList (Doc.padExponents input.toList false #[]).toList
  Parser.run (ws *> value <* eof) padded

end Adapter.OrderedJson
