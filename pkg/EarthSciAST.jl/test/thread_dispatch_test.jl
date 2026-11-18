# The allocation-free chunk dispatch (tree_walk/threading.jl), driven directly:
# every chunk runs exactly once with its own number, a chunk that throws
# rethrows on the calling thread after the others finish, and a job is
# reusable after an error. Holds with any thread count: chunks no worker takes
# run on the calling thread.
using Test
using EarthSciAST
const _TD = EarthSciAST

struct _TDRecord end
(::_TDRecord)(args, c::Int, nchunks::Int) = (args[1][c] = 10c + nchunks; nothing)
struct _TDThrow end
function (::_TDThrow)(args, c::Int, nchunks::Int)
    args[1][c] = c
    c == 3 && throw(ArgumentError("chunk 3"))
    return nothing
end

@testset "thread dispatch" begin
    @testset "every chunk runs once, with its number" begin
        for n in (1, 2, 5, 17)
            seen = zeros(Int, n)
            j = _TD._ThreadJob{_TDRecord, Tuple{Vector{Int}}}()
            j.body = _TDRecord(); j.args = (seen,); j.nchunks = n
            _TD._dispatch_job!(j)
            @test seen == [10c + n for c in 1:n]
        end
    end
    @testset "a chunk that throws rethrows on the caller" begin
        seen = zeros(Int, 6)
        j = _TD._ThreadJob{_TDThrow, Tuple{Vector{Int}}}()
        j.body = _TDThrow(); j.args = (seen,); j.nchunks = 6
        @test_throws ArgumentError _TD._dispatch_job!(j)
        @test seen == collect(1:6)          # the other chunks still ran
        # The error is cleared: the same job dispatches again.
        fill!(seen, 0)
        j.nchunks = 2
        _TD._dispatch_job!(j)
        @test seen == [1, 2, 0, 0, 0, 0]
    end
    @testset "a section's cached jobs" begin
        tc = _TD._SecTCache(100, true)
        j1 = _TD._section_job!(tc, _TDRecord, Tuple{Vector{Int}})
        @test _TD._section_job!(tc, _TDRecord, Tuple{Vector{Int}}) === j1
        j2 = _TD._section_job!(tc, _TDRecord, Tuple{Vector{Float64}})
        @test j2 !== j1
        @test _TD._section_job!(tc, _TDRecord, Tuple{Vector{Int}}) === j1
    end
    @testset "the static partition tiles the ordinals" begin
        for n in (0, 1, 7, 100), nc in (1, 3, 8)
            spans = [_TD._chunk_ordinals(n, c, nc) for c in 1:nc]
            @test first(spans[1]) == 0 && last(spans[end]) == n
            @test all(spans[c][2] == spans[c + 1][1] for c in 1:(nc - 1))
            @test maximum(b - a for (a, b) in spans) - minimum(b - a for (a, b) in spans) <= 1
        end
    end
end
