import Esm.Document.Source.Text
import Esm.Document.Source.Equation

/-!
# The Typst container

An ESM document in Typst is markup plus the functions of an `esm` Typst package:

```
#import "@preview/esm:0.1.0": *
#show: esm-document.with(esm: "2.1.0", name: "Decay")

#description[First\-order radioactive decay.]

#model("Decay")

#var($N$, default: 100, units: "mol")

$ (dif N)/(dif t) = -lambda N $
```

The constructs (`Esm.Document.Source.RItem`), and where they may appear:

* the header: the `#import` line, then `#show: esm-document.with(…)` with the
  front-matter entries as named arguments (values in the Typst value syntax,
  `Esm.Document.TypstDict`);
* at the start of a line: `#description[…]` (the text with Typst's markup characters
  escaped by a backslash), `#esm-block("key", value)` (a path block), `#model("Name")`
  or `#reaction-system("Name")`, and a display equation `$ … $` (optionally followed by
  a label `<eq-x>`, which is discarded);
* anywhere: a declaration `#var($N$, …)`, `#param(…)` or `#species(…)`, the name in
  Typst math and the attributes as named arguments.

Everything else is prose, which the parser skips, so the parse depends only on the
sequence of constructs (`lex_render`). Prose may not contain a declaration opener
(`#var(`, `#param(`, `#species(`), nor start a line with a block opener; in particular
a line starting with `$ ` is always a model equation.
-/

namespace Esm.Document.Source.Typ

open Esm.Document Esm.Document.Math Esm.Document.Source Esm.Document.Strings

/-! ## Spellings -/

def oDesc : List Char := "#description[".toList
def oBlock : List Char := "#esm-block(".toList
def oModel : List Char := "#model(".toList
def oRs : List Char := "#reaction-system(".toList
def oEq : List Char := "$ ".toList
def oVar : List Char := "#var(".toList
def oParam : List Char := "#param(".toList
def oSpecies : List Char := "#species(".toList
/-- The header's first line and the start of its second. -/
def header : List Char := "#import \"@preview/esm:0.1.0\": *\n#show: esm-document.with(".toList

/-! ## Description text -/

/-- Whether a character of a description is written escaped: Typst's markup characters
always; `=`, `-` and `+` at the start of a line (a heading or a list item); `/` before
`/` or `*` (a comment). -/
def mustEsc (bol : Bool) (c : Char) (next : Option Char) : Bool :=
  ['\\', '[', ']', '#', '$', '*', '_', '`', '<', '>', '@', '~'].contains c ||
  (bol && ['=', '-', '+'].contains c) ||
  (c == '/' && (next == some '/' || next == some '*'))

/-- A description's text in a content block. -/
def escT : Bool → List Char → List Char
  | _, [] => []
  | bol, c :: r => (if mustEsc bol c r.head? then ['\\', c] else [c]) ++ escT (c == '\n') r

/-- The text of a content block up to its unescaped `]`. -/
def readEsc : List Char → Option (List Char × List Char)
  | [] => none
  | ']' :: r => some ([], r)
  | '\\' :: c :: r => (readEsc r).map (fun p => (c :: p.1, p.2))
  | '[' :: _ => none
  | c :: r => (readEsc r).map (fun p => (c :: p.1, p.2))

theorem readEsc_escT (r : List Char) : ∀ (bol : Bool) (s : List Char),
    readEsc (escT bol s ++ ']' :: r) = some (s, r)
  | _, [] => rfl
  | bol, c :: s => by
    have ih := readEsc_escT r (c == '\n') s
    simp only [escT, List.append_assoc]
    by_cases h : mustEsc bol c s.head? = true
    · simp only [h, ite_true, List.cons_append, List.nil_append, readEsc, ih, Option.map_some]
    · simp only [h, Bool.false_eq_true, ite_false, List.cons_append, List.nil_append]
      have h1 : c ≠ ']' := fun e => h (by subst e; simp [mustEsc])
      have h2 : c ≠ '\\' := fun e => h (by subst e; simp [mustEsc])
      have h3 : c ≠ '[' := fun e => h (by subst e; simp [mustEsc])
      rw [readEsc] <;> simp_all

/-! ## Named arguments -/

/-- `key: value`. -/
def argT (a : String × Json) : List Char := a.1.toList ++ ':' :: ' ' :: TypstDict.encode a.2

/-- One named argument at its key. -/
def pArg (F : Nat) (s : List Char) : Option ((String × Json) × List Char) :=
  if isIdent (readIdent s).1 && !TypstDict.reserved (String.ofList (readIdent s).1) then
    match (readIdent s).2 with
    | ':' :: ' ' :: u => (TypstDict.pVal F u).map (fun p => ((String.ofList (readIdent s).1, p.1), p.2))
    | _ => none
  else none

/-- `, key: value` repeated, up to `)`. -/
def pArgsMore (F : Nat) : Nat → List Char → Option (List (String × Json) × List Char)
  | 0, _ => none
  | _ + 1, ')' :: r => some ([], r)
  | f + 1, ',' :: ' ' :: r => (pArg F r).bind (fun p => (pArgsMore F f p.2).map (fun q => (p.1 :: q.1, q.2)))
  | _ + 1, _ => none

/-- Arguments directly after `(`. -/
def pArgsFirst (F f : Nat) : List Char → Option (List (String × Json) × List Char)
  | ')' :: r => some ([], r)
  | s => (pArg F s).bind (fun p => (pArgsMore F f p.2).map (fun q => (p.1 :: q.1, q.2)))

/-- Arguments after a first positional one: each `, key: value`. -/
def argsMoreT (as : List (String × Json)) : List Char := as.flatMap (fun a => ',' :: ' ' :: argT a)

/-- Arguments directly after `(`. -/
def argsFirstT : List (String × Json) → List Char
  | [] => []
  | a :: as => argT a ++ argsMoreT as

/-- A named argument Typst can carry: an identifier key that is not a keyword. -/
def argOK (a : String × Json) : Bool := bareKey TypstDict.reserved a.1 && jwf a.2

/-! ## Constructs -/

def nameTyp (n : String) : List Char := (printTypst {} (.str n)).toList

def dkw : DKind → List Char
  | .var => oVar
  | .param => oParam
  | .species => oSpecies

/-- `#var($N$, default: 100)`. -/
def declT (d : Decl) : List Char := dkw d.kind ++ '$' :: nameTyp d.name ++ '$' :: argsMoreT d.attrs ++ [')']

/-- The text of a construct. -/
def itemT : RItem → List Char
  | .desc s => oDesc ++ escT true s.toList ++ [']', '\n']
  | .block k v => oBlock ++ quote true k ++ ',' :: ' ' :: TypstDict.encode v ++ [')', '\n']
  | .comp .model n => oModel ++ quote true n ++ [')', '\n']
  | .comp .rs n => oRs ++ quote true n ++ [')', '\n']
  | .decl d => declT d
  | .eqn raw => oEq ++ raw.toList ++ [' ', '$', '\n']

/-- A display equation with a label after it (` <eq-x>`). -/
def eqnLabeled (raw : String) (label : List Char) : List Char :=
  oEq ++ raw.toList ++ ' ' :: '$' :: label ++ ['\n']

/-- A label after a display equation: nothing, or `<id>`, with spaces around. -/
def labelOK (sl : List Char) : Bool :=
  match sl.dropWhile (· == ' ') with
  | [] => true
  | '<' :: r => r.getLast? == some '>' && !(r.dropLast.contains '>') && !(r.dropLast.contains '<')
  | _ => false

/-! ## The lexer -/

def blockOpen (s : List Char) : Bool := pre oDesc s || pre oBlock s || pre oModel s || pre oRs s || pre oEq s

def declOpen (s : List Char) : Bool := pre oVar s || pre oParam s || pre oSpecies s

/-- The rest of a construct's line must be blank. -/
def lineEnd (t : List Char) : Option (List Char) :=
  if (splitLine t).1.all (· == ' ') then some (splitLine t).2 else none

def descAt (u : List Char) : Option (RItem × List Char) :=
  (readEsc u).bind (fun p => (lineEnd p.2).map (fun r => (.desc (String.ofList p.1), r)))

def blockAtT (F : Nat) (u : List Char) : Option (RItem × List Char) :=
  match parseQuoted true u with
  | some (k, ',' :: ' ' :: w) =>
    match TypstDict.pVal F w with
    | some (v, ')' :: r) => (lineEnd r).map (fun r' => (.block k v, r'))
    | _ => none
  | _ => none

def compAt (K : Kind) (u : List Char) : Option (RItem × List Char) :=
  match parseQuoted true u with
  | some (n, ')' :: r) => (lineEnd r).map (fun r' => (.comp K n, r'))
  | _ => none

def eqAt (u : List Char) : Option (RItem × List Char) :=
  match u.drop (u.takeWhile (· != '$')).length with
  | '$' :: r =>
    if (u.takeWhile (· != '$')).getLast? == some ' ' && labelOK (splitLine r).1 then
      some (.eqn (String.ofList (u.takeWhile (· != '$')).dropLast), (splitLine r).2)
    else none
  | _ => none

def blockAt (F : Nat) (s : List Char) : Option (RItem × List Char) :=
  if pre oDesc s then descAt (s.drop oDesc.length)
  else if pre oBlock s then blockAtT F (s.drop oBlock.length)
  else if pre oModel s then compAt .model (s.drop oModel.length)
  else if pre oRs s then compAt .rs (s.drop oRs.length)
  else eqAt (s.drop oEq.length)

def declBody (F f : Nat) (k : DKind) : List Char → Option (RItem × List Char)
  | '$' :: t =>
    match t.drop (t.takeWhile (· != '$')).length with
    | '$' :: u =>
      match parseTypst {} (String.ofList (t.takeWhile (· != '$'))) with
      | some (.str n) => (pArgsMore F f u).map (fun p => (.decl ⟨k, n, p.1⟩, p.2))
      | _ => none
    | _ => none
  | _ => none

def declAt (F f : Nat) (s : List Char) : Option (RItem × List Char) :=
  if pre oVar s then declBody F f .var (s.drop oVar.length)
  else if pre oParam s then declBody F f .param (s.drop oParam.length)
  else declBody F f .species (s.drop oSpecies.length)

/-- **The Typst lexer**: the constructs of a text, skipping prose one character at a
time. -/
def lex : Nat → Bool → List Char → Option (List RItem)
  | 0, _, _ => none
  | _ + 1, _, [] => some []
  | f + 1, bol, c :: r =>
    if bol && blockOpen (c :: r) then
      (blockAt (3 * f + 3) (c :: r)).bind (fun p => (lex f true p.2).map (p.1 :: ·))
    else if declOpen (c :: r) then
      (declAt (3 * f + 3) f (c :: r)).bind (fun p => (lex f false p.2).map (p.1 :: ·))
    else lex f (c == '\n') r

/-! ## Reading back the pieces -/

theorem numStop_of {rest : List Char} (h : rest.head? = some ',' ∨ rest.head? = some ')') :
    Number.NumStop rest := by
  intro c hc
  rcases h with h | h <;> rw [h] at hc <;> cases hc <;> decide

theorem pArg_argT (F : Nat) (a : String × Json) (ha : argOK a = true) (rest : List Char)
    (hr : rest.head? = some ',' ∨ rest.head? = some ')') (hF : 3 * a.2.size ≤ F) :
    pArg F (argT a ++ rest) = some (a, rest) := by
  obtain ⟨k, v⟩ := a
  simp only [argOK, bareKey, Bool.and_eq_true, Bool.not_eq_true'] at ha
  obtain ⟨⟨hk, hres⟩, hw⟩ := ha
  have hrd : readIdent (argT (k, v) ++ rest) = (k.toList, ':' :: ' ' :: (TypstDict.encode v ++ rest)) := by
    simp only [argT, List.append_assoc, List.cons_append]
    exact readIdent_append _ _ (isIdent_all hk) (by simp [isIdentChar])
  unfold pArg
  rw [hrd]
  simp only [String.ofList_toList, hk, hres, Bool.not_false, Bool.and_self, ite_true]
  rw [TypstDict.encode, TypstDict.pVal_enc 0 v F rest (jwf_sound v hw) (numStop_of hr) hF]
  rfl

/-- The fuel the value reader needs, bounded by the text. -/
theorem size_le_argT (a : String × Json) : a.2.size ≤ (argT a).length := by
  have := TypstDict.size_le 0 a.2
  simp [argT, TypstDict.encode]; omega

theorem pArgsMore_argsMoreT (F : Nat) (as : List (String × Json)) (ha : ∀ a ∈ as, argOK a = true)
    (hF : ∀ a ∈ as, 3 * a.2.size ≤ F) (t : List Char) :
    ∀ f, as.length < f → pArgsMore F f (argsMoreT as ++ ')' :: t) = some (as, t) := by
  induction as with
  | nil => intro f hf; obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩; rfl
  | cons a as ih =>
    intro f hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    simp only [argsMoreT, List.flatMap_cons, List.cons_append, List.append_assoc, pArgsMore]
    have hr : (argsMoreT as ++ ')' :: t).head? = some ',' ∨ (argsMoreT as ++ ')' :: t).head? = some ')' := by
      cases as <;> simp [argsMoreT]
    rw [show as.flatMap (fun a => ',' :: ' ' :: argT a) = argsMoreT as from rfl,
      pArg_argT F a (ha a List.mem_cons_self) _ hr (hF a List.mem_cons_self)]
    simp only [Option.bind_some]
    rw [ih (fun b hb => ha b (List.mem_cons_of_mem _ hb)) (fun b hb => hF b (List.mem_cons_of_mem _ hb))
      g (by simp at hf; omega)]
    rfl

theorem pArgsFirst_argsFirstT (F : Nat) (as : List (String × Json)) (ha : ∀ a ∈ as, argOK a = true)
    (hF : ∀ a ∈ as, 3 * a.2.size ≤ F) (t : List Char) (f : Nat) (hf : as.length < f) :
    pArgsFirst F f (argsFirstT as ++ ')' :: t) = some (as, t) := by
  cases as with
  | nil => rfl
  | cons a as =>
    have hk : (argT a).head? ≠ some ')' := by
      obtain ⟨k, v⟩ := a
      have := ha (k, v) List.mem_cons_self
      simp only [argOK, bareKey, Bool.and_eq_true] at this
      cases hk : k.toList with
      | nil => rw [hk] at this; simp [isIdent] at this
      | cons c r =>
        rw [hk] at this
        simp only [isIdent, Bool.and_eq_true] at this
        simp only [argT, hk, List.cons_append, List.head?_cons, ne_eq, Option.some.injEq]
        intro e; subst e; simp [isIdentStart] at this
    have hpa : pArgsFirst F f (argsFirstT (a :: as) ++ ')' :: t) =
        (pArg F (argsFirstT (a :: as) ++ ')' :: t)).bind
          (fun p => (pArgsMore F f p.2).map (fun q => (p.1 :: q.1, q.2))) := by
      unfold pArgsFirst
      split
      · rename_i r hr
        exfalso; apply hk
        simp only [argsFirstT, List.append_assoc] at hr
        cases hm : argT a with
        | nil => simp [argT] at hm
        | cons x y => rw [hm] at hr; simp at hr; rw [hr.1]; rfl
      · rfl
    rw [hpa]
    simp only [argsFirstT, List.append_assoc]
    have hr : (argsMoreT as ++ ')' :: t).head? = some ',' ∨ (argsMoreT as ++ ')' :: t).head? = some ')' := by
      cases as <;> simp [argsMoreT]
    rw [pArg_argT F a (ha a List.mem_cons_self) _ hr (hF a List.mem_cons_self)]
    simp only [Option.bind_some]
    rw [pArgsMore_argsMoreT F as (fun b hb => ha b (List.mem_cons_of_mem _ hb))
      (fun b hb => hF b (List.mem_cons_of_mem _ hb)) t f (by simp at hf; omega)]
    rfl

/-- A declaration the Typst syntax can hold. -/
def declOK (d : Decl) : Bool := nameOK d.name && !(nameTyp d.name).contains '$' && d.attrs.all argOK

theorem takeWhile_noDollar (x y : List Char) (hx : x.contains '$' = false) :
    (x ++ '$' :: y).takeWhile (· != '$') = x := by
  induction x with
  | nil => simp
  | cons c x ih =>
    simp only [List.contains_cons, Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq] at hx
    simp [Ne.symm hx.1, ih hx.2]

theorem argsMoreT_len (as : List (String × Json)) : as.length ≤ (argsMoreT as).length := by
  induction as with
  | nil => simp [argsMoreT]
  | cons a as ih => simp [argsMoreT, List.flatMap_cons] at ih ⊢; omega

theorem argsMoreT_size (as : List (String × Json)) : ∀ a ∈ as, a.2.size ≤ (argsMoreT as).length := by
  intro a ha
  induction as with
  | nil => cases ha
  | cons b bs ih =>
    have h1 := size_le_argT b
    simp only [argsMoreT, List.flatMap_cons, List.length_append, List.length_cons] at ih ⊢
    rcases List.mem_cons.mp ha with rfl | h
    · omega
    · have := ih h; omega

theorem declBody_declT (F f : Nat) (d : Decl) (hd : declOK d = true) (t : List Char)
    (hf : d.attrs.length < f) (hF : ∀ a ∈ d.attrs, 3 * a.2.size ≤ F) :
    declBody F f d.kind ('$' :: nameTyp d.name ++ '$' :: argsMoreT d.attrs ++ ')' :: t) =
      some (.decl d, t) := by
  obtain ⟨k, n, as⟩ := d
  simp only [declOK, Bool.and_eq_true, Bool.not_eq_true'] at hd
  obtain ⟨⟨hn, hdol⟩, has⟩ := hd
  simp only at hn hdol has hf hF ⊢
  simp only [List.cons_append, declBody, List.append_assoc]
  simp only [takeWhile_noDollar _ _ hdol, List.drop_left]
  have hp : parseTypst {} (String.ofList (nameTyp n)) = some (.str n) := by
    simp only [nameTyp, String.ofList_toList]
    exact parseTypst_printTypst {} (.str n) (by simpa [isE] using hn)
  rw [hp]
  simp only
  rw [pArgsMore_argsMoreT F as (fun a ha => List.all_eq_true.mp has a ha) hF t f hf]
  rfl

/-! ## Documents, prose and validity -/

/-- A piece of a Typst document: a construct, a labelled equation, or prose. -/
inductive Seg where
  | item (it : RItem)
  | labeled (raw : String) (label : List Char)
  | prose (p : List Char)

def segText : Seg → List Char
  | .item it => itemT it
  | .labeled raw l => eqnLabeled raw l
  | .prose p => p

def render (segs : List Seg) : List Char := segs.flatMap segText

def segItems : List Seg → List RItem
  | [] => []
  | .item it :: r => it :: segItems r
  | .labeled raw _ :: r => .eqn raw :: segItems r
  | .prose _ :: r => segItems r

def isBlock : RItem → Bool
  | .decl _ => false
  | _ => true

/-- What each construct's content must satisfy for its text to read back. -/
def itemOK : RItem → Bool
  | .desc _ => true
  | .block _ v => jwf v
  | .comp _ _ => true
  | .decl d => declOK d
  | .eqn raw => !raw.toList.contains '$'

/-- Prose that the lexer skips. -/
def Inert : Bool → List Char → List Char → Prop
  | _, [], _ => True
  | bol, c :: p, t =>
    (bol && blockOpen (c :: p ++ t)) = false ∧ declOpen (c :: p ++ t) = false ∧ Inert (c == '\n') p t

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
  | c :: p, t, bol, ⟨h1, h2, h3⟩, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    simp only [List.cons_append, lex]
    simp only [List.cons_append] at h1 h2
    rw [h1, h2]
    simp only [Bool.false_eq_true, ite_false]
    rw [lex_prose p t _ h3 g (by simp at hf; omega), endBol_cons]
    congr 1
    simp

theorem lex_block_step (g : Nat) (bol : Bool) (x t : List Char) (it : RItem) (hx : x ≠ [])
    (ho : blockOpen (x ++ t) = true) (hbol : bol = true)
    (hb : blockAt (3 * g + 3) (x ++ t) = some (it, t)) :
    lex (g + 1) bol (x ++ t) = (lex g true t).map (it :: ·) := by
  obtain ⟨c, r, hcr⟩ : ∃ c r, x ++ t = c :: r := by
    cases x with
    | nil => exact absurd rfl hx
    | cons c r => exact ⟨c, r ++ t, rfl⟩
  rw [hcr] at ho hb ⊢
  simp only [lex, hbol, ho, Bool.and_self, ite_true, hb, Option.bind_some]

theorem lex_decl_step (g : Nat) (bol : Bool) (x t : List Char) (it : RItem) (hx : x ≠ [])
    (hb1 : blockOpen (x ++ t) = false) (ho : declOpen (x ++ t) = true)
    (hd : declAt (3 * g + 3) g (x ++ t) = some (it, t)) :
    lex (g + 1) bol (x ++ t) = (lex g false t).map (it :: ·) := by
  obtain ⟨c, r, hcr⟩ : ∃ c r, x ++ t = c :: r := by
    cases x with
    | nil => exact absurd rfl hx
    | cons c r => exact ⟨c, r ++ t, rfl⟩
  rw [hcr] at hb1 hd ho ⊢
  simp only [lex, hb1, Bool.and_false, Bool.false_eq_true, ite_false, ho, ite_true, hd,
    Option.bind_some]

theorem lineEnd_nl (t : List Char) : lineEnd ('\n' :: t) = some t := by simp [lineEnd, splitLine]

theorem pre_desc_block (X : List Char) : pre oDesc (oBlock ++ X) = false := by simp [oDesc, oBlock, pre]
theorem pre_desc_model (X : List Char) : pre oDesc (oModel ++ X) = false := by simp [oDesc, oModel, pre]
theorem pre_block_model (X : List Char) : pre oBlock (oModel ++ X) = false := by simp [oBlock, oModel, pre]
theorem pre_desc_rs (X : List Char) : pre oDesc (oRs ++ X) = false := by simp [oDesc, oRs, pre]
theorem pre_block_rs (X : List Char) : pre oBlock (oRs ++ X) = false := by simp [oBlock, oRs, pre]
theorem pre_model_rs (X : List Char) : pre oModel (oRs ++ X) = false := by simp [oModel, oRs, pre]
theorem pre_desc_eq (X : List Char) : pre oDesc (oEq ++ X) = false := by simp [oDesc, oEq, pre]
theorem pre_block_eq (X : List Char) : pre oBlock (oEq ++ X) = false := by simp [oBlock, oEq, pre]
theorem pre_model_eq (X : List Char) : pre oModel (oEq ++ X) = false := by simp [oModel, oEq, pre]
theorem pre_rs_eq (X : List Char) : pre oRs (oEq ++ X) = false := by simp [oRs, oEq, pre]

theorem lex_desc (s : String) (bol : Bool) (hbol : bol = true) (t : List Char) (g : Nat) :
    lex (g + 1) bol (itemT (.desc s) ++ t) = (lex g true t).map (.desc s :: ·) := by
  apply lex_block_step g bol _ t _ (by simp [itemT, oDesc]) _ hbol
  · simp only [itemT, List.append_assoc, blockAt, pre_append, ite_true, List.drop_left,
      List.cons_append, List.nil_append]
    simp [descAt, readEsc_escT, lineEnd_nl]
  · simp [itemT, blockOpen, pre_append]

theorem lex_block (k : String) (v : Json) (hv : itemOK (.block k v) = true) (bol : Bool)
    (hbol : bol = true) (t : List Char) (g : Nat)
    (hg : (itemT (.block k v)).length + t.length < g + 1) :
    lex (g + 1) bol (itemT (.block k v) ++ t) = (lex g true t).map (.block k v :: ·) := by
  apply lex_block_step g bol _ t _ (by simp [itemT, oBlock]) _ hbol
  · simp only [itemT, List.append_assoc, blockAt, pre_desc_block, pre_append, Bool.false_eq_true,
      ite_false, ite_true, List.drop_left, List.cons_append, List.nil_append]
    unfold blockAtT
    rw [parseQuoted_quote]
    simp only
    have hs := TypstDict.size_le 0 v
    rw [TypstDict.encode, TypstDict.pVal_enc 0 v _ _ (jwf_sound v hv) (by intro c hc; cases hc; decide)
      (by simp [itemT, TypstDict.encode] at hg; omega)]
    simp [lineEnd_nl]
  · simp [itemT, blockOpen, pre_append]

theorem lex_comp (K : Kind) (n : String) (bol : Bool) (hbol : bol = true) (t : List Char) (g : Nat) :
    lex (g + 1) bol (itemT (.comp K n) ++ t) = (lex g true t).map (.comp K n :: ·) := by
  cases K with
  | model =>
    apply lex_block_step g bol _ t _ (by simp [itemT, oModel]) _ hbol
    · simp only [itemT, List.append_assoc, blockAt, pre_desc_model, pre_block_model, pre_append,
        Bool.false_eq_true, ite_false, ite_true, List.drop_left, List.cons_append, List.nil_append]
      simp [compAt, parseQuoted_quote, lineEnd_nl]
    · simp [itemT, blockOpen, pre_append]
  | rs =>
    apply lex_block_step g bol _ t _ (by simp [itemT, oRs]) _ hbol
    · simp only [itemT, List.append_assoc, blockAt, pre_desc_rs, pre_block_rs, pre_model_rs,
        pre_append, Bool.false_eq_true, ite_false, ite_true, List.drop_left, List.cons_append,
        List.nil_append]
      simp [compAt, parseQuoted_quote, lineEnd_nl]
    · simp [itemT, blockOpen, pre_append]

theorem lex_eqnL (raw : String) (l : List Char) (hr : itemOK (.eqn raw) = true)
    (hl : labelOK l = true) (hln : '\n' ∉ l) (bol : Bool) (hbol : bol = true) (t : List Char)
    (g : Nat) :
    lex (g + 1) bol (eqnLabeled raw l ++ t) = (lex g true t).map (.eqn raw :: ·) := by
  simp only [itemOK, Bool.not_eq_true'] at hr
  apply lex_block_step g bol _ t _ (by simp [eqnLabeled, oEq]) _ hbol
  · simp only [eqnLabeled, List.append_assoc, blockAt, pre_desc_eq, pre_block_eq, pre_model_eq,
      pre_rs_eq, Bool.false_eq_true, ite_false, List.drop_left, List.cons_append]
    unfold eqAt
    have htw : (raw.toList ++ ' ' :: '$' :: (l ++ '\n' :: t)).takeWhile (· != '$') =
        raw.toList ++ [' '] := by
      rw [show raw.toList ++ ' ' :: '$' :: (l ++ '\n' :: t) =
        (raw.toList ++ [' ']) ++ '$' :: (l ++ '\n' :: t) by simp]
      exact takeWhile_noDollar _ _ (by simpa using hr)
    simp only [List.nil_append, htw]
    rw [show raw.toList ++ ' ' :: '$' :: (l ++ '\n' :: t) =
      (raw.toList ++ [' ']) ++ '$' :: (l ++ '\n' :: t) by simp, List.drop_left]
    simp [splitLine_line l t hln, hl]
  · simp [eqnLabeled, blockOpen, oDesc, oBlock, oModel, oRs, oEq, pre]

theorem lex_decl (d : Decl) (hd : itemOK (.decl d) = true) (bol : Bool) (t : List Char)
    (g : Nat) (hg : (itemT (.decl d)).length + t.length < g + 1) :
    lex (g + 1) bol (itemT (.decl d) ++ t) = (lex g false t).map (.decl d :: ·) := by
  simp only [itemOK] at hd
  have hlen := argsMoreT_len d.attrs
  have hsz := argsMoreT_size d.attrs
  obtain ⟨k, n, as⟩ := d
  have hg' : (dkw k).length + (nameTyp n).length + (argsMoreT as).length + t.length + 3 < g + 1 := by
    simp [itemT, declT, List.length_append] at hg; omega
  have hb := declBody_declT (3 * g + 3) g ⟨k, n, as⟩ hd t
    (by simp at hlen ⊢; omega)
    (by intro a ha; have := hsz a ha; simp at this; omega)
  simp only [List.cons_append, List.append_assoc] at hb
  have eV : oVar = ['#', 'v', 'a', 'r', '('] := rfl
  have eP : oParam = ['#', 'p', 'a', 'r', 'a', 'm', '('] := rfl
  have eS : oSpecies = ['#', 's', 'p', 'e', 'c', 'i', 'e', 's', '('] := rfl
  apply lex_decl_step g bol _ t _ (by cases k <;> simp [itemT, declT, dkw, oVar, oParam, oSpecies])
  · cases k <;> simp [itemT, declT, dkw, blockOpen, oVar, oParam, oSpecies, oDesc, oBlock, oModel,
      oRs, oEq, pre]
  · cases k <;> simp [itemT, declT, dkw, declOpen, oVar, oParam, oSpecies, pre]
  · cases k <;> simpa [itemT, declT, dkw, declAt, eV, eP, eS, pre] using hb

theorem itemT_eqn (raw : String) : itemT (.eqn raw) = eqnLabeled raw [] := by
  simp [itemT, eqnLabeled]

/-- **The Typst lexer reads back every valid document body**: exactly its constructs,
whatever prose surrounds them and whatever labels the equations carry. -/
theorem lex_render : ∀ (segs : List Seg) (bol : Bool), Valid bol segs →
    ∀ f, (render segs).length < f → lex f bol (render segs) = some (segItems segs)
  | [], bol, _, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp [render] at hf; omega⟩
    rfl
  | .prose p :: rest, bol, ⟨hi, hv⟩, f, hf => by
    rw [show render (.prose p :: rest) = p ++ render rest from rfl] at hf ⊢
    rw [lex_prose p _ bol hi f (by simpa using hf)]
    exact lex_render rest _ hv _ (by simp at hf ⊢; omega)
  | .labeled raw l :: rest, bol, ⟨hb, hr, hl, hln, hv⟩, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp [render] at hf; omega⟩
    rw [show render (.labeled raw l :: rest) = eqnLabeled raw l ++ render rest from rfl] at hf ⊢
    rw [lex_eqnL raw l hr hl hln bol hb _ g]
    rw [lex_render rest true hv g (by simp [eqnLabeled] at hf ⊢; omega)]
    rfl
  | .item it :: rest, bol, ⟨hok, hb, hv⟩, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp [render] at hf; omega⟩
    rw [show render (.item it :: rest) = itemT it ++ render rest from rfl] at hf ⊢
    have hlen : ∀ x : List Char, x ≠ [] → (x ++ render rest).length < g + 1 →
        (render rest).length < g := by
      intro x hx h
      have : 1 ≤ x.length := List.length_pos_of_ne_nil hx
      simp at h; omega
    have hf' := hf
    rw [List.length_append] at hf'
    cases it with
    | desc s =>
      rw [lex_desc s bol (hb rfl) _ g,
        lex_render rest true hv g (hlen _ (by simp [itemT, oDesc]) hf)]
      rfl
    | block k v =>
      rw [lex_block k v hok bol (hb rfl) _ g hf',
        lex_render rest true hv g (hlen _ (by simp [itemT, oBlock]) hf)]
      rfl
    | comp K n =>
      rw [lex_comp K n bol (hb rfl) _ g,
        lex_render rest true hv g (hlen _ (by cases K <;> simp [itemT, oModel, oRs]) hf)]
      rfl
    | decl d =>
      rw [lex_decl d hok bol _ g hf',
        lex_render rest false hv g (hlen _ (by simp [itemT, declT]) hf)]
      rfl
    | eqn raw =>
      rw [itemT_eqn] at hf ⊢
      rw [lex_eqnL raw [] hok rfl (by simp) bol (hb rfl) _ g,
        lex_render rest true hv g (hlen _ (by simp [eqnLabeled, oEq]) hf)]
      rfl

end Esm.Document.Source.Typ
