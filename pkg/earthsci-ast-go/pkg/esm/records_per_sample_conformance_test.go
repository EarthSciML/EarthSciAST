package esm

// Conformance: `from.records_per_sample` (esm-spec §8.5.1).
//
// Consumes tests/conformance/records_per_sample/manifest.json. A valid case
// must validate, round-trip the field, and flatten with each data-fed
// parameter's LoaderField reporting the EFFECTIVE value (the binding's own,
// else the source's `temporal.records_per_sample`, else 1) and the flattened
// parameter's `update.from` carrying the field as written. An `invalid` case
// must be refused by structural validation with exactly one
// `records_per_sample_invalid` at the pinned pointer. A `flatten_invalid` case
// must pass validation with none and then be refused by Flatten with that code
// at that pointer. A `refused` case may be refused by either stage.

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type recordsPerSampleCase struct {
	ID           string `json:"id"`
	Path         string `json:"path"`
	Expect       string `json:"expect"`
	Code         string `json:"code"`
	Pointer      string `json:"pointer"`
	LoaderFields []struct {
		Name             string `json:"name"`
		Source           string `json:"source"`
		FileVariable     string `json:"file_variable"`
		Cadence          string `json:"cadence"`
		RecordsPerSample int    `json:"records_per_sample"`
	} `json:"loader_fields"`
	Flattened map[string]*int `json:"flattened_from_records_per_sample"`
}

func recordsOf(rules []ParameterUpdate) *int {
	for _, r := range rules {
		if r.From != nil {
			return r.From.RecordsPerSample
		}
	}
	return nil
}

func sameRecords(a, b *int) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

// requireFlattenRefusal asserts Flatten refuses file with c.Code, attributed
// to c.Pointer.
func requireFlattenRefusal(t *testing.T, file *ESMFile, c recordsPerSampleCase) {
	t.Helper()
	_, err := Flatten(file)
	if err == nil {
		t.Fatalf("flatten accepted the document; want %s at %s", c.Code, c.Pointer)
	}
	var coded *ExpressionTemplateError
	if !errors.As(err, &coded) || coded.DiagnosticCode() != c.Code || coded.DiagnosticPath() != c.Pointer {
		t.Fatalf("flatten: want %s at %s, got %v", c.Code, c.Pointer, err)
	}
}

func TestRecordsPerSampleConformance(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	tier := filepath.Join(repoRoot, "tests", "conformance", "records_per_sample")
	raw, err := os.ReadFile(filepath.Join(tier, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Cases []recordsPerSampleCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	for _, c := range manifest.Cases {
		t.Run(c.ID, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(tier, c.Path))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			result := Validate(file)
			var found []string
			for _, e := range result.StructuralErrors {
				if e.Code == ErrorRecordsPerSampleInvalid {
					found = append(found, e.Path)
				}
			}
			switch c.Expect {
			case "invalid":
				if len(found) != 1 || found[0] != c.Pointer {
					t.Fatalf("want one %s at %s, got %v", c.Code, c.Pointer, found)
				}
				return
			case "refused":
				if len(found) > 0 {
					if len(found) != 1 || found[0] != c.Pointer {
						t.Fatalf("want one %s at %s, got %v", c.Code, c.Pointer, found)
					}
					return
				}
				requireFlattenRefusal(t, file, c)
				return
			case "flatten_invalid":
				if len(found) != 0 {
					t.Fatalf("validation reported %s at %v; the record shape is decidable only at flatten", c.Code, found)
				}
				requireFlattenRefusal(t, file, c)
				return
			}
			if len(found) != 0 || len(result.SchemaErrors) != 0 {
				t.Fatalf("valid case refused: %v %v", found, result.SchemaErrors)
			}
			flat, err := Flatten(file)
			if err != nil {
				t.Fatalf("flatten: %v", err)
			}
			got := map[string]LoaderField{}
			for _, lf := range flat.LoaderFields {
				got[lf.Name] = lf
			}
			for _, want := range c.LoaderFields {
				lf, ok := got[want.Name]
				if !ok {
					t.Fatalf("no loader field %s", want.Name)
				}
				if lf.Source != want.Source || lf.FileVariable != want.FileVariable ||
					lf.Cadence != want.Cadence || lf.RecordsPerSample != want.RecordsPerSample {
					t.Errorf("%s: got %+v, want %+v", want.Name, lf, want)
				}
			}
			for name, written := range c.Flattened {
				var hit bool
				for _, p := range flat.Parameters {
					if p.Name == name {
						hit = true
						if !sameRecords(recordsOf(p.UpdateRules()), written) {
							t.Errorf("flattened %s: records_per_sample %v, want %v", name, recordsOf(p.UpdateRules()), written)
						}
					}
				}
				if !hit {
					t.Errorf("flattened parameter %s missing", name)
				}
			}
			text, err := ToJSON(file)
			if err != nil {
				t.Fatal(err)
			}
			again, err := LoadString(text)
			if err != nil {
				t.Fatal(err)
			}
			for mname, model := range file.Models {
				for vname, v := range model.Variables {
					w := again.Models[mname].Variables[vname]
					if !sameRecords(recordsOf(v.UpdateRules()), recordsOf(w.UpdateRules())) {
						t.Errorf("%s.%s: round trip changed records_per_sample", mname, vname)
					}
				}
			}
		})
	}
}
