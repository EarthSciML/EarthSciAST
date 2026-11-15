// Command esm-document-format is the Go batch driver of the document-format
// gate (scripts/run-document-format-gate.py):
//
//	esm-document-format print MANIFEST OUT   canonical form and both printed texts
//	esm-document-format parse MANIFEST OUT   read each text back
//
// The manifest and output layout are described in run-document-format-gate.py.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

type item struct {
	ID     string `json:"id"`
	Path   string `json:"path"`
	Format string `json:"format"`
}

var formats = []struct {
	name string
	f    esm.DocumentFormat
	ext  string
}{
	{"markdown", esm.DocumentMarkdown, "md"},
	{"typst", esm.DocumentTypst, "typ"},
}

// decode reads JSON keeping every number token exactly (json.Number).
func decode(raw []byte) (any, error) {
	var v any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	return v, nil
}

// guarded runs f, turning a panic into an error.
func guarded(f func() (string, error)) (out string, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	return f()
}

func write(path, text string) {
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func jsonText(v any) (string, error) {
	b, err := json.Marshal(v)
	return string(b), err
}

func printOne(it item, out string) {
	stem := filepath.Join(out, it.ID)
	var canon any
	text, err := guarded(func() (string, error) {
		raw, err := os.ReadFile(it.Path)
		if err != nil {
			return "", err
		}
		doc, err := decode(raw)
		if err != nil {
			return "", err
		}
		canon = esm.CanonicalizeDocument(doc)
		return jsonText(canon)
	})
	if err != nil {
		write(stem+".canon.error", err.Error())
		return
	}
	write(stem+".canon.json", text)
	for _, f := range formats {
		text, err := guarded(func() (string, error) { return esm.PrintDocument(canon, f.f), nil })
		if err != nil {
			write(stem+"."+f.ext+".error", err.Error())
		} else {
			write(stem+"."+f.ext, text)
		}
	}
}

func parseOne(it item, out string) {
	stem := filepath.Join(out, it.ID)
	text, err := guarded(func() (string, error) {
		raw, err := os.ReadFile(it.Path)
		if err != nil {
			return "", err
		}
		for _, f := range formats {
			if f.name == it.Format {
				doc, err := esm.ParseDocument(string(raw), f.f)
				if err != nil {
					return "", err
				}
				return jsonText(doc)
			}
		}
		return "", fmt.Errorf("unknown format %q", it.Format)
	})
	if err != nil {
		write(stem+".error", err.Error())
	} else {
		write(stem+".json", text)
	}
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: esm-document-format print|parse MANIFEST OUT")
		os.Exit(2)
	}
	mode, manifest, out := os.Args[1], os.Args[2], os.Args[3]
	raw, err := os.ReadFile(manifest)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var items []item
	if err := json.Unmarshal(raw, &items); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	for _, it := range items {
		switch mode {
		case "print":
			printOne(it, out)
		case "parse":
			parseOne(it, out)
		default:
			fmt.Fprintf(os.Stderr, "unknown mode %q\n", mode)
			os.Exit(2)
		}
	}
}
