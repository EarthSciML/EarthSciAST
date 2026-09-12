# The shard split is only safe if it PARTITIONS the unit list in runtests.jl:
# every unit owned by exactly one shard, so that running all shards runs the
# whole suite exactly once — nothing dropped, nothing run twice. That property
# is the entire rigor argument for sharding, so it is asserted here rather than
# argued in a comment.
#
# This file is included UNCONDITIONALLY, after every `shard_include` /
# `shard_claim` call has registered itself. Both of those matter: a partition
# proven only in shard 1 says nothing about shard 2, and a registry read before
# the list finishes is incomplete.
#
# Note what is being checked and what is not. The claim is about the ASSIGNMENT
# FUNCTION over the registered units — which is exactly the thing that decides
# whether a test runs — not about the contents of any test file.
using Test

@testset "shard partition (ESM_TEST_SHARDS/ESM_TEST_SHARD)" begin
    units = SHARD_UNITS

    @test !isempty(units)
    @test length(units) >= 200  # the list is ~217 units; a collapse is a bug

    # A unit registered twice would mean a file included twice, which would
    # break the disjointness claim below no matter how the owner function
    # behaves. Check it separately so the failure reads for what it is.
    @testset "every unit is registered exactly once" begin
        dupes = [u for u in unique(units) if count(==(u), units) > 1]
        @test isempty(dupes)
    end

    # The partition property itself, for the shard count actually configured
    # AND for a spread of others — the function must be correct for whatever
    # `ESM_TEST_SHARDS` CI is set to next, not just for today's value.
    @testset "shards partition the unit list (n = $n)" for n in
                                                          unique([TEST_SHARDS, 1, 2, 3, 4, 7])
        owners = [shard_owner(i, n) for i in eachindex(units)]

        # Total and in range: every unit is assigned, to a real shard.
        @test length(owners) == length(units)
        @test all(o -> 1 <= o <= n, owners)

        parts = [Set(units[i] for i in eachindex(units) if owners[i] == s) for s in 1:n]

        # Union covers everything, and the sizes add up — together with
        # disjointness below, that is exactly "partition".
        @test reduce(union, parts) == Set(units)
        @test sum(length, parts) == length(units)

        # Pairwise disjoint: nothing runs twice.
        for a in 1:n, b in (a + 1):n
            @test isempty(intersect(parts[a], parts[b]))
        end
    end

    # …and that THIS process actually honoured the assignment: it ran its own
    # units, in order, and none of anyone else's. Without this the checks above
    # would only prove the arithmetic, not that `shard_claim` dispatches on it.
    @testset "this shard ran exactly its own units" begin
        expected = [units[i] for i in eachindex(units) if shard_owner(i) == TEST_SHARD]
        @test SHARD_EXECUTED == expected
        if TEST_SHARDS == 1
            @test SHARD_EXECUTED == units
        end
    end
end
