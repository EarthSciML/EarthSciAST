package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var (
	regionOpen  = regexp.MustCompile(`^\s*// region: (\S+)(?:\s+ops=(\S+))?\s*$`)
	regionClose = regexp.MustCompile(`^\s*// endregion\s*$`)
)

// checkRegions enforces the region rules of docs/api/README.md §3 on the Go
// example programs: every region closes, none nest, no id repeats, and every
// ops= entry is a canonical name the manifest gives a Go spelling.
func checkRegions(dir string, m *manifest) error {
	goOps := map[string]bool{}
	for _, s := range m.Symbols {
		if _, ok := s.Bindings["go"]; ok {
			goOps[s.Name] = true
		}
	}
	files, err := filepath.Glob(filepath.Join(dir, "*.go"))
	if err != nil {
		return err
	}
	sort.Strings(files)
	seen := map[string]string{}
	var problems []string
	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			return err
		}
		open, openAt := "", 0
		sc := bufio.NewScanner(fh)
		for line := 1; sc.Scan(); line++ {
			at := fmt.Sprintf("%s:%d", filepath.Base(f), line)
			if g := regionOpen.FindStringSubmatch(sc.Text()); g != nil {
				if open != "" {
					problems = append(problems, at+": region "+g[1]+" opens inside region "+open)
				}
				if prev, dup := seen[g[1]]; dup {
					problems = append(problems, at+": region id "+g[1]+" already used at "+prev)
				}
				seen[g[1]] = at
				open, openAt = g[1], line
				for _, op := range strings.Split(g[2], ",") {
					if op != "" && !goOps[op] {
						problems = append(problems, at+": ops= names "+op+", which is not a canonical name with a Go spelling")
					}
				}
			} else if regionClose.MatchString(sc.Text()) {
				if open == "" {
					problems = append(problems, at+": endregion with no open region")
				}
				open = ""
			}
		}
		fh.Close()
		if err := sc.Err(); err != nil {
			return err
		}
		if open != "" {
			problems = append(problems, fmt.Sprintf("%s:%d: region %s never closes", filepath.Base(f), openAt, open))
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("example regions:\n  %s", strings.Join(problems, "\n  "))
	}
	return nil
}
