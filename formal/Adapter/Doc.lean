import Lean.Data.Json
import Esm.Document.Source.MarkdownDoc

/-! `esm-lean print-md|parse-md|canon <file>`: the document source formats.

* `canon <doc.esm>`: the document in canonical form (sorted keys, canonical numbers), as
  compact JSON.
* `print-md <doc.esm>`: the Markdown spelling (`Esm.Document.Source.Md.printMd`).
* `parse-md <doc.md>`: the document a Markdown source holds, as canonical JSON; exit 1
  when it does not parse.

JSON goes through `Lean.Json` (whose objects are sorted by key) and is converted to the
document value type with numbers in the canonical form of CONFORMANCE §5.5.3.1. -/

namespace Adapter.Doc

open Esm.Document

/-- The canonical number a JSON decimal `m × 10^-e` is. -/
def toJNum (m : Int) (e : Nat) : JNum :=
  if m = 0 then .int 0 else
  let neg := decide (m < 0)
  let ds := (Nat.toDigits 10 m.natAbs).map (fun c => c.toNat - 48)
  let rds := ds.reverse
  let tz := (rds.takeWhile (· == 0)).length
  let core := (rds.dropWhile (· == 0)).reverse
  let e10 : Int := (core.length : Int) - 1 + tz - e
  if (core.length : Int) ≤ e10 + 1 then
    let z : Int := (if neg then -1 else 1) * (JNum.digitsVal core : Int) * 10 ^ (e10 + 1 - core.length).toNat
    if -(2 ^ 63 : Int) ≤ z ∧ z < 2 ^ 63 then .int z else .dec neg core e10
  else .dec neg core e10

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
  | .arr xs => "[" ++ ",".intercalate (xs.map render) ++ "]"
  | .obj kvs => "{" ++ ",".intercalate (kvs.map fun (k, v) =>
      String.ofList (Strings.quote false k) ++ ":" ++ render v) ++ "}"

def readDoc (path : String) : IO Json := do
  let text ← IO.FS.readFile path
  match Lean.Json.parse text with
  | .ok j => pure (conv j)
  | .error e => throw (IO.userError s!"{path}: not JSON: {e}")

def main (mode : String) (args : List String) : IO UInt32 := do
  let [path] := args | IO.eprintln s!"usage: esm-lean {mode} <file>"; return 2
  match mode with
  | "canon" =>
    let d ← readDoc path
    IO.println (render d)
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
  | _ => IO.eprintln s!"unknown mode {mode}"; return 2

end Adapter.Doc
