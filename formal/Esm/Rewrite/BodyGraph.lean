import Esm.Rewrite.Engine

/-! Authored definition-reference graph checks shared by component scopes and
operator-library export scopes (esm-spec §9.7.3). -/

namespace Esm.Rewrite.BodyGraph

abbrev Graph := List (String × List String)
private abbrev Depths := List (String × Nat)

private partial def bodyDepth (graph : Graph) (ancestors : List String) (known : Depths)
    (name : String) : Except (String × String) (Depths × Nat) := do
  if ancestors.contains name then throw ("operator_recursive_body", name)
  if ancestors.length ≥ maxRewritePasses then throw ("operator_body_expansion_too_deep", name)
  if let some depth := known.lookup name then return (known, depth)
  let mut depths := known
  let mut longest := 0
  for child in (graph.lookup name).getD [] do
    let (next, depth) ← bodyDepth graph (name :: ancestors) depths child
    depths := next
    longest := max longest depth
  let depth := longest + 1
  if depth > maxRewritePasses then throw ("operator_body_expansion_too_deep", name)
  return ((name, depth) :: depths, depth)

/-- Acyclic, with at most 64 definitions along every authored body path.
Callers resolve names and check bindings before handing the graph to this function. -/
def checkGraph (graph : Graph) : Except (String × String) Unit := do
  let _ ← graph.foldlM (fun known (name, _) => do
    return (← bodyDepth graph [] known name).1) []

end Esm.Rewrite.BodyGraph
