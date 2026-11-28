import Lean

/-! Resolve explicit local paths and `esm:std` references for the formal adapters. -/

namespace Adapter.LibraryPath

open System (FilePath)

private def findRoot (dir : FilePath) : Nat → IO (Option FilePath)
  | 0 => pure none
  | remaining + 1 => do
    if (← (dir / "esm-spec.md").pathExists) && (← (dir / "lib").isDir) then
      return some dir
    let some parent := dir.parent | return none
    findRoot parent remaining

private def repositoryRoot (fromDir : FilePath) : IO (Option FilePath) := do
  let app ← IO.appPath
  let appDir := app.parent.getD "."
  if let some root ← findRoot appDir (appDir.components.length + 1) then return some root
  try
    let dir ← IO.FS.realPath fromDir
    findRoot dir (dir.components.length + 1)
  catch _ => return none

/-- Resolve one named file from the bundled library directory or a local
path relative to the importing document. -/
def resolve (dir : FilePath) (ref : String) : ExceptT String IO FilePath := do
  unless ref.startsWith "esm:" do return dir / ref
  let start := "esm:std/"
  let name := (ref.drop start.length).toString
  unless ref.startsWith start && name.endsWith ".esm" && name != ".esm" &&
      !name.contains '/' && !name.contains '\\' do
    throw s!"template_import_unresolved: {ref}"
  let some root ← repositoryRoot dir | throw s!"template_import_unresolved: {ref}"
  let path := root / "lib" / name
  unless ← path.pathExists do throw s!"template_import_unresolved: {ref}"
  return path

end Adapter.LibraryPath
