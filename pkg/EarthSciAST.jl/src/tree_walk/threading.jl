# ========================================================================
# tree_walk/threading.jl — every threaded section's machinery: the verdict
# tally, the serial work floor, the static partition, the per-section verdict
# cache and the allocation-free chunk dispatch over Polyester's worker pool.
# ========================================================================

# ---- Why the cell axis is safe ------------------------------------------------
#
# The main consumer of everything below is the CODEGEN tier's chunked cell axis
# (codegen_kernel.jl): the section builder proves at build time that every
# emitted `du` slot is globally unique, and the runtime then runs the generated
# function as `nchunks` static contiguous cell-ordinal chunks. The contraction
# nests, the fused scans and the scan folds thread the same way.
#
# WHY THE CELL AXIS IS THE SAFE ONE. Every ⊕-fold a kernel hosts is WITHIN a
# cell (`_NK_CONTRACTION` / `_NK_AREDUCE` loops are per-cell); nothing
# accumulates across cells or into `du` — each cell's value is computed from
# `u`/`p`/`t` alone and stored to exactly one `du` slot. So chunk boundaries
# are not observable (any split of the ordinal axis reproduces the serial
# values BIT FOR BIT), and chunks race only if two cells target the same `du`
# slot — which the codegen build's `_cg_covered_outs_disjoint` rules out up
# front.
#
# ON BY DEFAULT. Polyester is a hard dependency and the chunked cell axis runs
# whenever Julia has more than one thread; with one thread (`julia -t 1`, the
# default without `JULIA_NUM_THREADS`) every section runs its serial `(1, 1)`
# instance. Inside an ODE solve a stiff solver calls the RHS in short bursts
# separated by linear-algebra work, so the pool may sleep between calls and a
# dispatch pays a wake-up; the per-chunk work floor (`ESS_THREADS_MIN_WORK`)
# keeps small sections serial for that reason. Raising that floor past a
# section's work forces a serial run — chunking changes no bit, so it is
# not a choice of evaluator and has no `compiler` value of its own.

# The dispatch itself is below: Polyester's worker pool, driven without a
# per-call allocation.

# One-time threading verdicts: bumped once per
# generated SECTION (not per eval) by `_sec_prep_threads!` (codegen_kernel.jl).
# Read it via `EarthSciAST._THREAD_TALLY`, reset with
# `EarthSciAST._reset_thread_tally!()`.
#   :cg_threaded              — the section's cell axes run as static chunks
#   :cg_serial_small          — fewer than 2 chunks' worth of work (node
#                               evaluations summed across the section's
#                               emitted kernels' cells; a contraction counts
#                               its fold terms too)
#   :cg_serial_shared_outs    — two emitted cells (same or different kernel)
#                               target the same `du` slot; the section never
#                               chunks (see `_cg_covered_outs_disjoint`)
#
# Problems first called from different tasks tally concurrently, so every
# write takes `_THREAD_TALLY_LOCK`.
const _THREAD_TALLY = Dict{Symbol, Int}()
const _THREAD_TALLY_LOCK = ReentrantLock()
_tally_thread!(k::Symbol) = lock(_THREAD_TALLY_LOCK) do
    _THREAD_TALLY[k] = get(_THREAD_TALLY, k, 0) + 1
    nothing
end
_reset_thread_tally!() = lock(() -> (empty!(_THREAD_TALLY); nothing), _THREAD_TALLY_LOCK)

# The serial work floor: the least work, in node evaluations (the `work` of a
# section's `_SecTCache`), one chunk of a thread dispatch must carry. A section
# with less than two chunks' worth runs serially, so turning threads on never
# makes a small section slower than its serial run. The default is the cost of
# one empty fork-join of Polyester's pool over the cost of one node evaluation
# in the cheapest generated loops (array_contraction.jl, codegen_kernel.jl),
# both measured on a 4-thread run: a chunk below it would spend about as long
# being dispatched as computing. Override with ESS_THREADS_MIN_WORK, read when
# a build starts: a tuning threshold, not a refusal boundary — both sides of it evaluate the
# same bits, so no compiler refuses a rule for crossing it.
const _THREAD_MIN_WORK_DEFAULT = 6000

# The least cells per chunk for a section whose loops may read-modify-write
# each `du` slot once per reduced term (an interchanged affine reduction): the
# cache line two neighbouring chunks share at their boundary is then written by
# both threads on every term, so a chunk must hold enough cells to outweigh
# that traffic. Not read from the environment: ESS_THREADS_MIN_WORK set to 0
# still leaves it, and set past a section's work still forces it serial.
const _THREAD_MIN_RMW_CELLS = 512

@inline _threads_available() = Threads.nthreads() > 1

# The static partition itself: chunk `c` of `nchunks` covers the half-open
# 0-based ordinal range `[a, b)` of `n` cells, sizes differing by at most one.
# A pure function of `(n, nchunks, c)` — identical run to run, no dynamic work
# stealing, nothing that could reorder a fold. Every emitted loop nest computes
# its own `[a, b)` from this exact arithmetic.
@inline function _chunk_ordinals(n::Int, c::Int, nchunks::Int)
    base = div(n, nchunks)
    rem = n - base * nchunks
    a = (c - 1) * base + min(c - 1, rem)
    b = c * base + min(c, rem)
    return a, b
end

# ---- One section's verdict ----------------------------------------------------
# GRANULARITY: the WHOLE SECTION is chunked, not each kernel. One batch
# dispatch runs chunk `c` of every emitted kernel back to back —
# `f(du, u, p, t, tabs, c, nchunks)` — with no inter-kernel barrier. That is
# safe because the section builder proves the strong property up front:
# `_cg_covered_outs_disjoint` verifies at build time that every covered
# out-slot is globally unique ACROSS all emitted kernels. When that holds, no
# two cells anywhere in the section touch the same `du` slot, kernels share no
# other mutable state (locals only; `u`/`p`/`t`/tabs are read-only here), and
# the inter-kernel barrier is unnecessary — one dispatch per RHS call, so the
# per-dispatch wake-up latency is paid ONCE instead of #kernels times. When it
# does NOT hold (`:cg_serial_shared_outs`), the section never chunks and every
# generated function runs its serial `(1, 1)` instance.
#
# BIT-IDENTITY, per kernel: chunk boundaries are not observable (a cell
# computes the same instruction sequence on the same inputs whichever chunk it
# lands in; every ⊕-fold is WITHIN a cell — contraction loops are per-cell in
# the emitted body), the partition is the static
# `_chunk_ordinals`, and disjoint writes commute. Threaded `du` is bitwise
# `===` serial `du`.
#
# One Julia thread ⇒ serial; a section's work below two chunks of the serial
# work floor (`_SecTCache.min_work`, the build's `_Tuning`) ⇒ serial.
# Verdicts land in `_THREAD_TALLY` (`:cg_threaded` / `:cg_serial_small` /
# `:cg_serial_shared_outs`), documented above.

# One-time threading verdict for one generated function's cell axes:
# `state` is 0 unexamined, 1 chunked, -1 serial (too little work), -2 serial
# (globally shared out-slots — permanent, decided at build), -3 serial (a
# workspace's own copy of the section, which never dispatches to the pool:
# `_SECT_SERIAL_WORKSPACE`, rhs_program.jl).
# `ncells`/`disjoint` are build facts (`_CGBuilt`); `nchunks` is fixed
# at the first threaded call, so the partition is identical call to call.
# `work` is what the work floor is held against: the section's node
# evaluations per call (`_acc_kernel_work` per cell for a kernel section, the
# fold terms for a contraction, array_contraction.jl), the cell count when the
# builder gives none; the chunk count never exceeds `ncells`.
# `job1`/`job2` hold the section's dispatch jobs (`_ThreadJob`, below) for the
# last two argument types it ran at, so a caller alternating between Float64
# and dual-number calls (a solver and its Jacobian) reuses both.
mutable struct _SecTCache
    state::Int
    ncells::Int
    disjoint::Bool
    work::Int
    nchunks::Int
    job1::Any
    job2::Any
    rmw::Bool        # `_CGBuilt.rmw`: chunks also keep `_THREAD_MIN_RMW_CELLS` cells
    min_work::Int    # the work floor of the build that made the section
end
_SecTCache(ncells::Int, disjoint::Bool, work::Int = ncells, rmw::Bool = false) =
    _SecTCache(0, ncells, disjoint, work, 1, nothing, nothing, rmw, _tuning_now().thread_min_work)
_sec_tcache(::Nothing) = _SecTCache(0, false)

# Decide once whether this generated function may run chunked: size first
# (the work floor guards per-DISPATCH work, and the section is one dispatch),
# then the build-time disjointness verdict.
function _sec_prep_threads!(tc::_SecTCache)
    tc.state == 0 || return tc
    minw = tc.min_work
    nchunks = min(Threads.nthreads(), tc.ncells, max(1, div(tc.work, max(minw, 1))))
    tc.rmw && (nchunks = min(nchunks, max(1, div(tc.ncells, _THREAD_MIN_RMW_CELLS))))
    if nchunks < 2
        tc.state = -1                 # too little work to be worth a dispatch
        _tally_thread!(:cg_serial_small)
        return tc
    end
    if !tc.disjoint
        tc.state = -2                 # shared out-slots: chunks would race
        _tally_thread!(:cg_serial_shared_outs)
        return tc
    end
    tc.nchunks = nchunks
    tc.state = 1
    _tally_thread!(:cg_threaded)
    return tc
end

# This section's job for body type `B` and argument type `A`, from the two
# cached slots or freshly made (the only allocation, once per argument type).
@inline function _section_job!(tc::_SecTCache, ::Type{B}, ::Type{A}) where {B, A}
    J = _ThreadJob{B, A}
    j = tc.job1
    j isa J && return j
    j2 = tc.job2
    tc.job2 = j
    if j2 isa J
        tc.job1 = j2
        return j2
    end
    jn = J()
    tc.job1 = jn
    return jn
end

# Run a section: `body(args, c, nchunks)` for every chunk when its verdict
# allows threading (at most `maxchunks` chunks), else serially: `body(args, 1,
# 1)`, or its `ntiles` static tiles back to back (`body(args, c, ntiles)` for
# each `c`), which keeps a large section's working set in cache. A chunk or
# tile computes each of its cells exactly as the serial instance does, so every
# route gives the same bits.
@inline function _run_section!(
        tc::_SecTCache, body::B, args::A, maxchunks::Int = typemax(Int), ntiles::Int = 1
    ) where {B, A}
    if _threads_available() && _sec_prep_threads!(tc).state == 1
        tc.nchunks = min(tc.nchunks, maxchunks)
        _run_chunked!(tc, body, args)
    elseif ntiles == 1
        body(args, 1, 1)
    else
        for c in 1:ntiles
            body(args, c, ntiles)
        end
    end
    return nothing
end

# Run `body(args, c, nchunks)` for every chunk of the section's verdict.
@inline function _run_chunked!(tc::_SecTCache, body::B, args::A) where {B, A}
    j = _section_job!(tc, B, A)
    j.body = body
    j.args = args
    j.nchunks = tc.nchunks
    _dispatch_job!(j)
    return nothing
end

# ---- The allocation-free chunk dispatch ---------------------------------------
#
# Every threaded section of the right-hand side (the codegen'd kernel
# sections, the whole-array contraction nests, the scan folds) runs as
# `nchunks` static chunks of one body. This file hands those chunks to
# Polyester's worker pool without allocating on a steady call.
#
# `Polyester.@batch` cannot do that: it boxes its argument tuple in a
# `ManualMemory.Reference` on every call, and a closure over the call's
# arguments needs a run-time `@cfunction`. Here each section keeps a small
# mutable JOB per argument type (`_ThreadJob`, cached on the section's
# `_SecTCache`); a call stores its arguments into the job's typed fields and
# passes the workers the job's address and a chunk number. The worker entry
# point is a `@cfunction` of a singleton callable, so it is a compile-time
# constant per job type. The pool itself (the worker tasks, the thread
# requests and their release) is Polyester's, through the same
# ThreadingUtilities / PolyesterWeave calls `@batch` makes. Both are direct
# dependencies with their own compat bounds: the task-buffer layout below is
# theirs, so a release that changes it must fail resolution, not corrupt a
# worker's memory.
#
# The calling thread always runs chunk 1, and every chunk no worker was free
# to take (a nested call, `disable_polyester_threads`): the partition is fixed,
# only who runs each chunk changes, so the values never do.
#
# An exception thrown by a chunk is caught where it was thrown, the dispatch
# waits for every other chunk and releases its workers, and then the first
# exception recorded is rethrown on the calling thread — the error a serial
# call would raise, instead of a worker task that dies silently.

const _TU = ThreadingUtilities
const _PW = PolyesterWeave

# One section's chunk job for one argument type. `body(args, c, nchunks)`
# runs chunk `c`; `body` and `args` are rewritten on every dispatch (both are
# immutable values stored inline, so that is a copy, not an allocation).
# `err` is written by whichever chunks throw, from any thread, so it is an
# atomic field: the first exception wins the compare-and-swap, and the calling
# thread's atomic read after the waits sees it.
mutable struct _ThreadJob{B, A}
    body::B
    args::A
    nchunks::Int
    @atomic err::Any
    function _ThreadJob{B, A}() where {B, A}
        j = new{B, A}()
        @atomic j.err = nothing
        return j
    end
end

@inline function _job_chunk!(j::_ThreadJob, c::Int)
    try
        j.body(j.args, c, j.nchunks)
    catch e
        @atomicreplace j.err nothing => e
    end
    return nothing
end

# The worker entry point for a job type: read the job's address and the chunk
# number from the task buffer, run the chunk, and mark the task done.
struct _ChunkRunner{J} end
function (::_ChunkRunner{J})(p::Ptr{UInt}) where {J}
    offset, jp = _TU.load(p, Ptr{Cvoid}, 2 * sizeof(UInt))
    _, c = _TU.load(p, Int, offset)
    _job_chunk!(unsafe_pointer_to_objref(jp)::J, c)
    _TU._atomic_store!(p, _TU.SPIN)
    return nothing
end

@generated function _chunk_cfunc(::Type{J}) where {J}
    r = _ChunkRunner{J}()
    return :(@cfunction($r, Cvoid, (Ptr{UInt},)))
end

@inline function _setup_chunk!(p::Ptr{UInt}, fptr::Ptr{Cvoid}, jp::Ptr{Cvoid}, c::Int)
    offset = _TU.store!(p, fptr, sizeof(UInt))
    offset = _TU.store!(p, jp, offset)
    _TU.store!(p, c, offset)
    return nothing
end

# Run every chunk of `j`, workers first, and wait for all of them.
function _dispatch_job!(j::J) where {J <: _ThreadJob}
    n = j.nchunks
    threads, torelease = _PW.request_threads(n - 1)
    fptr = _chunk_cfunc(J)
    jp = pointer_from_objref(j)
    launched = 0
    GC.@preserve j begin
        tid = 0x00000000
        for th in threads
            tm = _PW.mask(th)
            k = length(th) % UInt32
            i = 0x00000000
            while i != k && launched < n - 1
                tz = (trailing_zeros(tm) % UInt32) + 0x00000001
                tid += tz
                tm >>>= tz
                i += 0x00000001
                launched += 1
                _TU.launch(_setup_chunk!, tid, fptr, jp, launched + 1)
            end
        end
        _job_chunk!(j, 1)
        for c in (launched + 2):n
            _job_chunk!(j, c)
        end
        tid = 0x00000000
        waited = 0
        for th in threads
            tm = _PW.mask(th)
            k = length(th) % UInt32
            i = 0x00000000
            while i != k && waited < launched
                tz = (trailing_zeros(tm) % UInt32) + 0x00000001
                tid += tz
                tm >>>= tz
                i += 0x00000001
                waited += 1
                _TU.wait(tid)
            end
        end
    end
    _PW.free_threads!(torelease)
    err = @atomic j.err
    if err !== nothing
        @atomic j.err = nothing
        throw(err)
    end
    return nothing
end
