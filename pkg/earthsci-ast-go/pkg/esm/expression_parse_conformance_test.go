package esm

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

// TestExpressionParseConformance consumes tests/conformance/expression_parse/
// cases.json — the cross-language contract for the INFIX TEXT parser, generated
// from the TypeScript oracle — and asserts, for every binding:
//
//	parse(text)              == ast
//	to_ascii(parse(text))    == reprint
//	parse(reprint)           == ast
//
// plus that every entry in expression_errors / equation_errors is REFUSED with
// this binding's expression-parse error type (*ExpressionParseError). The
// corpus `reason` strings are prose and are deliberately not asserted.
//
// ASTs are compared by serializing the parsed Expression through the package's
// canonical emitter and deep-comparing the decoded JSON against the corpus
// value — the language-neutral check. Numeric leaves keep their int/float
// distinction across the comparison (see normalizeParsedJSON).
func TestExpressionParseConformance(t *testing.T) {
	corpus := loadExpressionParseCorpus(t)

	if len(corpus.Expressions) == 0 || len(corpus.ExpressionErrors) == 0 ||
		len(corpus.Equations) == 0 || len(corpus.EquationErrors) == 0 {
		t.Fatalf("corpus looks truncated: %d expressions, %d expression_errors, %d equations, %d equation_errors",
			len(corpus.Expressions), len(corpus.ExpressionErrors),
			len(corpus.Equations), len(corpus.EquationErrors))
	}

	t.Run("expressions", func(t *testing.T) {
		for i, c := range corpus.Expressions {
			c := c
			t.Run(subtestName(i, c.Tier, c.Text), func(t *testing.T) {
				parsed, err := ParseExpression(c.Text)
				if err != nil {
					t.Fatalf("ParseExpression(%q): unexpected error: %v", c.Text, err)
				}
				assertSerializesTo(t, "parse(text)", parsed, c.AST)

				if got := ToAscii(parsed); got != c.Reprint {
					t.Errorf("ToAscii(ParseExpression(%q)) = %q, want %q", c.Text, got, c.Reprint)
				}

				reparsed, err := ParseExpression(c.Reprint)
				if err != nil {
					t.Fatalf("ParseExpression(reprint %q): unexpected error: %v", c.Reprint, err)
				}
				assertSerializesTo(t, "parse(reprint)", reparsed, c.AST)
			})
		}
	})

	t.Run("expression_errors", func(t *testing.T) {
		for i, c := range corpus.ExpressionErrors {
			c := c
			t.Run(subtestName(i, c.Tier, c.Text), func(t *testing.T) {
				got, err := ParseExpression(c.Text)
				if err == nil {
					t.Fatalf("ParseExpression(%q) = %#v, want refusal (%s)", c.Text, got, c.Reason)
				}
				var pe *ExpressionParseError
				if !errors.As(err, &pe) {
					t.Fatalf("ParseExpression(%q) error %v (%T) is not an *ExpressionParseError", c.Text, err, err)
				}
				if pe.Pos < 0 {
					t.Errorf("ParseExpression(%q): negative Pos %d", c.Text, pe.Pos)
				}
				if runes := len([]rune(c.Text)); pe.Pos > runes {
					t.Errorf("ParseExpression(%q): Pos %d past end of input (%d runes)", c.Text, pe.Pos, runes)
				}
			})
		}
	})

	t.Run("equations", func(t *testing.T) {
		for i, c := range corpus.Equations {
			c := c
			t.Run(subtestName(i, "equation", c.Text), func(t *testing.T) {
				eq, err := ParseEquation(c.Text)
				if err != nil {
					t.Fatalf("ParseEquation(%q): unexpected error: %v", c.Text, err)
				}
				if eq == nil {
					t.Fatalf("ParseEquation(%q) returned a nil equation", c.Text)
				}
				assertSerializesTo(t, "lhs", eq.LHS, c.LHS)
				assertSerializesTo(t, "rhs", eq.RHS, c.RHS)
			})
		}
	})

	t.Run("equation_errors", func(t *testing.T) {
		for i, c := range corpus.EquationErrors {
			c := c
			t.Run(subtestName(i, "equation", c.Text), func(t *testing.T) {
				got, err := ParseEquation(c.Text)
				if err == nil {
					t.Fatalf("ParseEquation(%q) = %#v, want refusal (%s)", c.Text, got, c.Reason)
				}
				var pe *ExpressionParseError
				if !errors.As(err, &pe) {
					t.Fatalf("ParseEquation(%q) error %v (%T) is not an *ExpressionParseError", c.Text, err, err)
				}
			})
		}
	})
}

// TestExpressionParseErrorRunePositions pins the contract that
// ExpressionParseError.Pos counts RUNES, not bytes — the corpus carries names
// such as `∂u_∂z` and `∇phi`, so a byte offset would be silently wrong for
// every diagnostic after one of them.
func TestExpressionParseErrorRunePositions(t *testing.T) {
	for _, tc := range []struct {
		src string
		pos int
	}{
		{"∇phi @", 5},    // '@' is the 6th rune but the 8th byte
		{"∂u_∂z + $", 8}, // '$' is the 9th rune but the 13th byte
		{"a $", 2},
		{"", 0},
	} {
		_, err := ParseExpression(tc.src)
		var pe *ExpressionParseError
		if !errors.As(err, &pe) {
			t.Fatalf("ParseExpression(%q): want *ExpressionParseError, got %v", tc.src, err)
		}
		if pe.Pos != tc.pos {
			t.Errorf("ParseExpression(%q): Pos = %d, want %d (rune offset)", tc.src, pe.Pos, tc.pos)
		}
	}
}

// --- corpus plumbing --------------------------------------------------------

type expressionParseCorpus struct {
	Expressions []struct {
		Text    string          `json:"text"`
		Tier    string          `json:"tier"`
		AST     json.RawMessage `json:"ast"`
		Reprint string          `json:"reprint"`
	} `json:"expressions"`
	ExpressionErrors []struct {
		Text   string `json:"text"`
		Tier   string `json:"tier"`
		Reason string `json:"reason"`
	} `json:"expression_errors"`
	Equations []struct {
		Text string          `json:"text"`
		LHS  json.RawMessage `json:"lhs"`
		RHS  json.RawMessage `json:"rhs"`
	} `json:"equations"`
	EquationErrors []struct {
		Text   string `json:"text"`
		Reason string `json:"reason"`
	} `json:"equation_errors"`
}

func loadExpressionParseCorpus(t *testing.T) expressionParseCorpus {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	// pkg/esm/expression_parse_conformance_test.go -> repo root is 4 levels up.
	repoRoot := filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..")
	path := filepath.Join(repoRoot, "tests", "conformance", "expression_parse", "cases.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read corpus: %v", err)
	}
	var corpus expressionParseCorpus
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatalf("parse corpus: %v", err)
	}
	return corpus
}

// assertSerializesTo serializes expr through the package's canonical emitter
// and deep-compares the result against the corpus AST.
func assertSerializesTo(t *testing.T, what string, expr Expression, want json.RawMessage) {
	t.Helper()
	gotJSON, err := SerializeExpressionCompact(expr)
	if err != nil {
		t.Fatalf("%s: SerializeExpressionCompact: %v", what, err)
	}
	gotVal := decodeParsedJSON(t, []byte(gotJSON))
	wantVal := decodeParsedJSON(t, want)
	if !reflect.DeepEqual(gotVal, wantVal) {
		t.Errorf("%s: AST mismatch\n got: %s\nwant: %s", what, gotJSON, compactJSON(t, want))
	}
}

// decodeParsedJSON decodes JSON with number literals preserved, then normalizes
// them so the comparison keeps the int-vs-float distinction the wire format
// encodes (`1` and `1.0` are different values) while tolerating equivalent
// spellings of the same float (`8.64e4` vs `86400.0`).
func decodeParsedJSON(t *testing.T, raw []byte) any {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		t.Fatalf("decode %s: %v", raw, err)
	}
	return normalizeParsedJSON(v)
}

func normalizeParsedJSON(v any) any {
	switch x := v.(type) {
	case json.Number:
		s := x.String()
		// A literal with no fraction/exponent is a JSON INTEGER; keep it typed
		// apart from a float so `1` never compares equal to `1.0`.
		if !strings.ContainsAny(s, ".eE") {
			if i, err := x.Int64(); err == nil {
				return i
			}
		}
		f, err := x.Float64()
		if err != nil {
			return s
		}
		return f
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, vv := range x {
			out[k] = normalizeParsedJSON(vv)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, vv := range x {
			out[i] = normalizeParsedJSON(vv)
		}
		return out
	}
	return v
}

func compactJSON(t *testing.T, raw []byte) string {
	t.Helper()
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return string(raw)
	}
	return buf.String()
}

// subtestName builds a stable, readable subtest name from a corpus entry.
func subtestName(i int, tier, text string) string {
	label := text
	if label == "" {
		label = "<empty>"
	}
	if len(label) > 48 {
		label = label[:48]
	}
	label = strings.Map(func(r rune) rune {
		if r == ' ' || r == '\t' || r == '\n' {
			return '_'
		}
		return r
	}, label)
	return fmt.Sprintf("%03d_%s_%s", i, tier, label)
}

// TestAggregateEmptyContainersSerialize guards the presence-vs-absence
// distinction the `esm:"keepempty"` tag on ExprNode.OutputIdx / ExprNode.Ranges
// buys: a full reduction carries `"output_idx": []` (which esm-schema.json
// REQUIRES on every aggregate) and a where-less aggregate carries
// `"ranges": {}`, matching the other language bindings. Plain `omitempty` would
// elide both and silently emit a schema-invalid node.
func TestAggregateEmptyContainersSerialize(t *testing.T) {
	for _, tc := range []struct {
		src  string
		want []string
	}{
		{"sum[] (u[i]) where {i in cells}", []string{`"output_idx":[]`}},
		{"prod[i, j] (A)", []string{`"ranges":{}`}},
		{"sum[] (A)", []string{`"output_idx":[]`, `"ranges":{}`}},
	} {
		expr, err := ParseExpression(tc.src)
		if err != nil {
			t.Fatalf("ParseExpression(%q): %v", tc.src, err)
		}
		got, err := SerializeExpressionCompact(expr)
		if err != nil {
			t.Fatalf("SerializeExpressionCompact(%q): %v", tc.src, err)
		}
		for _, want := range tc.want {
			if !strings.Contains(got, want) {
				t.Errorf("ParseExpression(%q) serialized to %s, want it to contain %s", tc.src, got, want)
			}
		}
	}

	// A node that never carried the keys keeps its compact form: nil stays
	// omitted, so non-aggregate nodes are untouched by the tag.
	expr, err := ParseExpression("a + b")
	if err != nil {
		t.Fatal(err)
	}
	got, err := SerializeExpressionCompact(expr)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(got, "ranges") || strings.Contains(got, "output_idx") {
		t.Errorf("plain operator node serialized to %s, want no ranges/output_idx keys", got)
	}
}
