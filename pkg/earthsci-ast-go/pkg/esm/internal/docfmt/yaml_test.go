package docfmt

import (
	"strings"
	"testing"
)

func yamlRt(t *testing.T, text string) string {
	t.Helper()
	v, ok := yamlDecode([]rune(text))
	if !ok {
		t.Fatalf("does not decode: %q", text)
	}
	return string(yamlEncode(v))
}

func TestYamlRoundTrips(t *testing.T) {
	for _, text := range []string{
		"a: 1\nb:\n  - 1\n  - c: \"x\"\n    d: []\n  -\n    - null\n\"y es\": {}\n\"Yes\": true\n",
		"- 1\n- \"a\\u0001\"\n",
		"1.0e-9\n",
		"\"s\"\n",
		"{}\n",
	} {
		if got := yamlRt(t, text); got != text {
			t.Errorf("round trip of %q gave %q", text, got)
		}
	}
}

func TestYamlRefusals(t *testing.T) {
	for _, text := range []string{"a: 1\na: 2\n", "yes: 1\n", "a: 01\n", "a:  1\n", "a: 1"} {
		if _, ok := yamlDecode([]rune(text)); ok {
			t.Errorf("%q decodes", text)
		}
	}
}

func TestYamlLongKeyExplicitForm(t *testing.T) {
	k := strings.Repeat("x", 1100)
	v := Obj{{"a", Obj{{k, IntNum(1)}}}}
	text := string(yamlEncode(v))
	if want := "a:\n  ? \"" + k + "\"\n  : 1\n"; text != want {
		t.Fatalf("got %q", text)
	}
	back, ok := yamlDecode([]rune(text))
	if !ok || !JsonEqual(back, v) {
		t.Fatalf("read back %v %v", back, ok)
	}
}
