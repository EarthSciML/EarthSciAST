package esm

// Conformance: record axes and the deprecated `records_per_sample`
// (esm-spec §8.5.1).
//
// Consumes tests/conformance/records_per_sample/manifest.json. A valid case
// must validate with none of `record_codes`, flatten with each listed
// LoaderField reporting the number of records its record shape gives it, keep
// the deprecated field on the flattened parameter's `update.from` exactly as
// written, survive emit then load with both the deprecated fields and every
// index set's `records` flag intact, and list exactly `deprecated_fields` from
// DeprecatedRecordsPerSampleSites — with the load warning emitted once when
// that list is non-empty and not at all otherwise. An `invalid` case must be
// refused by structural validation with exactly one diagnostic from
// `record_codes`, `code` at `pointer`. A `flatten_invalid` case must pass
// validation with none and then be refused by Flatten with that code at that
// pointer. A `refused` case may be refused by either stage.

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
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
	Flattened       map[string]*int `json:"flattened_from_records_per_sample"`
	DeprecatedSites []string        `json:"deprecated_fields"`
}

type recordFindingAt struct{ code, path string }

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

func sameFlag(a, b *bool) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

// loadCapturingStderr loads path and returns what the load wrote to stderr.
func loadCapturingStderr(t *testing.T, path string) (*ESMFile, string) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stderr
	os.Stderr = w
	done := make(chan string)
	go func() {
		b, _ := io.ReadAll(r)
		done <- string(b)
	}()
	file, loadErr := LoadPath(path)
	os.Stderr = saved
	w.Close()
	out := <-done
	r.Close()
	if loadErr != nil {
		t.Fatalf("load: %v", loadErr)
	}
	return file, out
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
	if !errors.As(err, &coded) || coded.DiagnosticCode() != c.Code || coded.DiagnosticPath() != c.Pointer ||
		!strings.Contains(err.Error(), c.Pointer) {
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
		RecordCodes        []string               `json:"record_codes"`
		DeprecationWarning string                 `json:"deprecation_warning"`
		Cases              []recordsPerSampleCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest.RecordCodes) == 0 || len(manifest.Cases) == 0 || manifest.DeprecationWarning == "" {
		t.Fatal("manifest lists no record_codes, no deprecation_warning or no cases")
	}
	recordCodes := map[string]bool{}
	for _, code := range manifest.RecordCodes {
		recordCodes[code] = true
	}
	for _, c := range manifest.Cases {
		t.Run(c.ID, func(t *testing.T) {
			file, stderr := loadCapturingStderr(t, filepath.Join(tier, c.Path))
			result := Validate(file)
			var found []recordFindingAt
			for _, e := range result.StructuralErrors {
				if recordCodes[e.Code] {
					found = append(found, recordFindingAt{e.Code, e.Path})
				}
			}
			one := len(found) == 1 && found[0] == recordFindingAt{c.Code, c.Pointer}
			switch c.Expect {
			case "invalid":
				if !one {
					t.Fatalf("want one %s at %s, got %v", c.Code, c.Pointer, found)
				}
				return
			case "refused":
				if len(found) > 0 {
					if !one {
						t.Fatalf("want one %s at %s, got %v", c.Code, c.Pointer, found)
					}
					return
				}
				requireFlattenRefusal(t, file, c)
				return
			case "flatten_invalid":
				if len(found) != 0 {
					t.Fatalf("validation reported %v; the record shape is decidable only at flatten", found)
				}
				requireFlattenRefusal(t, file, c)
				return
			case "valid":
			default:
				t.Fatalf("unknown expect %q", c.Expect)
			}
			if len(found) != 0 || len(result.SchemaErrors) != 0 {
				t.Fatalf("valid case refused: %v %v", found, result.SchemaErrors)
			}

			// The deprecated sites, and the one load warning naming them.
			sites := DeprecatedRecordsPerSampleSites(file)
			want := c.DeprecatedSites
			if want == nil {
				want = []string{}
			}
			if sites == nil {
				sites = []string{}
			}
			if !reflect.DeepEqual(sites, want) {
				t.Errorf("deprecated sites: got %v, want %v", sites, want)
			}
			warnings := strings.Count(stderr, manifest.DeprecationWarning)
			if len(want) == 0 && warnings != 0 {
				t.Errorf("load warned %d times with no deprecated field: %q", warnings, stderr)
			}
			if len(want) > 0 {
				if warnings != 1 {
					t.Errorf("load warned %d times, want once: %q", warnings, stderr)
				}
				if !strings.Contains(stderr, "Written at: "+strings.Join(want, ", ")+".") {
					t.Errorf("warning does not name %v: %q", want, stderr)
				}
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
					t.Errorf("%s: got {%s %s %s %d}, want %+v", want.Name,
						lf.Source, lf.FileVariable, lf.Cadence, lf.RecordsPerSample, want)
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
			for _, fis := range flat.IndexSets {
				if !sameFlag(fis.Set.Records, file.IndexSets[fis.Name].Records) {
					t.Errorf("flatten changed index set %s's records flag", fis.Name)
				}
			}

			// Emit then load keeps the deprecated fields and the records flags.
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
			if !reflect.DeepEqual(DeprecatedRecordsPerSampleSites(again), DeprecatedRecordsPerSampleSites(file)) {
				t.Errorf("round trip changed the deprecated sites: %v -> %v",
					DeprecatedRecordsPerSampleSites(file), DeprecatedRecordsPerSampleSites(again))
			}
			var flagged int
			for name, set := range file.IndexSets {
				if set.Records != nil && *set.Records {
					flagged++
				}
				if !sameFlag(set.Records, again.IndexSets[name].Records) {
					t.Errorf("index set %s: round trip changed the records flag", name)
				}
			}
			if wantsPair := func() bool {
				for _, lf := range c.LoaderFields {
					if lf.RecordsPerSample == 2 {
						return true
					}
				}
				return false
			}(); wantsPair && flagged == 0 {
				t.Errorf("a two-record case loaded with no record axis")
			}
		})
	}
}
