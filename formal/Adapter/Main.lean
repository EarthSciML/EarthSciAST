import Adapter.Templates
import Adapter.Units

/-! The `esm-lean` adapter: `esm-lean <mode> <args>…`. Each mode reads the same
fixture files the binding adapters read and prints the same result JSON. -/

def usage : String :=
  "usage: esm-lean <mode> <args>…\n" ++
  "modes:\n" ++
  "  templates <document.esm> [model [case.json]] evaluate the apply_expression_template equations of a document\n" ++
  "  units <unit_verdicts.json> resolve every unit string in a unit-registry golden\n"

def main (args : List String) : IO UInt32 := do
  match args with
  | "templates" :: rest => Adapter.Templates.main rest
  | "units" :: rest => Adapter.Units.main rest
  | _ => IO.eprint usage; return 2
