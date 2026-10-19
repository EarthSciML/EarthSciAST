// Draw the coupling between a document's components.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { loadPath, componentGraph, toMermaid, toDot } from '@earthsciml/ast'

const fixture = (name: string): string => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url))

// region: component_graph ops=component_graph,to_mermaid,to_dot
const doc = loadPath(fixture('coupled.esm'))
const graph = componentGraph(doc)

assert.deepEqual(graph.nodes.map((n) => n.id), ['Heater', 'Box'])
assert.deepEqual(graph.successors('Heater'), ['Box'])
const [edge] = graph.edges
assert.equal(edge.data.type, 'variable_map')

// Render for a Markdown page or for Graphviz.
const mermaid = toMermaid(graph)
assert.match(mermaid, /Heater -\.->\|T\| Box/)
assert.match(toDot(graph), /"Heater" -> "Box"/)
// endregion
