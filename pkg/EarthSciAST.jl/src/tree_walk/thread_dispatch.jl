# ========================================================================
# tree_walk/thread_dispatch.jl — the allocation-free chunk dispatch.
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
# ThreadingUtilities / PolyesterWeave calls `@batch` makes.
#
# The calling thread always runs chunk 1, and every chunk no worker was free
# to take (a nested call, `disable_polyester_threads`): the partition is fixed,
# only who runs each chunk changes, so the values never do.
#
# An exception thrown by a chunk is caught where it was thrown, the dispatch
# waits for every other chunk and releases its workers, and then the first
# exception recorded is rethrown on the calling thread — the error a serial
# call would raise, instead of a worker task that dies silently.
# ========================================================================

const _TU = Polyester.ThreadingUtilities
const _PW = Polyester.PolyesterWeave

# One section's chunk job for one argument type. `body(args, c, nchunks)`
# runs chunk `c`; `body` and `args` are rewritten on every dispatch (both are
# immutable values stored inline, so that is a copy, not an allocation).
mutable struct _ThreadJob{B,A}
    body::B
    args::A
    nchunks::Int
    err::Any
    function _ThreadJob{B,A}() where {B,A}
        j = new{B,A}()
        j.err = nothing
        return j
    end
end

@inline function _job_chunk!(j::_ThreadJob, c::Int)
    try
        j.body(j.args, c, j.nchunks)
    catch e
        j.err === nothing && (j.err = e)
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
function _dispatch_job!(j::J) where {J<:_ThreadJob}
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
    err = j.err
    if err !== nothing
        j.err = nothing
        throw(err)
    end
    return nothing
end

# ---- Threading the folds ------------------------------------------------------
# A lane's running accumulation is sequential, but lanes are independent of
# each other — within one fold and across folds (each state slot belongs to
# exactly one equation, so no two lanes share a slot). A `_ScanSection` numbers
# every lane of its folds globally and runs them as static chunks of that
# numbering: a lane is folded whole, ascending, by whichever thread owns it, so
# each slot gets the same value as the serial fold.
# `fused` holds the section's fused scans (scan_fused.jl), a tuple of
# `_FusedScan`s, each its own generated function that computes its terms too.
struct _ScanSection{FS}
    folds::Vector{_ScanFold}
    lanecum::Vector{Int}      # lanes before fold f; the last entry is the total
    tcache::_SecTCache
    fused::FS
end

function _make_scan_section(folds::AbstractVector{_ScanFold}, fused::Tuple = ())
    lanecum = Vector{Int}(undef, length(folds) + 1)
    lanecum[1] = 0
    nslots = 0
    for (k, S) in enumerate(folds)
        nl = S.len >= 1 ? div(length(S.slots), S.len) : 0
        lanecum[k + 1] = lanecum[k] + nl
        nslots += length(S.slots)
    end
    # Fewer than two lanes leave nothing to split; the verdict sees no cells.
    return _ScanSection(collect(folds), lanecum,
                        _SecTCache(lanecum[end] >= 2 ? nslots : 0, true), fused)
end

Base.isempty(s::_ScanSection) = isempty(s.folds) && isempty(s.fused)

struct _ScanChunk
    folds::Vector{_ScanFold}
    lanecum::Vector{Int}
end
function (b::_ScanChunk)(args, c::Int, nchunks::Int)
    du = args[1]
    a, z = _chunk_ordinals(b.lanecum[end], c, nchunks)   # global lanes [a, z)
    @inbounds for f in eachindex(b.folds)
        lo = max(a, b.lanecum[f])
        hi = min(z, b.lanecum[f + 1])
        lo < hi && _apply_scan_fold!(du, b.folds[f], lo - b.lanecum[f] + 1,
                                     hi - b.lanecum[f])
    end
    return nothing
end

# The section's unfused folds, over the terms already in `du`.
function _apply_scan_folds!(du, s::_ScanSection)
    isempty(s.folds) && return nothing
    tc = s.tcache
    if _threads_available() && _sec_prep_threads!(tc).state == 1
        tc.nchunks = min(tc.nchunks, s.lanecum[end])
        _run_chunked!(tc, _ScanChunk(s.folds, s.lanecum), (du,))
    else
        _apply_scan_folds!(du, s.folds)
    end
    return nothing
end

# The whole section: the fused scans (which compute their own terms from
# `u`), then the unfused folds. They write disjoint slots and read none the
# other writes, so the order between them is free.
function _apply_scan_folds!(du, u, p, t, s::_ScanSection)
    _run_fused_scans!(s.fused, du, u, p, t)
    _apply_scan_folds!(du, s)
    return nothing
end
