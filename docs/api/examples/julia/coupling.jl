# Flattening a coupled document into one system.
using EarthSciAST

const FIXTURES = joinpath(@__DIR__, "..", "fixtures")

# region: flatten ops=flatten,flattened_system
doc = load_path(joinpath(FIXTURES, "coupled.esm"))
sys = flatten(doc)
@assert sys isa FlattenedSystem

# Every name is qualified by the component it came from.
@assert collect(keys(sys.state_variables)) == ["Heater.T", "Box.T_air"]
# The param_to_var variable_map replaced the parameter Box.T_wall with the
# state Heater.T, so Box.T_wall is not a parameter of the flattened system...
@assert collect(keys(sys.parameters)) == ["Heater.rate", "Box.k"]

# ...and the equations read Heater.T where Box.T_wall was.
equations = [to_ascii(eq) for eq in sys.equations]
foreach(println, equations)
@assert equations == [
    "D(Heater.T)/Dt = Heater.rate",
    "D(Box.T_air)/Dt = Box.k * (Heater.T - Box.T_air)",
]
# endregion

# region: component_graph ops=component_graph,to_mermaid,to_dot
graph = component_graph(doc)
@assert [n.name for n in graph.nodes] == ["Heater", "Box"]

mermaid = to_mermaid(graph)
println(mermaid)
@assert occursin("Heater -.->|\"T\"| Box", mermaid)
@assert startswith(to_dot(graph), "digraph")
# endregion
