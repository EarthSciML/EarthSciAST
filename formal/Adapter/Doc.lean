import Lean.Data.Json
import Esm.Document.Source.TypstDoc

/-! `esm-lean canon|print-md|parse-md|print-typ|parse-typ <file>`: the document source formats.

* `canon <doc.esm>`: the document in canonical form, as compact JSON: sorted keys,
  canonical numbers (CONFORMANCE §5.5.3.1), every `units` and `default_units` string in
  the canonical unit spelling (`Esm.Units.canon`, as `canonicalize_document` does), and
  the deprecated `neg` and `pow` rewritten to unary `-` and `^`, and a `const` node in the
  dimensionless unit without its `units` (a scalar one becomes the bare number).
* `print-typ <doc.esm>`, `parse-typ <doc.typ>`: the same for Typst.
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

/-- Object properties whose value is a name-keyed map (esm-schema.json): its keys are
names, never fields, so a variable named `units` is not a units string. The list every
binding's `canonicalize_document` uses. -/
def mapKeys : List String :=
  ["bind", "bindings", "coordinates", "coords", "coupling_roles", "data_sources", "enums",
   "expression_template_imports", "expression_templates", "guesses", "index_set_rename",
   "index_sets", "initial_conditions", "map", "metaparameters", "models", "parameter_overrides",
   "parameters", "pinned_coords", "ranges", "reaction_systems", "rebind", "rename", "species",
   "subsystems", "translate", "url_substitutions", "variables", "where"]

/-- Free-form objects (schema `additionalProperties: true`), never descended. -/
def freeKeys : List String := ["attrs", "config", "metadata", "reader_options", "x_esd"]

/-- The deprecated operators and what they are rewritten to, with their arity. -/
def deprecatedTo : String → Option (String × Nat)
  | "neg" => some ("-", 1)
  | "pow" => some ("^", 2)
  | _ => none

/-- The spelling rules of the canonical form: units strings respelled, `neg` and `pow`
rewritten. `isMap`: the value is a name-keyed map. -/
partial def spellRules (isMap : Bool) : Json → Json
  | .arr xs => .arr (xs.map (spellRules false))
  | .obj kvs =>
    if isMap then .obj (kvs.map fun (k, v) => (k, spellRules false v))
    else
      let kvs' := kvs.map fun (k, v) =>
        match k, v with
        | "units", .str u => (k, .str (Esm.Units.canon u))
        | "default_units", .str u => (k, .str (Esm.Units.canon u))
        | _, _ => if freeKeys.contains k then (k, v) else (k, spellRules (mapKeys.contains k) v)
      match Math.look "op" kvs', Math.look "args" kvs' with
      | some (.str "const"), some (.arr []) =>
        -- A const in the dimensionless unit drops it: a scalar becomes a bare literal.
        match Math.look "units" kvs' with
        | some (.str "1") =>
          let kvs'' := kvs'.filter (fun kv => kv.1 != "units")
          match kvs'' with
          | [("args", .arr []), ("op", .str "const"), ("value", .num n)] => .num n
          | _ => .obj kvs''
        | _ => .obj kvs'
      | some (.str o), some (.arr as) =>
        match deprecatedTo o with
        | some (o', n) =>
          if as.length = n then .obj (kvs'.map fun (k, v) => if k = "op" then (k, .str o') else (k, v))
          else .obj kvs'
        | none => .obj kvs'
      | _, _ => .obj kvs'
  | j => j

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
