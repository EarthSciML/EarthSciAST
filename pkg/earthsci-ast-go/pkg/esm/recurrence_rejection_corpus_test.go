package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// recurrence_rejection_corpus_test.go drives the SHARED cross-binding rejection
// corpus, tests/conformance/recurrence/rejections.json, through Go's public
// validation entry point.
//
// It exists because per-binding unit tests let five bindings drift apart on a
// single `if`. The corpus's own boundary case (`unprovable_offset_on_two_axes`)
// is the proof: admitting an unprovable lag identifies the recurrence axis but
// does not stop counting axes, and a binding that returned early there would
// still pass every test it wrote for itself. CONFORMANCE_SPEC §5.19.5 therefore
// makes these negative cases a shared artifact that every binding reads, rather
// than eight documents each binding constructs privately.
//
// What is asserted is the (code, path) pair and NOTHING ELSE — see
// TestRecurrenceRejectionCorpusPinsCodeAndPathOnly for why the prose is
// deliberately out of scope.

// recurrenceRejectionCorpus is the corpus file's schema. Only the fields this
// driver acts on are modeled; `why` is carried so a failure can quote the
// corpus's own account of what makes the document illegal.
type recurrenceRejectionCorpus struct {
	Category string `json:"category"`
	Version  string `json:"version"`
	Pinned   struct {
		Code    bool   `json:"code"`
		Path    bool   `json:"path"`
		Message bool   `json:"message"`
		Note    string `json:"note"`
	} `json:"pinned"`
	Cases []recurrenceRejectionCase `json:"cases"`
}

type recurrenceRejectionCase struct {
	ID           string `json:"id"`
	ExpectedCode string `json:"expected_code"`
	ExpectedPath string `json:"expected_path"`
	Why          string `json:"why"`
	// Document stays RAW so it can go through LoadString — the identical
	// pipeline LoadPath runs, schema validation included. Decoding it to a
	// map[string]any first would lose the int/float distinction of every
	// numeric literal in the document.
	Document json.RawMessage `json:"document"`
}

// recurrenceRejectionCaseCount pins the corpus SIZE. Without it a case dropped
// upstream is a silent reduction in coverage: the sweep would still pass, over
// fewer documents. Raise it when the corpus grows.
const recurrenceRejectionCaseCount = 8

// recurrencePreemptingCodes are the diagnoses that must NOT come back for any
// corpus case. Each would mean the recurrence check never got to own the
// diagnosis, which is the CONFORMANCE_SPEC §5.19.5 candidacy regression stated
// directly: gate the self-edge exemption on WELL-FOUNDEDNESS instead of on
// CANDIDACY and an ill-founded read stops qualifying for the exemption, so a
// pre-existing cycle check fires and collapses the document to one whole-document
// error. Without this assertion that failure reads only as "some other code came
// back", which is a much longer trail to the actual mistake.
//
// `load_error` is the CROSS-BINDING spelling and this binding emits no such code;
// it is listed anyway so the guard keeps its meaning if one is ever introduced.
// Go's local analogue is `validation_failed` at path "" — what ValidateText
// returns for schema-clean text that will not parse or resolve — so that is the
// spelling this driver would actually catch today.
var recurrencePreemptingCodes = map[string]string{
	"load_error":             "a whole-document load error",
	CodeValidationFailed:     "a whole-document validation failure (Go's `load_error` analogue)",
	ErrorCircularDependency:  "a dependency-cycle error",
	CodeCadenceObservedCycle: "an observed-definition cycle error",
}

func loadRecurrenceRejectionCorpus(t *testing.T) recurrenceRejectionCorpus {
	t.Helper()
	path := filepath.Join(repoTestsDir(t), "conformance", "recurrence", "rejections.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the shared rejection corpus %s: %v", path, err)
	}
	var corpus recurrenceRejectionCorpus
	if err := json.Unmarshal(data, &corpus); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return corpus
}

// TestRecurrenceRejectionCorpusPinsCodeAndPathOnly guards the corpus's own
// contract before trusting it.
//
// `pinned.message` MUST stay false. The same defect legitimately reads
// differently depending on which check reached it first — an unbound parameter
// used as a WHOLE index is reported by the coefficient test in this binding and
// by the affinity test in others, and both are correct — so pinning prose would
// make the first reworded diagnostic a cross-binding conformance failure.
// Asserting it here means a later edit flipping the flag cannot happen quietly:
// it fails as a corpus-contract violation instead of silently obliging five
// bindings to agree on wording.
func TestRecurrenceRejectionCorpusPinsCodeAndPathOnly(t *testing.T) {
	corpus := loadRecurrenceRejectionCorpus(t)
	if !corpus.Pinned.Code {
		t.Errorf("pinned.code = false, want true: the corpus must pin the diagnostic code")
	}
	if !corpus.Pinned.Path {
		t.Errorf("pinned.path = false, want true: the corpus must pin the JSON pointer")
	}
	if corpus.Pinned.Message {
		t.Errorf("pinned.message = true, want false: the diagnostic PROSE is deliberately " +
			"NOT a cross-binding contract, and this driver asserts no wording. If the corpus " +
			"now intends to pin messages that is a contract change to settle in " +
			"CONFORMANCE_SPEC §5.19.5, not something to absorb here.")
	}
	if len(corpus.Cases) != recurrenceRejectionCaseCount {
		t.Errorf("corpus holds %d cases, want %d: a case was added or dropped upstream",
			len(corpus.Cases), recurrenceRejectionCaseCount)
	}
}

// TestRecurrenceRejectionCorpus asserts that every malformed document in the
// shared corpus is rejected by Go's validation with the pinned code at the
// pinned pointer.
//
// Go's trivial-DAE self-edge drop sits on the ApplyDAEContract path, NOT inside
// validation, so no cycle check can pre-empt the recurrence diagnosis here — the
// hazard CONFORMANCE_SPEC §5.19.5 "The exemption is gated on CANDIDACY, not on
// well-foundedness" describes. These eight cases are what would catch a
// regression that moved such a check onto the validate path.
func TestRecurrenceRejectionCorpus(t *testing.T) {
	corpus := loadRecurrenceRejectionCorpus(t)
	if len(corpus.Cases) == 0 {
		t.Fatal("the shared rejection corpus holds no cases")
	}

	for _, tc := range corpus.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			// ValidateText, not Validate: it schema-checks the document AS WRITTEN
			// and only then runs the semantic checks, so SchemaErrors below is a
			// real signal. Validate takes a *ESMFile, which can only exist by having
			// already come through a schema-validating loader, and so documents its
			// SchemaErrors as always empty — asserting on that would be vacuous.
			res := ValidateText(string(tc.Document))

			// GUARD 1: illegal for exactly ONE reason. Each case is malformed under
			// the recurrence rule and well formed under everything else; a corpus
			// document that drifted schema-invalid would be rejected for a shape
			// error instead, satisfying a bare "it was rejected" check while testing
			// nothing about this construct.
			for _, e := range res.SchemaErrors {
				t.Errorf("corpus document is SCHEMA-INVALID, so it would be rejected for a "+
					"shape error rather than for its self-reference: %s at %s",
					e.Message, e.Path)
			}
			if len(res.SchemaErrors) > 0 {
				t.Fatalf("why it is illegal: %s", tc.Why)
			}

			if res.IsValid {
				t.Errorf("IsValid = true, want false\nwhy it is illegal: %s", tc.Why)
			}

			// GUARD 2: the recurrence check must OWN the diagnosis.
			for _, e := range res.StructuralErrors {
				if what, preempting := recurrencePreemptingCodes[e.Code]; preempting {
					t.Errorf("case came back as %s ([%s] at %s), so the recurrence diagnosis "+
						"was pre-empted. Gate the self-edge exemption on CANDIDACY — an "+
						"array-shaped unknown with an `index` self-read, well founded or not — "+
						"not on the well-foundedness verdict (CONFORMANCE_SPEC §5.19.5).",
						what, e.Code, e.Path)
				}
			}

			// The pinned pair, and only the pair. No assertion is made about the
			// message: `pinned.message` is false (see the test above).
			for _, e := range res.StructuralErrors {
				if e.Code == tc.ExpectedCode && e.Path == tc.ExpectedPath {
					return
				}
			}
			t.Errorf("no [%s] at %s among the %d structural error(s)\nwhy it is illegal: %s",
				tc.ExpectedCode, tc.ExpectedPath, len(res.StructuralErrors), tc.Why)
			for _, e := range res.StructuralErrors {
				t.Errorf("  got [%s] at %s: %s", e.Code, e.Path, e.Message)
			}
		})
	}
}
