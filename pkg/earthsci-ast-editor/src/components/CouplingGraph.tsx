/**
 * CouplingGraph - Visual directed graph of the coupling structure
 *
 * Implements a comprehensive graph visualization component that consumes
 * componentGraph() from @earthsciml/ast and provides interactive exploration
 * of system coupling relationships.
 *
 * Reactivity: node positions live in a Solid signal that the d3-force tick
 * handler updates each frame, so the SVG animates as the layout settles.
 * Nodes are draggable via pointer move/up listeners, and the panels are
 * styled with plain CSS (coupling-graph.css) — no Tailwind dependency.
 */

import { Component, createSignal, createMemo, createEffect, on, onMount, onCleanup, Show, For } from 'solid-js';
import type { ComponentNode, CouplingEdge, Graph } from '@earthsciml/ast';
import { forceSimulation, forceLink, forceManyBody, forceCenter, forceCollide } from 'd3-force';
import type { Simulation, SimulationNodeDatum, SimulationLinkDatum } from 'd3-force';
import './coupling-graph.css';

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

/** Node position snapshot published by the simulation tick handler */
type PositionMap = Map<string, { x: number; y: number }>;

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

  // Node positions, written by the simulation tick handler and read by the
  // JSX below — this is what makes the force layout animate.
  const [positions, setPositions] = createSignal<PositionMap>(new Map());

  const pos = (id: string) => positions().get(id) ?? { x: 0, y: 0 };

  // SVG refs
  let svgRef: SVGSVGElement | undefined;
  let simulation: Simulation<GraphNode, GraphEdge> | undefined;

  /** Publish current simulation positions into the reactive signal */
  const publishPositions = () => {
    if (!simulation) return;
    const map: PositionMap = new Map();
    for (const node of simulation.nodes()) {
      map.set(node.id, { x: node.x ?? 0, y: node.y ?? 0 });
    }
    setPositions(map);
  };

  // Initialize D3 force simulation
  const initializeSimulation = () => {
    const nodeData = nodes();
    const edgeData = edges();

    // Initialize positions if not set
    nodeData.forEach(node => {
      if (node.x === undefined) node.x = width() / 2 + (Math.random() - 0.5) * 100;
      if (node.y === undefined) node.y = height() / 2 + (Math.random() - 0.5) * 100;
    });

    simulation = forceSimulation(nodeData)
      .force('link', forceLink(edgeData)
        .id(d => (d as GraphNode).id)
        .distance(100)
        .strength(0.1))
      .force('charge', forceManyBody().strength(-300))
      .force('center', forceCenter(width() / 2, height() / 2))
      .force('collision', forceCollide().radius(30))
      .on('tick', publishPositions);

    publishPositions();
  };

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

  // Teardown for an in-progress drag (also invoked if the component
  // unmounts mid-drag)
  let endActiveDrag: (() => void) | null = null;

  /**
   * Pointer-based node dragging: mousedown pins the node (fx/fy), document
   * mousemove follows the pointer, and mouseup releases the pin.
   */
  const handleNodeMouseDown = (node: GraphNode, event: MouseEvent) => {
    event.preventDefault();
    endActiveDrag?.();

    node.fx = node.x;
    node.fy = node.y;
    simulation?.alphaTarget(0.3).restart();

    const toGraphCoords = (e: MouseEvent) => {
      const rect = svgRef?.getBoundingClientRect();
      const k = transform().k || 1;
      if (!rect) return { x: e.offsetX, y: e.offsetY };
      return {
        x: (e.clientX - rect.left) / k,
        y: (e.clientY - rect.top) / k
      };
    };

    const handleMouseMove = (e: MouseEvent) => {
      const point = toGraphCoords(e);
      node.fx = point.x;
      node.fy = point.y;
      simulation?.alpha(Math.max(simulation.alpha(), 0.3)).restart();
    };

    const handleMouseUp = () => {
      node.fx = null;
      node.fy = null;
      simulation?.alphaTarget(0);
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
      endActiveDrag = null;
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);
    endActiveDrag = handleMouseUp;
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
    endActiveDrag?.();
    simulation?.stop();
    if (svgRef) {
      svgRef.removeEventListener('wheel', handleWheel);
    }
  });

  // Feed graph-data changes into the running simulation (side effect, so an
  // effect — not a memo). Deferred: onMount performs the initial setup.
  createEffect(on([nodes, edges], ([nodeData, edgeData]) => {
    if (!simulation) return;

    nodeData.forEach(node => {
      if (node.x === undefined) node.x = width() / 2 + (Math.random() - 0.5) * 100;
      if (node.y === undefined) node.y = height() / 2 + (Math.random() - 0.5) * 100;
    });

    simulation.nodes(nodeData);
    const linkForce = simulation.force('link');
    if (linkForce && 'links' in linkForce) {
      (linkForce as { links: (edges: GraphEdge[]) => void }).links(edgeData);
    }
    simulation.alpha(0.3).restart();
    publishPositions();
  }, { defer: true }));

  // Render node shapes based on type (positions read reactively)
  const renderNode = (node: GraphNode) => {
    const style = () => getNodeStyle(node);
    const commonHandlers = {
      onClick: () => handleNodeClick(node),
      onMouseEnter: () => setHoveredElement(node.id),
      onMouseLeave: () => setHoveredElement(null),
      onMouseDown: (e: MouseEvent) => handleNodeMouseDown(node, e)
    };

    switch (node.type) {
      case 'model':
      case 'reaction_system':
        return (
          <rect
            x={pos(node.id).x - 25}
            y={pos(node.id).y - 15}
            width="50"
            height="30"
            {...style()}
            {...commonHandlers}
          />
        );

      case 'data_loader':
        return (
          <ellipse
            cx={pos(node.id).x}
            cy={pos(node.id).y}
            rx="25"
            ry="15"
            {...style()}
            {...commonHandlers}
          />
        );

      default:
        return (
          <circle
            cx={pos(node.id).x}
            cy={pos(node.id).y}
            r="20"
            {...style()}
            {...commonHandlers}
          />
        );
    }
  };

  /** Resolve an edge endpoint to a node id */
  const endpointId = (endpoint: GraphEdge['source']): string =>
    typeof endpoint === 'object' ? (endpoint as GraphNode).id : String(endpoint);

  // Render edge with arrowhead
  const renderEdge = (edge: GraphEdge) => {
    const style = () => getEdgeStyle(edge.data);
    const source = () => pos(endpointId(edge.source));
    const target = () => pos(endpointId(edge.target));

    return (
      <line
        x1={source().x}
        y1={source().y}
        x2={target().x}
        y2={target().y}
        {...style()}
        onClick={() => handleEdgeClick(edge.data)}
        onMouseEnter={() => setHoveredElement(edge.data.id)}
        onMouseLeave={() => setHoveredElement(null)}
      />
    );
  };

  // Minimap component
  const Minimap: Component = () => {
    const minimapSize = 150;
    const scale = () => Math.min(minimapSize / width(), minimapSize / height());

    return (
      <div class="coupling-graph-minimap">
        <svg width={minimapSize} height={minimapSize}>
          <rect width="100%" height="100%" fill="white" stroke="gray" />

          {/* Minimap nodes */}
          <For each={nodes()}>
            {(node) => (
              <circle
                cx={pos(node.id).x * scale()}
                cy={pos(node.id).y * scale()}
                r="2"
                fill={getNodeStyle(node).fill as string}
              />
            )}
          </For>

          {/* Viewport indicator */}
          <rect
            x={-transform().x * scale()}
            y={-transform().y * scale()}
            width={width() * scale() / transform().k}
            height={height() * scale() / transform().k}
            fill="none"
            stroke="red"
            stroke-width="1"
          />
        </svg>
      </div>
    );
  };

  return (
    <div class="coupling-graph-container">
      <svg
        ref={(el) => (svgRef = el)}
        width={width()}
        height={height()}
        style={`transform: translate(${transform().x}px, ${transform().y}px) scale(${transform().k})`}
        class="coupling-graph-svg"
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
                x={pos(node.id).x}
                y={pos(node.id).y + 40}
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
        <div class="coupling-graph-details">
          <Show when={selectedNode()}>
            <div>
              <h3>{selectedNode()!.name}</h3>
              <p class="coupling-graph-detail-type">Type: {selectedNode()!.type}</p>
              <Show when={selectedNode()!.description}>
                <p class="coupling-graph-detail-text">{selectedNode()!.description}</p>
              </Show>
              <div class="coupling-graph-detail-meta">
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
              <h3>{selectedEdge()!.label}</h3>
              <p class="coupling-graph-detail-type">Type: {selectedEdge()!.type}</p>
              <p class="coupling-graph-detail-text">
                From: {selectedEdge()!.from} → To: {selectedEdge()!.to}
              </p>
              <Show when={selectedEdge()!.description}>
                <p class="coupling-graph-detail-text">{selectedEdge()!.description}</p>
              </Show>
            </div>
          </Show>

          <button
            onClick={() => {
              setSelectedNode(null);
              setSelectedEdge(null);
            }}
            class="coupling-graph-close-btn"
          >
            Close
          </button>
        </div>
      </Show>
    </div>
  );
};

export default CouplingGraph;
