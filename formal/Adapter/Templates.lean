import Lean.Data.Json
import Adapter.Interp
import Esm.Expr.Template

/-! `esm-lean templates <document.esm> [model]`: the `apply_expression_template`
equations of a template-application document (the `interp_templates` tier,
`tests/closed_functions/interp/*/template.esm`), evaluated with the model's
expression evaluator (`Esm.Expr.evalApply`) at `Float`.

Reads only what those documents use: one model (the one named, or the
document's sole model when none is); its `expression_template_imports`
(each `ref` a library file relative to the document, or `esm:std/<file>.esm`
for the repository's `lib/`; `only` honoured); its
`parameter` variables' `default`s (a number, or a nested array of numbers up
to rank 3) and the variables defined by an equation `x ~ const(...)`, which
form the environment, together with every interval index set's `size` (so a
`{"from": set}` range evaluates over the set's positions); each equation
`lhs ~ apply_expression_template(...)`; and each array equation `lhs ~ faq(...)`
whose output indices each range over a whole interval index set
(`{"from": set}`, extent from `index_sets`), with no `join` or `filter` — its
body, or the reduction over its remaining (contracted) ranges, evaluated at
every output index tuple. A ragged range (`{"from": set, "of": [...]}`) is
refused. An equation may be written `lhs ~ ...` or, for an array equation,
`index(lhs, i, ...) ~ faq(...)`. A `distinct` value-invention `faq` (the
producer of a derived index set, `materialize`) is evaluated to its ascending
integer members, which give the derived sets it produces their sizes and their
`member_factor` arrays. Each result is bound for the equations after it. With
a third argument, a caller-data case file (`{"params": {...}, "const_arrays":
{...}}`, the relational rewrites tier's form), its values bind over the
document's defaults. Prints

```json
{"results": [{"name": "r_x", "value": 15.0, "bits": "4624633867356078080"},
             {"name": "A", "coords": {"src_cells": 1, "tgt_cells": 2}, "value": 0.5, ...},
             {"name": "r_y", "error": "..."},
             {"name": "B", "skipped": "faq with join"}]}
```

with one entry per scalar equation and per array entry, in document order; an
array equation outside that slice is reported `skipped`, not evaluated. Anything else in the
document (an equation of another form, a state, a test block) is ignored: this
mode evaluates expressions, it does not simulate. Exit status 0 on a
well-formed document, 2 on a usage or parse error. -/

namespace Adapter.Templates

open Lean Esm.Expr

/-- The file an `expression_template_imports` `ref` names. A standard-library
ref `esm:std/<file>.esm` (esm-spec §4.7) names a file of the repository's
top-level `lib/`, the library this model is checked against (the adapter runs
from `formal/.lake/build/bin/`); its `<file>` is one path segment. Any other ref
is a path relative to the document's directory. -/
def libPath (dir : System.FilePath) (ref : String) : ExceptT String IO System.FilePath := do
  let pre := "esm:std/"
  unless ref.startsWith "esm:" do return dir / ref
  let name := String.ofList (ref.toList.drop pre.length)
  unless ref.startsWith pre && name.endsWith ".esm" && !name.contains '/' && name != ".esm" do
    throw s!"template_import_unresolved: {ref}"
  let app ← IO.appPath
  let some root := app.parent >>= (·.parent) >>= (·.parent) >>= (·.parent) >>= (·.parent)
    | throw s!"template_import_unresolved: {ref} (no repository root above {app})"
  let path := root / "lib" / name
  unless ← path.pathExists do throw s!"template_import_unresolved: {ref}"
  return path

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
    -- `id` and `expect_cadence` are node-header fields (esm-spec §9.7.6): they
    -- describe the node and do not change its value
    let allowed : List String := ["id", "expect_cadence"] ++
      (if op == "const" then ["op", "args", "value", "units"]
      else if op == "apply_expression_template" then ["op", "args", "name", "bindings"]
      else if op == "faq" then ["op", "args", "output_idx", "reduce", "ranges", "expr", "filter"]
      else ["op", "args"])
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
            match t with
              | .arr a => return Ranges.cons k (← a.toList.mapM astOf) acc
              | _ =>
                if let .ok o := t.getObj? then
                  for (f, _) in o.toArray.toList do
                    unless f == "from" do
                      throw s!"faq range {k}: field {f} (a ragged range) is outside the modelled slice"
                match t.getObjValAs? String "from" with
                | .ok set => return Ranges.fromSet k set acc
                | .error _ => throw s!"faq range {k}: neither a tuple nor a from-set") Ranges.nil
        | _ => pure Ranges.nil
      match j.getObjVal? "filter" with
      | .ok p => return .faqWhere out red ranges (← astOf p) (← astOf (← j.getObjVal? "expr")) args
      | .error _ => return .faq out red ranges (← astOf (← j.getObjVal? "expr")) args
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

/-- Every index tuple of the given extents, 1-based, in row-major order. -/
def tuples : List Nat → List (List Nat)
  | [] => [[]]
  | n :: ns => (List.range n).flatMap (fun i => (tuples ns).map (fun t => (i + 1) :: t))

/-- Consecutive runs of `n` elements. -/
def chunk {β : Type} (n : Nat) (l : List β) : List (List β) :=
  (List.range (l.length / n)).map (fun i => (l.drop (i * n)).take n)

/-- An array of rank 1 to 3 from its row-major entries. -/
def shapeVal (sizes : List Nat) (vals : List Float) : Option (Val Float) :=
  match sizes with
  | [_] => some (.arr1 vals)
  | [_, n2] => some (.arr2 (chunk n2 vals))
  | [_, n2, n3] => some (.arr3 (chunk n2 (chunk n3 vals)))
  | _ => none

/-- A `faq` body at one index tuple, references expanded through `scope`. -/
def evalAt (scope : List (String × Template)) (env : Env Float) (body : Ast)
    (syms : List String) (t : List Nat) : Except String Float := do
  let a ← match expandRefs scope 32 body with
    | .ok a => pure a
    | .error e => throw (errorString (.expand e))
  let env' := (syms.zip t).foldl (fun e (sk : String × Nat) =>
    (sk.1, Val.num (Float.ofNat sk.2)) :: e) env
  match eval a env' with
  | .ok (.num x) => pure x
  | .ok _ => throw "not a scalar"
  | .error e => throw (errorString (.eval e))

/-- A `faq` whose output indices each range over a whole interval index set
(`{"from": set}`), with no `join` or `filter`: its output symbols, their
index-set names and extents in `output_idx` order, and the faq left to
evaluate at each output tuple — the node itself with no output indices and only
its contracted ranges, or just its body when it contracts nothing. Or why it is
not one. -/
def mapFaq (sets : Json) (derived : List (String × Nat)) (rhs : Json) :
    Except String (List String × List String × List Nat × Json) := do
  for f in ["join", "filter", "distinct", "key"] do
    if (rhs.getObjVal? f).toOption.isSome then throw s!"faq with {f}"
  if let .ok sr := rhs.getObjValAs? String "semiring" then
    unless sr == "sum_product" do throw s!"faq with semiring {sr}"
  let out ← (← rhs.getObjVal? "output_idx").getArr?
  let syms ← out.toList.mapM (·.getStr?)
  let ranges ← (← rhs.getObjVal? "ranges").getObj?
  let mut names : List String := []
  let mut sizes : List Nat := []
  for k in syms do
    let r ← match ranges.get? k with
      | some r => pure r
      | none => throw s!"output index {k} has no range"
    let set ← r.getObjValAs? String "from"
    let size ← match derived.lookup set with
      | some n => pure n
      | none => match (sets.getObjValD set).getObjValAs? Nat "size" with
        | .ok n => pure n
        | .error _ => throw s!"index set {set} has no size (a derived set not materialised, or not declared)"
    names := names ++ [set]
    sizes := sizes ++ [size]
  let contracted := ranges.toArray.toList.filter (fun (k, _) => !syms.contains k)
  let cell := if contracted.isEmpty then rhs.getObjValD "expr"
    else Json.mkObj ([("op", Json.str "faq"), ("output_idx", Json.arr #[]),
      ("ranges", Json.mkObj contracted), ("expr", rhs.getObjValD "expr")] ++
      ((rhs.getObjVal? "reduce").toOption.map (fun r => ("reduce", r))).toList)
  return (syms, names, sizes, cell)

/-- The literal `{"op": "true"}` (a value-invention body or filter that always
holds). -/
def isTrue (j : Json) : Bool := (j.getObjValAs? String "op").toOption == some "true"

/-- How a derived set could not be materialised: outside the modelled slice
(reported `skipped`), or a value-invention error (reported `error`). -/
inductive VIFail where
  | skip (why : String)
  | error (what : String)

/-- The index set of a rank-1 variable (its `shape`), or none. -/
def shape1 (vars : Json) (name : String) : Option String :=
  match (vars.getObjValD name).getObjValD "shape" with
  | .arr #[.str s] => some s
  | _ => none

/-- §9.6.6 value invention, the `distinct` form a derived index set is produced
by: a `bool_and_or` `faq` with `distinct: true`, every range over a whole
interval set, body `true`, an optional `filter` and optional `join` `on`
clauses (each column a rank-1 variable over the set one range draws from), and
an integer-valued `key`. Every index tuple, in any order, whose join
equalities and filter hold contributes its key; a NaN key is
`value_invention_key_out_of_range`; `-0.0` is `+0.0`; the members are the
distinct keys in ascending order. -/
def materialize (scope : List (String × Template)) (env : Env Float) (vars sets rhs : Json) :
    Except VIFail (List Float) := do
  let skip (w : String) : Except VIFail Unit := throw (.skip w)
  let id := (rhs.getObjValAs? String "id").toOption.getD "?"
  if (rhs.getObjValAs? String "semiring").toOption != some "bool_and_or" then
    skip "distinct faq outside the bool_and_or semiring"
  unless isTrue (rhs.getObjValD "expr") do skip "distinct faq body other than true"
  let ranges ← match (rhs.getObjValD "ranges").getObj? with
    | .ok r => pure r.toArray.toList
    | .error _ => throw (.skip "distinct faq without ranges")
  let mut syms : List String := []
  let mut sizes : List Nat := []
  let mut setOf : List (String × String) := []
  for (k, r) in ranges do
    let fields := (r.getObj?.toOption.map (·.toArray.toList.map (·.1))).getD []
    unless fields == ["from"] do throw (.skip s!"distinct faq range {k}: not a whole index set")
    let some set := (r.getObjValAs? String "from").toOption | throw (.skip s!"range {k}")
    let sj := sets.getObjValD set
    unless (sj.getObjValAs? String "kind").toOption == some "interval" do
      throw (.skip s!"distinct faq range {k} over non-interval set {set}")
    let some n := (sj.getObjValAs? Nat "size").toOption | throw (.skip s!"set {set}: no size")
    syms := syms ++ [k]; sizes := sizes ++ [n]; setOf := setOf ++ [(k, set)]
  let parse (j : Json) : Except VIFail Ast :=
    match astOf j with
    | .error w => throw (.skip w)
    | .ok a => match expandRefs scope 32 a with
      | .ok a => pure a
      | .error e => throw (.error (errorString (.expand e)))
  let keyAst ← parse (← match rhs.getObjVal? "key" with
    | .ok k => pure k
    | .error _ => throw (.skip "distinct faq without key"))
  let mut conds : List Ast := []
  if let .ok f := rhs.getObjVal? "filter" then
    unless isTrue f do conds := conds ++ [← parse f]
  if let .ok (.arr clauses) := rhs.getObjVal? "join" then
    for c in clauses do
      let fields := (c.getObj?.toOption.map (·.toArray.toList.map (·.1))).getD []
      unless fields == ["on"] do throw (.skip "join clause other than on")
      let some (.arr pairs) := (c.getObjVal? "on").toOption | throw (.skip "join on")
      for pr in pairs do
        let some #[.str a, .str b] := pr.getArr?.toOption | throw (.skip "join on pair")
        let symFor (col : String) : Except VIFail String := do
          let some set := shape1 vars col | throw (.skip s!"join column {col}: not a rank-1 variable")
          match setOf.filter (·.2 == set) with
          | [(k, _)] => pure k
          | _ => throw (.skip s!"join column {col}: no single range over {set}")
        let ka ← symFor a
        let kb ← symFor b
        conds := conds ++ [.node "==" [.node "index" [.var a, .var ka], .node "index" [.var b, .var kb]]]
  let ev (a : Ast) (e : Env Float) : Except VIFail Float :=
    match eval a e with
    | .ok (.num x) => pure x
    | .ok _ => throw (.error "not a scalar")
    | .error err => throw (.error (errorString (.eval err)))
  let mut keys : List Float := []
  for t in tuples sizes do
    let e := (syms.zip t).foldl (fun e (sk : String × Nat) =>
      (sk.1, Val.num (Float.ofNat sk.2)) :: e) env
    let mut keep := true
    for c in conds do
      if keep then keep := truthy (← ev c e)
    if keep then
      let k ← ev keyAst e
      if k.isNaN then
        throw (.error s!"value_invention_key_out_of_range: a key of {id} is NaN")
      unless k.isFinite && k.floor == k do
        throw (.error s!"value_invention_key_out_of_range: a key of {id} is not an integer")
      keys := (if k == 0.0 then 0.0 else k) :: keys
  let sorted := keys.mergeSort (fun a b => a ≤ b)
  return sorted.foldr (fun x acc => match acc with
    | y :: _ => if x == y then acc else x :: acc
    | [] => [x]) []

def main (args : List String) : IO UInt32 := do
  match args with
  | path :: rest =>
    if rest.length > 2 then
      IO.eprintln "usage: esm-lean templates <document.esm> [model [case.json]]"
      return 2
    let dir := (System.FilePath.mk path).parent.getD "."
    let run : ExceptT String IO Json := do
      let doc ← liftExcept (Json.parse (← IO.FS.readFile path))
      let modelsJ ← liftExcept (doc.getObjVal? "models")
      let models ← liftExcept modelsJ.getObj?
      let m ← match rest.take 1, models.toArray.toList with
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
        let lib ← liftExcept (Json.parse (← IO.FS.readFile (← libPath dir ref)))
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
      -- a caller-data case (the relational rewrites tier): its `params` and
      -- `const_arrays` bind over the defaults
      if let [_, casePath] := rest then
        let cj ← liftExcept (Json.parse (← IO.FS.readFile casePath))
        if let .ok ps := (cj.getObjValD "params").getObj? then
          for (k, v) in ps.toArray.toList do
            if let .ok n := v.getNum? then env := (k, .num (Lits.ofDec n.mantissa n.exponent)) :: env
        if let .ok cs := (cj.getObjValD "const_arrays").getObj? then
          for (k, v) in cs.toArray.toList do
            match constOf v with
            | .ok c => match constVal (α := Float) c with
              | .ok val => env := (k, val) :: env
              | .error _ => throw s!"case array {k}: not an array of rank 1 to 3"
            | .error w => throw s!"case array {k}: {w}"
      let eqs := (m.getObjValD "equations").getArr?.toOption.getD #[]
      for e in eqs do
        if let .ok lhs := e.getObjValAs? String "lhs" then
          let rhs := e.getObjValD "rhs"
          if (rhs.getObjValAs? String "op").toOption == some "const" then
            if let .ok c := (rhs.getObjVal? "value").bind constOf then
              if let .ok val := constVal (α := Float) c then env := (lhs, val) :: env
      -- every lhs ~ apply_expression_template(...) equation, and every array
      -- equation lhs ~ faq(...) that maps such a template (or any expression
      -- the evaluator covers) over whole index sets; each result is bound for
      -- the equations after it
      let sets := match doc.getObjVal? "index_sets" with
        | .ok j => j
        | .error _ => m.getObjValD "index_sets"
      -- every interval set's declared size, for the `{"from": set}` ranges the
      -- evaluator visits (`Esm.Expr.setKey`); a derived or ragged set has none
      if let .ok so := sets.getObj? then
        for (name, sj) in so.toArray.toList do
          if (sj.getObjValAs? String "kind").toOption == some "interval" then
            if let .ok n := sj.getObjValAs? Nat "size" then
              env := (setKey name, .num (Float.ofNat n)) :: env
      -- equations are evaluated in document order, in passes until a pass
      -- evaluates no more of them than the one before: a document may define a
      -- variable after the equations that read it
      let mut out : Array Json := #[]
      -- the sizes of the derived sets materialised so far
      let mut derived : List (String × Nat) := []
      let mut prevOk := 0
      for _pass in List.range (eqs.size + 1) do
        out := #[]
        for e in eqs do
          let rhs := e.getObjValD "rhs"
          let op := (rhs.getObjValAs? String "op").toOption
          -- `x` or `index(x, i, ...)` (an array equation's element form)
          let lhsJ := e.getObjValD "lhs"
          let indexed := (lhsJ.getObjValAs? String "op").toOption == some "index"
          let some lhs := (match lhsJ with
            | .str s => some s
            | l => if indexed then
                match l.getObjValD "args" with
                | .arr a => (a[0]?.bind (·.getStr?.toOption))
                | _ => none
              else none) | continue
          if op == some "faq" && (rhs.getObjValAs? Bool "distinct").toOption == some true then
            let id := (rhs.getObjValAs? String "id").toOption.getD ""
            match materialize scope env (Json.mkObj vars.toArray.toList) sets rhs with
            | .error (.skip why) =>
              out := out.push (Json.mkObj [("name", lhs), ("set", id), ("skipped", why)])
            | .error (.error what) =>
              out := out.push (Json.mkObj [("name", lhs), ("set", id), ("error", what)])
            | .ok keys =>
              out := out.push (Json.mkObj [("name", lhs), ("set", id),
                ("members", toJson (keys.map Adapter.Interp.floatJson)),
                ("extent", toJson keys.length)])
              -- every index set this node produces gets its size, and its
              -- `member_factor` the ascending keys
              if let .ok so := sets.getObj? then
                for (name, sj) in so.toArray.toList do
                  if (sj.getObjValAs? String "from_faq").toOption == some id then
                    env := (setKey name, .num (Float.ofNat keys.length)) :: env
                    derived := (name, keys.length) :: derived
                    if let .ok mf := sj.getObjValAs? String "member_factor" then
                      env := (mf, .arr1 keys) :: env
          else if indexed && op != some "faq" then
            continue
          else if op == some "apply_expression_template" then
            let name ← liftExcept (rhs.getObjValAs? String "name")
            let some t := tpls.lookup name | throw s!"{lhs}: template {name} is not imported"
            let bs ← liftExcept ((← liftExcept (rhs.getObjVal? "bindings")).getObj?)
            let σ ← liftExcept (bs.toArray.toList.mapM (fun (k, v) => do return (k, ← astOf v)))
            match evalApplyIn scope 32 t σ env with
            | .ok (.num x) =>
              out := out.push ((Adapter.Interp.floatJson x).mergeObj (Json.mkObj [("name", lhs)]))
              env := (lhs, .num x) :: env
            | .ok (.inf neg) =>
              let x : Float := if neg then -(1.0 / 0.0) else 1.0 / 0.0
              out := out.push ((Adapter.Interp.floatJson x).mergeObj (Json.mkObj [("name", lhs)]))
            | .ok _ => out := out.push (Json.mkObj [("name", lhs), ("error", "not a scalar")])
            | .error err =>
              out := out.push (Json.mkObj [("name", lhs), ("error", errorString err)])
          else if op == some "faq" && (rhs.getObjVal? "output_idx").toOption.isSome then
            match mapFaq sets derived rhs with
            | .error why => out := out.push (Json.mkObj [("name", lhs), ("skipped", why)])
            | .ok (syms, names, sizes, cell) =>
              match astOf cell with
              | .error why => out := out.push (Json.mkObj [("name", lhs), ("skipped", why)])
              | .ok body =>
                let ts := tuples sizes
                match ts.mapM (evalAt scope env body syms) with
                | .error why => out := out.push (Json.mkObj [("name", lhs), ("skipped", why)])
                | .ok vals =>
                  for (t, x) in ts.zip vals do
                    let coords := Json.mkObj ((names.zip t).map (fun (n, k) => (n, toJson k)))
                    out := out.push ((Adapter.Interp.floatJson x).mergeObj
                      (Json.mkObj [("name", lhs), ("coords", coords)]))
                  if let some v := shapeVal sizes vals then env := (lhs, v) :: env
        let ok := (out.filter (fun r => (r.getObjVal? "skipped").toOption.isNone &&
          (r.getObjVal? "error").toOption.isNone)).size
        if ok == prevOk then break
        prevOk := ok
      return Json.mkObj [("results", Json.arr out)]
    match ← run.run with
    | .ok j => IO.println j.compress; return 0
    | .error e => IO.eprintln s!"esm-lean templates: {e}"; return 2
  | _ => IO.eprintln "usage: esm-lean templates <document.esm> [model]"; return 2

end Adapter.Templates
