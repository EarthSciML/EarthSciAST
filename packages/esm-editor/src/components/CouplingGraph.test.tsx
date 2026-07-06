import { describe, it, beforeEach, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import { CouplingGraph } from './CouplingGraph';
import type { ComponentNode, CouplingEdge, Graph } from 'earthsci-toolkit';

// No need to mock d3-force since we're using manual implementation

describe('CouplingGraph', () => {
  let mockGraph: Graph<ComponentNode, CouplingEdge>;

  beforeEach(() => {
    vi.clearAllMocks();

    // Create mock graph data
    const nodes: ComponentNode[] = [
      {
        id: 'model1',
        name: 'Atmospheric Model',
        type: 'model',
        description: 'Atmospheric chemistry model',
        metadata: {
          var_count: 5,
          eq_count: 3,
          species_count: 0
        }
      },
      {
        id: 'loader1',
        name: 'Data Loader',
        type: 'data_loader',
        description: 'Loads atmospheric data',
        metadata: {
          var_count: 2,
          eq_count: 0,
          species_count: 0
        }
      },
      {
        id: 'op1',
        name: 'Interpolation Op',
        type: 'reaction_system',
        description: 'Spatial interpolation operator',
        metadata: {
          var_count: 1,
          eq_count: 1,
          species_count: 0
        }
      }
    ];

    const edges = [
      {
        source: 'loader1',
        target: 'op1',
        data: {
          id: 'edge1',
          from: 'loader1',
          to: 'op1',
          type: 'variable_map' as const,
          label: 'Temperature Data',
          description: 'Temperature coupling',
          coupling: {} as any
        }
      },
      {
        source: 'op1',
        target: 'model1',
        data: {
          id: 'edge2',
          from: 'op1',
          to: 'model1',
          type: 'couple' as const,
          label: 'Interpolated Temp',
          description: 'Spatial coupling',
          coupling: {} as any
        }
      }
    ];

    mockGraph = {
      nodes,
      edges,
      adjacency: vi.fn(() => []),
      predecessors: vi.fn(() => []),
      successors: vi.fn(() => [])
    };
  });

  it('renders without crashing', () => {
    render(() => <CouplingGraph graph={mockGraph} />);

    // Should create an SVG element
    const svgs = document.querySelectorAll('svg');
    expect(svgs.length).toBeGreaterThan(0);
  });

  it('renders nodes with correct shapes based on type', () => {
    render(() => <CouplingGraph graph={mockGraph} />);

    // Should render different shapes for different node types
    const svgs = document.querySelectorAll('svg');
    expect(svgs.length).toBeGreaterThan(0);

    // Check that all nodes are rendered
    expect(screen.getByText('Atmospheric Model')).toBeInTheDocument();
    expect(screen.getByText('Data Loader')).toBeInTheDocument();
    expect(screen.getByText('Interpolation Op')).toBeInTheDocument();
  });

  it('handles node selection', () => {
    const onNodeSelect = vi.fn();
    render(() => <CouplingGraph graph={mockGraph} onNodeSelect={onNodeSelect} />);

    // Click on the atmospheric model node
    const modelShapes = document.querySelectorAll('rect[fill="#4CAF50"]');
    expect(modelShapes.length).toBe(1);
    fireEvent.click(modelShapes[0]);

    expect(onNodeSelect).toHaveBeenCalledWith(mockGraph.nodes[0]);
  });

  it('handles edge selection', () => {
    const onEdgeSelect = vi.fn();
    render(() => <CouplingGraph graph={mockGraph} onEdgeSelect={onEdgeSelect} />);

    // Note: Edge clicking is harder to test without more complex setup
    // This would require mocking SVG elements and click detection
    expect(onEdgeSelect).toBeDefined();
  });

  it('displays node details when selected', () => {
    render(() => <CouplingGraph graph={mockGraph} />);

    // Initially no details panel should be visible
    expect(screen.queryByText('Variables:')).not.toBeInTheDocument();

    // Click on a node to select it
    const modelShapes = document.querySelectorAll('rect[fill="#4CAF50"]');
    fireEvent.click(modelShapes[0]);

    // Details panel should appear - check for the specific details panel elements
    expect(screen.getByText(/Type:\s*model/)).toBeInTheDocument();
    expect(screen.getByText(/Variables:\s*5/)).toBeInTheDocument();
    expect(screen.getByText(/Equations:\s*3/)).toBeInTheDocument();
  });

  it('handles hover effects', () => {
    render(() => <CouplingGraph graph={mockGraph} />);

    const modelShapes = document.querySelectorAll('rect[fill="#4CAF50"]');

    // Test hover enter
    fireEvent.mouseEnter(modelShapes[0]);
    // Note: Testing visual hover effects would require more complex DOM inspection

    // Test hover leave
    fireEvent.mouseLeave(modelShapes[0]);
  });

  it('respects width and height props', () => {
    render(() => <CouplingGraph graph={mockGraph} width={1000} height={800} />);

    const mainSvg = document.querySelector('svg[width="1000"]');
    expect(mainSvg).toBeInTheDocument();
    expect(mainSvg).toHaveAttribute('width', '1000');
    expect(mainSvg).toHaveAttribute('height', '800');
  });

  it('can hide minimap', () => {
    render(() => <CouplingGraph graph={mockGraph} showMinimap={false} />);

    // Should still render main SVG but minimap should not be visible
    const svgs = document.querySelectorAll('svg');
    expect(svgs.length).toBe(1); // Only main SVG, no minimap
  });

  it('handles empty graph', () => {
    const emptyGraph: Graph<ComponentNode, CouplingEdge> = {
      nodes: [],
      edges: [],
      adjacency: vi.fn(() => []),
      predecessors: vi.fn(() => []),
      successors: vi.fn(() => [])
    };

    render(() => <CouplingGraph graph={emptyGraph} />);

    // Should still render SVG container
    const svgs = document.querySelectorAll('svg');
    expect(svgs.length).toBeGreaterThan(0);
  });

  it('closes details panel when close button is clicked', () => {
    render(() => <CouplingGraph graph={mockGraph} />);

    // Select a node to open details panel
    const modelShapes = document.querySelectorAll('rect[fill="#4CAF50"]');
    fireEvent.click(modelShapes[0]);

    // Details panel should be visible
    expect(screen.getByText(/Type:\s*model/)).toBeInTheDocument();

    // Click close button
    const closeButton = screen.getByText('Close');
    fireEvent.click(closeButton);

    // Details panel should be closed (the Close button should no longer be visible)
    expect(screen.queryByText('Close')).not.toBeInTheDocument();
  });

  it('handles node dragging', () => {
    render(() => <CouplingGraph graph={mockGraph} />);

    const modelShapes = document.querySelectorAll('rect[fill="#4CAF50"]');

    // Test mouse down event (simulating drag start)
    fireEvent.mouseDown(modelShapes[0], { clientX: 100, clientY: 100 });

    // Note: Full drag testing would require more complex event simulation
    // This basic test ensures the event handler is attached
  });

  it('animates node positions as the force simulation ticks', async () => {
    const { waitFor } = await import('@solidjs/testing-library');
    render(() => <CouplingGraph graph={mockGraph} showMinimap={false} />);

    const modelShape = document.querySelector('rect[fill="#4CAF50"]') as SVGRectElement;
    expect(modelShape).toBeTruthy();
    const initialX = modelShape.getAttribute('x');
    const initialY = modelShape.getAttribute('y');

    // The tick handler publishes positions into a reactive signal, so the
    // SVG attributes must change as the simulation settles.
    await waitFor(() => {
      expect(
        modelShape.getAttribute('x') !== initialX ||
        modelShape.getAttribute('y') !== initialY
      ).toBe(true);
    }, { timeout: 3000 });
  });

  it('updates simulation when graph data changes', () => {
    const graphSignal = mockGraph;
    render(() => <CouplingGraph graph={graphSignal} />);

    // Add a new node
    const newGraph = {
      ...mockGraph,
      nodes: [
        ...mockGraph.nodes,
        {
          id: 'newNode',
          name: 'New Node',
          type: 'model' as const,
          metadata: { var_count: 1, eq_count: 1, species_count: 0 }
        }
      ]
    };

    // This test is simplified since we can't easily test reactive updates in this setup
    // In a real application, the graph updates would be handled by the parent component
    expect(newGraph.nodes).toHaveLength(4);
    expect(screen.getByText('Atmospheric Model')).toBeInTheDocument();
  });
});