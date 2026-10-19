# Turning a reaction system into ordinary differential equations.
using EarthSciAST

const FIXTURES = joinpath(@__DIR__, "..", "fixtures")

# region: reactions ops=derive_odes,stoichiometric_matrix,reaction_system
doc = load_path(joinpath(FIXTURES, "ozone.esm"))
rs = doc.reaction_systems["Ozone"]
@assert rs isa ReactionSystem
@assert length(rs.reactions) == 2

odes = derive_odes(rs)  # a Model with one D(species)/dt per species
for eq in odes.equations
    println(to_ascii(eq))
end
@assert [to_ascii(eq) for eq in odes.equations] == [
    "D(O3)/Dt = -k1 * NO * O3 + jNO2 * NO2",
    "D(NO)/Dt = -k1 * NO * O3 + jNO2 * NO2",
    "D(NO2)/Dt = k1 * NO * O3 - jNO2 * NO2",
]

# Rows are species (O3, NO, NO2), columns are reactions (R1, R2).
@assert stoichiometric_matrix(rs) == [-1.0 1.0; -1.0 1.0; 1.0 -1.0]
# endregion
