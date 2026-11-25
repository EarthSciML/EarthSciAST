import Adapter.Templates
import Adapter.Static
import Adapter.Units
import Adapter.Doc

/-! The `esm-lean` adapter: `esm-lean <mode> <args>…`. Each mode reads the same
fixture files the binding adapters read and prints the same result JSON. -/

def usage : String :=
  "usage: esm-lean <mode> <args>…\n" ++
  "modes:\n" ++
  "  templates <document.esm> [model [case.json]] evaluate the apply_operator equations of a document\n" ++
  "  static-assertions <doc.esm> <model> evaluate requested static assertions (JSON on stdin)\n" ++
  "  static-assertions-jsonl <model> evaluate static assertions for a stream of ESM documents\n" ++
  "  units <unit_verdicts.json> resolve every unit string in a unit-registry golden\n" ++
  "  canon <doc.esm>              print a document in canonical form (compact JSON)\n" ++
  "  print-md <doc.esm>           print a document as Markdown\n" ++
  "  parse-md <doc.md>            read a Markdown document, print its canonical JSON\n" ++
  "  print-typ <doc.esm>          print a document as Typst\n" ++
  "  parse-typ <doc.typ>          read a Typst document, print its canonical JSON\n"

def main (args : List String) : IO UInt32 := do
  match args with
  | "templates" :: rest => Adapter.Templates.main rest
  | "static-assertions" :: rest => Adapter.Static.main rest
  | "static-assertions-jsonl" :: rest => Adapter.Static.batch rest
  | "units" :: rest => Adapter.Units.main rest
  | m :: rest =>
    if m ∈ ["canon", "print-md", "parse-md", "print-typ", "parse-typ"] then Adapter.Doc.main m rest
    else do IO.eprint usage; return 2
  | [] => IO.eprint usage; return 2
