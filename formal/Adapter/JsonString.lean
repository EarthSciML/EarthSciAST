import Lean.Data.Json

namespace Adapter.JsonString

/-- Compact UTF-8 JSON string spelling shared by the byte-comparison adapters. -/
def quote (s : String) : String :=
  (s.foldl (fun acc c =>
    match c with
    | '\t' => acc ++ "\\t"
    | '\x08' => acc ++ "\\b"
    | '\x0c' => acc ++ "\\f"
    | _ => Lean.Json.escape (String.singleton c) acc) "\"").push '"'

end Adapter.JsonString
