using Test
src = read("runtests.jl", String)
hdr = src[1:prevind(src, findfirst("@testset verbose = true", src)[1])]
hdr = replace(hdr, "using Test\n"=>"", "using EarthSciAST\n"=>"", "using JSON3\n"=>"",
              "include(\"testutils.jl\")"=>"#")
include_string(Main, hdr, "hdr")
for m in eachmatch(r"shard_include\(\"([A-Za-z0-9_]+_test\.jl)\"\)", src); shard_claim(m.captures[1]); end
shard_claim("(inline) Fixture sweeps")
println("SHARDS=$TEST_SHARDS SHARD=$TEST_SHARD units=$(length(SHARD_UNITS)) executed=$(length(SHARD_EXECUTED))")
include(joinpath(pwd(), "shard_partition_test.jl"))
