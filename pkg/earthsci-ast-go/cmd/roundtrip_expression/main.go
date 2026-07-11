// Go expression round-trip driver for property-corpus conformance (gt-3fbf).
//
// Reads expression JSON fixtures, deserializes each via the esm package's
// ExprNode (for operator-node inputs) or directly as a literal number/string,
// re-serializes through SerializeExpressionCompact, and emits a JSON object
// {fixture_name: {"ok": bool, "value"|"error": ...}} to stdout.
//
// Usage: go run ./cmd/roundtrip_expression <fixture.json> ...
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

type result struct {
	OK    bool            `json:"ok"`
	Value json.RawMessage `json:"value,omitempty"`
	Error string          `json:"error,omitempty"`
}

func roundtripOne(path string) result {
	raw, err := os.ReadFile(path)
	if err != nil {
		return result{OK: false, Error: fmt.Sprintf("read error: %v", err)}
	}

	// The root of a fixture may be a JSON number, string, or operator object.
	// Use json.Unmarshal with interface{} to discover the shape, then
	// re-cast operator nodes through esm.ExprNode to exercise the binding's
	// typed path.
	var rawAny interface{}
	if err := json.Unmarshal(raw, &rawAny); err != nil {
		return result{OK: false, Error: fmt.Sprintf("decode error: %v", err)}
	}

	var expr esm.Expression
	switch rawAny.(type) {
	case map[string]interface{}:
		var node esm.ExprNode
		if err := json.Unmarshal(raw, &node); err != nil {
			return result{OK: false, Error: fmt.Sprintf("node decode error: %v", err)}
		}
		expr = node
	default:
		// Number / string literals pass through unchanged.
		expr = rawAny
	}

	out, err := esm.SerializeExpressionCompact(expr)
	if err != nil {
		return result{OK: false, Error: fmt.Sprintf("serialize error: %v", err)}
	}
	return result{OK: true, Value: json.RawMessage(out)}
}

func main() {
	results := make(map[string]result)
	for _, arg := range os.Args[1:] {
		results[filepath.Base(arg)] = roundtripOne(arg)
	}

	// encoding/json marshals map keys in sorted order, producing byte-identical
	// (deterministic) output to the previous manual encoding — and it surfaces
	// the marshal error the hand-rolled version discarded.
	out, err := json.Marshal(results)
	if err != nil {
		fmt.Fprintf(os.Stderr, "encode error: %v\n", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}
