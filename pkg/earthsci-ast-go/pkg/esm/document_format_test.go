package esm

// The document source formats (CONFORMANCE_SPEC §5.58): the golden set in
// tests/conformance/document_format/, and the whole-corpus round trip.
//
// The fixture contract is the README of that directory:
//
//   - print: PrintDocument(esm) == text byte for byte and ParseDocument(text)
//     == esm as a JSON value, in both formats (and CanonicalizeDocument(written)
//     == esm when the case is about the canonical form);
//   - variant: ParseDocument(input) == esm and PrintDocument(esm) == canonical;
//   - refusal: ParseDocument(input) fails with the diagnostic code `error`.
//
// Documents are compared as JSON values with numbers compared by type
// (typedJSONNumbers: an integer token is an int64, any other a float64).
//
// The corpus round trip is computed from the corpus itself, never stored:
// every .esm under tests/ that is a JSON object (the corpus of
// formal/scripts/doc-corpus.py), canonicalized, printed in each format and
// read back, must give its canonical form again.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
)

var documentFormatFixtureFiles = []string{
	"operators.json", "names.json", "variants.json", "documents.json", "units.json", "refusals.json",
}

var documentFormats = []DocumentFormat{DocumentMarkdown, DocumentTypst}

// decodeDocJSON decodes JSON text keeping every number token exactly
// (json.Number).
func decodeDocJSON(raw []byte) (any, error) {
	var v any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("trailing data")
	}
	return v, nil
}

func docfmtSurface(t *testing.T, name any) DocumentFormat {
	switch name {
	case "markdown":
		return DocumentMarkdown
	case "typst":
		return DocumentTypst
	}
	t.Fatalf("unknown surface %v", name)
	return 0
}

func docfmtJSONText(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// docfmtGuarded runs f, turning a panic into an error.
func docfmtGuarded[T any](f func() T) (out T, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	return f(), nil
}

func runDocumentFormatCase(t *testing.T, c map[string]any) {
	switch c["kind"] {
	case "print":
		esm := c["esm"]
		want := typedJSONNumbers(esm)
		if written, ok := c["written"]; ok {
			if got := CanonicalizeDocument(written); !reflect.DeepEqual(got, want) {
				t.Errorf("canonicalize(written) != esm:\n got %s", docfmtJSONText(got))
			}
		}
		for _, f := range documentFormats {
			text := c[f.String()].(string)
			printed, err := docfmtGuarded(func() string { return PrintDocument(esm, f) })
			if err != nil {
				t.Errorf("print %s: %v", f, err)
			} else if printed != text {
				t.Errorf("print %s differs:\n--- got\n%s\n--- want\n%s", f, printed, text)
			}
			back, err := ParseDocument(text, f)
			if err != nil {
				t.Errorf("parse %s refused: %v", f, err)
			} else if !reflect.DeepEqual(back, want) {
				t.Errorf("parse %s differs:\n--- got\n%s\n--- want\n%s", f, docfmtJSONText(back), docfmtJSONText(want))
			}
		}
	case "variant":
		f := docfmtSurface(t, c["surface"])
		esm := c["esm"]
		want := typedJSONNumbers(esm)
		back, err := ParseDocument(c["input"].(string), f)
		if err != nil {
			t.Errorf("parse refused: %v", err)
		} else if !reflect.DeepEqual(back, want) {
			t.Errorf("parse differs:\n--- got\n%s\n--- want\n%s", docfmtJSONText(back), docfmtJSONText(want))
		}
		if printed := PrintDocument(esm, f); printed != c["canonical"].(string) {
			t.Errorf("print differs:\n--- got\n%s\n--- want\n%s", printed, c["canonical"])
		}
	case "refusal":
		f := docfmtSurface(t, c["surface"])
		want := c["error"].(string)
		v, err := ParseDocument(c["input"].(string), f)
		var de *DocumentFormatError
		switch {
		case err == nil:
			t.Errorf("expected %q, read %s", want, docfmtJSONText(v))
		case !errors.As(err, &de):
			t.Errorf("expected a *DocumentFormatError, got %T", err)
		case de.DiagnosticCode() != want:
			t.Errorf("expected %q, got %q", want, de.DiagnosticCode())
		}
	default:
		t.Fatalf("unknown kind %v", c["kind"])
	}
}

// TestDocumentFormatFixtures runs every case of tests/conformance/document_format/.
func TestDocumentFormatFixtures(t *testing.T) {
	dir := filepath.Join(repoTestsDir(t), "conformance", "document_format")
	seen := map[string]bool{}
	for _, file := range documentFormatFixtureFiles {
		raw, err := os.ReadFile(filepath.Join(dir, file))
		if err != nil {
			t.Fatal(err)
		}
		doc, err := decodeDocJSON(raw)
		if err != nil {
			t.Fatalf("%s: %v", file, err)
		}
		cases, _ := doc.(map[string]any)["cases"].([]any)
		if len(cases) == 0 {
			t.Fatalf("%s has no cases", file)
		}
		t.Run(strings.TrimSuffix(file, ".json"), func(t *testing.T) {
			for _, raw := range cases {
				c := raw.(map[string]any)
				id := c["id"].(string)
				if seen[id] {
					t.Errorf("duplicate case id %s", id)
				}
				seen[id] = true
				t.Run(id, func(t *testing.T) {
					if _, err := docfmtGuarded(func() int { runDocumentFormatCase(t, c); return 0 }); err != nil {
						t.Error(err)
					}
				})
			}
		})
	}
}

// TestDocumentFormatPrintMath: the `math` field of a fixture case is the math
// of the case's one equation display, so PrintMath of that equation under the
// names its model declares (the keys of its variables, species and parameters,
// and the document's index sets) gives it in both formats. A case whose model
// or document declares expression templates is skipped: no template is in
// scope for PrintMath.
func TestDocumentFormatPrintMath(t *testing.T) {
	dir := filepath.Join(repoTestsDir(t), "conformance", "document_format")
	checked, skipped := 0, 0
	for _, file := range documentFormatFixtureFiles {
		raw, err := os.ReadFile(filepath.Join(dir, file))
		if err != nil {
			t.Fatal(err)
		}
		doc, err := decodeDocJSON(raw)
		if err != nil {
			t.Fatalf("%s: %v", file, err)
		}
		cases, _ := doc.(map[string]any)["cases"].([]any)
		for _, rawCase := range cases {
			c := rawCase.(map[string]any)
			want, ok := c["math"].(map[string]any)
			if !ok {
				continue
			}
			id := c["id"].(string)
			esm := c["esm"].(map[string]any)
			models, _ := esm["models"].(map[string]any)
			if len(models) != 1 {
				t.Errorf("%s: a math case has %d models, want 1", id, len(models))
				continue
			}
			var model map[string]any
			for _, m := range models {
				model = m.(map[string]any)
			}
			if _, ok := model["expression_templates"]; ok {
				skipped++
				continue
			}
			if _, ok := esm["expression_templates"]; ok {
				skipped++
				continue
			}
			eqs, _ := model["equations"].([]any)
			if len(eqs) != 1 {
				t.Errorf("%s: a math case has %d equations, want 1", id, len(eqs))
				continue
			}
			var names []string
			for _, field := range []string{"variables", "species", "parameters"} {
				if m, ok := model[field].(map[string]any); ok {
					for k := range m {
						names = append(names, k)
					}
				}
			}
			if m, ok := esm["index_sets"].(map[string]any); ok {
				for k := range m {
					names = append(names, k)
				}
			}
			for _, f := range documentFormats {
				key := map[DocumentFormat]string{DocumentMarkdown: "latex", DocumentTypst: "typst"}[f]
				got, err := docfmtGuarded(func() string { return PrintMath(eqs[0], names, f) })
				if err != nil {
					t.Errorf("%s: PrintMath %s: %v", id, f, err)
				} else if got != want[key] {
					t.Errorf("%s: PrintMath %s = %q, want %q", id, f, got, want[key])
				}
			}
			checked++
		}
	}
	if checked == 0 {
		t.Fatal("no math case checked")
	}
	t.Logf("PrintMath: %d math cases checked, %d skipped (a template in scope)", checked, skipped)
}

// documentFormatCorpus is the corpus of formal/scripts/doc-corpus.py: every
// .esm file under tests/ that decodes as a JSON object, in path order, with
// its decoded value (numbers kept exactly).
func documentFormatCorpus(t *testing.T) (paths []string, docs []any) {
	root := repoTestsDir(t)
	var files []string
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && strings.HasSuffix(p, ".esm") {
			files = append(files, p)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(files)
	for _, p := range files {
		raw, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		v, err := decodeDocJSON(raw)
		if err != nil {
			continue
		}
		if _, ok := v.(map[string]any); ok {
			paths = append(paths, p)
			docs = append(docs, v)
		}
	}
	if len(paths) < 100 {
		t.Fatalf("only %d corpus documents found", len(paths))
	}
	return paths, docs
}

// docfmtParallelEach runs f(i) for i in [0, n) on GOMAXPROCS workers.
func docfmtParallelEach(n int, f func(i int)) {
	var wg sync.WaitGroup
	next := make(chan int)
	for w := 0; w < runtime.GOMAXPROCS(0); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range next {
				f(i)
			}
		}()
	}
	for i := 0; i < n; i++ {
		next <- i
	}
	close(next)
	wg.Wait()
}

// TestDocumentFormatCorpusRoundTrip: every corpus document, canonicalized,
// printed in each format and read back, is its canonical form again.
func TestDocumentFormatCorpusRoundTrip(t *testing.T) {
	paths, docs := documentFormatCorpus(t)
	failures := make([][]string, len(paths))
	docfmtParallelEach(len(paths), func(i int) {
		canon := CanonicalizeDocument(docs[i])
		for _, f := range documentFormats {
			back, err := docfmtGuarded(func() any {
				v, err := ParseDocument(PrintDocument(canon, f), f)
				if err != nil {
					return err
				}
				return v
			})
			var what string
			switch {
			case err != nil:
				what = err.Error()
			case docfmtIsError(back):
				what = "does not read back: " + back.(error).Error()
			case !reflect.DeepEqual(back, canon):
				what = "reads back differently"
			default:
				continue
			}
			failures[i] = append(failures[i], fmt.Sprintf("%s (%s): %s", paths[i], f, what))
		}
	})
	t.Logf("%d corpus documents, %d round trips", len(paths), 2*len(paths))
	var all []string
	for _, fs := range failures {
		all = append(all, fs...)
	}
	if len(all) > 0 {
		t.Errorf("%d of %d round trips failed:\n%s", len(all), 2*len(paths), strings.Join(all, "\n"))
	}
}

func docfmtIsError(v any) bool { _, ok := v.(error); return ok }

// docfmtEsmLean runs `esm-lean <mode> <path>`: its stdout, or ok false when it
// refuses.
func docfmtEsmLean(binary, mode, path string) (string, bool) {
	out, err := exec.Command(binary, mode, path).Output()
	return string(out), err == nil
}

// TestDocumentFormatMatchesLean is the cross-check against the Lean model, run
// where `esm-lean` is built (ESM_LEAN=path/to/esm-lean; ESM_LEAN_SCRATCH names
// a directory for the intermediate files): over the whole corpus, the canonical
// form matches `esm-lean canon`, the printers write exactly what `esm-lean
// print-md` / `print-typ` write for it, and the readers read the Lean-printed
// texts exactly as `esm-lean parse-md` / `parse-typ` do. A self round trip
// alone cannot see a printer and a reader that drift together.
func TestDocumentFormatMatchesLean(t *testing.T) {
	binary := os.Getenv("ESM_LEAN")
	if binary == "" {
		t.Skip("set ESM_LEAN to the esm-lean executable to compare with the Lean model")
	}
	scratch := os.Getenv("ESM_LEAN_SCRATCH")
	if scratch == "" {
		scratch = t.TempDir()
	} else if err := os.MkdirAll(scratch, 0o755); err != nil {
		t.Fatal(err)
	}
	paths, docs := documentFormatCorpus(t)
	root := repoTestsDir(t)
	failures := make([][]string, len(paths))
	docfmtParallelEach(len(paths), func(i int) {
		fail := func(format string, args ...any) {
			failures[i] = append(failures[i], fmt.Sprintf(format, args...))
		}
		rel, _ := filepath.Rel(root, paths[i])
		stem := filepath.Join(scratch, strings.ReplaceAll(strings.TrimSuffix(rel, ".esm"), string(filepath.Separator), "__"))
		leanCanon, ok := docfmtEsmLean(binary, "canon", paths[i])
		if !ok {
			fail("%s: esm-lean canon refused", rel)
			return
		}
		canonPath := stem + ".canon.json"
		if err := os.WriteFile(canonPath, []byte(leanCanon), 0o644); err != nil {
			fail("%s: %v", rel, err)
			return
		}
		goCanon := CanonicalizeDocument(docs[i])
		leanCanonV, err := decodeDocJSON([]byte(leanCanon))
		if err != nil || !reflect.DeepEqual(typedJSONNumbers(leanCanonV), goCanon) {
			fail("%s: canonical forms differ", rel)
			return
		}
		for _, m := range []struct {
			f                    DocumentFormat
			printMode, parseMode string
			ext                  string
		}{
			{DocumentMarkdown, "print-md", "parse-md", ".md"},
			{DocumentTypst, "print-typ", "parse-typ", ".typ"},
		} {
			leanText, ok := docfmtEsmLean(binary, m.printMode, canonPath)
			if !ok {
				fail("%s: esm-lean %s refused", rel, m.printMode)
				continue
			}
			goText, err := docfmtGuarded(func() string { return PrintDocument(goCanon, m.f) })
			if err == nil {
				_ = os.WriteFile(stem+".go"+m.ext, []byte(goText), 0o644)
			}
			if err != nil || goText != leanText {
				fail("%s: %s differs", rel, m.printMode)
			}
			textPath := stem + m.ext
			if err := os.WriteFile(textPath, []byte(leanText), 0o644); err != nil {
				fail("%s: %v", rel, err)
				continue
			}
			var leanBack any
			if out, ok := docfmtEsmLean(binary, m.parseMode, textPath); ok {
				v, err := decodeDocJSON([]byte(out))
				if err != nil {
					fail("%s: esm-lean %s output: %v", rel, m.parseMode, err)
					continue
				}
				leanBack = typedJSONNumbers(v)
			}
			goBack, perr := docfmtGuarded(func() any {
				v, err := ParseDocument(leanText, m.f)
				if err != nil {
					return nil
				}
				return v
			})
			if perr != nil || !reflect.DeepEqual(leanBack, goBack) {
				fail("%s: %s differs", rel, m.parseMode)
			}
		}
	})
	var all []string
	for _, fs := range failures {
		all = append(all, fs...)
	}
	t.Logf("%d differences over %d documents", len(all), len(paths))
	if len(all) > 0 {
		t.Errorf("%d differences over %d documents:\n%s", len(all), len(paths), strings.Join(all, "\n"))
	}
}
