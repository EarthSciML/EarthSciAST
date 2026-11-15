package docfmt

import "testing"

func tdictRt(t *testing.T, text string) string {
	t.Helper()
	v, ok := tdictDecode([]rune(text))
	if !ok {
		t.Fatalf("does not decode: %q", text)
	}
	return string(tdictEncode(v))
}

func TestTdictRoundTrip(t *testing.T) {
	if got, want := tdictRt(t, "(a: 1, \"b c\": (1,), d: (:), e: ())"),
		"(\n  a: 1,\n  \"b c\": (\n    1,\n  ),\n  d: (:),\n  e: (),\n)"; got != want {
		t.Errorf("got %q", got)
	}
	if got := tdictRt(t, "( -9223372036854775807 - 1 )"); got != "(-9223372036854775807 - 1)" {
		t.Errorf("got %q", got)
	}
	for _, bad := range []string{"(1)", "(none: 1)"} {
		if _, ok := tdictDecode([]rune(bad)); ok {
			t.Errorf("%q decodes", bad)
		}
	}
}
