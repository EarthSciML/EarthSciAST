using Test
d = ARGS[1]; cd(d)
for f in ARGS[2:end]
    include(joinpath(d, f))
end
