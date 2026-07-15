// Command esm-conformance is the Go conformance PRODUCER for the
// cross-language harness.
//
// Go had no producer at all (audit 2026-07-14, F9): `scripts/test-conformance.sh`
// ran `go test ./...` and `compare_outputs` hardcoded
// `--languages julia typescript python rust`, so the most conformant binding in
// the repo contributed nothing to the cross-language comparison.
//
// Like every other producer it reads the shared CORPUS MANIFEST
// (`scripts/conformance_corpus.py`) and emits one record per entry — it does not
// enumerate the corpus itself. See `scripts/run-python-conformance.py` for the
// wire shape; every producer emits the same one.
//
// Usage:
//
//	go run ./cmd/esm-conformance <output_dir> [<corpus_manifest.json>]
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

type validationEntry struct {
	ID       string `json:"id"`
	Category string `json:"category"`
	Path     string `json:"path"`
	Basename string `json:"basename"`
	Expect   string `json:"expect"`
}

type displayCase struct {
	ID    string `json:"id"`
	Kind  string `json:"kind"`
	Input any    `json:"input"`
}

type substitutionCase struct {
	ID       string         `json:"id"`
	Input    any            `json:"input"`
	Bindings map[string]any `json:"bindings"`
}

type manifest struct {
	ValidationFiles   []validationEntry  `json:"validation_files"`
	DisplayCases      []displayCase      `json:"display_cases"`
	SubstitutionCases []substitutionCase `json:"substitution_cases"`
}

type errRecord struct {
	Path    string         `json:"path"`
	Message string         `json:"message"`
	Code    string         `json:"code"`
	Keyword string         `json:"keyword"`
	Details map[string]any `json:"details"`
}

// repoRoot walks up from the executable's working directory until it finds the
// repository (identified by the tests/valid corpus), so the producer resolves
// the manifest's repo-relative paths no matter where it is invoked from.
func repoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if info, err := os.Stat(filepath.Join(dir, "tests", "valid")); err == nil && info.IsDir() {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("could not locate repo root (no tests/valid above %s)", dir)
		}
		dir = parent
	}
}

func schemaErrors(errs []esm.SchemaError) []errRecord {
	out := make([]errRecord, 0, len(errs))
	for _, e := range errs {
		out = append(out, errRecord{
			Path: e.Path, Message: e.Message, Keyword: e.Keyword, Code: e.Keyword,
			Details: map[string]any{},
		})
	}
	return out
}

func structuralErrors(errs []esm.StructuralError) []errRecord {
	out := make([]errRecord, 0, len(errs))
	for _, e := range errs {
		details := e.Details
		if details == nil {
			details = map[string]any{}
		}
		out = append(out, errRecord{
			Path: e.Path, Message: e.Message, Code: e.Code, Keyword: e.Code, Details: details,
		})
	}
	return out
}

// runValidation runs the full load → resolve → validate pipeline over every
// manifest entry. esm.Load resolves §4.7 subsystem refs against the file's own
// directory; Validate does no file I/O, so without that phase a {ref} stub reads
// as unresolved.
//
// When load/resolve REJECTS a document, validation is still attempted on the raw
// text, so a binding that fails early still gets to enumerate its structured
// (code, path) findings for the pin check instead of reporting an opaque string.
func runValidation(root string, m *manifest) map[string]any {
	results := make(map[string]any, len(m.ValidationFiles))

	for _, entry := range m.ValidationFiles {
		fullPath := filepath.Join(root, entry.Path)
		record := map[string]any{
			"schema_errors":     []errRecord{},
			"structural_errors": []errRecord{},
		}

		raw, readErr := os.ReadFile(fullPath)
		if readErr != nil {
			record["resolve_ok"] = false
			record["is_valid"] = false
			record["outcome"] = "invalid"
			record["phase"] = "load"
			record["error"] = readErr.Error()
			record["error_type"] = "ReadError"
			results[entry.ID] = record
			continue
		}

		file, loadErr := esm.Load(fullPath)
		if loadErr != nil {
			record["resolve_ok"] = false
			record["error"] = loadErr.Error()
			record["error_type"] = "LoadError"
			record["phase"] = "load"
			// A load-phase rejection that carries a STRUCTURED diagnostic — a
			// stable code plus the JSON Pointer of the offending node — is surfaced
			// as a structural finding. Some defects (an unresolved / ambiguous §4.7
			// subsystem ref) are caught by esm.Load before the typed structural scan
			// can run, so without this the producer would record is_valid:false but
			// no (code, path) tuple, and the pin check would see nothing. See
			// esm.ExpressionTemplateError.Path.
			var etErr *esm.ExpressionTemplateError
			if errors.As(loadErr, &etErr) && etErr.Path != "" {
				record["structural_errors"] = []errRecord{{
					Path:    etErr.Path,
					Message: etErr.Message,
					Code:    etErr.Code,
					Keyword: etErr.Code,
					Details: map[string]any{},
				}}
			}
		} else {
			record["resolve_ok"] = true
			record["phase"] = "validate"
		}

		// SCHEMA judges the document AS WRITTEN and STRUCTURAL judges the
		// RESOLVED form. ValidateFile does exactly that split — it schema-checks
		// `raw` and only then structurally checks `file` — and it returns early
		// when the schema fails, so the empty placeholder below is never
		// structurally walked. Running it even on a load-phase rejection is what
		// lets a schema-invalid fixture have its pinned (keyword, path) findings
		// checked at all.
		target := file
		if target == nil {
			target = &esm.ESMFile{}
		}
		result := esm.ValidateFile(target, string(raw))
		record["schema_errors"] = schemaErrors(result.SchemaErrors)
		if file != nil {
			record["structural_errors"] = structuralErrors(result.StructuralErrors)
		}

		// The verdict is "did this binding accept the document", regardless of
		// WHICH phase answered. A rejection at resolve is still a rejection.
		schemaClean := len(result.SchemaErrors) == 0
		structuralClean := file != nil && len(result.StructuralErrors) == 0
		valid := loadErr == nil && schemaClean && structuralClean
		record["is_valid"] = valid
		if valid {
			record["outcome"] = "valid"
		} else {
			record["outcome"] = "invalid"
		}
		results[entry.ID] = record
	}

	return results
}

// decodeExpression turns a manifest case's JSON-native input into this binding's
// native Expression (an ExprNode for op nodes). Handing the raw map[string]any
// straight to Substitute would silently no-op — its type switch only knows
// ExprNode — so the decode is what gives the binding a fair shot.
func decodeExpression(input any) (esm.Expression, error) {
	blob, err := json.Marshal(input)
	if err != nil {
		return nil, err
	}
	return esm.UnmarshalExpression(blob)
}

func runDisplay(m *manifest) map[string]any {
	results := make(map[string]any, len(m.DisplayCases))

	for _, c := range m.DisplayCases {
		// A "formula" case is a bare chemical-formula string ("O3" → "O₃"); an
		// "expression" case is a dict-form Expression.
		target := c.Input
		record := map[string]any{}
		if c.Kind != "formula" {
			decoded, err := decodeExpression(c.Input)
			if err != nil {
				record["unicode"], record["latex"], record["ascii"] = nil, nil, nil
				record["errors"] = map[string]any{"decode": err.Error()}
				results[c.ID] = record
				continue
			}
			target = decoded
		}
		record["unicode"] = esm.ToUnicode(target)
		record["latex"] = esm.ToLatex(target)
		record["ascii"] = esm.ToAscii(target)
		results[c.ID] = record
	}

	return results
}

func runSubstitution(m *manifest) map[string]any {
	results := make(map[string]any, len(m.SubstitutionCases))

	for _, c := range m.SubstitutionCases {
		expr, err := decodeExpression(c.Input)
		if err != nil {
			results[c.ID] = map[string]any{"result": nil, "error": err.Error()}
			continue
		}
		bindings := make(map[string]esm.Expression, len(c.Bindings))
		for k, v := range c.Bindings {
			decoded, err := decodeExpression(v)
			if err != nil {
				decoded = v
			}
			bindings[k] = decoded
		}
		out, err := esm.Substitute(expr, bindings)
		if err != nil {
			results[c.ID] = map[string]any{"result": nil, "error": err.Error()}
			continue
		}
		// Round-trip through JSON so the emitted AST is the dict form the corpus
		// and the other bindings speak, not Go's internal ExprNode shape.
		var normalized any
		if b, err := json.Marshal(out); err == nil {
			_ = json.Unmarshal(b, &normalized)
		}
		results[c.ID] = map[string]any{"result": normalized}
	}

	return results
}

// loadManifest resolves the manifest path handed over by the harness. There is
// no fallback sweep: a producer that invents its own corpus when the manifest is
// missing is a producer that can silently under-report coverage.
func loadManifest(outputDir string) (*manifest, error) {
	var manifestPath string
	switch {
	case len(os.Args) >= 3:
		manifestPath = os.Args[2]
	case os.Getenv("ESM_CONFORMANCE_MANIFEST") != "":
		manifestPath = os.Getenv("ESM_CONFORMANCE_MANIFEST")
	default:
		manifestPath = filepath.Join(filepath.Dir(outputDir), "corpus_manifest.json")
	}

	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return nil, fmt.Errorf("corpus manifest not found: %s\n"+
			"Generate it with: python3 scripts/conformance_corpus.py --output <path>", manifestPath)
	}
	var m manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("corpus manifest %s is not valid JSON: %w", manifestPath, err)
	}
	return &m, nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr,
			"Usage: esm-conformance <output_dir> [<corpus_manifest.json>]")
		os.Exit(1)
	}
	outputDir := os.Args[1]

	m, err := loadManifest(outputDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	root, err := repoRoot()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	fmt.Println("Running Go conformance producer...")
	fmt.Printf("Output directory: %s\n", outputDir)

	validation := runValidation(root, m)
	fmt.Printf("✓ Validation sweep completed (%d files)\n", len(validation))
	display := runDisplay(m)
	fmt.Printf("✓ Display sweep completed (%d cases)\n", len(display))
	substitution := runSubstitution(m)
	fmt.Printf("✓ Substitution sweep completed (%d cases)\n", len(substitution))

	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	out := map[string]any{
		"language":             "go",
		"validation_results":   validation,
		"display_results":      display,
		"substitution_results": substitution,
		"errors":               []string{},
	}
	blob, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	resultsFile := filepath.Join(outputDir, "results.json")
	if err := os.WriteFile(resultsFile, blob, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("Go conformance results written to: %s\n", resultsFile)
}
