package esm

// Regression tests for the cross-binding record-axis rules (esm-spec §8.5.1,
// §4.7): `"records": false` is an absent `records` and `true` is not, at every
// index-set merge; a reaction-system data-fed parameter gets the model
// parameter's record-count check; and a record shape whose first axis an
// unmounted `{ref}` could still declare is not decidable at validation.

import (
	"encoding/json"
	"strings"
	"testing"
)

func boolPtr(b bool) *bool { return &b }

func TestIndexSetDeepEqualTreatsRecordsFalseAsAbsent(t *testing.T) {
	size := 2
	plain := IndexSet{Kind: "interval", Size: &size}
	falseFlag := IndexSet{Kind: "interval", Size: &size, Records: boolPtr(false)}
	trueFlag := IndexSet{Kind: "interval", Size: &size, Records: boolPtr(true)}
	if !indexSetDeepEqual(plain, falseFlag) || !indexSetDeepEqual(falseFlag, plain) {
		t.Error(`"records": false must merge with an absent records`)
	}
	if indexSetDeepEqual(plain, trueFlag) || indexSetDeepEqual(falseFlag, trueFlag) {
		t.Error(`"records": true must conflict with an absent or false records`)
	}
	if falseFlag.Records == nil {
		t.Error("the comparison must not rewrite its arguments")
	}
}

func TestTemplateImportIndexSetMergeTreatsRecordsFalseAsAbsent(t *testing.T) {
	decode := func(s string) any {
		var v any
		if err := json.Unmarshal([]byte(s), &v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	plain := `{"kind": "interval", "size": 2}`
	for _, tc := range []struct {
		other string
		same  bool
	}{
		{`{"kind": "interval", "size": 2, "records": false}`, true},
		{`{"kind": "interval", "size": 2, "records": true}`, false},
	} {
		dst := newOrderedMap()
		dst.set("rec", decode(plain))
		err := mergeNamed(dst, "rec", decode(tc.other), CodeTemplateImportIndexSetConflict, "index set", "test")
		if (err == nil) != tc.same {
			t.Errorf("%s against %s: merge error %v, want same=%v", tc.other, plain, err, tc.same)
		}
	}
}

// reactionSystemDoc is a reaction system whose parameter T reads a source that
// writes the deprecated temporal.records_per_sample 2, shaped shape.
func reactionSystemDoc(shape string) string {
	return `{
  "esm": "1.3.0",
  "metadata": {"name": "RS"},
  "index_sets": {
    "cells": {"kind": "interval", "size": 4},
    "rec": {"kind": "interval", "size": 2, "records": true}
  },
  "data_sources": {"Reanalysis": {"kind": "grid",
    "source": {"url_template": "file:///data/r_{date:%Y%m%d}.nc"},
    "temporal": {"start": "2016-01-01T00:00:00Z", "end": "2016-01-02T00:00:00Z",
      "file_period": "P1D", "frequency": "PT1H", "records_per_file": 24,
      "records_per_sample": 2}}},
  "reaction_systems": {"Chem": {
    "species": {"A": {"units": "mol/L", "default": 1.0}, "B": {"units": "mol/L", "default": 0.0}},
    "parameters": {"k": {"units": "1/s", "default": 0.1},
      "T": {"units": "K", "default": 298.0, "shape": ` + shape + `,
        "update": {"kind": "data", "source": "Reanalysis", "from": {"file_variable": "t2m"}}}},
    "reactions": [{"id": "R1", "substrates": [{"species": "A", "stoichiometry": 1}],
      "products": [{"species": "B", "stoichiometry": 1}], "rate": "k"}]}}
}`
}

func recordCodesAt(result *ValidationResult) []string {
	var out []string
	for _, e := range result.StructuralErrors {
		if strings.HasPrefix(e.Code, "record") {
			out = append(out, e.Code+"@"+e.Path)
		}
	}
	return out
}

func TestReactionSystemDataFedParameterIsRecordChecked(t *testing.T) {
	file, err := LoadString(reactionSystemDoc(`["cells"]`))
	if err != nil {
		t.Fatal(err)
	}
	got := recordCodesAt(Validate(file))
	want := []string{"records_per_sample_invalid@/reaction_systems/Chem/parameters/T/update"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("findings %v, want %v", got, want)
	}
	if _, err := Flatten(file); err == nil || !strings.Contains(err.Error(), "records_per_sample_invalid") {
		t.Errorf("flatten must refuse it too, got %v", err)
	}

	good, err := LoadString(reactionSystemDoc(`["rec", "cells"]`))
	if err != nil {
		t.Fatal(err)
	}
	if got := recordCodesAt(Validate(good)); len(got) != 0 {
		t.Errorf("a record-axis shape agrees with 2, got %v", got)
	}
}

func TestReactionSystemDeprecatedSiteIsNamed(t *testing.T) {
	doc := strings.Replace(reactionSystemDoc(`["rec", "cells"]`),
		`"from": {"file_variable": "t2m"}`, `"from": {"file_variable": "t2m", "records_per_sample": 2}`, 1)
	file, err := LoadString(doc)
	if err != nil {
		t.Fatal(err)
	}
	got := DeprecatedRecordsPerSampleSites(file)
	want := []string{
		"/data_sources/Reanalysis/temporal/records_per_sample",
		"/reaction_systems/Chem/parameters/T/update/from/records_per_sample",
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("sites %v, want %v", got, want)
	}
}

// An index set an unmounted `{ref}` could still declare: Box.F writes
// records_per_sample 2 and is shaped over `rec`, which the document does not
// declare while subsystem Grid is still a `{ref}` (LoadString does not mount
// it). Its record count is not decidable at validation (esm-spec §8.5.1).
const pendingRefDoc = `{
  "esm": "1.3.0",
  "metadata": {"name": "Pending"},
  "index_sets": {"x": {"kind": "interval", "size": 3}},
  "data_sources": {"Met": {"kind": "grid",
    "source": {"url_template": "file:///data/met/{date:%Y%m%d}.nc"},
    "temporal": {"start": "2024-05-01T00:00:00Z", "end": "2024-05-31T21:00:00Z",
      "file_period": "P1D", "frequency": "PT3H", "records_per_file": 8}}},
  "models": {"Box": {
    "variables": {
      "c": {"type": "unknown", "units": "1", "default": 1.0},
      "F": {"type": "parameter", "units": "1", "default": 1.0, "shape": ["rec", "x"],
        "update": {"kind": "data", "source": "Met",
          "from": {"file_variable": "PBLH", "records_per_sample": 2}}}},
    "equations": [{"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs": {"op": "*", "args": ["F", "c"]}}],
    "subsystems": {"Grid": {"ref": "./grid.esm"}}
  }}
}`

func TestRecordShapeOverIndexSetAnUnmountedRefCouldDeclareIsUndecidable(t *testing.T) {
	file, err := LoadString(pendingRefDoc)
	if err != nil {
		t.Fatal(err)
	}
	if !hasUnmountedRefs(file) {
		t.Fatal("subsystem Grid is an unmounted ref")
	}
	for _, e := range Validate(file).StructuralErrors {
		if e.Code == ErrorRecordsPerSampleInvalid || e.Code == ErrorRecordAxisMisplaced {
			t.Errorf("an undecidable record shape was judged: %s at %s", e.Code, e.Path)
		}
	}

	// With nothing left to mount, the undeclared `rec` is an ordinary axis and
	// the written 2 disagrees with it.
	box := file.Models["Box"]
	box.Subsystems = nil
	file.Models["Box"] = box
	p := newRecordPass(file, nil, false)
	var codes []string
	walkRecordsPerSampleSites(file, func(site recordsPerSampleSite) {
		source := file.DataSources[site.rule.Source]
		f, _ := p.recordShapeFindings(site, &source)
		for _, x := range f {
			codes = append(codes, x.code)
		}
	})
	if strings.Join(codes, ",") != ErrorRecordsPerSampleInvalid {
		t.Errorf("a decidable record shape must be judged, got %v", codes)
	}
}
