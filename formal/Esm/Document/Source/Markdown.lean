import Esm.Document.Source.Text
import Esm.Document.Source.YamlLines

/-!
# The Markdown container

An ESM document in Markdown is CommonMark with `$…$` / `$$…$$` math (LaTeX), fenced
blocks, YAML front matter and directives:

```
---
esm: "2.1.0"
name: "Decay"
---

```esm:description
First-order radioactive decay.
```

::model[Decay]

:var[$N$]{default=100 units="mol"}

$$
\frac{\mathrm{d} N}{\mathrm{d} t} = -\lambda N
$$
```

The constructs (`Esm.Document.Source.RItem`), and where they may appear:

* front matter: the first line is `---`, then the YAML of the front-matter entries
  (`Esm.Document.Yaml`), then a line `---`;
* at the start of a line: a fenced block ```` ```esm:description ```` holding a
  description verbatim, or ```` ```esm:<key> ```` holding a path block's value in YAML;
  a display equation `$$`, its LaTeX on the following lines, then `$$` (optionally
  followed by an equation label `{#eq-x}`, which is discarded); a component directive
  `::model[Name]` or `::reaction-system[Name]` on a line of its own;
* anywhere in a line: a declaration `:var[$N$]{…}`, `:param[…]{…}` or `:species[…]{…}`,
  the name in LaTeX math and the attributes as `key=value` pairs with YAML scalars.

Everything else is prose, which the parser skips: `lex` reads a construct where one
starts and otherwise drops one character. So the parse depends only on the sequence of
constructs (`lex_render`): inserting or removing prose, and adding or removing equation
labels, never changes it.

Restrictions this places on prose (`Inert`): prose may not contain a declaration opener
(`:var[`, `:param[`, `:species[`) anywhere, nor start a line with ```` ```esm: ````,
`$$`, `::model[` or `::reaction-system[`. In particular display math (`$$`) at the start
of a line is always a model equation; illustrative math in prose uses inline `$…$` or
another delimiter.
-/

namespace Esm.Document.Source.Md

open Esm.Document Esm.Document.Math Esm.Document.Source Esm.Document.Strings

/-! ## Spellings -/

/-- ```` ```esm: ```` -/
def fenceEsm : List Char := "```esm:".toList
/-- ```` ``` ```` -/
def fence : List Char := "```".toList
/-- `$$` -/
def dd : List Char := "$$".toList
/-- `::model[` -/
def dModel : List Char := "::model[".toList
/-- `::reaction-system[` -/
def dRs : List Char := "::reaction-system[".toList
/-- `---` -/
def dashes : List Char := "---".toList
/-- The info string of the description block. -/
def descInfo : List Char := "description".toList

/-- The directive keyword of a declaration. -/
def dkw : DKind → List Char
  | .var => "var".toList
  | .param => "param".toList
  | .species => "species".toList

/-! ## Path-block keys -/

/-- One character of a quoted key: the JSON escape, and the backtick as ``` (the info
string of a backtick fence cannot hold a backtick). -/
def escKey (c : Char) : List Char :=
  if c = '`' then '\\' :: 'u' :: hex4 c.toNat else escChar false c

/-- A path block's key in the fence's info string: bare when it is an identifier other
than `description` (the description block), quoted otherwise. -/
def keyMd (k : String) : List Char :=
  if isIdent k.toList && k != "description" then k.toList
  else '"' :: k.toList.flatMap escKey ++ ['"']

/-- Read a path block's key from the info string (all of it). -/
def parseKeyMd (info : List Char) : Option String :=
  match info with
  | '"' :: _ =>
    match parseQuoted false info with
    | some (k, []) => some k
    | _ => none
  | _ => if isIdent info && info != descInfo then some (String.ofList info) else none

/-! ## Declarations -/

/-- A declared name, as LaTeX math under the empty symbol table (so it reads the same
whatever else the document declares). -/
def nameLatex (n : String) : List Char := (printLatex {} (.str n)).toList

/-- One attribute: `key=value`, the value a YAML scalar. -/
def attrMd (a : String × Json) : List Char := a.1.toList ++ '=' :: Yaml.inline a.2

/-- The attributes, separated by spaces. -/
def attrsMd : List (String × Json) → List Char
  | [] => []
  | a :: as => attrMd a ++ as.flatMap (fun b => ' ' :: attrMd b)

/-- `:var[$N$]{default=100 units="mol"}`. -/
def declMd (d : Decl) : List Char :=
  ':' :: dkw d.kind ++ '[' :: '$' :: nameLatex d.name ++ '$' :: ']' :: '{' :: attrsMd d.attrs ++ ['}']

/-- One attribute. -/
def pAttr (s : List Char) : Option ((String × Json) × List Char) :=
  if isIdent (readIdent s).1 then
    match (readIdent s).2 with
    | '=' :: u => (Yaml.pInline u).map (fun p => ((String.ofList (readIdent s).1, p.1), p.2))
    | _ => none
  else none

/-- The attributes after the first, each after a space, up to the closing brace. -/
def pAttrsMore : Nat → List Char → Option (List (String × Json) × List Char)
  | 0, _ => none
  | _ + 1, '}' :: r => some ([], r)
  | f + 1, ' ' :: r =>
    (pAttr r).bind (fun p => (pAttrsMore f p.2).map (fun q => (p.1 :: q.1, q.2)))
  | _ + 1, _ => none

/-- The attributes after the opening brace, up to the closing one. -/
def pAttrs (f : Nat) : List Char → Option (List (String × Json) × List Char)
  | '}' :: r => some ([], r)
  | s => (pAttr s).bind (fun p => (pAttrsMore f p.2).map (fun q => (p.1 :: q.1, q.2)))

/-- A declaration after its `[`. -/
def declBody (f : Nat) (k : DKind) : List Char → Option (RItem × List Char)
  | '$' :: t =>
    match t.drop (t.takeWhile (· != '$')).length with
    | '$' :: ']' :: '{' :: u =>
      match parseLatex {} (String.ofList (t.takeWhile (· != '$'))) with
      | some (.str n) => (pAttrs f u).map (fun p => (.decl ⟨k, n, p.1⟩, p.2))
      | _ => none
    | _ => none
  | _ => none

/-! ## Block constructs -/

/-- A fenced block's construct, from its info string and body. -/
def fenceItem (info body : List Char) : Option RItem :=
  if info = descInfo then
    if body.getLast? = some '\n' then some (.desc (String.ofList body.dropLast)) else none
  else (parseKeyMd info).bind (fun k => (Yaml.decode body).map (.block k))

/-- An equation label after the closing `$$`: nothing, or `{#id}`, with spaces around. -/
def labelOK (sl : List Char) : Bool :=
  match sl.dropWhile (· == ' ') with
  | [] => true
  | '{' :: '#' :: r => r.getLast? == some '}' && !(r.dropLast.contains '}')
  | _ => false

/-- A fenced block after ```` ```esm: ````. -/
def fenceAt (f : Nat) (u : List Char) : Option (RItem × List Char) :=
  match untilStop fence f (splitLine u).2 with
  | some (body, sl, rest) =>
    if sl.all (· == ' ') then (fenceItem (splitLine u).1 body).map (fun it => (it, rest)) else none
  | none => none

/-- A display equation after its opening `$$`. -/
def mathAt (f : Nat) (u : List Char) : Option (RItem × List Char) :=
  if (splitLine u).1.all (· == ' ') then
    match untilStop dd f (splitLine u).2 with
    | some (body, sl, rest) =>
      if labelOK sl && body.getLast? == some '\n' then
        some (.eqn (String.ofList body.dropLast), rest)
      else none
    | none => none
  else none

/-- A component directive after its `[`. -/
def dirAt (K : Kind) (u : List Char) : Option (RItem × List Char) :=
  match u.drop (u.takeWhile (fun c => c != ']' && c != '\n')).length with
  | ']' :: t =>
    if (splitLine t).1.all (· == ' ') then
      some (.comp K (String.ofList (u.takeWhile (fun c => c != ']' && c != '\n'))), (splitLine t).2)
    else none
  | _ => none

/-! ## The lexer -/

/-- A block construct starts here (at the start of a line). -/
def blockOpen (s : List Char) : Bool := pre fenceEsm s || pre dd s || pre dModel s || pre dRs s

/-- A declaration starts here. -/
def declOpen (s : List Char) : Bool :=
  pre ":var[".toList s || pre ":param[".toList s || pre ":species[".toList s

/-- Read the block construct that starts here. -/
def blockAt (f : Nat) (s : List Char) : Option (RItem × List Char) :=
  if pre fenceEsm s then fenceAt f (s.drop 7)
  else if pre dd s then mathAt f (s.drop 2)
  else if pre dModel s then dirAt .model (s.drop 8)
  else dirAt .rs (s.drop 18)

/-- Read the declaration that starts here. -/
def declAt (f : Nat) (s : List Char) : Option (RItem × List Char) :=
  if pre ":var[".toList s then declBody f .var (s.drop 5)
  else if pre ":param[".toList s then declBody f .param (s.drop 7)
  else declBody f .species (s.drop 9)

/-! ## The declarations table (an accepted input variant)

A per-model declarations table is read as the declarations it lists; the printer never
writes it (it writes `:var` directives):

```
| decl | name | default | units |
| --- | --- | --- | --- |
| var | $N$ | 100 | "mol" |
| param | $\lambda$ | 0.1 | "1/s" |
```

The first two columns are the directive and the name; every other column header is an
attribute key, and a cell is a YAML scalar or empty (the attribute is absent). -/

/-- `| decl | name |`, the start of a declarations table. -/
def tableOpen : List Char := "| decl | name |".toList

/-- The attribute columns of the header, up to its newline. -/
def pCols : Nat → List Char → Option (List String × List Char)
  | 0, _ => none
  | _ + 1, '\n' :: r => some ([], r)
  | f + 1, ' ' :: r =>
    if isIdent (readIdent r).1 then
      match (readIdent r).2 with
      | ' ' :: '|' :: u => (pCols f u).map (fun p => (String.ofList (readIdent r).1 :: p.1, p.2))
      | _ => none
    else none
  | _ + 1, _ => none

/-- One cell: ` value |`, or ` |` when the attribute is absent. -/
def pCell : List Char → Option (Option Json × List Char)
  | ' ' :: '|' :: r => some (none, r)
  | ' ' :: r =>
    match Yaml.pInline r with
    | some (v, ' ' :: '|' :: r') => some (some v, r')
    | _ => none
  | _ => none

/-- The cells of a row, one per attribute column. -/
def pCells : List String → List Char → Option (List (String × Json) × List Char)
  | [], s => some ([], s)
  | k :: ks, s =>
    (pCell s).bind (fun p => (pCells ks p.2).map (fun q => ((p.1.map (fun v => (k, v))).toList ++ q.1, q.2)))

/-- The directive keyword of a row. -/
def kindOf (w : List Char) : Option DKind :=
  if w = "var".toList then some .var
  else if w = "param".toList then some .param
  else if w = "species".toList then some .species
  else none

/-- One row: `| var | $N$ |` and the cells, then a newline. -/
def pRow (cols : List String) : List Char → Option (Decl × List Char)
  | '|' :: ' ' :: r =>
    match kindOf (readIdent r).1, (readIdent r).2 with
    | some k, ' ' :: '|' :: ' ' :: '$' :: u =>
      match u.drop (u.takeWhile (· != '$')).length with
      | '$' :: ' ' :: '|' :: v =>
        match parseLatex {} (String.ofList (u.takeWhile (· != '$'))) with
        | some (.str n) =>
          (pCells cols v).bind (fun p => match p.2 with
            | '\n' :: r' => some (⟨k, n, p.1⟩, r')
            | _ => none)
        | _ => none
      | _ => none
    | _, _ => none
  | _ => none

/-- The rows, as long as lines start with `| `. -/
def pRows (cols : List String) : Nat → List Char → Option (List Decl × List Char)
  | 0, _ => none
  | f + 1, s =>
    if pre ['|', ' '] s then
      (pRow cols s).bind (fun p => (pRows cols f p.2).map (fun q => (p.1 :: q.1, q.2)))
    else some ([], s)

/-- The separator row: only `|`, `-`, `:` and spaces. -/
def sepOK (l : List Char) : Bool := l.all (fun c => c == '|' || c == '-' || c == ' ' || c == ':')

/-- A declarations table, at its `| decl | name |`. -/
def tableAt (f : Nat) (s : List Char) : Option (List RItem × List Char) :=
  (pCols f (s.drop tableOpen.length)).bind (fun p =>
    if sepOK (splitLine p.2).1 then
      (pRows p.1 f (splitLine p.2).2).map (fun q => (q.1.map RItem.decl, q.2))
    else none)

/-- **The Markdown lexer**: the constructs of a text, skipping prose one character at a
time. `bol`: the text starts at the beginning of a line. A malformed construct is an
error (`none`). -/
def lex : Nat → Bool → List Char → Option (List RItem)
  | 0, _, _ => none
  | _ + 1, _, [] => some []
  | f + 1, bol, c :: r =>
    if bol && blockOpen (c :: r) then
      (blockAt f (c :: r)).bind (fun p => (lex f true p.2).map (p.1 :: ·))
    else if declOpen (c :: r) then
      (declAt f (c :: r)).bind (fun p => (lex f false p.2).map (p.1 :: ·))
    else if bol && pre tableOpen (c :: r) then
      (tableAt f (c :: r)).bind (fun p => (lex f true p.2).map (p.1 ++ ·))
    else lex f (c == '\n') r

/-! ## Reading back the pieces -/

/-- A YAML scalar read back whatever follows it (a number needs a non-number character
after it). -/
theorem pInline_gen (v : Json) (hi : Yaml.isInl v = true) (hv : v.WF) (rest : List Char)
    (hr : Number.NumStop rest) : Yaml.pInline (Yaml.inline v ++ rest) = some (v, rest) := by
  match v with
  | .null => rfl
  | .bool true => rfl
  | .bool false => rfl
  | .arr [] => rfl
  | .obj [] => rfl
  | .str s =>
    have h : Yaml.inline (.str s) ++ rest = '"' :: (escape false s.toList ++ ['"'] ++ rest) := by
      simp [Yaml.inline, quote]
    rw [h]
    simp only [Yaml.pInline, (by decide : ('"' = 'n') = False), (by decide : ('"' = 't') = False),
      (by decide : ('"' = 'f') = False), (by decide : ('"' = '[') = False),
      (by decide : ('"' = '{') = False), ite_false, ite_true]
    rw [← h]
    simp [Yaml.inline, parseQuoted_quote]
  | .num n =>
    obtain ⟨c, t, h, hc⟩ := Number.print_head n hv
    have hp := Number.parse_print n rest hv hr
    simp only [Yaml.inline, h, List.cons_append] at hp ⊢
    simp only [Yaml.pInline, numHead_ne hc 'n', numHead_ne hc 't', numHead_ne hc 'f',
      numHead_ne hc '[', numHead_ne hc '{', numHead_ne hc '"', ite_false, hp]
    rfl

/-- An attribute the Markdown attribute syntax can hold: an identifier key and a YAML
scalar value. -/
def attrOK (a : String × Json) : Bool := isIdent a.1.toList && Yaml.isInl a.2 && jwf a.2

theorem isIdent_chars {cs : List Char} (h : isIdent cs = true) : cs.all isIdentChar = true :=
  isIdent_all h

theorem pAttr_attrMd (a : String × Json) (ha : attrOK a = true) (rest : List Char)
    (hr : rest.head? = some ' ' ∨ rest.head? = some '}') :
    pAttr (attrMd a ++ rest) = some (a, rest) := by
  obtain ⟨k, v⟩ := a
  simp only [attrOK, Bool.and_eq_true] at ha
  obtain ⟨⟨hk, hi⟩, hw⟩ := ha
  have hwf : v.WF := jwf_sound v hw
  have hrd : readIdent (attrMd (k, v) ++ rest) = (k.toList, '=' :: (Yaml.inline v ++ rest)) := by
    simp only [attrMd, List.append_assoc, List.cons_append]
    exact readIdent_append _ _ (isIdent_chars hk) (by simp [isIdentChar])
  unfold pAttr
  rw [hrd]
  simp only [hk, ite_true]
  have hns : Number.NumStop rest := by
    intro c hc
    rcases hr with h | h <;> rw [h] at hc <;> cases hc <;> decide
  rw [pInline_gen v hi hwf rest hns]
  simp

theorem pAttrsMore_attrs (as : List (String × Json)) (ha : ∀ a ∈ as, attrOK a = true)
    (t : List Char) : ∀ f, as.length < f →
      pAttrsMore f (as.flatMap (fun b => ' ' :: attrMd b) ++ '}' :: t) = some (as, t) := by
  induction as with
  | nil => intro f hf; obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩; rfl
  | cons a as ih =>
    intro f hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    simp only [List.flatMap_cons, List.cons_append, List.append_assoc, pAttrsMore]
    have hr : (as.flatMap (fun b => ' ' :: attrMd b) ++ '}' :: t).head? = some ' ' ∨
        (as.flatMap (fun b => ' ' :: attrMd b) ++ '}' :: t).head? = some '}' := by
      cases as <;> simp
    rw [pAttr_attrMd a (ha a List.mem_cons_self) _ hr]
    simp only [Option.bind_some]
    rw [ih (fun b hb => ha b (List.mem_cons_of_mem _ hb)) g (by simp at hf; omega)]
    rfl

theorem pAttrs_attrsMd (as : List (String × Json)) (ha : ∀ a ∈ as, attrOK a = true)
    (t : List Char) (f : Nat) (hf : as.length < f) :
    pAttrs f (attrsMd as ++ '}' :: t) = some (as, t) := by
  cases as with
  | nil => rfl
  | cons a as =>
    have hk : (attrMd a).head? ≠ some '}' := by
      obtain ⟨k, v⟩ := a
      have := ha (k, v) List.mem_cons_self
      simp only [attrOK, Bool.and_eq_true] at this
      cases hk : k.toList with
      | nil => rw [hk] at this; simp [isIdent] at this
      | cons c r =>
        rw [hk] at this
        simp only [isIdent, Bool.and_eq_true] at this
        simp only [attrMd, hk, List.cons_append, List.head?_cons, ne_eq, Option.some.injEq]
        intro e; subst e; simp [isIdentStart] at this
    have hpa : pAttrs f (attrsMd (a :: as) ++ '}' :: t) =
        (pAttr (attrsMd (a :: as) ++ '}' :: t)).bind
          (fun p => (pAttrsMore f p.2).map (fun q => (p.1 :: q.1, q.2))) := by
      unfold pAttrs
      split
      · rename_i r hr
        exfalso
        apply hk
        simp only [attrsMd, List.append_assoc] at hr
        cases hm : attrMd a with
        | nil => simp [attrMd] at hm
        | cons x y => rw [hm] at hr; simp at hr; rw [hr.1]; rfl
      · rfl
    rw [hpa]
    simp only [attrsMd, List.append_assoc]
    have hr : (as.flatMap (fun b => ' ' :: attrMd b) ++ '}' :: t).head? = some ' ' ∨
        (as.flatMap (fun b => ' ' :: attrMd b) ++ '}' :: t).head? = some '}' := by
      cases as <;> simp
    rw [pAttr_attrMd a (ha a List.mem_cons_self) _ hr]
    simp only [Option.bind_some]
    rw [pAttrsMore_attrs as (fun b hb => ha b (List.mem_cons_of_mem _ hb)) t f (by simp at hf; omega)]
    rfl

/-- A declaration the Markdown syntax can hold. -/
def declOK (d : Decl) : Bool :=
  nameOK d.name && !(nameLatex d.name).contains '$' && d.attrs.all attrOK

theorem takeWhile_noDollar (x y : List Char) (hx : x.contains '$' = false) :
    (x ++ '$' :: y).takeWhile (· != '$') = x := by
  induction x with
  | nil => simp
  | cons c x ih =>
    simp only [List.contains_cons, Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq] at hx
    simp [Ne.symm hx.1, ih hx.2]

theorem declBody_declMd (f : Nat) (d : Decl) (hd : declOK d = true) (t : List Char)
    (hf : d.attrs.length < f) :
    declBody f d.kind ('$' :: nameLatex d.name ++ '$' :: ']' :: '{' :: attrsMd d.attrs ++ '}' :: t) =
      some (.decl d, t) := by
  obtain ⟨k, n, as⟩ := d
  simp only [declOK, Bool.and_eq_true, Bool.not_eq_true'] at hd
  obtain ⟨⟨hn, hdol⟩, has⟩ := hd
  simp only at hn hdol has ⊢
  simp only [List.cons_append, declBody, List.append_assoc]
  simp only [takeWhile_noDollar _ _ hdol, List.drop_left]
  have hp : parseLatex {} (String.ofList (nameLatex n)) = some (.str n) := by
    simp only [nameLatex, String.ofList_toList]
    exact parseLatex_printLatex {} (.str n) (by simpa [isE] using hn)
  rw [hp]
  simp only
  rw [pAttrs_attrsMd as (fun a ha => List.all_eq_true.mp has a ha) t f hf]
  rfl

/-! ## Keys -/

theorem hexChar_ne (d : Nat) (h : d < 16) : hexChar d ≠ '\n' :=
  (by decide : ∀ d : Fin 16, hexChar d.val ≠ '\n') ⟨d, h⟩

theorem escChar_noNl (c : Char) : '\n' ∉ escChar false c := by
  unfold escChar
  split
  · simp
  split
  · simp
  split
  · simp
  split
  · simp
  split
  · simp
  split
  · simp only [Bool.false_eq_true, ite_false, List.mem_cons]
    simp only [hex4, List.mem_cons, List.not_mem_nil, or_false, not_or]
    refine ⟨by decide, by decide, ?_, ?_, ?_, ?_⟩ <;>
      exact fun h => hexChar_ne _ (Nat.mod_lt _ (by decide)) h.symm
  · rename_i h1 _ _ _ _ _
    simp only [List.mem_singleton]
    intro h; exact absurd h.symm (by assumption)

theorem escKey_noNl (c : Char) : '\n' ∉ escKey c := by
  unfold escKey
  split
  · rename_i h; subst h; decide
  · exact escChar_noNl c

theorem unquoteBody_escKey (c : Char) (r : List Char) :
    unquoteBody false (escKey c ++ r) = (unquoteBody false r).map (fun p => (c :: p.1, p.2)) := by
  unfold escKey
  split
  · rename_i h; subst h
    show unquoteBody false ('\\' :: 'u' :: '0' :: '0' :: '6' :: '0' :: r) = _
    rw [unquoteBody]
    · rfl
    · intro _ _ h _; cases h
  · exact unquoteBody_escChar false c r

theorem unquoteBody_escKeys (cs rest : List Char) :
    unquoteBody false (cs.flatMap escKey ++ '"' :: rest) = some (cs, rest) := by
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    simp only [List.flatMap_cons, List.append_assoc]
    rw [unquoteBody_escKey, ih]
    rfl

theorem parseKeyMd_keyMd (k : String) : parseKeyMd (keyMd k) = some k := by
  unfold keyMd
  split
  · rename_i h
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at h
    obtain ⟨hi, hd⟩ := h
    unfold parseKeyMd
    split
    · rename_i r hr
      rw [hr] at hi; simp [isIdent, isIdentStart] at hi
    · have : k.toList ≠ descInfo := by
        intro e; apply hd
        rw [← String.ofList_toList (s := k), e]; rfl
      simp [hi, this]
  · simp only [parseKeyMd, List.cons_append]
    simp only [parseQuoted, unquoteBody_escKeys, Option.map_some, String.ofList_toList]

theorem keyMd_noNl (k : String) : '\n' ∉ keyMd k := by
  unfold keyMd
  split
  · rename_i h
    simp only [Bool.and_eq_true] at h
    intro hm
    have := List.all_eq_true.mp (isIdent_all h.1) _ hm
    simp [isIdentChar] at this
  · simp only [List.cons_append, List.mem_cons, List.mem_append, List.mem_flatMap, not_or]
    refine ⟨by decide, ?_, by decide⟩
    rintro ⟨c, _, hc⟩
    exact escKey_noNl c hc

/-! ## The printer -/

/-- The text of a construct. A description is written verbatim in its fence; a path
block's value in YAML; a declaration inline (no newline of its own). -/
def itemMd : RItem → List Char
  | .desc s => fenceEsm ++ descInfo ++ '\n' :: s.toList ++ '\n' :: fence ++ ['\n']
  | .block k v => fenceEsm ++ keyMd k ++ '\n' :: Yaml.encode v ++ fence ++ ['\n']
  | .comp .model n => dModel ++ n.toList ++ [']', '\n']
  | .comp .rs n => dRs ++ n.toList ++ [']', '\n']
  | .decl d => declMd d
  | .eqn raw => dd ++ '\n' :: raw.toList ++ '\n' :: dd ++ ['\n']

/-- A display equation with an equation label after its closing `$$` (` {#eq-x}`). -/
def eqnLabeled (raw : String) (label : List Char) : List Char :=
  dd ++ '\n' :: raw.toList ++ '\n' :: dd ++ label ++ ['\n']

/-- A piece of a Markdown document: a construct, a labelled equation, or prose. -/
inductive Seg where
  | item (it : RItem)
  | labeled (raw : String) (label : List Char)
  | prose (p : List Char)

def segText : Seg → List Char
  | .item it => itemMd it
  | .labeled raw l => eqnLabeled raw l
  | .prose p => p

/-- The text of a document body. -/
def render (segs : List Seg) : List Char := segs.flatMap segText

/-- The constructs of a document body: prose dropped, labels dropped. -/
def segItems : List Seg → List RItem
  | [] => []
  | .item it :: r => it :: segItems r
  | .labeled raw _ :: r => .eqn raw :: segItems r
  | .prose _ :: r => segItems r

/-- A construct that must start a line (all but declarations). -/
def isBlock : RItem → Bool
  | .decl _ => false
  | _ => true

/-- What each construct's content must satisfy for its text to read back. -/
def itemOK : RItem → Bool
  | .desc s => noStop fence (s.toList ++ ['\n'])
  | .block _ v => jwf v
  | .comp _ n => !n.toList.contains ']' && !n.toList.contains '\n'
  | .decl d => declOK d
  | .eqn raw => noStop dd (raw.toList ++ ['\n'])

/-- **Prose that the lexer skips**: at no character does a construct start (a block
construct only matters at the start of a line). `t` is the text after the prose. -/
def Inert : Bool → List Char → List Char → Prop
  | _, [], _ => True
  | bol, c :: p, t =>
    (bol && blockOpen (c :: p ++ t)) = false ∧ declOpen (c :: p ++ t) = false ∧
      (bol && pre tableOpen (c :: p ++ t)) = false ∧ Inert (c == '\n') p t

/-- A document body whose constructs read back: each construct's content is spellable,
block constructs start a line, labels are labels, and prose is inert. -/
def Valid : Bool → List Seg → Prop
  | _, [] => True
  | bol, .item it :: rest => itemOK it = true ∧ (isBlock it = true → bol = true) ∧ Valid (isBlock it) rest
  | bol, .labeled raw l :: rest =>
    bol = true ∧ itemOK (.eqn raw) = true ∧ labelOK l = true ∧ '\n' ∉ l ∧ Valid true rest
  | bol, .prose p :: rest => Inert bol p (render rest) ∧ Valid (endBol bol p) rest

/-! ## Lexing, construct by construct -/

theorem lex_prose : ∀ (p t : List Char) (bol : Bool), Inert bol p t →
    ∀ f, p.length + t.length < f → lex f bol (p ++ t) = lex (f - p.length) (endBol bol p) t
  | [], t, bol, _, f, _ => by simp [endBol]
  | c :: p, t, bol, ⟨h1, h2, h4, h3⟩, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    simp only [List.cons_append, lex]
    simp only [List.cons_append] at h1 h2 h4
    rw [h1, h2, h4]
    simp only [Bool.false_eq_true, ite_false]
    rw [lex_prose p t _ h3 g (by simp at hf; omega), endBol_cons]
    congr 1
    simp

theorem lex_block_step (g : Nat) (bol : Bool) (x t : List Char) (it : RItem) (hx : x ≠ [])
    (ho : blockOpen (x ++ t) = true) (hbol : bol = true) (hb : blockAt g (x ++ t) = some (it, t)) :
    lex (g + 1) bol (x ++ t) = (lex g true t).map (it :: ·) := by
  obtain ⟨c, r, hcr⟩ : ∃ c r, x ++ t = c :: r := by
    cases x with
    | nil => exact absurd rfl hx
    | cons c r => exact ⟨c, r ++ t, rfl⟩
  rw [hcr] at ho hb ⊢
  simp only [lex, hbol, ho, Bool.and_self, ite_true, hb, Option.bind_some]

theorem lex_decl_step (g : Nat) (bol : Bool) (x t : List Char) (it : RItem) (hx : x ≠ [])
    (hb1 : blockOpen (x ++ t) = false) (ho : declOpen (x ++ t) = true)
    (hd : declAt g (x ++ t) = some (it, t)) :
    lex (g + 1) bol (x ++ t) = (lex g false t).map (it :: ·) := by
  obtain ⟨c, r, hcr⟩ : ∃ c r, x ++ t = c :: r := by
    cases x with
    | nil => exact absurd rfl hx
    | cons c r => exact ⟨c, r ++ t, rfl⟩
  rw [hcr] at hb1 ho hd ⊢
  simp only [lex, hb1, Bool.and_false, Bool.false_eq_true, ite_false, ho, ite_true, hd,
    Option.bind_some]

theorem fenceEsm_pre (X : List Char) : pre fenceEsm (fenceEsm ++ X) = true := pre_append _ _

theorem blockAt_fence (g : Nat) (X : List Char) : blockAt g (fenceEsm ++ X) = fenceAt g X := by
  simp only [blockAt, fenceEsm_pre, ite_true]
  rw [show (7 : Nat) = fenceEsm.length from rfl, List.drop_left]

theorem descInfo_noNl : '\n' ∉ descInfo := by decide

theorem lines_nl (x : List Char) : Lines (x ++ ['\n']) := Or.inr (by simp)

theorem fence_ne : fence ≠ [] := by decide
theorem fence_noNl : '\n' ∉ fence := by decide
theorem dd_ne : dd ≠ [] := by decide
theorem dd_noNl : '\n' ∉ dd := by decide

theorem lex_desc (s : String) (hs : itemOK (.desc s) = true) (bol : Bool) (hbol : bol = true)
    (t : List Char) (g : Nat) (hg : (itemMd (.desc s)).length + t.length < g + 1) :
    lex (g + 1) bol (itemMd (.desc s) ++ t) = (lex g true t).map (.desc s :: ·) := by
  apply lex_block_step g bol _ t _ (by simp [itemMd, fenceEsm]) _ hbol
  · simp only [itemMd, List.append_assoc, List.cons_append]
    rw [blockAt_fence, fenceAt, splitLine_line _ _ descInfo_noNl]
    have hb := untilStop_body fence fence_ne fence_noNl (s.toList ++ ['\n']) [] t (lines_nl _) hs
      (by simp) g (by simp [itemMd, List.length_append] at hg ⊢; omega)
    simp only [List.append_assoc, List.cons_append, List.nil_append] at hb
    simp only [List.nil_append]
    rw [hb]
    simp [fenceItem]
  · simp only [itemMd, List.append_assoc, blockOpen, fenceEsm_pre, Bool.true_or]

theorem takeWhile_noBr (x y : List Char) (h1 : x.contains ']' = false) (h2 : x.contains '\n' = false) :
    (x ++ ']' :: y).takeWhile (fun c => c != ']' && c != '\n') = x := by
  induction x with
  | nil => simp
  | cons c x ih =>
    simp only [List.contains_cons, Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq] at h1 h2
    simp [Ne.symm h1.1, Ne.symm h2.1, ih h1.2 h2.2]

theorem pre_fe_dd (X : List Char) : pre fenceEsm (dd ++ X) = false := by simp [fenceEsm, dd, pre]
theorem pre_fe_dm (X : List Char) : pre fenceEsm (dModel ++ X) = false := by simp [fenceEsm, dModel, pre]
theorem pre_dd_dm (X : List Char) : pre dd (dModel ++ X) = false := by simp [dd, dModel, pre]
theorem pre_fe_dr (X : List Char) : pre fenceEsm (dRs ++ X) = false := by simp [fenceEsm, dRs, pre]
theorem pre_dd_dr (X : List Char) : pre dd (dRs ++ X) = false := by simp [dd, dRs, pre]
theorem pre_dm_dr (X : List Char) : pre dModel (dRs ++ X) = false := by simp [dModel, dRs, pre]

theorem keyMd_ne_desc (k : String) : keyMd k ≠ descInfo := by
  intro h
  have := parseKeyMd_keyMd k
  rw [h] at this
  simp [parseKeyMd, descInfo] at this

theorem lex_block (k : String) (v : Json) (hv : itemOK (.block k v) = true) (bol : Bool)
    (hbol : bol = true) (t : List Char) (g : Nat)
    (hg : (itemMd (.block k v)).length + t.length < g + 1) :
    lex (g + 1) bol (itemMd (.block k v) ++ t) = (lex g true t).map (.block k v :: ·) := by
  have hw : v.WF := jwf_sound v hv
  apply lex_block_step g bol _ t _ (by simp [itemMd, fenceEsm]) _ hbol
  · simp only [itemMd, List.append_assoc, List.cons_append]
    rw [blockAt_fence, fenceAt, splitLine_line _ _ (keyMd_noNl k)]
    have hb := untilStop_body fence fence_ne fence_noNl (Yaml.encode v) [] t
      (Or.inr (by
        have := yaml_ends v
        unfold endBol at this
        split at this
        · cases this
        · rename_i c hc; simp at this; rw [hc, this]))
      (noStop_of_heads _ _ (yaml_heads_tick v hw))
      (by simp) g (by simp [itemMd, List.length_append] at hg ⊢; omega)
    simp only [List.append_assoc, List.nil_append] at hb
    simp only [List.nil_append, hb]
    simp [fenceItem, keyMd_ne_desc, parseKeyMd_keyMd, Yaml.decode_encode v hw]
  · simp only [itemMd, List.append_assoc, blockOpen, fenceEsm_pre, Bool.true_or]

theorem lex_comp (K : Kind) (n : String) (hn : itemOK (.comp K n) = true) (bol : Bool)
    (hbol : bol = true) (t : List Char) (g : Nat) :
    lex (g + 1) bol (itemMd (.comp K n) ++ t) = (lex g true t).map (.comp K n :: ·) := by
  simp only [itemOK, Bool.and_eq_true, Bool.not_eq_true'] at hn
  have htw := takeWhile_noBr n.toList ('\n' :: t) hn.1 hn.2
  cases K with
  | model =>
    apply lex_block_step g bol _ t _ (by simp [itemMd, dModel]) _ hbol
    · simp only [itemMd, List.append_assoc, blockAt, pre_fe_dm, pre_dd_dm, pre_append,
        Bool.false_eq_true, ite_false, ite_true]
      rw [show (8 : Nat) = dModel.length from rfl, List.drop_left, dirAt]
      simp only [List.cons_append, List.nil_append, htw, List.drop_left]
      simp [splitLine]
    · simp [itemMd, blockOpen, pre_append]
  | rs =>
    apply lex_block_step g bol _ t _ (by simp [itemMd, dRs]) _ hbol
    · simp only [itemMd, List.append_assoc, blockAt, pre_fe_dr, pre_dd_dr, pre_dm_dr,
        Bool.false_eq_true, ite_false]
      rw [show (18 : Nat) = dRs.length from rfl, List.drop_left, dirAt]
      simp only [List.cons_append, List.nil_append, htw, List.drop_left]
      simp [splitLine]
    · simp [itemMd, blockOpen, pre_append]

theorem lex_eqnL (raw : String) (l : List Char) (hr : itemOK (.eqn raw) = true)
    (hl : labelOK l = true) (hln : '\n' ∉ l) (bol : Bool) (hbol : bol = true) (t : List Char)
    (g : Nat) (hg : (eqnLabeled raw l).length + t.length < g + 1) :
    lex (g + 1) bol (eqnLabeled raw l ++ t) = (lex g true t).map (.eqn raw :: ·) := by
  apply lex_block_step g bol _ t _ (by simp [eqnLabeled, dd]) _ hbol
  · simp only [eqnLabeled, List.append_assoc, List.cons_append, blockAt, pre_fe_dd, pre_append,
      Bool.false_eq_true, ite_false, ite_true]
    rw [show (2 : Nat) = dd.length from rfl, List.drop_left, mathAt]
    simp only [splitLine, ite_true, List.all_nil]
    have hb := untilStop_body dd dd_ne dd_noNl (raw.toList ++ ['\n']) l t (lines_nl _) hr hln g
      (by simp [eqnLabeled, List.length_append] at hg ⊢; omega)
    simp only [List.append_assoc, List.cons_append, List.nil_append] at hb
    simp only [List.nil_append, hb]
    simp [hl]
  · simp [eqnLabeled, blockOpen, dd, fenceEsm, pre]

theorem lex_decl (d : Decl) (hd : itemOK (.decl d) = true) (bol : Bool) (t : List Char)
    (g : Nat) (hg : d.attrs.length < g) :
    lex (g + 1) bol (itemMd (.decl d) ++ t) = (lex g false t).map (.decl d :: ·) := by
  simp only [itemOK] at hd
  obtain ⟨k, n, as⟩ := d
  apply lex_decl_step g bol _ t _ (by simp [itemMd, declMd])
  · cases k <;> simp [itemMd, declMd, dkw, blockOpen, fenceEsm, dd, dModel, dRs, pre]
  · cases k <;> simp [itemMd, declMd, dkw, declOpen, pre]
  · have hb := declBody_declMd g ⟨k, n, as⟩ hd t hg
    simp only [List.cons_append, List.append_assoc] at hb
    have e1 : ":var[".toList = [':', 'v', 'a', 'r', '['] := rfl
    have e2 : ":param[".toList = [':', 'p', 'a', 'r', 'a', 'm', '['] := rfl
    have e3 : "var".toList = ['v', 'a', 'r'] := rfl
    have e4 : "param".toList = ['p', 'a', 'r', 'a', 'm'] := rfl
    have e5 : "species".toList = ['s', 'p', 'e', 'c', 'i', 'e', 's'] := rfl
    cases k <;>
      simpa [itemMd, declMd, declAt, dkw, e1, e2, e3, e4, e5, pre] using hb

theorem attrs_len : ∀ as : List (String × Json), as.length ≤ (attrsMd as).length
  | [] => le_refl _
  | a :: as => by
    simp only [attrsMd, List.length_append, List.length_cons]
    have h1 : 1 ≤ (attrMd a).length := by simp [attrMd]; omega
    have h2 : as.length ≤ (as.flatMap (fun b => ' ' :: attrMd b)).length := by
      clear h1
      induction as with
      | nil => simp
      | cons b bs ih => simp [List.flatMap_cons] at ih ⊢; omega
    omega

theorem itemMd_eqn (raw : String) : itemMd (.eqn raw) = eqnLabeled raw [] := by
  simp [itemMd, eqnLabeled]

/-- **The Markdown lexer reads back every valid document body**: exactly its constructs,
whatever prose surrounds them and whatever labels the equations carry. -/
theorem lex_render : ∀ (segs : List Seg) (bol : Bool), Valid bol segs →
    ∀ f, (render segs).length < f → lex f bol (render segs) = some (segItems segs)
  | [], bol, _, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp [render] at hf; omega⟩
    rfl
  | .prose p :: rest, bol, ⟨hi, hv⟩, f, hf => by
    rw [show render (.prose p :: rest) = p ++ render rest from rfl] at hf ⊢
    rw [lex_prose p _ bol hi f (by simpa using hf)]
    exact lex_render rest _ hv _ (by simp [render] at hf ⊢; omega)
  | .labeled raw l :: rest, bol, ⟨hb, hr, hl, hln, hv⟩, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp [render] at hf; omega⟩
    rw [show render (.labeled raw l :: rest) = eqnLabeled raw l ++ render rest from rfl] at hf ⊢
    rw [lex_eqnL raw l hr hl hln bol hb _ g (by simpa using hf)]
    rw [lex_render rest true hv g (by simp [render, eqnLabeled] at hf ⊢; omega)]
    rfl
  | .item it :: rest, bol, ⟨hok, hb, hv⟩, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp [render] at hf; omega⟩
    rw [show render (.item it :: rest) = itemMd it ++ render rest from rfl] at hf ⊢
    have hlen : ∀ x : List Char, x ≠ [] → (x ++ render rest).length < g + 1 →
        (render rest).length < g := by
      intro x hx h
      have : 1 ≤ x.length := List.length_pos_of_ne_nil hx
      simp at h; omega
    have hf' := hf
    rw [List.length_append] at hf' 
    cases it with
    | desc s =>
      rw [lex_desc s hok bol (hb rfl) _ g hf',
        lex_render rest true hv g (hlen _ (by simp [itemMd, fenceEsm]) hf)]
      rfl
    | block k v =>
      rw [lex_block k v hok bol (hb rfl) _ g hf',
        lex_render rest true hv g (hlen _ (by simp [itemMd, fenceEsm]) hf)]
      rfl
    | comp K n =>
      rw [lex_comp K n hok bol (hb rfl) _ g,
        lex_render rest true hv g (hlen _ (by cases K <;> simp [itemMd, dModel, dRs]) hf)]
      rfl
    | decl d =>
      have hlen' := hlen _ (by simp [itemMd, declMd]) hf
      rw [lex_decl d hok bol _ g (by
        have := attrs_len d.attrs
        simp [itemMd, declMd] at hf; omega),
        lex_render rest false hv g hlen']
      rfl
    | eqn raw =>
      rw [itemMd_eqn] at hf hf' ⊢
      rw [lex_eqnL raw [] hok rfl (by simp) bol (hb rfl) _ g hf',
        lex_render rest true hv g (hlen _ (by simp [eqnLabeled, dd]) hf)]
      rfl

/-! ## The declarations table reads as its declarations -/

def kindWord : DKind → List Char
  | .var => "var".toList
  | .param => "param".toList
  | .species => "species".toList

/-- A header column. -/
def colText (k : String) : List Char := ' ' :: (k.toList ++ [' ', '|'])

/-- A cell. -/
def cellText : Option Json → List Char
  | none => [' ', '|']
  | some v => ' ' :: (Yaml.inline v ++ [' ', '|'])

/-- A row of the table. -/
def rowText (cols : List String) (d : Decl) : List Char :=
  '|' :: ' ' :: kindWord d.kind ++ ' ' :: '|' :: ' ' :: '$' :: nameLatex d.name ++
    '$' :: ' ' :: '|' :: cols.flatMap (fun k => cellText (look k d.attrs)) ++ ['\n']

/-- A declarations table over the attribute columns `cols`. -/
def tableText (cols : List String) (ds : List Decl) : List Char :=
  tableOpen ++ cols.flatMap colText ++ ['\n'] ++
    '|' :: (List.replicate (cols.length + 2) " --- |".toList).flatten ++ ['\n'] ++
    ds.flatMap (rowText cols)

/-- A declaration a table over `cols` holds: its name and attributes spellable, and its
attributes exactly the columns it has a value in, in column order. -/
def TableOK (cols : List String) (d : Decl) : Prop :=
  declOK d = true ∧ d.attrs = cols.filterMap (fun k => (look k d.attrs).map (fun v => (k, v)))

theorem pCols_cols (cols : List String) (hc : ∀ k ∈ cols, isIdent k.toList = true) (t : List Char) :
    ∀ f, cols.length < f → pCols f (cols.flatMap colText ++ '\n' :: t) = some (cols, t) := by
  induction cols with
  | nil => intro f hf; obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩; rfl
  | cons k ks ih =>
    intro f hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    have hk := hc k List.mem_cons_self
    have ih' := ih (fun k' hk' => hc k' (List.mem_cons_of_mem _ hk')) g (by simp at hf; omega)
    have hrd : readIdent (k.toList ++ (' ' :: '|' :: (ks.flatMap colText ++ '\n' :: t))) =
        (k.toList, ' ' :: '|' :: (ks.flatMap colText ++ '\n' :: t)) :=
      readIdent_append _ _ (isIdent_all hk) (by simp [isIdentChar])
    rw [List.flatMap_cons, show colText k ++ ks.flatMap colText ++ '\n' :: t =
      ' ' :: (k.toList ++ (' ' :: '|' :: (ks.flatMap colText ++ '\n' :: t))) by simp [colText]]
    simp only [pCols, hrd, hk, ite_true, ih', Option.map_some, String.ofList_toList]

theorem inline_head (v : Json) (hv : v.WF) : ∃ c t, Yaml.inline v = c :: t ∧ c ≠ '|' := by
  match v with
  | .null => exact ⟨_, _, rfl, by decide⟩
  | .bool true => exact ⟨_, _, rfl, by decide⟩
  | .bool false => exact ⟨_, _, rfl, by decide⟩
  | .str s => exact ⟨'"', escape false s.toList ++ ['"'], by simp [Yaml.inline, quote], by decide⟩
  | .arr _ => exact ⟨_, _, rfl, by decide⟩
  | .obj _ => exact ⟨_, _, rfl, by decide⟩
  | .num n =>
    obtain ⟨c, t, h, hc⟩ := Number.print_head n hv
    refine ⟨c, t, h, ?_⟩
    rcases hc with rfl | ⟨d, hd, rfl⟩
    · decide
    · exact (by decide : ∀ d : Fin 10, digitChar d.val ≠ '|') ⟨d, hd⟩

theorem pCell_some (v : Json) (hi : Yaml.isInl v = true) (hv : v.WF) (rest : List Char) :
    pCell (cellText (some v) ++ rest) = some (some v, rest) := by
  obtain ⟨c, t, hct, hc⟩ := inline_head v hv
  have hp := pInline_gen v hi hv (' ' :: '|' :: rest) (by intro x hx; cases hx; decide)
  simp only [cellText, List.cons_append, List.append_assoc, List.nil_append]
  rw [hct] at hp ⊢
  simp only [List.cons_append] at hp
  unfold pCell
  split
  · rename_i r h; simp at h; exact absurd h.1 hc
  · rename_i r _ heq
    simp only [List.cons.injEq, true_and] at heq
    rw [← heq, List.cons_append, hp]; rfl
  · rename_i h1 h2; exact absurd rfl (h2 _)

theorem pCells_cells (cols : List String) (attrs : List (String × Json))
    (ha : ∀ a ∈ attrs, attrOK a = true) (t : List Char) :
    pCells cols (cols.flatMap (fun k => cellText (look k attrs)) ++ t) =
      some (cols.filterMap (fun k => (look k attrs).map (fun v => (k, v))), t) := by
  induction cols with
  | nil => rfl
  | cons k ks ih =>
    simp only [List.flatMap_cons, List.append_assoc, pCells]
    cases hl : look k attrs with
    | none =>
      rw [show pCell (cellText none ++ (ks.flatMap (fun k => cellText (look k attrs)) ++ t)) =
        some (none, ks.flatMap (fun k => cellText (look k attrs)) ++ t) from rfl]
      simp only [Option.bind_some]
      rw [ih]
      simp [hl]
    | some v =>
      have hv := ha (k, v) (look_mem' hl)
      simp only [attrOK, Bool.and_eq_true] at hv
      rw [pCell_some v hv.1.2 (jwf_sound v hv.2)]
      simp only [Option.bind_some]
      rw [ih]
      simp [hl]

theorem kindOf_kindWord (k : DKind) : kindOf (kindWord k) = some k := by
  cases k <;> decide

theorem kindWord_ident (k : DKind) : (kindWord k).all isIdentChar = true := by
  cases k <;> decide

theorem pRow_rowText (cols : List String) (d : Decl) (hd : TableOK cols d) (rest : List Char) :
    pRow cols (rowText cols d ++ rest) = some (d, rest) := by
  obtain ⟨k, n, as⟩ := d
  obtain ⟨hok, has⟩ := hd
  simp only [declOK, Bool.and_eq_true, Bool.not_eq_true'] at hok
  obtain ⟨⟨hn, hdol⟩, hall⟩ := hok
  simp only at hn hdol hall has
  have hrd : readIdent (kindWord k ++ ' ' :: '|' :: ' ' :: '$' :: (nameLatex n ++
      '$' :: ' ' :: '|' :: (cols.flatMap (fun c => cellText (look c as)) ++ '\n' :: rest))) =
      (kindWord k, ' ' :: '|' :: ' ' :: '$' :: (nameLatex n ++
      '$' :: ' ' :: '|' :: (cols.flatMap (fun c => cellText (look c as)) ++ '\n' :: rest))) :=
    readIdent_append _ _ (kindWord_ident k) (by simp [isIdentChar])
  have hp : parseLatex {} (String.ofList (nameLatex n)) = some (.str n) := by
    simp only [nameLatex, String.ofList_toList]
    exact parseLatex_printLatex {} (.str n) (by simpa [isE] using hn)
  have hc := pCells_cells cols as (fun a ha => List.all_eq_true.mp hall a ha) ('\n' :: rest)
  rw [← has] at hc
  simp only [rowText, List.cons_append, List.append_assoc, List.nil_append, pRow, hrd,
    kindOf_kindWord, takeWhile_noDollar _ _ hdol, List.drop_left, hp, hc, Option.bind_some]

theorem pRows_rows (cols : List String) (ds : List Decl) (hd : ∀ d ∈ ds, TableOK cols d)
    (t : List Char) (ht : pre ['|', ' '] t = false) :
    ∀ f, ds.length < f → pRows cols f (ds.flatMap (rowText cols) ++ t) = some (ds, t) := by
  induction ds with
  | nil => intro f hf; obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩; simp [pRows, ht]
  | cons d ds ih =>
    intro f hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    simp only [List.flatMap_cons, List.append_assoc]
    have hpre : pre ['|', ' '] (rowText cols d ++ (ds.flatMap (rowText cols) ++ t)) = true := by
      simp [rowText, pre]
    simp only [pRows, hpre, ite_true, pRow_rowText cols d (hd d List.mem_cons_self), Option.bind_some]
    rw [ih (fun d' hd' => hd d' (List.mem_cons_of_mem _ hd')) g (by simp at hf; omega)]
    rfl

/-- **A declarations table reads as the declarations it lists** (and as the
`:var`/`:param`/`:species` directives of the same declarations: the same constructs). -/
theorem lex_table (cols : List String) (hc : ∀ k ∈ cols, isIdent k.toList = true)
    (ds : List Decl) (hd : ∀ d ∈ ds, TableOK cols d) (t : List Char)
    (ht : pre ['|', ' '] t = false) (g : Nat) (hg : (tableText cols ds).length + t.length < g + 1) :
    lex (g + 1) true (tableText cols ds ++ t) = (lex g true t).map (ds.map RItem.decl ++ ·) := by
  have hlen1 : cols.length ≤ (cols.flatMap colText).length := by
    clear hc hd hg
    induction cols with
    | nil => simp
    | cons k ks ih => simp [colText] at ih ⊢; omega
  have hlen2 : ds.length ≤ (ds.flatMap (rowText cols)).length := by
    clear hc hd hg
    induction ds with
    | nil => simp
    | cons d ds ih => simp [rowText] at ih ⊢; omega
  have hrep : ∀ n (p : Char → Bool), " --- |".toList.all p = true →
      ((List.replicate n " --- |".toList).flatten).all p = true := by
    intro n p hp
    induction n with
    | zero => rfl
    | succ n ih => simp only [List.replicate_succ, List.flatten_cons, List.all_append, hp, ih, Bool.and_self]
  have hsep : sepOK ('|' :: (List.replicate (cols.length + 2) " --- |".toList).flatten) = true := by
    simp only [sepOK, List.all_cons]
    rw [hrep _ _ (by decide)]
    rfl
  have hsepnl : '\n' ∉ '|' :: (List.replicate (cols.length + 2) " --- |".toList).flatten := by
    intro hm
    have := hrep (cols.length + 2) (fun c => c != '\n') (by decide)
    rw [List.all_eq_true] at this
    rcases List.mem_cons.mp hm with h | h
    · cases h
    · have := this _ h; simp at this
  have hT : (cols.flatMap colText).length + (ds.flatMap (rowText cols)).length + 1 ≤
      (tableText cols ds).length := by
    unfold tableText; simp only [List.length_append, List.length_cons]; omega
  have htab : tableAt g (tableText cols ds ++ t) = some (ds.map RItem.decl, t) := by
    unfold tableAt tableText
    simp only [List.append_assoc, List.drop_left]
    rw [show ['\n'] ++ ('|' :: (List.replicate (cols.length + 2) " --- |".toList).flatten ++
      (['\n'] ++ (ds.flatMap (rowText cols) ++ t))) = '\n' :: ('|' :: (List.replicate (cols.length + 2)
      " --- |".toList).flatten ++ '\n' :: (ds.flatMap (rowText cols) ++ t)) by simp,
      pCols_cols cols hc _ g (by omega)]
    simp only [Option.bind_some, splitLine_line _ _ hsepnl, hsep, ite_true]
    rw [pRows_rows cols ds hd t ht g (by omega)]
    rfl
  obtain ⟨c, r, hcr⟩ : ∃ c r, tableText cols ds ++ t = c :: r := by
    cases h : tableText cols ds ++ t with
    | nil => simp [tableText, tableOpen] at h
    | cons c r => exact ⟨c, r, rfl⟩
  rw [hcr] at htab ⊢
  have hb : blockOpen (c :: r) = false := by
    rw [← hcr]; simp [tableText, tableOpen, blockOpen, fenceEsm, dd, dModel, dRs, pre]
  have hdo : declOpen (c :: r) = false := by
    rw [← hcr]; simp [tableText, tableOpen, declOpen, pre]
  have hto : pre tableOpen (c :: r) = true := by
    rw [← hcr]; simp only [tableText, List.append_assoc]; exact pre_append _ _
  simp only [lex, hb, hdo, hto, Bool.and_false, Bool.true_and, Bool.false_eq_true, ite_false,
    ite_true, htab, Option.bind_some]

end Esm.Document.Source.Md
