package docfmt

import "testing"

// A document with no math, no declarations and no components exercises the
// whole source layer without the math layer.
func TestSourceRoundTripWithoutMath(t *testing.T) {
	doc := FromGo(map[string]any{
		"esm": "0.1.0",
		"metadata": map[string]any{
			"name":        "x",
			"description": "Hello `code` and\n```not a fence",
			"tags":        []any{"a", "b"},
		},
		"data_sources": map[string]any{"a": map[string]any{"x": int64(1), "y": 2.5, "z": nil}},
		"weird key":    []any{int64(1), 1e-9, map[string]any{"q": true}},
		"description":  "top",
	})
	if !skCanonDoc(doc) {
		t.Fatal("test document is not canonical")
	}
	md := mdDocPrintMd(&Lim{}, doc)
	back, ok := mdDocParseMd(&Lim{}, md)
	if !ok || !JsonEqual(back, doc) {
		t.Errorf("markdown round trip failed (%v):\n%s\n%s", ok, md, Render(back))
	}
	typ := typDocPrintTyp(&Lim{}, doc)
	back, ok = typDocParseTyp(&Lim{}, typ)
	if !ok || !JsonEqual(back, doc) {
		t.Errorf("typst round trip failed (%v):\n%s\n%s", ok, typ, Render(back))
	}
	// Prose between the constructs is ignored.
	withProse := md + "\nSome prose with `` ` `` code.\n"
	if back, ok := mdDocParseMd(&Lim{}, withProse); !ok || !JsonEqual(back, doc) {
		t.Errorf("prose changed the markdown reading")
	}
	// CRLF and a BOM are accepted.
	crlf := "\uFEFF" + replaceNl(md)
	if back, ok := mdDocParseMd(&Lim{}, crlf); !ok || !JsonEqual(back, doc) {
		t.Errorf("CRLF input not read")
	}
}

func replaceNl(s string) string {
	out := make([]rune, 0, len(s))
	for _, c := range s {
		if c == '\n' {
			out = append(out, '\r')
		}
		out = append(out, c)
	}
	return string(out)
}

func TestSourceRefusesBadFrontMatter(t *testing.T) {
	for _, text := range []string{"", "---\nesm: 1\n", "--\nesm: 1\n---\n", "---\nesm: 1\n--- x\n"} {
		if _, ok := mdDocParseMd(&Lim{}, text); ok {
			t.Errorf("%q reads", text)
		}
	}
	if _, ok := typDocParseTyp(&Lim{}, "#import nothing\n"); ok {
		t.Error("bad typst header reads")
	}
}

func TestMdFlowAttrs(t *testing.T) {
	v := Obj{{"a", []Json{IntNum(1), "it's & x"}}, {"yes", Obj{}}}
	text := mdAttrVal(v)
	if string(text) != "'{a: [1, \"it&#39;s &amp; x\"], \"yes\": {}}'" {
		t.Fatalf("got %s", string(text))
	}
	got, rest, ok := mdPQuoted(&Lim{}, text[1:])
	if !ok || len(rest) != 0 || !JsonEqual(got, v) {
		t.Fatalf("read back %v %v %q", got, ok, string(rest))
	}
	as, rest, ok := mdPAttrs(&Lim{}, []rune("a=1 b='[2]' c=\"s\"} x"))
	if !ok || len(as) != 3 || string(rest) != " x" {
		t.Fatalf("attrs %v %v %q", as, ok, string(rest))
	}
}

func TestLabels(t *testing.T) {
	for s, want := range map[string]bool{"": true, "  ": true, " {#eq-1}": true, "{#a}}": false, "x": false} {
		if mdLabelOk([]rune(s)) != want {
			t.Errorf("mdLabelOk(%q)", s)
		}
	}
	for s, want := range map[string]bool{"": true, " <eq-1>": true, "<a<b>": false, "<a": false} {
		if stypLabelOk([]rune(s)) != want {
			t.Errorf("stypLabelOk(%q)", s)
		}
	}
}

func TestTextHelpers(t *testing.T) {
	body, rest, after, ok := textUntilStop([]rune("$$"), []rune("a\nb\n$$ x\nc"))
	if !ok || string(body) != "a\nb\n" || string(rest) != " x" || string(after) != "c" {
		t.Fatalf("untilStop %q %q %q %v", string(body), string(rest), string(after), ok)
	}
	if !textNoStop([]rune("```"), []rune("a\n ```\n")) || textNoStop([]rune("```"), []rune("a\n```\n")) {
		t.Fatal("noStop")
	}
	if got := string(linesDecodeText([]rune("\uFEFFa\r\nb\r\n"))); got != "a\nb\n" {
		t.Fatalf("decodeText %q", got)
	}
	if !stypVerbOK([]rune("a `b` [c [d]] col_1d")) || stypVerbOK([]rune("a * b")) || stypVerbOK([]rune("x_ y")) {
		t.Fatal("verbOK")
	}
	if s, r, ok := stypReadVerb([]rune("a\\]b [c]] x")); !ok || string(s) != "a]b [c]" || string(r) != " x" {
		t.Fatal("readVerb")
	}
	if stypNameLenT([]rune("italic(\"a,b\"), c")) != 13 {
		t.Fatal("nameLenT")
	}
}

func TestMultiLineGroup(t *testing.T) {
	x, eq, amp := tLetter('x'), tKw(KwEq), tKw(KwAmp)
	rows := [][]Tok{{x, amp, eq, x}, {amp, tKw(KwPlus), x}, {}}
	g, ok := mlGroup(false, rows)
	if !ok || len(g) != 1 || len(g[0]) != 5 {
		t.Fatalf("group %v %v", g, ok)
	}
	if _, ok := mlGroup(false, [][]Tok{{amp, eq, x}}); ok {
		t.Fatal("continuation without a first row")
	}
	if _, ok := mlGroup(false, [][]Tok{{x, eq, x}, {amp, eq, x}}); ok {
		t.Fatal("continuation with its own =")
	}
	if _, ok := mlGroup(false, [][]Tok{{x, amp, eq, amp, x}}); ok {
		t.Fatal("two ampersands")
	}
	g, ok = mlGroup(true, [][]Tok{{x, eq}, {x, amp, x}})
	if !ok || len(g) != 1 || len(g[0]) != 4 {
		t.Fatalf("one group %v", g)
	}
	// depth: an `&` inside parentheses is not a cell break
	b, _, found := mlCut(KwAmp, 0, []Tok{tKw(KwLpg), amp, tKw(KwRpg), amp})
	if !found || len(b) != 3 {
		t.Fatal("cut depth")
	}
}

func TestKeysJoinField(t *testing.T) {
	pick := func(k string, v Json) (KV, bool) {
		if _, ok := v.(JNum); ok {
			return KV{k, v}, true
		}
		return KV{}, false
	}
	back := func(kv KV) (KV, bool) { return kv, true }
	v := Obj{{"a", IntNum(1)}, {"b", "s"}, {"c", IntNum(2)}}
	ps, r, hasR := keysSplitField(pick, v)
	if len(ps) != 2 || !hasR || !JsonEqual(r, Obj{{"b", "s"}}) {
		t.Fatal("split")
	}
	j, present, ok := keysJoinField(back, ps, r, hasR)
	if !ok || !present || !JsonEqual(j, v) {
		t.Fatalf("join %v", Render(j))
	}
	all := Obj{{"a", IntNum(1)}}
	ps, _, hasR = keysSplitField(pick, all)
	if hasR || len(ps) != 1 {
		t.Fatal("split all")
	}
	if _, _, ok := keysPickOne("a", Obj{{"a", nil}, {"a", nil}}); ok {
		t.Fatal("pickOne duplicate")
	}
}

// The front matter and path-block layout of the golden set
// (documents.json `front_matter` and `path_blocks`), without their model.
func TestSourceGoldenLayoutWithoutMath(t *testing.T) {
	doc := FromGo(map[string]any{
		"coupling": []any{map[string]any{"systems": []any{"M", "M"}, "type": "operator_compose"}},
		"esm":      "2.3.0",
		"metadata": map[string]any{
			"authors": []any{"A. Author", "B. Author"}, "created": "2026-11-13T00:00:00Z",
			"description": "A well-mixed box.\nTwo lines.", "license": "CC0-1.0", "name": "box",
			"tags": []any{"test"},
		},
		"tolerance": map[string]any{"rel": 1e-06},
	})
	wantMd := "---\nesm: \"2.3.0\"\nauthors:\n  - \"A. Author\"\n  - \"B. Author\"\n" +
		"created: \"2026-11-13T00:00:00Z\"\nlicense: \"CC0-1.0\"\nname: \"box\"\ntags:\n  - \"test\"\n---\n\n" +
		"```esm:description\nA well-mixed box.\nTwo lines.\n```\n\n" +
		"```esm:coupling\n- systems:\n    - \"M\"\n    - \"M\"\n  type: \"operator_compose\"\n```\n\n" +
		"```esm:tolerance\nrel: 1.0e-6\n```\n"
	wantTyp := "#import \"@preview/esm:0.1.0\": *\n#show: esm-document.with(esm: \"2.3.0\", authors: (\n" +
		"  \"A. Author\",\n  \"B. Author\",\n), created: \"2026-11-13T00:00:00Z\", license: \"CC0-1.0\", " +
		"name: \"box\", tags: (\n  \"test\",\n))\n\n#description[A well-mixed box.\nTwo lines.]\n\n" +
		"#esm-block(\"coupling\", (\n  (\n    systems: (\n      \"M\",\n      \"M\",\n    ),\n" +
		"    type: \"operator_compose\",\n  ),\n))\n\n#esm-block(\"tolerance\", (\n  rel: 1.0e-6,\n))\n"
	if got := mdDocPrintMd(&Lim{}, doc); got != wantMd {
		t.Errorf("markdown:\n%s", got)
	}
	if got := typDocPrintTyp(&Lim{}, doc); got != wantTyp {
		t.Errorf("typst:\n%s", got)
	}
	for _, f := range []func(*Lim, string) (Json, bool){mdDocParseMd, typDocParseTyp} {
		for _, text := range []string{wantMd, wantTyp} {
			if back, ok := f(&Lim{}, text); ok && !JsonEqual(back, doc) {
				t.Errorf("reads back differently: %s", Render(back))
			}
		}
	}
	if back, ok := mdDocParseMd(&Lim{}, wantMd); !ok || !JsonEqual(back, doc) {
		t.Error("markdown does not read back")
	}
	if back, ok := typDocParseTyp(&Lim{}, wantTyp); !ok || !JsonEqual(back, doc) {
		t.Error("typst does not read back")
	}
}
