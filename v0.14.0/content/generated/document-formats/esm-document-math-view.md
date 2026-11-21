---
title: "How the printer prints each expression"
type: lean
lean_module: "Esm.Document.Math.View"
weight: 12
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.View</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/View.lean"><code>formal/Esm/Document/Math/View.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-parse"><code>Esm.Document.Math.Parse</code></a></p>

`view` sorts every well-formed expression into the notation the printer gives it
and states the printer's output for it, so the round-trip proof never unfolds the
printer itself.

<div class="lean-decl" id="Esm.Document.Math.V">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.V" title="Esm.Document.Math.V"><code>V</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/View.lean#L22-L164">source</a></div>

```lean
inductive V (c : Ctx) : Json → Prop where
  | num (n : JNum) (h : n.WF) : V c (.num n)
  | name (s : String) (h : nameOK s = true) : V c (.str s)
  | neg (o : String) (a : Json) (ho : kindOf o = .minus) (ha : isE a = true)
      (hpr : pr c (node o [a]) =
        mkOut c.sf 5 (.kw .minus :: (if startsNum ((pr c a).at c.sf 5) then grp c.sf ((pr c a).at c.sf 5)
          else (pr c a).at c.sf 5))) : V c (node o [a])
  | minus (o : String) (a b : Json) (ho : kindOf o = .minus) (ha : isE a = true) (hb : isE b = true)
      (hpr : pr c (node o [a, b]) = mkOut c.sf 4 ((pr c a).at c.sf 4 ++ .kw .minus :: (pr c b).at c.sf 5)) :
      V c (node o [a, b])
  | div (o : String) (a b : Json) (ho : kindOf o = .div) (ha : isE a = true) (hb : isE b = true)
      (hpr : pr c (node o [a, b]) = match c.sf with
        | .latex => mkOut c.sf 10 ([.kw .frac, .kw .lb] ++ (pr c a).at c.sf 1 ++
            [.kw .rb, .kw .lb] ++ (pr c b).at c.sf 1 ++ [.kw .rb])
        | .typst => mkOut c.sf 7 ((pr c a).at c.sf 8 ++ .kw .slash :: (pr c b).at c.sf 8)) :
      V c (node o [a, b])
  | pow (o : String) (a b : Json) (ho : kindOf o = .pow) (ha : isE a = true) (hb : isE b = true)
      (hpr : pr c (node o [a, b]) = mkOut c.sf 8 ((pr c a).at c.sf 9 ++ .kw .caret :: (match c.sf with
          | .latex => [.kw .lb] ++ (pr c b).at c.sf 1 ++ [.kw .rb]
          | .typst =>
            match simpleE c b with
            | some t => [t]
            | none => grp c.sf (pr c b).toks))) :
      V c (node o [a, b])
  | lnot (o : String) (a : Json) (ho : kindOf o = .lnot) (ha : isE a = true)
      (hpr : pr c (node o [a]) = mkOut c.sf 6 (.kw .lnot :: (pr c a).at c.sf 6)) : V c (node o [a])
  | tru (o : String) (ho : kindOf o = .tru) (hpr : pr c (node o []) = mkOut c.sf 10 [.txt "true"]) :
      V c (node o [])
  | fls (o : String) (ho : kindOf o = .fls) (hpr : pr c (node o []) = mkOut c.sf 10 [.txt "false"]) :
      V c (node o [])
  | ite (o : String) (cnd a b : Json) (ho : kindOf o = .ite) (hc : isE cnd = true) (ha : isE a = true)
      (hb : isE b = true)
      (hpr : pr c (node o [cnd, a, b]) =
        ⟨10, casesToks c.sf (caseRow c.sf ((pr c a).at c.sf 1) ((pr c cnd).at c.sf 1) ++ (pr c b).crow),
          caseRow c.sf ((pr c a).at c.sf 1) ((pr c cnd).at c.sf 1) ++ (pr c b).crow⟩) :
      V c (node o [cnd, a, b])
  | un (o : String) (k : Kw) (a : Json) (ho : kindOf o = .un k) (ha : isE a = true)
      (hpr : pr c (node o [a]) = mkOut c.sf 10 (unToks c.sf k ((pr c a).at c.sf 1))) : V c (node o [a])
  | ic (o : String) (n : String) (ho : kindOf o = .ic) (hn : nameOK n = true)
      (hpr : pr c (node o [.str n]) = mkOut c.sf 10 (nameToks c n ++ icTail c.sf)) :
      V c (node o [.str n])
  | idxSub (o : String) (b : String) (is : List Json) (ho : kindOf o = .index) (hne : is ≠ [])
      (hs : subOK c.S (.str b) is = true)
      (hsp : subPat c.sf (subList c.sf (simpleArg c is) (is.map fun x => (pr c x).at c.sf 1)) = false)
      (hi : ∀ x ∈ is, isE x = true)
      (hpr : pr c (node o (.str b :: is)) =
        mkOut c.sf 9 (nameToks c b ++ subList c.sf (simpleArg c is) (is.map fun x => (pr c x).at c.sf 1))) :
      V c (node o (.str b :: is))
  | idxBr (o : String) (base : Json) (is : List Json) (ho : kindOf o = .index) (hne : is ≠ [])
      (hb : isE base = true) (hi : ∀ x ∈ is, isE x = true)
      (hpr : pr c (node o (base :: is)) = mkOut c.sf 9 ((pr c base).at c.sf 10 ++ [.kw .lbk] ++
        sepBy [.kw .comma] (is.map fun x => (pr c x).at c.sf 1) ++ [.kw .rbk])) :
      V c (node o (base :: is))
  | cmp (o : String) (k : Kw) (a b : Json) (ho : kindOf o = .cmp k) (ha : isE a = true) (hb : isE b = true)
      (hpr : pr c (node o [a, b]) = mkOut c.sf 3 ((pr c a).at c.sf 4 ++ .kw k :: (pr c b).at c.sf 4)) :
      V c (node o [a, b])
  | plus (o : String) (xs : List Json) (ho : kindOf o = .plus) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 4 (sepBy [.kw .plus] (xs.map fun x => (pr c x).at c.sf 5))) :
      V c (node o xs)
  | times (o : String) (xs : List Json) (ho : kindOf o = .times) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 5 (mulToks (xs.map fun x => (pr c x).at c.sf 6))) :
      V c (node o xs)
  | land (o : String) (xs : List Json) (ho : kindOf o = .land) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 2 (sepBy [.kw .land] (xs.map fun x => (pr c x).at c.sf 3))) :
      V c (node o xs)
  | lor (o : String) (xs : List Json) (ho : kindOf o = .lor) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 1 (sepBy [.kw .lor] (xs.map fun x => (pr c x).at c.sf 2))) :
      V c (node o xs)
  | mm (o : String) (k : Kw) (xs : List Json) (ho : kindOf o = .mm k) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 10 (callToks c.sf [.kw k] (xs.map fun x => (pr c x).at c.sf 1))) :
      V c (node o xs)
  | call (o : String) (xs : List Json) (ho : kindOf o = .call) (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 10 (callToks c.sf [.opn o] (xs.map fun x => (pr c x).at c.sf 4))) :
      V c (node o xs)
  | dTime (a : Json) (ha : isE a = true)
      (hpr : pr c (dNode a "t") = dTime c.sf (pr c a)) : V c (dNode a "t")
  | dSpace (w : String) (a : Json) (hw : w ≠ "t") (hwn : nameOK w = true) (ha : isE a = true)
      (hpr : pr c (dNode a w) = dSpace c.sf (nameToks c w) (pr c a)) : V c (dNode a w)
  | dCall (w : String) (xs : List Json) (hw : w ≠ "t") (hwn : nameOK w = true) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (dCallNode w xs) =
        mkOut c.sf 10 (dCall c.sf (nameToks c w) (xs.map fun x => (pr c x).at c.sf 4))) :
      V c (dCallNode w xs)
  | qty (u : String) (n : JNum) (hn : n.WF) (hu : unitsOK c.sf u = true)
      (hpr : pr c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)]) =
        mkOut c.sf 7 (qtyToks n (factorsOf u))) :
      V c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)])
  | arr (xs : List Json) (af : AForm) (haf : arrForm (.arr xs) = some af)
      (hpr : pr c (.obj [("args", .arr []), ("op", .str "const"), ("value", .arr xs)]) =
        mkOut c.sf 10 (arrToks c.sf af)) :
      V c (.obj [("args", .arr []), ("op", .str "const"), ("value", .arr xs)])
  | arrU (u : String) (xs : List Json) (af : AForm) (haf : arrForm (.arr xs) = some af)
      (hu : unitsOK c.sf u = true)
      (hpr : pr c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .arr xs)]) =
        mkOut c.sf 7 (arrToks c.sf af ++ unitToks (factorsOf u))) :
      V c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .arr xs)])
  | tpos (n : String) (bs : List (String × Json)) (ps : List String) (hn : tnameOK n = true)
      (hs : keysSorted bs = true) (hb : ∀ kv ∈ bs, isE kv.2 = true) (hps : positional c.S n bs = some ps)
      (hpr : pr c (tNode n bs) = mkOut c.sf 10 (callToks c.sf [.opn n]
        (ps.map fun p => ((bs.map fun kv => (kv.1, (pr c kv.2).at c.sf 4)).lookup p).getD []))) :
      V c (tNode n bs)
  | tnamed (n : String) (bs : List (String × Json)) (hn : tnameOK n = true) (hs : keysSorted bs = true)
      (hb : ∀ kv ∈ bs, isE kv.2 = true) (hps : positional c.S n bs = none) (hne : bs ≠ [])
      (hk : ∀ kv ∈ bs, nameOK kv.1 = true) (hkn : (bs.map Prod.fst).Nodup)
      (hpr : pr c (tNode n bs) = mkOut c.sf 10 (callToks c.sf [.opn n]
        (bs.map fun kv => nameToks c kv.1 ++ .kw .eq :: (pr c kv.2).at c.sf 4))) :
      V c (tNode n bs)
  | openop (kvs : List (String × Json)) (o : String) (as : List Json)
      (hop : look "op" kvs = some (.str o)) (hargs : look "args" kvs = some (.arr as))
      (hs : keysSorted kvs = true) (hx : ∀ x ∈ as, isE x = true)
      (hf : ∀ kv ∈ fieldsOf kvs, jwf kv.2 = true)
      (hcf : callFormOK o (fieldsOf kvs) = true) (hopn : opnOK o = true) (htp : tparams c.S o = none)
      (hnat : nativeK c.sf kvs = false)
      (hkey : ∀ kv ∈ fieldsOf kvs, keyOK kv.1 = true)
      (hsz : ∀ x ∈ as, sizeOf x < sizeOf (Json.obj kvs))
      (hszf : ∀ kv ∈ fieldsOf kvs, sizeOf kv.2 < sizeOf (Json.obj kvs))
      (hpr : pr c (.obj kvs) = mkOut c.sf 10 (openToks c.sf o (as.map fun x => (pr c x).at c.sf 4)
        ((fieldsOf kvs).map fun kv =>
          keyToks c.sf kv.1 ++ .kw .eq :: (if mathField o kv then (pr c kv.2).at c.sf 4 else jsonVal c.sf kv.2)))) :
      V c (.obj kvs)
  | faq (kvs : List (String × Json)) (F : FaqForm) (hF : faqForm kvs = some F) (hok : faqOK F = true)
      (P : Json → Out) (hP : ∀ x ∈ faqSubs F, P x = pr c x)
      (hpr : pr c (.obj kvs) = faqOut c P F) : V c (.obj kvs)
  | mk (kvs : List (String × Json)) (M : MkForm) (hM : mkForm kvs = some M) (hok : mkOK M = true)
      (P : Json → Out) (hP : ∀ x ∈ mkSubs M, P x = pr c x)
      (hpr : pr c (.obj kvs) = mkOutT c P M) : V c (.obj kvs)
  | tbare (n : String) (hn : tnameOK n = true) (hps : positional c.S n [] = none)
      (hpr : pr c (tNode n []) = mkOut c.sf 5 [.opn n]) : V c (tNode n [])
  | esc (kvs : List (String × Json)) (o : String) (as : List Json)
      (hop : look "op" kvs = some (.str o)) (hargs : look "args" kvs = some (.arr as))
      (hs : keysSorted kvs = true) (hx : ∀ x ∈ as, isE x = true)
      (hf : ∀ kv ∈ fieldsOf kvs, jwf kv.2 = true)
      (hoOK : opOK o = true) (hrem : removedOps.contains o = false)
      (hdep : deprecatedOps.contains o = false)
      (hsz : ∀ x ∈ as, sizeOf x < sizeOf (Json.obj kvs))
      (hpr : pr c (.obj kvs) =
        mkOut c.sf 10 (escToks c.sf o (fieldsOf kvs) (as.map fun x => (pr c x).at c.sf 1))) :
      V c (.obj kvs)
```

The printer's case for an expression, with its output.

</div>

<p class="lean-meta">This module also proves 13 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/View.lean">the source</a>.</p>
