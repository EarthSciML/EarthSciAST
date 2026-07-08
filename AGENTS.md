# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

## Simulation runner pathway (ABSOLUTE)

ESS hosts the rule engine and the simulation runners that consume it.
There is **one and only one** pathway from a model artifact to a numerical
result. Every contributor — and every AI agent — must use it.

### The single pathway

```
.esm JSON → parse → AST (canonical form)
         → AST transforms (canonicalize, flatten, discretize, substitute, …)
         → official simulation runner (consumes AST directly, no shortcuts)
```

No step is allowed to bypass the AST. The runner does not receive a
pre-numericised, pre-tabulated, or imperatively rewritten form of the
rules; it walks the same canonical AST that the rule engine produced.

### Official ESS Julia simulation runners

A binding **may** ship more than one official runner. Each must satisfy
all four invariants below:

1. **AST-pure.** Walks the canonical AST directly. No imperative shortcut,
   no materialised rule output that bypasses the AST.
2. **No per-rule-shape dispatch.** No `if rule.kind == flux_1d_ppm then …`
   branches at the runner layer. All rule-shape handling happens in
   `discretize` (production), upstream of the runner.
3. **Documented use case.** Docs state when to choose this runner over the
   alternatives (system size, performance, feature support).
4. **Public API.** Invokable by users — not just by test infrastructure.

Current Julia runners:

- **ModelingToolkit (`mtk_export.jl` + extensions)** — default for
  small-to-medium ODE/DAE systems. Compiles via MTK's symbolic pipeline
  (tearing, structural simplification, codegen). Best when MTK's
  compile-time scales acceptably.
- **`tree_walk.jl`** — AST tree-walker producing
  `f!(du, u, p, t)` directly, bypassing MTK codegen. Use for discretized
  PDEs whose scalar count exceeds MTK's tearing/codegen ceiling, where
  MTK compile time becomes the bottleneck. Audit + formal documentation
  is tracked under `esm-qrj`; see that bead for status.

### Official per-binding runners (cross-language)

Each binding has its own official runner(s) consuming the same canonical AST:

| Binding    | Official runner(s)                                                                        | File(s) |
|------------|-------------------------------------------------------------------------------------------|---------|
| Julia      | ModelingToolkit; `tree_walk.jl`                                                           | `pkg/EarthSciAST.jl/src/mtk_export.jl`, `tree_walk.jl` |
| Python     | `numpy_interpreter` (AST evaluator); `simulation.simulate()` (SciPy backend)              | `pkg/earthsci-ast-py/src/earthsci_ast/numpy_interpreter.py`, `simulation.py` |
| Rust       | `simulate` (diffsol scalar ODE); `simulate_array` (ndarray array-op runtime)              | `pkg/earthsci-ast-rs/src/simulate.rs`, `simulate_array.rs` |
| TypeScript | `codegen` (canonical-AST → JS lowering)                                                   | `pkg/earthsci-ast-ts/src/codegen.ts` |
| Go         | (none — `earthsci-ast-go` is parse + validate only by design)                               | — |

If a binding lacks a runner, that gap is filed as a bead, not patched
around with a one-off evaluator.

### Prohibitions (ABSOLUTE)

- **No new test-only evaluators.** If a test wants to compare numerical
  output against a reference, it runs the official pathway above. Tests do
  not get their own parallel evaluator.
- **No new doc-only / example-only evaluators.** Examples consume the same
  pathway users would.
- **No imperative shortcut paths inside a runner.** A runner that special-
  cases a rule shape, flattens an AST node into a hand-rolled numeric
  kernel, or short-circuits the AST walk for "speed" violates invariant
  #1 and must be fixed or rejected.
- **No per-rule-shape dispatch at the runner layer.** Rule-shape handling
  belongs in `discretize`. If a rule shape doesn't materialize correctly
  through the production pipeline, the bug is in the production pipeline.

The retirement of ESS's parallel test-path evaluators (`mms_evaluator.jl`,
`grid_assembly.apply_*!`, and the four binding stencil-walker mirrors —
~6,260 LoC) is tracked under `esm-4t5`. Those files exist as historical
artifacts only; do not extend them, do not model new code on them, and do
not re-introduce the pattern under a new name.

### Cross-reference

This rule is the ESS-specific specialization of the workspace-wide
single-pathway rule. See the workspace `CLAUDE.md` (rig root) and the
mayor's workspace-level `CLAUDE.md` for the global formulation.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
