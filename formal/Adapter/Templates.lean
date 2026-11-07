import Lean.Data.Json
import Adapter.Interp
import Esm.Expr.Template

/-! `esm-lean templates <document.esm> [model]`: the `apply_expression_template`
equations of a template-application document (the `interp_templates` tier,
`tests/closed_functions/interp/*/template.esm`), evaluated with the model's
expression evaluator (`Esm.Expr.evalApply`) at `Float`.

Reads only what those documents use: one model (the one named, or the
document's sole model when none is); its `expression_template_imports`
(each `ref` a library file relative to the document, `only` honoured); its
`parameter` variables' `default`s (a number, or a nested array of numbers up
to rank 3) and the variables defined by an equation `x ~ const(...)`, which
form the environment; and each equation `lhs ~ apply_expression_template(...)`. Prints

```json
{"results": [{"name": "r_x", "value": 15.0, "bits": "4624633867356078080"},
             {"name": "r_y", "error": "..."}]}
```

with one entry per such equation, in document order. Anything else in the
document (an equation of another form, a state, a test block) is ignored: this
mode evaluates expressions, it does not simulate. Exit status 0 on a
well-formed document, 2 on a usage or parse error. -/

namespace Adapter.Templates

open Lean Esm.Expr

partial def constOf (j : Json) : Except String Const :=
  match j with
  | .num n => .ok (.leaf n.mantissa n.exponent)
  | .arr a => return .arr (← a.toList.mapM constOf)
  | _ => .error s!"const value: {j.compress}"

/-- A JSON Expression (§4.1) as an `Ast`. A node field outside the modelled
slice is refused, not dropped. -/
partial def astOf (j : Json) : Except String Ast := do
  match j with
  | .num n => return .num n.mantissa n.exponent
  | .str s => return .var s
  | .obj kvs =>
    let op ← j.getObjValAs? String "op"
    let fields := kvs.toArray.map (·.1)
    let allowed : List String :=
      if op == "const" then ["op", "args", "value", "units"]
      else if op == "apply_expression_template" then ["op", "args", "name", "bindings"]
      else if op == "faq" then ["op", "args", "output_idx", "reduce", "ranges", "expr"]
      else ["op", "args"]
    for f in fields do
      unless allowed.contains f do throw s!"{op} node field {f} is outside the modelled slice"
    let args ← match j.getObjVal? "args" with
      | .ok (.arr a) => a.toList.mapM astOf
      | _ => pure []
    if op == "const" then
      return .const (← constOf (← j.getObjVal? "value"))
    else if op == "apply_expression_template" then
      let bs ← (← j.getObjVal? "bindings").getObj?
      let binds ← bs.toArray.toList.foldrM (fun (k, v) acc => do
        return Binds.cons k (← astOf v) acc) Binds.nil
      return .apply (← j.getObjValAs? String "name") binds
    else if op == "faq" then
      let out ← match j.getObjVal? "output_idx" with
        | .ok (.arr a) => a.toList.mapM (fun o => o.getStr?)
        | _ => pure []
      let red := (j.getObjValAs? String "reduce").toOption.getD "+"
      let ranges ← match j.getObjVal? "ranges" with
        | .ok (.obj rs) =>
          rs.toArray.toList.foldrM (fun (k, t) acc => do
            let tup ← match t with
              | .arr a => a.toList.mapM astOf
              | _ => throw s!"faq range {k}: only a [start, stop] tuple is modelled"
            return Ranges.cons k tup acc) Ranges.nil
        | _ => pure Ranges.nil
      return .faq out red ranges (← astOf (← j.getObjVal? "expr")) args
    else
      return .node op args
  | _ => throw s!"not an Expression: {j.compress}"

def templateOf (j : Json) : Except String Template := do
  let params ← (← j.getObjVal? "params").getArr?
  return { params := (← params.toList.mapM (·.getStr?)), body := ← astOf (← j.getObjVal? "body") }

def errorString : ApplyError → String
  | .expand (.missingBinding p) => s!"apply_expression_template: no binding for {p}"
  | .expand (.extraBinding b) => s!"apply_expression_template: binding {b} names no parameter"
  | .expand (.unknownTemplate n) => s!"apply_expression_template: no template {n} in scope"
  | .expand .tooDeep => "template_body_expansion_too_deep"
  | .eval (.unsupported w) => s!"unsupported: {w}"
  | .eval (.unbound n) => s!"unbound: {n}"
  | .eval (.typeError w) => s!"type error: {w}"
  | .eval .outOfRange => "E_TREEWALK_CONSTARRAY_OOB"
  | .eval .nonIntegral => "index not integral"

def main (args : List String) : IO UInt32 := do
  match args with
  | path :: rest =>
    if rest.length > 1 then
      IO.eprintln "usage: esm-lean templates <document.esm> [model]"
      return 2
    let dir := (System.FilePath.mk path).parent.getD "."
    let run : ExceptT String IO Json := do
      let doc ← liftExcept (Json.parse (← IO.FS.readFile path))
      let modelsJ ← liftExcept (doc.getObjVal? "models")
      let models ← liftExcept modelsJ.getObj?
      let m ← match rest, models.toArray.toList with
        | [name], _ => match modelsJ.getObjVal? name with
          | .ok m => pure m
          | .error _ => throw s!"no model {name}"
        | _, [(_, m)] => pure m
        | _, ms => throw s!"{ms.length} models: name the one to evaluate"
      -- the imported templates
      let mut tpls : List (String × Template) := []
      -- every template of an imported library: the scope its bodies' references
      -- resolve in (§9.7.3), whatever `only` admits for direct use
      let mut scope : List (String × Template) := []
      let imports := (m.getObjValD "expression_template_imports").getArr?.toOption.getD #[]
      for imp in imports do
        let ref ← liftExcept (imp.getObjValAs? String "ref")
        let lib ← liftExcept (Json.parse (← IO.FS.readFile (dir / ref)))
        let ts ← liftExcept ((← liftExcept (lib.getObjVal? "expression_templates")).getObj?)
        let only := (imp.getObjValD "only").getArr?.toOption.map (·.toList.filterMap (·.getStr?.toOption))
        for (name, tj) in ts.toArray.toList do
          let t ← liftExcept (templateOf tj)
          scope := (name, t) :: scope
          if only.all (·.contains name) then
            tpls := (name, t) :: tpls
      -- parameter defaults (numbers or nested arrays of numbers) and variables
      -- defined by a `const` equation (§4.3.3) form the environment
      let vars ← liftExcept ((← liftExcept (m.getObjVal? "variables")).getObj?)
      let mut env : Env Float := []
      for (name, v) in vars.toArray.toList do
        if (v.getObjValAs? String "type").toOption == some "parameter" then
          match v.getObjVal? "default" with
          | .ok (.num n) => env := (name, .num (Lits.ofDec n.mantissa n.exponent)) :: env
          | .ok (.arr a) =>
            if let .ok c := constOf (.arr a) then
              if let .ok val := constVal (α := Float) c then env := (name, val) :: env
          | _ => pure ()
      let eqs := (m.getObjValD "equations").getArr?.toOption.getD #[]
      for e in eqs do
        if let .ok lhs := e.getObjValAs? String "lhs" then
          let rhs := e.getObjValD "rhs"
          if (rhs.getObjValAs? String "op").toOption == some "const" then
            if let .ok c := (rhs.getObjVal? "value").bind constOf then
              if let .ok val := constVal (α := Float) c then env := (lhs, val) :: env
      -- every lhs ~ apply_expression_template(...) equation
      let mut out : Array Json := #[]
      for e in eqs do
        let rhs := e.getObjValD "rhs"
        unless (rhs.getObjValAs? String "op").toOption == some "apply_expression_template" do
          continue
        let lhs ← liftExcept (e.getObjValAs? String "lhs")
        let name ← liftExcept (rhs.getObjValAs? String "name")
        let some t := tpls.lookup name | throw s!"{lhs}: template {name} is not imported"
        let bs ← liftExcept ((← liftExcept (rhs.getObjVal? "bindings")).getObj?)
        let σ ← liftExcept (bs.toArray.toList.mapM (fun (k, v) => do return (k, ← astOf v)))
        match evalApplyIn scope 32 t σ env with
        | .ok (.num x) => out := out.push ((Adapter.Interp.floatJson x).mergeObj
            (Json.mkObj [("name", lhs)]))
        | .ok _ => out := out.push (Json.mkObj [("name", lhs), ("error", "not a scalar")])
        | .error err => out := out.push (Json.mkObj [("name", lhs), ("error", errorString err)])
      return Json.mkObj [("results", Json.arr out)]
    match ← run.run with
    | .ok j => IO.println j.compress; return 0
    | .error e => IO.eprintln s!"esm-lean templates: {e}"; return 2
  | _ => IO.eprintln "usage: esm-lean templates <document.esm> [model]"; return 2

end Adapter.Templates
