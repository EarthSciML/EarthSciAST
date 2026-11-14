import Esm.Document.Source.Markdown
import Esm.Document.Source.Equation
import Esm.Document.Source.MultiLine

/-!
# Markdown documents: printing, parsing, and the round trip

`printMd` spells a canonical ESM document as Markdown, `parseMd` reads it back, and
`parseMd_printMd` is the round trip. The layers compose:

1. `toDoc capsMd` (the skeleton, with the path-keyed fallback for anything Markdown
   cannot spell natively) and `ofDoc` — `ofDoc_toDoc`;
2. `rawDoc prMdx` (each equation, and each reaction's rate, as LaTeX under its
   component's symbol table) and `cookDoc ckMdx` — `cookDoc_rawDoc`, with the Phase 2
   theorem `parseLatex_printLatex`;
3. `items` and `unitems` — `unitems_items`;
4. the text: front matter, then the constructs separated by blank lines — `lex_render`.
-/

namespace Esm.Document.Source.Md

open Esm.Document Esm.Document.Math Esm.Document.Source Esm.Document.Strings

/-! ## Equations in LaTeX -/

/-- An equation's LaTeX under the symbol table `S`. -/
def latexOf (S : Sym) (e : Eqn) : List Char := (printLatex S (eqExpr e)).toList

/-- An equation's math text: its `_comment` as a LaTeX comment line, then the equation. -/
def prMd (S : Sym) (e : Eqn) : String :=
  String.ofList ((match e.comment with
    | some c => '%' :: ' ' :: c.toList ++ ['\n']
    | none => []) ++ latexOf S e)

/-- The multi-line environments: `true` when all rows are one equation. -/
def envs : List (String × Bool) :=
  [("aligned", false), ("align", false), ("align*", false), ("gathered", false),
    ("split", true), ("multline", true), ("multline*", true)]

def isWsC (c : Char) : Bool := c == ' ' || c == '\n' || c == '\t'

/-- A display that is one multi-line environment: whether its rows are one equation, and
the environment's body. -/
def envOf (body : List Char) : Option (Bool × List Char) :=
  let b := ((body.dropWhile isWsC).reverse.dropWhile isWsC).reverse
  envs.findSome? (fun E =>
    let o := ("\\begin{" ++ E.1 ++ "}").toList
    let c := ("\\end{" ++ E.1 ++ "}").toList
    if pre o b && pre c.reverse b.reverse then
      some (E.2, (b.drop o.length).take (b.length - o.length - c.length))
    else none)

/-- The comment goes to the first equation of a display. -/
def withComment (c : Option String) : List Eqn → List Eqn
  | e :: es => { e with comment := c } :: es
  | [] => []

/-- One display in LaTeX: a multi-line environment (an accepted variant), or one
equation. -/
def oneMd (S : Sym) (c : Option String) (body : List Char) : Option (List Eqn) :=
  match envOf body with
  | some (one, inner) => ((Latex.lex inner).bind (cookRows .latex S one)).map (withComment c)
  | none =>
    match (parseLatex S (String.ofList body)).bind eqSides with
    | some (l, r) => some [⟨c, l, r⟩]
    | none => none

/-- **Read the math text of a display equation** under the symbol table `S`: an
optional leading comment line `% …` (the `_comment`), then the equation. -/
def ckMd (S : Sym) (raw : String) : Option (List Eqn) :=
  match raw.toList with
  | '%' :: ' ' :: r => oneMd S (some (String.ofList (splitLine r).1)) (splitLine r).2
  | cs => oneMd S none cs

/-- A math entry's text: an equation's LaTeX (`prMd`), or a reaction with its rate as
LaTeX. -/
def prMdx : Sym → MC → MR := prMx prMd (fun S j => printLatex S j)

/-- Read a math entry's text. -/
def ckMdx : Sym → MR → Option (List MC) := ckMx ckMd (fun S raw => parseLatex S raw)

/-- A comment Markdown can carry on its LaTeX comment line. -/
def commentOK : Option String → Bool
  | some c => !c.toList.contains '\n' && !c.toList.contains '$'
  | none => true

/-! ## What Markdown spells natively -/

/-- The Markdown container's predicates. A description must not contain a line that
would close its fence (`noStop`; CommonMark also closes a fence indented by up to three
spaces, and treats a carriage return as a line end). An equation's LaTeX must be one
line without `$` and not start with `%`. -/
def capsMd : Caps where
  frontKey _ := true
  desc s := noStop fence (s.toList ++ ['\n']) && noStop (' ' :: fence) (s.toList ++ ['\n']) &&
    noStop (' ' :: ' ' :: fence) (s.toList ++ ['\n']) &&
    noStop (' ' :: ' ' :: ' ' :: fence) (s.toList ++ ['\n']) && !s.toList.contains '\r'
  compName n := !n.toList.contains ']' && !n.toList.contains '\n'
  declName n := nameOK n && !(nameLatex n).contains '$' && !n.toList.contains ']' &&
    !n.toList.contains '\n'
  attr a := isIdent a.1.toList
  eqn S e := commentOK e.comment && !(latexOf S e).contains '$' && !(latexOf S e).contains '\n' &&
    (latexOf S e).head? != some '%' && (envOf (latexOf S e)).isNone
  rxn S x := rxnOK { x with rate := printLatex S x.rate }
  plot a := a.all attrOK

theorem heads_sub {c : Char} : ∀ {bol : Bool} {x : List Char}, c ∈ heads bol x → c ∈ x
  | _, [], h => by cases h
  | bol, d :: r, h => by
    simp only [heads, List.mem_append] at h
    rcases h with h | h
    · cases bol <;> simp_all
    · exact List.mem_cons_of_mem _ (heads_sub h)

theorem contains_false {c : Char} {x : List Char} (h : x.contains c = false) : c ∉ x := by
  intro hm
  have : x.contains c = true := List.contains_iff_mem.mpr hm
  rw [h] at this; cases this

/-- **An equation reads back from its LaTeX**, comment included. -/
theorem ckMd_prMd (S : Sym) (e : Eqn) (hc : capsMd.eqn S e = true) (hl : isE e.lhs = true)
    (hr : isE e.rhs = true) : ckMd S (prMd S e) = some [e] := by
  simp only [capsMd, Bool.and_eq_true, Bool.not_eq_true', bne_iff_ne, ne_eq] at hc
  obtain ⟨⟨⟨⟨hcm, hd⟩, hn⟩, hp⟩, henv⟩ := hc
  have hparse : (parseLatex S (String.ofList (latexOf S e))).bind eqSides = some (e.lhs, e.rhs) := by
    simp only [latexOf, String.ofList_toList, parseLatex_printLatex S _ (isE_eqExpr e hl hr),
      Option.bind_some, eqSides_eqExpr]
  obtain ⟨cm, l, r⟩ := e
  unfold ckMd prMd
  rw [String.toList_ofList]
  cases cm with
  | some c =>
    simp only [commentOK, Bool.and_eq_true, Bool.not_eq_true'] at hcm
    simp only [List.cons_append, List.append_assoc]
    rw [splitLine_line _ _ (contains_false hcm.1)]
    simp only [oneMd, String.ofList_toList, List.nil_append, Option.isNone_iff_eq_none.mp henv]
    rw [hparse]
  | none =>
    simp only [List.nil_append]
    split
    · rename_i r' h; rw [h] at hp; simp at hp
    · simp only [oneMd, Option.isNone_iff_eq_none.mp henv]; rw [hparse]

/-! ## The document -/

/-- The front matter: `---`, the YAML of the entries, `---`. -/
def frontMd (front : List (String × Json)) : List Char :=
  dashes ++ '\n' :: Yaml.encode (.obj front) ++ dashes ++ ['\n']

/-- The canonical layout: each construct after a blank line, a declaration on a line of
its own. -/
def canonSegs (its : List RItem) : List Seg :=
  its.flatMap (fun it => [.prose ['\n'], .item it] ++ (if isBlock it then [] else [.prose ['\n']]))

/-- **Print a document as Markdown.** -/
def printMd (d : Json) : String :=
  let D := toDoc capsMd d
  String.ofList (frontMd D.front ++ render (canonSegs (items (rawDoc prMdx D))))

/-- Read the front matter and the constructs. -/
def lexDoc (s : List Char) : Option (List (String × Json) × List RItem) :=
  match s with
  | '-' :: '-' :: '-' :: '\n' :: r =>
    match untilStop dashes (s.length + 1) r with
    | some (body, sl, rest) =>
      if sl.all (· == ' ') then
        match Yaml.decode body with
        | some (.obj kvs) => (lex (s.length + 1) true rest).map (fun its => (kvs, its))
        | _ => none
      else none
    | none => none
  | _ => none

/-- **Read a Markdown document.** -/
def parseMd (s : String) : Option Json := do
  let p ← lexDoc s.toList
  let R ← unitems p.1 p.2
  let D ← cookDoc ckMdx R
  ofDoc D

theorem segItems_append (a b : List Seg) : segItems (a ++ b) = segItems a ++ segItems b := by
  induction a with
  | nil => rfl
  | cons x a ih => cases x <;> simp [segItems, ih]

theorem segItems_canon (its : List RItem) : segItems (canonSegs its) = its := by
  induction its with
  | nil => rfl
  | cons it its ih =>
    simp only [canonSegs, List.flatMap_cons] at ih ⊢
    rw [segItems_append, ih]
    cases it with
    | decl d => by_cases hk : d.kind = .sub <;> simp [segItems, isBlock, hk]
    | _ => simp [segItems, isBlock]

theorem render_append (a b : List Seg) : render (a ++ b) = render a ++ render b := by
  simp [render]

theorem inert_nl (bol : Bool) (t : List Char) : Inert bol ['\n'] t := by
  refine ⟨?_, ?_, ?_, ?_, trivial⟩
  · simp [blockOpen, fenceEsm, dd, dModel, dRs, dPlot, dSub, pre]
  · simp [declOpen, pre]
  · simp [tableOpen, pre]
  · simp [contOpen, dInit_l, dCons_l, pre]

theorem valid_canon : ∀ (its : List RItem), (∀ it ∈ its, itemOK it = true) →
    ∀ bol, Valid bol (canonSegs its)
  | [], _, _ => trivial
  | it :: its, h, bol => by
    have ih := valid_canon its (fun x hx => h x (List.mem_cons_of_mem _ hx))
    have hit := h it List.mem_cons_self
    simp only [canonSegs, List.flatMap_cons] at ih ⊢
    cases it with
    | decl d =>
      obtain ⟨k, n, as⟩ := d
      cases k
      · exact ⟨inert_nl _ _, hit, fun h => by simp [isBlock] at h, inert_nl _ _, ih _⟩
      · exact ⟨inert_nl _ _, hit, fun h => by simp [isBlock] at h, inert_nl _ _, ih _⟩
      · exact ⟨inert_nl _ _, hit, fun h => by simp [isBlock] at h, inert_nl _ _, ih _⟩
      · exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | desc _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | block _ _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | comp _ _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | eqn _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | eqx _ _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | rxn _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩
    | plot _ => exact ⟨inert_nl _ _, hit, fun _ => rfl, ih _⟩

/-- **The front matter and the body read back.** -/
theorem lexDoc_front (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (segs : List Seg) (hv : Valid true segs) :
    lexDoc (frontMd front ++ render segs) = some (front, segItems segs) := by
  have hw : (Json.obj front).WF := jwf_sound _ hf
  have hl : Lines (Yaml.encode (.obj front)) := Or.inr (by
    have := yaml_ends (.obj front)
    unfold endBol at this
    split at this
    · cases this
    · rename_i c hc; simp at this; rw [hc, this])
  have hns : noStop dashes (Yaml.encode (.obj front)) = true :=
    noStop_of_heads _ _ (yaml_heads_dash front hw)
  unfold lexDoc frontMd
  simp only [dashes, List.append_assoc, List.cons_append]
  have hu := untilStop_body dashes (by decide) (by decide) (Yaml.encode (.obj front)) [] (render segs)
    hl hns (by simp)
  have e : ("---".toList : List Char) = ['-', '-', '-'] := rfl
  simp only [dashes, List.append_assoc, List.nil_append, e, List.cons_append] at hu ⊢
  rw [hu _ (by simp; omega)]
  simp only [List.all_nil, ↓reduceIte, Yaml.decode_encode _ hw]
  rw [lex_render segs true hv _ (by simp; omega)]
  rfl

theorem prMd_noDollar (S : Sym) (e : Eqn) (hc : capsMd.eqn S e = true) :
    '$' ∉ (prMd S e).toList ++ ['\n'] := by
  simp only [capsMd, Bool.and_eq_true, Bool.not_eq_true'] at hc
  obtain ⟨⟨⟨⟨hcm, hd⟩, _⟩, _⟩, _⟩ := hc
  unfold prMd
  rw [String.toList_ofList]
  intro hm
  simp only [List.mem_append, List.mem_singleton] at hm
  rcases hm with (hm | hm) | hm
  · cases hcom : e.comment with
    | none => rw [hcom] at hm; cases hm
    | some c =>
      rw [hcom] at hm hcm
      simp only [commentOK, Bool.and_eq_true, Bool.not_eq_true'] at hcm
      simp only [List.cons_append, List.mem_cons, List.mem_append] at hm
      rcases hm with h | h | h | h | h
      · cases h
      · cases h
      · exact contains_false hcm.2 h
      · cases h
      · cases h
  · exact contains_false hd hm
  · cases hm

/-- Every construct of the printed skeleton satisfies `itemOK`. -/
theorem items_ok (D : Doc MC) (h : DocOK capsMd D) :
    ∀ it ∈ items (rawDoc prMdx D), itemOK it = true := by
  intro it hit
  simp only [items, rawDoc, List.mem_append, List.mem_map, List.mem_flatMap, Option.mem_toList,
    Option.map_eq_some_iff] at hit
  rcases hit with ((⟨s, hs, rfl⟩) | ⟨kv, hkv, rfl⟩) | ⟨c', ⟨c, hc, rfl⟩, hit⟩
  · have := h.desc s hs
    simp only [capsMd, Bool.and_eq_true] at this
    exact this.1.1.1.1
  · exact h.blocks kv hkv
  · simp only [compItems, Comp.mapMath, List.mem_cons, List.mem_append, List.mem_map,
      Option.mem_toList, Option.map_eq_some_iff] at hit
    rcases hit with rfl | (((((⟨s, hs, rfl⟩) | ⟨d, hd, rfl⟩) | ⟨r, ⟨m, hm, rfl⟩, rfl⟩) |
      ⟨kv, hkv, rfl⟩) | ⟨kv, hkv, rfl⟩)
    · exact h.compName c hc
    · have := h.cdesc c hc s hs
      simp only [capsMd, Bool.and_eq_true] at this
      exact this.1.1.1.1
    · have hn := h.declName c hc d hd
      have ha := h.attrs c hc d hd
      have hat : d.attrs.all attrOK = true := List.all_eq_true.mpr fun a hma => by
        have := ha a hma
        simp only [capsMd] at this
        simp only [attrOK, Bool.and_eq_true]
        exact ⟨this.1, this.2⟩
      simp only [capsMd, Bool.and_eq_true] at hn
      simp only [itemOK]
      split
      · simp only [subOK, Bool.and_eq_true]; exact ⟨⟨hn.1.2, hn.2⟩, hat⟩
      · simp only [declOK, Bool.and_eq_true]; exact ⟨hn.1.1, hat⟩
    · have hmc := (h.math c hc m hm).1
      cases m with
      | eq ro e =>
        have hns : noStop dd ((prMd (symFor D.blocks c) e).toList ++ ['\n']) = true :=
          noStop_of_heads _ _ (fun hm' => prMd_noDollar _ e hmc (heads_sub hm'))
        cases ro with
        | eqn => exact hns
        | init => simp [prMdx, prMx, mItem, itemOK, hns]
        | cons => simp [prMdx, prMx, mItem, itemOK, hns]
      | rxn x => exact hmc
      | plot a => exact hmc
    · exact (h.mathBlocks c hc kv hkv).2
    · exact (h.cblocks c hc kv hkv).2

/-- **The Markdown round trip.** Every ESM document in canonical form reads back from its
Markdown spelling. -/
theorem parseMd_printMd (d : Json) (hd : canonDoc d = true) : parseMd (printMd d) = some d := by
  have hok := toDoc_ok capsMd rfl d hd
  unfold parseMd printMd
  simp only [String.toList_ofList]
  rw [lexDoc_front _ hok.frontWF _ (valid_canon _ (items_ok _ hok) true), segItems_canon]
  simp only [Option.bind_eq_bind, Option.bind_some]
  have hR := unitems_items (rawDoc prMdx (toDoc capsMd d)) (by
    intro c hc
    simp only [rawDoc, List.mem_map] at hc
    obtain ⟨c0, hc0, rfl⟩ := hc
    exact ⟨fun kv hkv => (hok.cblocks c0 hc0 kv hkv).1, fun kv hkv => (hok.mathBlocks c0 hc0 kv hkv).1⟩)
  rw [show (rawDoc prMdx (toDoc capsMd d)).front = (toDoc capsMd d).front from rfl] at hR
  rw [hR]
  simp only [Option.bind_some]
  rw [cookDoc_rawDoc prMdx ckMdx _ (fun c hc m hm => by
    have := hok.math c hc m hm
    apply ckMx_prMx
    · intro r e he
      subst he
      simp only [mathWF, Bool.and_eq_true] at this
      exact ckMd_prMd _ e this.1 this.2.1 this.2.2
    · intro x hx
      subst hx
      exact parseLatex_printLatex _ _ this.2)]
  simp only [Option.bind_some]
  exact ofDoc_toDoc capsMd d hd

/-! ## Prose and labels do not change the parse -/

/-- What a document says, given its front matter and its constructs. -/
def parseItemsMd (front : List (String × Json)) (its : List RItem) : Option Json := do
  let R ← unitems front its
  let D ← cookDoc ckMdx R
  ofDoc D

/-- **The parse of a Markdown document depends only on its front matter and its sequence
of constructs**: not on the prose between them, and not on equation labels. -/
theorem parseMd_body (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (segs : List Seg) (hv : Valid true segs) :
    parseMd (String.ofList (frontMd front ++ render segs)) = parseItemsMd front (segItems segs) := by
  unfold parseMd parseItemsMd
  simp only [String.toList_ofList]
  rw [lexDoc_front front hf segs hv]
  rfl

/-- Two valid documents with the same constructs parse alike. -/
theorem parseMd_eq_of_items (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (s₁ s₂ : List Seg) (h₁ : Valid true s₁) (h₂ : Valid true s₂) (h : segItems s₁ = segItems s₂) :
    parseMd (String.ofList (frontMd front ++ render s₁)) =
      parseMd (String.ofList (frontMd front ++ render s₂)) := by
  rw [parseMd_body front hf s₁ h₁, parseMd_body front hf s₂ h₂, h]

/-- Inserting prose leaves the constructs as they were. -/
theorem segItems_prose (a b : List Seg) (p : List Char) :
    segItems (a ++ .prose p :: b) = segItems (a ++ b) := by
  simp [segItems_append, segItems]

/-- Labelling an equation leaves the constructs as they were. -/
theorem segItems_label (a b : List Seg) (raw : String) (l : List Char) :
    segItems (a ++ .labeled raw l :: b) = segItems (a ++ .item (.eqn raw) :: b) := by
  simp [segItems_append, segItems]

/-- **Inserting prose does not change the parse** (where the result is still valid: the
prose is `Inert` and block constructs still start a line). -/
theorem parseMd_insert_prose (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (a b : List Seg) (p : List Char) (h₁ : Valid true (a ++ b)) (h₂ : Valid true (a ++ .prose p :: b)) :
    parseMd (String.ofList (frontMd front ++ render (a ++ .prose p :: b))) =
      parseMd (String.ofList (frontMd front ++ render (a ++ b))) :=
  parseMd_eq_of_items front hf _ _ h₂ h₁ (segItems_prose a b p)

/-- **Adding an equation label does not change the parse.** -/
theorem parseMd_label (front : List (String × Json)) (hf : jwf (.obj front) = true)
    (a b : List Seg) (raw : String) (l : List Char) (h₁ : Valid true (a ++ .item (.eqn raw) :: b))
    (h₂ : Valid true (a ++ .labeled raw l :: b)) :
    parseMd (String.ofList (frontMd front ++ render (a ++ .labeled raw l :: b))) =
      parseMd (String.ofList (frontMd front ++ render (a ++ .item (.eqn raw) :: b))) :=
  parseMd_eq_of_items front hf _ _ h₂ h₁ (segItems_label a b raw l)

/-! ## Multi-line equations -/

theorem withComment_none (es : List Eqn) (h : ∀ e ∈ es, e.comment = none) : withComment none es = es := by
  cases es with
  | nil => rfl
  | cons e es => cases e; simp at h; simp [withComment, h.1]

/-- **The `aligned` variant reads as the equations it lays out**: a display
`\begin{aligned} … \end{aligned}` whose rows lay out the canonical LaTeX of equations
(`Layout`) reads back as exactly those equations. -/
theorem ckMd_aligned (S : Sym) (Ls : List Layout) (es : List Eqn)
    (hL : ∀ L ∈ Ls, L.OK) (hne : Ls ≠ [])
    (h : List.Forall₂ (fun L e => L.toks = print .latex S (eqExpr e) ∧ isE e.lhs = true ∧
      isE e.rhs = true) Ls es) :
    ckMd S (String.ofList ("\\begin{aligned}".toList ++ Latex.render (rowsToks Ls) ++
      "\\end{aligned}".toList)) = some (es.map (fun e => ⟨none, e.lhs, e.rhs⟩)) := by
  have htok : ∀ t ∈ rowsToks Ls, Latex.tokOK t := by
    intro t ht
    rcases mem_rowsToks ht with rfl | rfl | ⟨L, hLm, htL⟩
    · simp [Latex.tokOK, Latex.kwOK]
    · simp [Latex.tokOK, Latex.kwOK]
    · obtain ⟨e, -, he⟩ : ∃ e ∈ es, L.toks = print .latex S (eqExpr e) ∧ isE e.lhs = true ∧
          isE e.rhs = true := by
        clear hL hne htL ht
        induction h with
        | nil => cases hLm
        | @cons L' e' _ _ hh _ ih =>
          rcases List.mem_cons.mp hLm with rfl | hm
          · exact ⟨e', List.mem_cons_self, hh⟩
          · obtain ⟨e'', hm', h''⟩ := ih hm
            exact ⟨e'', List.mem_cons_of_mem _ hm', h''⟩
      rw [he.1] at htL
      exact Latex.print_tokOK S _ (isE_eqExpr e he.2.1 he.2.2) t htL
  set X := Latex.render (rowsToks Ls) with hX
  have henv : envOf ("\\begin{aligned}".toList ++ X ++ "\\end{aligned}".toList) = some (false, X) := by
    unfold envOf
    have h1 : ("\\begin{aligned}".toList ++ X ++ "\\end{aligned}".toList).dropWhile isWsC =
        "\\begin{aligned}".toList ++ X ++ "\\end{aligned}".toList := by
      simp [isWsC]
    have h2 : ("\\begin{aligned}".toList ++ X ++ "\\end{aligned}".toList).reverse.dropWhile isWsC =
        ("\\begin{aligned}".toList ++ X ++ "\\end{aligned}".toList).reverse := by
      simp [isWsC]
    rw [h1, h2, List.reverse_reverse]
    simp only [envs, List.findSome?_cons]
    have h3 : pre ("\\begin{" ++ "aligned" ++ "}").toList
        ("\\begin{aligned}".toList ++ X ++ "\\end{aligned}".toList) = true := by
      rw [List.append_assoc]; exact pre_append _ _
    have h4 : pre ("\\end{" ++ "aligned" ++ "}").toList.reverse
        ("\\begin{aligned}".toList ++ X ++ "\\end{aligned}".toList).reverse = true := by
      rw [List.reverse_append]; exact pre_append _ _
    simp only [h3, h4, Bool.and_self, ↓reduceIte]
    congr 2
    simp
  unfold ckMd
  rw [String.toList_ofList]
  split
  · rename_i r hr; simp at hr
  · simp only [oneMd]
    rw [henv]
    simp only [hX, Latex.lex_render _ htok, Option.bind_some,
      cookRows_layout .latex S Ls es hL hne h, Option.map_some]
    rw [withComment_none _ (by simp)]

end Esm.Document.Source.Md
