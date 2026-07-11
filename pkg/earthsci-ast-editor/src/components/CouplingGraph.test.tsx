import { describe, it, beforeEach, expect, vi } from 'vitest'
import { createSignal } from 'solid-js'
import { render, screen, fireEvent } from '@solidjs/testing-library'
import { CouplingGraph, NODE_FILL } from './CouplingGraph'
import type { ComponentNode, CouplingEdge, Graph } from '@earthsciml/ast'

/** Query the model node's rendered shape by its fill (no hard-coded hex). */
const modelRectSelector = `rect[fill="${NODE_FILL.model}"]`

// No need to mock d3-force since we're using manual implementation

describe('CouplingGraph', () => {
  let mockGraph: Graph<ComponentNode, CouplingEdge>

  beforeEach(() => {
    vi.clearAllMocks()

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
          species_count: 0,
        },
      },
      {
        id: 'loader1',
        name: 'Data Loader',
        type: 'data_loader',
        description: 'Loads atmospheric data',
        metadata: {
          var_count: 2,
          eq_count: 0,
          species_count: 0,
        },
      },
      {
        id: 'op1',
        name: 'Interpolation Op',
        type: 'reaction_system',
        description: 'Spatial interpolation operator',
        metadata: {
          var_count: 1,
          eq_count: 1,
          species_count: 0,
        },
      },
    ]

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
          coupling: {} as any,
        },
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
          coupling: {} as any,
        },
      },
    ]

    mockGraph = {
      nodes,
      edges,
      adjacency: vi.fn(() => []),
      predecessors: vi.fn(() => []),
      successors: vi.fn(() => []),
    }
  })

  it('renders without crashing', () => {
    render(() => <CouplingGraph graph={mockGraph} />)

    // Should create an SVG element
    const svgs = document.querySelectorAll('svg')
    expect(svgs.length).toBeGreaterThan(0)
  })

  it('renders nodes with correct shapes based on type', () => {
    render(() => <CouplingGraph graph={mockGraph} />)

    // Should render different shapes for different node types
    const svgs = document.querySelectorAll('svg')
    expect(svgs.length).toBeGreaterThan(0)

    // Check that all nodes are rendered
    expect(screen.getByText('Atmospheric Model')).toBeInTheDocument()
    expect(screen.getByText('Data Loader')).toBeInTheDocument()
    expect(screen.getByText('Interpolation Op')).toBeInTheDocument()
  })

  it('handles node selection', () => {
    const onNodeSelect = vi.fn()
    render(() => <CouplingGraph graph={mockGraph} onNodeSelect={onNodeSelect} />)

    // Click on the atmospheric model node
    const modelShapes = document.querySelectorAll(modelRectSelector)
    expect(modelShapes.length).toBe(1)
    fireEvent.click(modelShapes[0])

    expect(onNodeSelect).toHaveBeenCalledWith(mockGraph.nodes[0])
  })

  it('handles edge selection', () => {
    const onEdgeSelect = vi.fn()
    render(() => <CouplingGraph graph={mockGraph} onEdgeSelect={onEdgeSelect} />)

    // Edges render as <line> elements inside the .edges group, in edge order.
    const lines = document.querySelectorAll('.edges line')
    expect(lines.length).toBe(mockGraph.edges.length)

    fireEvent.click(lines[0])
    expect(onEdgeSelect).toHaveBeenCalledWith(mockGraph.edges[0].data)

    // Selecting the edge shows its details (label + coupling type).
    expect(screen.getByText('Temperature Data')).toBeInTheDocument()
    expect(screen.getByText(/Type:\s*variable_map/)).toBeInTheDocument()
  })

  it('displays node details when selected', () => {
    render(() => <CouplingGraph graph={mockGraph} />)

    // Initially no details panel should be visible
    expect(screen.queryByText('Variables:')).not.toBeInTheDocument()

    // Click on a node to select it
    const modelShapes = document.querySelectorAll(modelRectSelector)
    fireEvent.click(modelShapes[0])

    // Details panel should appear - check for the specific details panel elements
    expect(screen.getByText(/Type:\s*model/)).toBeInTheDocument()
    expect(screen.getByText(/Variables:\s*5/)).toBeInTheDocument()
    expect(screen.getByText(/Equations:\s*3/)).toBeInTheDocument()
  })

  it('applies a brightness filter to the hovered node', () => {
    render(() => <CouplingGraph graph={mockGraph} />)

    const modelShape = document.querySelector(modelRectSelector) as SVGRectElement
    expect(modelShape.getAttribute('filter')).toBe('none')

    fireEvent.mouseEnter(modelShape)
    expect(modelShape.getAttribute('filter')).toBe('brightness(1.2)')

    fireEvent.mouseLeave(modelShape)
    expect(modelShape.getAttribute('filter')).toBe('none')
  })

  it('respects width and height props', () => {
    render(() => <CouplingGraph graph={mockGraph} width={1000} height={800} />)

    const mainSvg = document.querySelector('svg[width="1000"]')
    expect(mainSvg).toBeInTheDocument()
    expect(mainSvg).toHaveAttribute('width', '1000')
    expect(mainSvg).toHaveAttribute('height', '800')
  })

  it('can hide minimap', () => {
    render(() => <CouplingGraph graph={mockGraph} showMinimap={false} />)

    // Should still render main SVG but minimap should not be visible
    const svgs = document.querySelectorAll('svg')
    expect(svgs.length).toBe(1) // Only main SVG, no minimap
  })

  it('handles empty graph', () => {
    const emptyGraph: Graph<ComponentNode, CouplingEdge> = {
      nodes: [],
      edges: [],
      adjacency: vi.fn(() => []),
      predecessors: vi.fn(() => []),
      successors: vi.fn(() => []),
    }

    render(() => <CouplingGraph graph={emptyGraph} />)

    // Should still render SVG container
    const svgs = document.querySelectorAll('svg')
    expect(svgs.length).toBeGreaterThan(0)
  })

  it('closes details panel when close button is clicked', () => {
    render(() => <CouplingGraph graph={mockGraph} />)

    // Select a node to open details panel
    const modelShapes = document.querySelectorAll(modelRectSelector)
    fireEvent.click(modelShapes[0])

    // Details panel should be visible
    expect(screen.getByText(/Type:\s*model/)).toBeInTheDocument()

    // Click close button
    const closeButton = screen.getByText('Close')
    fireEvent.click(closeButton)

    // Details panel should be closed (the Close button should no longer be visible)
    expect(screen.queryByText('Close')).not.toBeInTheDocument()
  })

  it('drags a node so its shape follows the pointer', async () => {
    const { waitFor } = await import('@solidjs/testing-library')
    render(() => <CouplingGraph graph={mockGraph} showMinimap={false} />)

    const modelShape = document.querySelector(modelRectSelector) as SVGRectElement

    // mousedown pins the node, then a document mousemove drags it. jsdom's
    // getBoundingClientRect returns 0s and k=1, so graph coords == client coords.
    fireEvent.mouseDown(modelShape, { clientX: 0, clientY: 0 })
    fireEvent.mouseMove(document, { clientX: 300, clientY: 200 })

    // The rect is drawn at (x-25, y-15); pinned to (300, 200) it settles at
    // (275, 185) once the simulation ticks.
    await waitFor(
      () => {
        expect(modelShape.getAttribute('x')).toBe('275')
        expect(modelShape.getAttribute('y')).toBe('185')
      },
      { timeout: 3000 },
    )

    fireEvent.mouseUp(document)
  })

  it('animates node positions as the force simulation ticks', async () => {
    const { waitFor } = await import('@solidjs/testing-library')
    render(() => <CouplingGraph graph={mockGraph} showMinimap={false} />)

    const modelShape = document.querySelector(modelRectSelector) as SVGRectElement
    expect(modelShape).toBeTruthy()
    const initialX = modelShape.getAttribute('x')
    const initialY = modelShape.getAttribute('y')

    // The tick handler publishes positions into a reactive signal, so the
    // SVG attributes must change as the simulation settles.
    await waitFor(
      () => {
        expect(
          modelShape.getAttribute('x') !== initialX || modelShape.getAttribute('y') !== initialY,
        ).toBe(true)
      },
      { timeout: 3000 },
    )
  })

  it('renders newly added nodes when the graph prop changes', async () => {
    const { waitFor } = await import('@solidjs/testing-library')
    const [graph, setGraph] = createSignal(mockGraph)
    render(() => <CouplingGraph graph={graph()} showMinimap={false} />)

    expect(screen.queryByText('New Node')).not.toBeInTheDocument()

    setGraph({
      ...mockGraph,
      nodes: [
        ...mockGraph.nodes,
        {
          id: 'newNode',
          name: 'New Node',
          type: 'model' as const,
          metadata: { var_count: 1, eq_count: 1, species_count: 0 },
        },
      ],
    })

    await waitFor(() => {
      expect(screen.getByText('New Node')).toBeInTheDocument()
    })
    // Existing nodes remain rendered after the reactive update.
    expect(screen.getByText('Atmospheric Model')).toBeInTheDocument()
  })

  it('does not mutate the caller-owned node objects (props stay immutable)', async () => {
    const { waitFor } = await import('@solidjs/testing-library')
    render(() => <CouplingGraph graph={mockGraph} showMinimap={false} />)

    const modelShape = document.querySelector(modelRectSelector) as SVGRectElement
    const initialX = modelShape.getAttribute('x')
    const initialY = modelShape.getAttribute('y')

    // Let the force simulation run; it writes positions onto its own copies.
    await waitFor(
      () => {
        expect(
          modelShape.getAttribute('x') !== initialX || modelShape.getAttribute('y') !== initialY,
        ).toBe(true)
      },
      { timeout: 3000 },
    )

    // d3-force adds x/y/vx/vy/index to the objects it owns; the caller's
    // ComponentNode objects must be left untouched.
    for (const node of mockGraph.nodes) {
      const raw = node as unknown as Record<string, unknown>
      expect(raw.x).toBeUndefined()
      expect(raw.y).toBeUndefined()
      expect(raw.vx).toBeUndefined()
      expect(raw.vy).toBeUndefined()
      expect(raw.index).toBeUndefined()
    }
  })
})
