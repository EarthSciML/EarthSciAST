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
Use [`operator_ir`](@ref) and [`emit_fragment`](@ref) when your application owns
the Reactant trace. For the legacy `direct_rhs` device-placement helpers shown
below, obtain their input with `EarthSciAST.Internal.build(doc; form = :oop)`.
The client of the arrays you pass selects the device.

The emitter lives in the Reactant package extension; its entry points are
declared (unexported) in EarthSciAST itself, so they are reached as
`EarthSciAST.direct_rhs` and friends once Reactant is loaded:

```julia
using EarthSciAST, Reactant
const ESA = EarthSciAST
```

## Compose fragments in an integrator trace

Build a fragment from an `esm_problem` created with the native compiler. A
fragment emits into the active Reactant block. It can be called at multiple
stage sites and inside `Reactant.@trace while`. The integrator builds the
device inputs, compiles the surrounding program and controls device placement.

```julia
prob = esm_problem(doc, (0.0, 1.0))
ir = operator_ir(prob)
frag = emit_fragment(ir)

# This example uses a whole model with no read-only states or forcing slots.
u = ConcreteRArray(prob.u0)
aux = ConcreteRArray(Float64[])
p = ConcreteRArray(parameter_vector(rhs_program(prob)))
t = ConcreteRNumber(0.0)
program = Reactant.@compile frag(u, aux, p, t, ())
```

- `select = RhsSelection(writes = ..., terms = ...)` selects the states and
  equation contributions for one operator. Use `ir_layout(ir)` for state
  and read-only state packing.
- Pass a flat Float64 parameter tensor in `parameter_names(ir)` order, a
  Float64 scalar time, and a tuple of flat device tensors in
  `forcing_slots(ir)` order. Array lengths are part of the compiled signature.
  New parameter values and forcing data of the same shape can be passed to the
  compiled program.
- `emit_fragment(ir; eltype = Float32)` evaluates in single precision and
  takes Float32 state and auxiliary tensors. Time, scalar parameters and
  floating-point forcing are converted on read. The default `fold = :tree`
  emits balanced binary folds, and a Float64 fragment still evaluates
  subtrees of constants on the host, grouped the same way. Choose
  `fold = :reduce` for the legacy emitter's reduction policy.
- `Tile(dec; owned, storage)` uses the native tile boxes. The output uses the
  tile storage layout, with zeros outside owned rows. `halo(ir)` reports the
  state reach of that tile. Pass compact column-major windows in
  `forcing_reach(ir)` order, or pass whole forcing buffers for a fixed tile.
- `tile_classes(prog, dec, tiles)` groups tiles whose local instructions and
  buffer layouts agree. Build and compile one fragment per returned target.
  Its sixth argument is a traced Int32 vector of the owned box's lower
  corners in decomposition axis order. Pack forcing from
  `forcing_reach(ir, origin)` for each member's origin and reuse the compiled
  fragment as that origin changes. The supplied origin must belong to that
  class. Unsupported structural comparisons retain a separate program for
  each affected tile.
- `Lanes(:cells, sets, capacity)` or `Lanes(:columns, sets, capacity)`
  accepts a sixth argument, a traced Int32 matrix of 1-based coordinates with
  rows in `sets` order. Duplicate cells can pad evaluations; use distinct
  cells when writing them back with `scatter_lanes`. The fragment
  supports pre-gathered forcing and constant-array subscripts affine in the
  lane coordinates. As in the native lane program, such a read outside an
  array dimension without a `periodic` or `clamp` boundary gives 0.0.
  Coordinates outside the domain are not checked: `gather_lanes` reads an
  unspecified element for them and `scatter_lanes` drops their updates.
- `outputs = KernelOutputs(spec)` takes one `compile_kernels` specification
  and emits a whole-domain output kernel. Pass a traced Float64 `dt` as the
  sixth argument if the spec reads it. The result is a tuple of flat tensors
  matching `ir_layout(ir).out`. `KernelOutputs(spec; out_eltype = Float32)`
  converts the outputs at the end of emission.

## One device

`direct_rhs` takes a `client` keyword — `nothing` (Reactant's default backend),
`:cpu`, `:gpu`, or an `XLA` client object. Build the device-resident inputs with
the helpers so that they land on the client you asked for, rather than on
whatever Reactant's default happens to be:

```julia
fo, u0, p, _, vmap = EarthSciAST.Internal.build(doc; form = :oop)

d  = ESA.direct_rhs(fo; var_map = vmap, client = :gpu)
ur = ESA.direct_state(d, u0)      # ConcreteRArray on that client
pr = ESA.direct_params(d, p)      # every parameter as a ConcreteRNumber
tr = ESA.direct_time(d, 0.0)

xla = Reactant.@compile sync = true d(ur, pr, tr)
du  = Array(xla(ur, pr, tr))
```

### Compile at the DEFAULT stack, and do not raise it

`Reactant.@compile` on this backend needs no special stack size, and **raising
the stack makes it worse rather than better** — `ulimit -s 131072` before a run
is the one thing to avoid.

Reactant's interpreter rewrites every type-unstable call in a traced body into
its generated `call_with_reactant`, and that generator runs a whole nested
GPUCompiler inference to build the replacement. The emitter's walk over the
compiled IR is recursive, so if every level of the tree were rewritten, each
would be one more nested generator, and a bigger stack would only let that
nesting run deeper. The walk's entry is therefore marked
`Reactant.@skip_rewrite_func`, so the interpreter calls it natively and builds
no nested generator for the recursion (`ext/reactant_direct/device.jl` says why
that is safe — the walk constructs `stablehlo.*` operations from the traced
values' `mlir_data` and otherwise reads host data, so there is no
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

`ESA.direct_platform(d)` reports what the wrapper settled on (`"cuda x1"`,
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
d = ESA.direct_rhs(fo; var_map = vmap, client = :gpu, sharding = :cells)  # all of them
d = ESA.direct_rhs(fo; var_map = vmap, client = :gpu, sharding = 4)       # the first four
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

The multi-device agreement test (`test/reactant/reactant_direct_sharding_test.jl`,
in the Reactant suite) is opt-in: it runs under `ESM_TEST_REACTANT_GPU=1` and
skips with a message explaining why otherwise. With `EARTHSCI_JULIA_XLA_DEVICE=cpu` and
`XLA_FLAGS=--xla_force_host_platform_device_count=4` it runs the identical
assertions against mock host devices, which is the way to develop a sharding
change without holding a GPU.
