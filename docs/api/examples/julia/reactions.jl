# Turning a reaction system into ordinary differential equations.
using EarthSciAST

const FIXTURES = joinpath(@__DIR__, "..", "fixtures")

# region: reactions ops=derive_odes,stoichiometric_matrix,reaction_system
doc = load_path(joinpath(FIXTURES, "ozone.esm"))
rs = doc.reaction_systems["Ozone"]
@assert rs isa ReactionSystem
@assert length(rs.reactions) == 2

odes = derive_odes(rs)  # a Model with one D(species)/dt per species
# d[NO2]/dt = k1 [NO][O3] - jNO2 [NO2], compared as canonical JSON.
no2 = odes.equations[3]
println(canonical_json(no2.rhs))
@assert canonical_json(no2.rhs) ==
    """{"args":[{"args":["NO","O3","k1"],"op":"*"},{"args":[-1,"NO2","jNO2"],"op":"*"}],"op":"+"}"""

# Rows are species (O3, NO, NO2), columns are reactions (R1, R2).
@assert stoichiometric_matrix(rs) == [-1.0 1.0; -1.0 1.0; 1.0 -1.0]
# endregion
