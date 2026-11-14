import Adapter.Templates
import Adapter.Units
import Adapter.Doc

/-! The `esm-lean` adapter: `esm-lean <mode> <args>…`. Each mode reads the same
fixture files the binding adapters read and prints the same result JSON. -/

def usage : String :=
  "usage: esm-lean <mode> <args>…\n" ++
  "modes:\n" ++
  "  templates <document.esm> [model [case.json]] evaluate the apply_expression_template equations of a document\n" ++
  "  units <unit_verdicts.json> resolve every unit string in a unit-registry golden\n" ++
  "  canon <doc.esm>              print a document in canonical form (compact JSON)\n" ++
  "  print-md <doc.esm>           print a document as Markdown\n" ++
  "  parse-md <doc.md>            read a Markdown document, print its canonical JSON\n" ++
  "  print-typ <doc.esm>          print a document as Typst\n" ++
  "  parse-typ <doc.typ>          read a Typst document, print its canonical JSON\n"

def main (args : List String) : IO UInt32 := do
  match args with
  | "templates" :: rest => Adapter.Templates.main rest
  | "units" :: rest => Adapter.Units.main rest
  | m :: rest =>
    if m ∈ ["canon", "print-md", "parse-md", "print-typ", "parse-typ"] then Adapter.Doc.main m rest
    else do IO.eprint usage; return 2
  | [] => IO.eprint usage; return 2
