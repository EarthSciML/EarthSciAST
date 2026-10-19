//! Graphs of a document: which components couple to which, and which
//! variables an equation reads.

use earthsci_ast::{component_graph, expression_graph, load_path, to_dot, to_json_graph, to_mermaid};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: component_graph ops=component_graph,to_dot,to_mermaid
    let doc = load_path(fixture("coupled.esm"))?;
    let graph = component_graph(&doc);
    let ids: Vec<&str> = graph.nodes.iter().map(|n| n.id.as_str()).collect();
    assert_eq!(ids, ["Box", "Heater"]);
    assert_eq!(graph.edges.len(), 1);
    assert_eq!((graph.edges[0].from.as_str(), graph.edges[0].to.as_str()), ("Heater", "Box"));

    let dot = to_dot(&graph);
    assert!(dot.starts_with("digraph"));
    assert!(to_mermaid(&graph).contains("Heater"));
    // endregion

    // region: expression_graph ops=expression_graph,to_json_graph
    let doc = load_path(fixture("decay.esm"))?;
    let model = &doc.models.as_ref().unwrap()["Decay"];
    let graph = expression_graph(model);
    let json = to_json_graph(&graph);
    println!("{json}");
    assert!(json.contains("\"lambda\"") && json.contains("\"N\""));
    // endregion

    Ok(())
}
