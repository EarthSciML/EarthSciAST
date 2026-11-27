import Adapter.OrderedJson
import Adapter.LibraryPath
import Esm.Rewrite.BodyGraph
import Esm.Rewrite.Imports
import Esm.Rewrite.Metaparameters

/-! Load local operator libraries in dependency order, then instantiate each
edge in the export vocabulary of its target (esm-spec §9.7). -/

namespace Adapter.OperatorImports

open Esm.Document (Json)
open Esm.Rewrite.Imports
open System (FilePath)

open Esm.Rewrite

private abbrev Loader := StateT (Std.HashMap String Exports) (ExceptT Failure IO)

private def liftResult {α : Type} (result : Except Failure α) : Loader α :=
  match result with
  | .ok value => pure value
  | .error error => throw error

private def liftMeta {α : Type} (result : Except Metaparameters.Error α) : Loader α :=
  liftResult (result.mapError fun error => ⟨error.code, error.detail⟩)

private def invalid (field : String) : Failure :=
  ⟨"invalid_document", s!"{field}: malformed import declaration"⟩

private def renameMap (node : Json) (key : String) : Except Failure Renames := do
  let some value := get node key | return []
  let .obj fields := value | throw ⟨"operator_import_rename_invalid", key⟩
  fields.mapM fun (name, target) => do
    let .str target := target | throw ⟨"operator_import_rename_invalid", s!"{key}.{name}"⟩
    return (name, target)

private def readEdge (node : Json) : Except Failure Edge := do
  let some (.str ref) := get node "ref" | throw (invalid "ref")
  let only ← match get node "only" with
    | none => pure none
    | some (.arr nodes) => do
      let some names := nodes.mapM string? | throw (invalid "only")
      pure (some names)
    | _ => throw (invalid "only")
  let namespacePrefix ← match get node "prefix" with
    | none => pure none
    | some (.str value) => pure (some value)
    | _ => throw ⟨"operator_import_rename_invalid", "prefix"⟩
  let rename ← renameMap node "rename"
  let rebind ← renameMap node "rebind"
  return ⟨ref, only, namespacePrefix, rename, rebind⟩

private def readEdges (node : Json) : Except Failure (List Json) := do
  match get node "operator_imports" with
  | none => pure []
  | some (.arr values) => pure values
  | _ => throw (invalid "operator_imports")

private def forbiddenLibraryKeys (document : Json) : List String :=
  ["models", "reaction_systems", "data_sources", "coupling", "domain"].filter fun key =>
    (get document key).isSome

private def earlierThanImports (document : Json) : Bool :=
  match ((get document "esm").bind string?).map (·.splitOn ".") with
  | some (major :: minor :: _) => major.toNat? == some 0 && (minor.toNat?.any (· < 8))
  | _ => false

private def components (document : Json) : List (String × Entries) :=
  ["models", "reaction_systems"].map fun key => (key, entries document key)

private def checkVersion (document : Json) (source : FilePath) : Except Failure Unit := do
  let usesImports := (get document "operators").isSome || (get document "operator_imports").isSome ||
    (get document "metaparameters").isSome ||
    (components document).any (fun (_, nodes) =>
      nodes.any fun (_, node) => (get node "operator_imports").isSome)
  if usesImports && earlierThanImports document then
    throw ⟨"operator_import_version_too_old", source.toString⟩

private def readDocument (source : FilePath) : IO (Except Failure Json) := do
  try
    let input ← IO.FS.readFile source
    return (OrderedJson.parse input).map
      (Doc.spellRules false · (omitFaqDefaults := false))
      |>.mapError fun error => ⟨"operator_import_unresolved", s!"{source}: {error}"⟩
  catch error =>
    return .error ⟨"operator_import_unresolved", s!"{source}: {error}"⟩

private def canonicalFile (source : FilePath) : IO (Except Failure FilePath) := do
  try return .ok (← IO.FS.realPath source)
  catch error => return .error ⟨"operator_import_unresolved", s!"{source}: {error}"⟩

private def locate (source : FilePath) (ref : String) : Loader (String × FilePath) := do
  if ref.contains ':' && !ref.startsWith "esm:" then
    throw ⟨"operator_import_unresolved", s!"URL imports are unavailable: {ref}"⟩
  let directory := source.parent.getD "."
  let lookedUp ← (LibraryPath.resolve directory ref).run
  let path ← liftResult (lookedUp.mapError fun error => ⟨"operator_import_unresolved", error⟩)
  let path ← liftResult (← canonicalFile path)
  let identity := if ref.startsWith "esm:" then ref else path.toString
  return (identity, path)

private def referenceTarget (definitions : Entries) (site : Json) : Except Failure String := do
  let some (.str name) := get site "name"
    | throw ⟨"operator_unknown_definition", "missing name"⟩
  let some declaration := definitions.lookup name
    | throw ⟨"operator_unknown_definition", name⟩
  if (get declaration "match").isSome then throw ⟨"operator_unknown_definition", name⟩
  let some (.arr []) := get site "args" | throw ⟨"operator_bindings_mismatch", name⟩
  let some (.obj bindings) := get site "bindings" | throw ⟨"operator_bindings_mismatch", name⟩
  let params := (get declaration "params").map strings |>.getD []
  if bindings.length != params.length || !(params.all fun key => (bindings.lookup key).isSome) then
    throw ⟨"operator_bindings_mismatch", name⟩
  return name

private def checkBodies (definitions : Entries) : Except Failure Unit := do
  let graph ← definitions.mapM fun (name, declaration) => do
    let some body := get declaration "body" | throw ⟨"operator_invalid_definition", name⟩
    let edges ← (referenceSites body).mapM (referenceTarget definitions)
    return (name, edges)
  (Esm.Rewrite.BodyGraph.checkGraph graph).mapError fun (code, detail) => ⟨code, detail⟩

private partial def containsEnum : Json → Bool
  | .arr items => items.any containsEnum
  | .obj fields => (fields.lookup "op").any (fun value => string? value == some "enum") ||
      fields.any (fun (key, value) => key != "attrs" && containsEnum value)
  | _ => false

private def checkEnumScope (source : FilePath) (definitions : Entries) : Except Failure Unit := do
  -- These calls must resolve in the library's own instance scope before
  -- crossing the edge. Passing through the importer would change their meaning.
  for (name, declaration) in definitions do
    if (get declaration "body").any containsEnum then
      throw ⟨"unsupported_construct", s!"library-local enum resolution in {source}, definition {name}"⟩

private structure Prepared where
  raw : Json
  edge : Edge
  target : Exports

private def bindingNames (edge : Json) : List String := (entries edge "bindings").map Prod.fst

private def plannedMetaNames (prepared : Prepared) : List String :=
  prepared.target.metaparameters.filterMap fun (name, _) =>
    if (bindingNames prepared.raw).contains name then none
    else some (renamedExport prepared.edge name)

private def applyEdge (importerNames : List String) (prepared : Prepared) : Loader Exports := do
  let bindings ← liftMeta (Metaparameters.edgeBindings prepared.raw importerNames)
  let definitions ← liftResult (selectDefinitions prepared.target.definitions prepared.edge.only)
  let selected := {prepared.target with definitions}
  let plan ← liftResult (planRename prepared.edge selected (bindings.map Prod.fst))
  let (document, deferredBindings) ← liftMeta (Metaparameters.instantiate
    prepared.target.asDocument bindings plan.metaRenames prepared.target.deferredBindings)
  let instantiated := exports document
  let definitions := instantiated.definitions.filter fun (name, _) => (definitions.lookup name).isSome
  return plan.transform {instantiated with definitions, deferredBindings}

private def mergeEdges (importerNames : List String) (prepared : List Prepared) :
    Loader Exports :=
  prepared.foldlM (init := {}) fun merged edge => do
    let imported ← applyEdge importerNames edge
    liftResult (merge merged imported)

mutual

private partial def prepareEdges (stack : List String) (source : FilePath) (scope : Json) :
    Loader (List Prepared) := do
  (← liftResult (readEdges scope)).mapM fun raw => do
    let edge ← liftResult (readEdge raw)
    let target ← loadLibrary stack source edge.ref
    return ⟨raw, edge, target⟩

private partial def loadLibrary (stack : List String) (source : FilePath) (ref : String) :
    Loader Exports := do
  let (identity, path) ← locate source ref
  if stack.contains identity then
    throw ⟨"operator_import_cycle", " → ".intercalate (stack.reverse ++ [identity])⟩
  if let some cached := (← StateT.get)[identity]? then return cached
  let document ← liftResult (← readDocument path)
  if !(forbiddenLibraryKeys document).isEmpty || (get document "operators").isNone then
    throw ⟨"operator_import_not_library", path.toString⟩
  let some (.obj _) := get document "operators"
    | throw ⟨"operator_import_not_library", path.toString⟩
  liftResult (checkVersion document path)
  let prepared ← prepareEdges (identity :: stack) path document
  let localExports := exports document
  liftResult (checkEnumScope path localExports.definitions)
  let names := localExports.metaparameters.map Prod.fst ++ prepared.flatMap plannedMetaNames
  let imported ← mergeEdges names prepared
  let all ← liftResult (merge imported localExports)
  liftMeta (Metaparameters.validateNames all.asDocument)
  liftResult (checkBodies all.definitions)
  modify fun cache => cache.insert identity all
  return all

end

private def updateEntries (node : Json) (key : String) (values : Entries) : Json :=
  if values.isEmpty && (get node key).isNone then node else set node key (.obj values)

private def resolveRootLibrary (stack : List String) (source : FilePath) (document : Json) :
    Loader Json := do
  let forbidden := forbiddenLibraryKeys document
  unless forbidden.isEmpty do
    throw ⟨"operator_library_illegal_payload", ", ".intercalate forbidden⟩
  let prepared ← prepareEdges stack source document
  let localExports := exports document
  let names := localExports.metaparameters.map Prod.fst ++ prepared.flatMap plannedMetaNames
  let imported ← mergeEdges names prepared
  let all ← liftResult (merge imported localExports)
  liftMeta (Metaparameters.validateNames all.asDocument)
  liftResult (checkBodies all.definitions)
  -- Generic library loading leaves exported metaparameters open.
  return Metaparameters.clearDeferred
    (updateEntries
      (updateEntries (set (remove document "operator_imports") "operators" (.obj all.definitions))
        "index_sets" all.axes)
      "metaparameters" all.metaparameters)

private def resolveRoot (source : FilePath) (document : Json) : Loader Json := do
  let source ← liftResult (← canonicalFile source)
  liftResult (checkVersion document source)
  let stack := [source.toString]
  if (get document "operators").isSome then return ← resolveRootLibrary stack source document
  if (get document "operator_imports").isSome then
    throw (invalid "top-level operator_imports requires an operator library")
  let sections ← (components document).mapM fun (key, values) => do
    let members ← values.mapM fun (name, component) => do
      return (name, component, ← prepareEdges stack source component)
    return (key, members)
  let localExports := exports document
  let allPrepared := sections.flatMap fun (_, members) => members.flatMap fun (_, _, edges) => edges
  let names := localExports.metaparameters.map Prod.fst ++ allPrepared.flatMap plannedMetaNames
  let mut globalExports := localExports
  let mut resolved := document
  for (key, members) in sections do
    let mut updated : Entries := []
    for (name, component, edges) in members do
      let imported ← mergeEdges names edges
      let definitions ← liftResult
        (mergeEntries "operator_import_name_conflict" imported.definitions (entries component "operators"))
      globalExports ← liftResult (merge globalExports {imported with definitions := []})
      let component := updateEntries (remove component "operator_imports") "operators" definitions
      updated := updated ++ [(name, component)]
    resolved := updateEntries resolved key updated
  let withExports := updateEntries (updateEntries resolved "index_sets" globalExports.axes)
    "metaparameters" globalExports.metaparameters
  let (closed, _) ← liftMeta (Metaparameters.close withExports
    (deferredBindings := globalExports.deferredBindings))
  return closed

/-- Resolve imports of an ordered, canonicalized document against its file.
A component retains its effective definitions in declaration order. -/
def resolve (source : FilePath) (document : Json) : IO (Except Failure Json) :=
  ((resolveRoot source document).run {}).run.map (·.map Prod.fst)

end Adapter.OperatorImports
