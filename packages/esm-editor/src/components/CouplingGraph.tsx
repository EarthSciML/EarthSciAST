/**
 * CouplingGraph - Visual directed graph of the coupling structure
 *
 * Implements a comprehensive graph visualization component that consumes
 * componentGraph() from earthsci-toolkit and provides interactive exploration
 * of system coupling relationships.
 */

import { Component, createSignal, createMemo, onMount, onCleanup, Show, For } from 'solid-js';
import type { ComponentNode, CouplingEdge, Graph } from 'earthsci-toolkit';
import { forceSimulation, forceLink, forceManyBody, forceCenter, forceCollide } from 'd3-force';
import type { Simulation, SimulationNodeDatum, SimulationLinkDatum } from 'd3-force';


export interface CouplingGraphProps {
  /** The graph data to visualize */
  graph: Graph<ComponentNode, CouplingEdge>;

  /** Width of the graph container */
  width?: number;

  /** Height of the graph container */
  height?: number;

  /** Optional callback when a node is selected */
  onNodeSelect?: (node: ComponentNode) => void;

  /** Optional callback when an edge is selected */
  onEdgeSelect?: (edge: CouplingEdge) => void;

  /** Whether to show the minimap */
  showMinimap?: boolean;
}

interface GraphNode extends ComponentNode, SimulationNodeDatum {
  // ComponentNode already has id, name, type properties
  // SimulationNodeDatum provides x?, y?, fx?, fy?, vx?, vy? properties
}

interface GraphEdge extends SimulationLinkDatum<GraphNode> {
  data: CouplingEdge;
}

export const CouplingGraph: Component<CouplingGraphProps> = (props) => {
  // Default dimensions
  const width = () => props.width ?? 800;
  const height = () => props.height ?? 600;

  // Reactive graph data
  const nodes = createMemo(() => [...props.graph.nodes] as GraphNode[]);
  const edges = createMemo(() =>
    props.graph.edges.map(edge => ({
      source: edge.source,
      target: edge.target,
      data: edge.data
    })) as GraphEdge[]
  );

  // Component state
  const [selectedNode, setSelectedNode] = createSignal<ComponentNode | null>(null);
  const [selectedEdge, setSelectedEdge] = createSignal<CouplingEdge | null>(null);
  const [hoveredElement, setHoveredElement] = createSignal<string | null>(null);
  const [transform, setTransform] = createSignal({ x: 0, y: 0, k: 1 });

  // SVG refs
  let svgRef: SVGSVGElement | undefined;
  let simulation: Simulation<GraphNode, GraphEdge> | undefined;

  // Initialize D3 force simulation
  const initializeSimulation = () => {
    const nodeData = nodes();
    const edgeData = edges();

    simulation = forceSimulation(nodeData)
      .force('link', forceLink(edgeData)
        .id(d => (d as GraphNode).id)
        .distance(100)
        .strength(0.1))
      .force('charge', forceManyBody().strength(-300))
      .force('center', forceCenter(width() / 2, height() / 2))
      .force('collision', forceCollide().radius(30))
      .on('tick', () => {
        // Force reactive update
        setNodes([...nodeData]);
      });

    // Initialize positions if not set
    nodeData.forEach(node => {
      if (node.x === undefined) node.x = width() / 2 + (Math.random() - 0.5) * 100;
      if (node.y === undefined) node.y = height() / 2 + (Math.random() - 0.5) * 100;
    });
  };

  // Force re-render signal for simulation updates
  const [, setNodes] = createSignal(nodes(), { equals: false });

  // Node styling based on type
  const getNodeStyle = (node: ComponentNode) => {
    const baseStyle = {
      stroke: '#333',
      'stroke-width': selectedNode()?.id === node.id ? 3 : 1,
      cursor: 'pointer',
      filter: hoveredElement() === node.id ? 'brightness(1.2)' : 'none'
    };

    switch (node.type) {
      case 'model':
        return { ...baseStyle, fill: '#4CAF50', rx: 5, ry: 5 }; // Green rectangle
      case 'data_loader':
        return { ...baseStyle, fill: '#2196F3' }; // Blue ellipse
      case 'reaction_system':
        return { ...baseStyle, fill: '#9C27B0' }; // Purple rectangle
      default:
        return { ...baseStyle, fill: '#607D8B' };
    }
  };

  // Edge styling based on coupling type
  const getEdgeStyle = (edge: CouplingEdge) => {
    const baseStyle = {
      stroke: '#999',
      'stroke-width': selectedEdge()?.id === edge.id ? 3 : 1,
      cursor: 'pointer',
      'marker-end': 'url(#arrowhead)',
      filter: hoveredElement() === edge.id ? 'brightness(1.5)' : 'none'
    };

    switch (edge.type) {
      case 'variable_map':
        return { ...baseStyle, 'stroke-dasharray': 'none' };
      case 'operator_compose':
        return { ...baseStyle, 'stroke-dasharray': '5,5' };
      case 'couple':
        return { ...baseStyle, 'stroke-dasharray': '10,2' };
      default:
        return baseStyle;
    }
  };

  // Event handlers
  const handleNodeClick = (node: ComponentNode) => {
    setSelectedNode(prev => prev?.id === node.id ? null : node);
    setSelectedEdge(null);
    props.onNodeSelect?.(node);
  };

  const handleEdgeClick = (edge: CouplingEdge) => {
    setSelectedEdge(prev => prev?.id === edge.id ? null : edge);
    setSelectedNode(null);
    props.onEdgeSelect?.(edge);
  };

  const handleNodeDrag = (node: GraphNode, event: MouseEvent) => {
    if (simulation) {
      node.fx = event.offsetX;
      node.fy = event.offsetY;
      simulation.alpha(0.3).restart();
    }
  };

  // Zoom and pan functionality
  const handleWheel = (event: WheelEvent) => {
    event.preventDefault();
    const delta = event.deltaY > 0 ? 0.9 : 1.1;
    const newTransform = transform();
    setTransform({
      ...newTransform,
      k: Math.max(0.1, Math.min(3, newTransform.k * delta))
    });
  };

  // Lifecycle management
  onMount(() => {
    initializeSimulation();
    if (svgRef) {
      svgRef.addEventListener('wheel', handleWheel, { passive: false });
    }
  });

  onCleanup(() => {
    simulation?.stop();
    if (svgRef) {
      svgRef.removeEventListener('wheel', handleWheel);
    }
  });

  // Reactive simulation updates
  createMemo(() => {
    if (simulation) {
      simulation.nodes(nodes());
      const linkForce = simulation.force('link');
      if (linkForce && 'links' in linkForce) {
        (linkForce as any).links(edges());
      }
      simulation.alpha(0.3).restart();
    }
  });

  // Render node shapes based on type
  const renderNode = (node: GraphNode) => {
    const style = getNodeStyle(node);
    const x = node.x ?? 0;
    const y = node.y ?? 0;

    switch (node.type) {
      case 'model':
      case 'reaction_system':
        return (
          <rect
            x={x - 25}
            y={y - 15}
            width="50"
            height="30"
            {...style}
            onClick={() => handleNodeClick(node)}
            onMouseEnter={() => setHoveredElement(node.id)}
            onMouseLeave={() => setHoveredElement(null)}
            onMouseDown={(e) => handleNodeDrag(node, e)}
          />
        );

      case 'data_loader':
        return (
          <ellipse
            cx={x}
            cy={y}
            rx="25"
            ry="15"
            {...style}
            onClick={() => handleNodeClick(node)}
            onMouseEnter={() => setHoveredElement(node.id)}
            onMouseLeave={() => setHoveredElement(null)}
            onMouseDown={(e) => handleNodeDrag(node, e)}
          />
        );

      default:
        return (
          <circle
            cx={x}
            cy={y}
            r="20"
            {...style}
            onClick={() => handleNodeClick(node)}
            onMouseEnter={() => setHoveredElement(node.id)}
            onMouseLeave={() => setHoveredElement(null)}
            onMouseDown={(e) => handleNodeDrag(node, e)}
          />
        );
    }
  };

  // Render edge with arrowhead
  const renderEdge = (edge: GraphEdge) => {
    const source = typeof edge.source === 'object' ? edge.source : nodes().find(n => n.id === edge.source);
    const target = typeof edge.target === 'object' ? edge.target : nodes().find(n => n.id === edge.target);

    if (!source?.x || !source?.y || !target?.x || !target?.y) return null;

    const style = getEdgeStyle(edge.data);
    return (
      <line
        x1={source.x}
        y1={source.y}
        x2={target.x}
        y2={target.y}
        {...style}
        onClick={() => handleEdgeClick(edge.data)}
        onMouseEnter={() => setHoveredElement(edge.data.id)}
        onMouseLeave={() => setHoveredElement(null)}
      />
    );
  };

  // Minimap component
  const Minimap: Component = () => {
    const minimapSize = 150;
    const scale = Math.min(minimapSize / width(), minimapSize / height());

    return (
      <div class="absolute top-4 right-4 border border-gray-300 bg-white bg-opacity-90">
        <svg width={minimapSize} height={minimapSize}>
          <rect width="100%" height="100%" fill="white" stroke="gray" />

          {/* Minimap nodes */}
          <For each={nodes()}>
            {(node) => (
              <circle
                cx={(node.x ?? 0) * scale}
                cy={(node.y ?? 0) * scale}
                r="2"
                fill={getNodeStyle(node).fill as string}
              />
            )}
          </For>

          {/* Viewport indicator */}
          <rect
            x={-transform().x * scale}
            y={-transform().y * scale}
            width={width() * scale / transform().k}
            height={height() * scale / transform().k}
            fill="none"
            stroke="red"
            stroke-width="1"
          />
        </svg>
      </div>
    );
  };

  return (
    <div class="relative w-full h-full">
      <svg
        ref={svgRef}
        width={width()}
        height={height()}
        style={`transform: translate(${transform().x}px, ${transform().y}px) scale(${transform().k})`}
        class="border border-gray-300"
      >
        {/* Arrow marker definition */}
        <defs>
          <marker
            id="arrowhead"
            markerWidth="10"
            markerHeight="7"
            refX="9"
            refY="3.5"
            orient="auto"
          >
            <polygon
              points="0 0, 10 3.5, 0 7"
              fill="#999"
            />
          </marker>
        </defs>

        {/* Render edges */}
        <g class="edges">
          <For each={edges()}>
            {(edge) => renderEdge(edge)}
          </For>
        </g>

        {/* Render nodes */}
        <g class="nodes">
          <For each={nodes()}>
            {(node) => renderNode(node)}
          </For>
        </g>

        {/* Node labels */}
        <g class="labels">
          <For each={nodes()}>
            {(node) => (
              <text
                x={node.x ?? 0}
                y={(node.y ?? 0) + 40}
                text-anchor="middle"
                font-size="12"
                fill="black"
                pointer-events="none"
              >
                {node.name}
              </text>
            )}
          </For>
        </g>
      </svg>

      {/* Minimap */}
      <Show when={props.showMinimap !== false}>
        <Minimap />
      </Show>

      {/* Selection details panel */}
      <Show when={selectedNode() || selectedEdge()}>
        <div class="absolute bottom-4 left-4 p-4 bg-white border border-gray-300 rounded shadow-lg max-w-md">
          <Show when={selectedNode()}>
            <div>
              <h3 class="font-bold text-lg">{selectedNode()!.name}</h3>
              <p class="text-sm text-gray-600">Type: {selectedNode()!.type}</p>
              <Show when={selectedNode()!.description}>
                <p class="text-sm mt-2">{selectedNode()!.description}</p>
              </Show>
              <div class="text-xs mt-2">
                <div>Variables: {selectedNode()!.metadata.var_count}</div>
                <div>Equations: {selectedNode()!.metadata.eq_count}</div>
                <Show when={selectedNode()!.metadata.species_count > 0}>
                  <div>Species: {selectedNode()!.metadata.species_count}</div>
                </Show>
              </div>
            </div>
          </Show>

          <Show when={selectedEdge()}>
            <div>
              <h3 class="font-bold text-lg">{selectedEdge()!.label}</h3>
              <p class="text-sm text-gray-600">Type: {selectedEdge()!.type}</p>
              <p class="text-sm">From: {selectedEdge()!.from} → To: {selectedEdge()!.to}</p>
              <Show when={selectedEdge()!.description}>
                <p class="text-sm mt-2">{selectedEdge()!.description}</p>
              </Show>
            </div>
          </Show>

          <button
            onClick={() => {
              setSelectedNode(null);
              setSelectedEdge(null);
            }}
            class="mt-2 px-2 py-1 text-xs bg-gray-200 hover:bg-gray-300 rounded"
          >
            Close
          </button>
        </div>
      </Show>
    </div>
  );
};

export default CouplingGraph;