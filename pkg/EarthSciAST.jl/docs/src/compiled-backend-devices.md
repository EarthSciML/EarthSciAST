```@meta
CurrentModule = EarthSciAST
```

# Compiled backend: choosing a device, and sharding across several

The compiled backend (`EarthSciASTReactantExt`, `direct_rhs`) lowers a model's
compiled tree-walk IR straight into StableHLO.

**Most callers do not need this page.** `esm_problem(doc, tspan; compiler =
:xla)` does all of it — build the intermediate representation, emit, compile
once, and hand back a Problem whose `f!` is the compiled program — and it picks
the client off `EARTHSCI_JULIA_XLA_DEVICE` (`cpu` / `gpu`). This page is for the
caller who needs the emitted callable ITSELF: to shard the state across several
devices, or to compose it into a larger traced program of their own.
`EarthSciAST._build_evaluator(doc; form = :oop)` is how you get the
intermediate representation for that — the private builder behind `esm_problem`
(`build_evaluator` has been retired; see `API_SPEC.md` §8 item 23) — and it
returns the build product a backend consumes, not a host evaluator: host
evaluation is the default in-place `f!`. Nothing in the emitted program names a
device: the same module compiles on a host CPU or on
an attached GPU, and **which one is fixed by the client of the arrays you feed
it**. This page is about that choice and about cutting the state across several
devices of one client.

The emitter lives in a package extension, so reach it through
`Base.get_extension`:

```julia
using EarthSciAST, Reactant
ext = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
```

## One device

`direct_rhs` takes a `client` keyword — `nothing` (Reactant's default backend),
`:cpu`, `:gpu`, or an `XLA` client object. Build the device-resident inputs with
the helpers so that they land on the client you asked for, rather than on
whatever Reactant's default happens to be:

```julia
fo, u0, p, _, vmap = EarthSciAST._build_evaluator(doc; form = :oop)

d  = ext.direct_rhs(fo; var_map = vmap, client = :gpu)
ur = ext.direct_state(d, u0)      # ConcreteRArray on that client
pr = ext.direct_params(d, p)      # every parameter as a ConcreteRNumber
tr = ext.direct_time(d, 0.0)

xla = Reactant.@compile sync = true d(ur, pr, tr)
du  = Array(xla(ur, pr, tr))
```

### Compile at the DEFAULT stack, and do not raise it

`Reactant.@compile` on this backend needs no special stack size, and **raising
the stack makes it worse rather than better** — `ulimit -s 131072` before a run
is the one thing to avoid.

That is worth saying out loud because the failure it prevents used to look like
a stack problem. Reactant's interpreter rewrites every type-unstable call in a
traced body into its generated `call_with_reactant`, and that generator runs a
whole nested GPUCompiler inference to build the replacement. The emitter's walk
over the compiled IR is recursive, so before it was made opaque to the rewrite
every level of the tree was one more nested generator: the compile wedged inside
`typeinf` with no error and no progress, or printed `detected a stack overflow`
a dozen times and took the process down with `SIGSEGV`. It was intermittent —
the depth reached depends on the fixture and on what inference had already
cached — and a bigger stack simply let the nesting run deeper before the guard
fired.

The fix is in the emitter, not in the caller's environment: the walk's entry is
marked `Reactant.@skip_rewrite_func`, so the interpreter calls it natively and
builds no nested generator for the recursion (`ext/reactant_direct/device.jl`
says why that is safe — the walk constructs `stablehlo.*` operations from the
traced values' `mlir_data` and otherwise reads host data, so there is no
`@reactant_overlay` method for the interpreter to find).

### Put a function between your program and `@compile`

If the wrapper and the device inputs come out of calls Julia cannot infer — a
document read at runtime, a fixture loop, anything where `fo` is not a concrete
type — then `d`, `ur` and `tr` are all `Any` at the call site, and
`Reactant.@compile` is inferred through them. Pass them through one plain
function first; Julia specializes it on their runtime types, so inside it every
argument is concrete, and the trace is inferred exactly as it is from a script
that spelled the concrete constructors out:

```julia
compile_rhs(d, ur, pr, tr) = Reactant.@compile sync = true d(ur, pr, tr)

xla = compile_rhs(d, ur, pr, tr)
```

The `compiled_rhs` adapter and the sharding test both do exactly this.

`ext.direct_platform(d)` reports what the wrapper settled on (`"cuda x1"`,
`"cpu x4"`), which is worth logging: asking for `:gpu` on a machine with no GPU
**throws** rather than quietly running on the CPU, and a run that silently
changed platform is a result nobody can interpret afterwards.

The `compiled_rhs` conformance adapter exposes the same choice as an environment
variable, `EARTHSCI_JULIA_XLA_DEVICE=cpu|gpu` (default `cpu`). On `gpu` with no
GPU attached it answers the tier's whole-output `unavailable` outcome with the
client error as the reason — never a pass, and never a CPU run under a GPU
label. The platform it used is printed on stderr, because the tier's report
schema has no field for it.

## Several devices: the cell-axis shard

`sharding` cuts the flat state across several devices of the chosen client:

```julia
d = ext.direct_rhs(fo; var_map = vmap, client = :gpu, sharding = :cells)  # all of them
d = ext.direct_rhs(fo; var_map = vmap, client = :gpu, sharding = 4)       # the first four
```

`direct_state` then builds `u` already distributed, and the emitted `du` carries
the matching sharding constraint, so the result stays where the next step
expects it. Nothing else in the call changes.

Whether a wrapper is sharded is part of its TYPE (`DirectRHS{F,SHARDED}`), and
the placement itself — the client and the mesh — is held beside the wrapper
rather than in it. Both are for the same reason as the function barrier above:
`Reactant.@compile` traces and infers the callable it is given, so the callable
carries no XLA object, and the one-device case is a separate method that does
not contain the sharding call at all. Read the placement through
`direct_client`, `direct_shard`, `direct_devicecount` and `direct_platform`;
there is no `place` field to reach for.

### Which axis, and why that one

The flat state is a **concatenation of per-variable cell blocks**: state
variables in sorted-name order, each contributing a contiguous block of its own
cells in column-major order, a scalar state being a block of one. One flat slot
is exactly one cell, so the flat axis *is* a cell axis — every variable's cell
axis laid end to end. `u` is rank 1, so it is also the only axis there is to
cut.

A one-dimensional mesh cuts that axis into equal contiguous slabs, one per
device. Two shapes of slab mean something physically, and those are the two that
are accepted:

* a slab **inside one variable's block** is a contiguous *cell range* of that
  variable — the stencil case, where a neighbour access crosses a device only at
  the two slab edges;
* a slab that is **exactly a union of whole blocks** is a *variable partition* —
  each device owns entire fields.

### What is refused

`direct_rhs` raises `DirectEmitError` (the emitter's ordinary
`E_DIRECT_EMIT_UNSUPPORTED` code) rather than silently accepting a cut that is
neither:

* **fewer than two devices.** A one-device mesh means "no sharding"; say that by
  leaving `sharding` unset.
* **a flat state length not divisible by the device count.** The slabs would be
  ragged. A 343-cell field, for instance, admits no even shard.
* **a slab that straddles a variable block boundary** — one that holds a suffix
  of one variable's cells and a prefix of another's. The message names the
  variables it would straddle and where the block boundaries are.

Correctness never depends on any of this: XLA's sharding propagation would
insert collectives for any cut. The refusals exist so that asking for a cell
shard tells you when the layout cannot give one, instead of handing back an
all-to-all.

Forcing buffers (`direct_rhs_with_buffers`, `direct_buffers`) are **replicated**,
not sharded: they are whole-field inputs read by gathers from anywhere in the
domain, so a sharded copy would turn every read into a collective.

## Running under SLURM

Multi-device here means several GPUs on **one node**. A generic batch script:

```bash
#!/bin/bash
#SBATCH --partition=<partition>
#SBATCH --account=<account>
#SBATCH --nodes=1
#SBATCH --gres=gpu:4
#SBATCH --mem=48000
#SBATCH --time=01:00:00

# Reactant bundles its own CUDA and cuDNN; no module load is needed, and the
# GPU client appears on its own once the job has a GPU.
export JULIA_DEPOT_PATH=/path/to/depot

# Compute nodes often mount /tmp as RAM. XLA's compilation cache and Julia's
# scratch space both land in TMPDIR, so point it at real disk or the job will
# fail in ways that look like memory pressure.
export TMPDIR=$SLURM_SUBMIT_DIR/tmp; mkdir -p "$TMPDIR"

# Leave the stack alone. `ulimit -s` is not part of this recipe; see
# "Compile at the DEFAULT stack" above for why raising it is actively harmful.

EARTHSCI_JULIA_XLA_DEVICE=gpu julia --project=. run_model.jl
```

`CUDA_VISIBLE_DEVICES` narrows what the job sees, which is how a four-GPU
allocation runs a two-device leg without a second submission. Reactant prints
hwloc and scheduler warnings on start-up that are harmless.

The multi-device agreement test is opt-in twice over: it runs under
`ESM_TEST_REACTANT=1` *and* `ESM_TEST_REACTANT_GPU=1`, and skips with a message
explaining why otherwise. With `EARTHSCI_JULIA_XLA_DEVICE=cpu` and
`XLA_FLAGS=--xla_force_host_platform_device_count=4` it runs the identical
assertions against mock host devices, which is the way to develop a sharding
change without holding a GPU.
