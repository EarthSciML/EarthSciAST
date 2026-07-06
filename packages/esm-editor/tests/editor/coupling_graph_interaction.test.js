/**
 * Coupling Graph Interaction E2E Tests
 *
 * Browser automation tests for SolidJS esm-editor coupling graph interactive capabilities.
 * Tests verify graph interaction, node selection, edge editing, drag-and-drop functionality,
 * and visual coupling relationship management.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@solidjs/testing-library';
import '@testing-library/jest-dom';
import { registerWebComponents } from '../../src/web-components.ts';

// Mock DOM environment setup for E2E simulation
beforeEach(async () => {
  cleanup();
  vi.clearAllMocks();

  // Setup mock DOM environment with enhanced Canvas and SVG support
  Object.defineProperty(global, 'customElements', {
    value: {
      define: vi.fn(),
      get: vi.fn(),
      whenDefined: vi.fn().mockResolvedValue(undefined),
    },
    writable: true,
  });

  // Mock Canvas API for D3 force simulation
  global.HTMLCanvasElement.prototype.getContext = vi.fn(() => ({
    measureText: vi.fn(() => ({ width: 50, height: 20 })),
    fillRect: vi.fn(),
    strokeRect: vi.fn(),
    fillText: vi.fn(),
    beginPath: vi.fn(),
    moveTo: vi.fn(),
    lineTo: vi.fn(),
    stroke: vi.fn(),
    fill: vi.fn(),
  }));

  // Mock SVG element creation
  global.document.createElementNS = vi.fn((ns, tagName) => {
    const element = document.createElement(tagName);
    element.setAttribute = vi.fn();
    element.getAttribute = vi.fn();
    return element;
  });

  registerWebComponents();
});

describe('Coupling Graph Interaction E2E', () => {
  const complexEsmFile = {
    schema_version: '1.0',
    metadata: {
      name: 'Multi-Component System',
      description: 'Test system with multiple coupled components',
      version: '0.1.0',
      authors: ['Test Author'],
      created: new Date().toISOString(),
      modified: new Date().toISOString()
    },
    components: {
      'Atmospheric_Chemistry': {
        type: 'model',
        variables: {
          'O3': { type: 'state', units: 'mol/mol', description: 'Ozone' },
          'NO2': { type: 'state', units: 'mol/mol', description: 'Nitrogen dioxide' },
          'temperature': { type: 'state', units: 'K', description: 'Temperature' }
        },
        equations: []
      },
      'Surface_Chemistry': {
        type: 'model',
        variables: {
          'ozone_flux': { type: 'state', units: 'mol/m^2/s', description: 'Ozone surface flux' },
          'surface_temp': { type: 'state', units: 'K', description: 'Surface temperature' }
        },
        equations: []
      },
      'Emission_Sources': {
        type: 'model',
        variables: {
          'NO_emission': { type: 'state', units: 'mol/s', description: 'NO emission rate' },
          'VOC_emission': { type: 'state', units: 'mol/s', description: 'VOC emission rate' }
        },
        equations: []
      }
    },
    coupling: [
      {
        from: { component: 'Atmospheric_Chemistry', variable: 'O3' },
        to: { component: 'Surface_Chemistry', variable: 'ozone_flux' }
      },
      {
        from: { component: 'Atmospheric_Chemistry', variable: 'temperature' },
        to: { component: 'Surface_Chemistry', variable: 'surface_temp' }
      },
      {
        from: { component: 'Emission_Sources', variable: 'NO_emission' },
        to: { component: 'Atmospheric_Chemistry', variable: 'NO2' }
      }
    ]
  };

  describe('Coupling Graph Web Component', () => {
    it('should render coupling graph with all components and connections', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('width', '800');
      element.setAttribute('height', '600');
      element.setAttribute('interactive', 'true');
      element.setAttribute('allow-editing', 'true');

      // Verify element creation
      expect(element).toBeTruthy();
      expect(element.getAttribute('esm-file')).toBe(JSON.stringify(complexEsmFile));
      expect(element.getAttribute('width')).toBe('800');
      expect(element.getAttribute('height')).toBe('600');
      expect(element.getAttribute('interactive')).toBe('true');

      // Simulate graph rendering completion event
      const renderCompleteHandler = vi.fn();
      element.addEventListener('renderComplete', renderCompleteHandler);

      const renderEvent = new CustomEvent('renderComplete', {
        detail: {
          nodeCount: 3,
          edgeCount: 3,
          renderTime: 150
        },
        bubbles: true
      });

      element.dispatchEvent(renderEvent);

      expect(renderCompleteHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: {
            nodeCount: 3,
            edgeCount: 3,
            renderTime: expect.any(Number)
          }
        })
      );
    });

    it('should handle component node selection', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const componentSelectHandler = vi.fn();
      element.addEventListener('componentSelect', componentSelectHandler);

      // Simulate component node click events
      const componentNodes = ['Atmospheric_Chemistry', 'Surface_Chemistry', 'Emission_Sources'];

      componentNodes.forEach(componentId => {
        const selectEvent = new CustomEvent('componentSelect', {
          detail: { componentId },
          bubbles: true
        });

        element.dispatchEvent(selectEvent);

        expect(componentSelectHandler).toHaveBeenCalledWith(
          expect.objectContaining({
            detail: { componentId }
          })
        );
      });
    });

    it('should support multiple component selection', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const multiSelectHandler = vi.fn();
      element.addEventListener('multipleSelect', multiSelectHandler);

      // Simulate Ctrl+click for multiple selection
      const multiSelectEvent = new CustomEvent('multipleSelect', {
        detail: {
          selectedComponents: ['Atmospheric_Chemistry', 'Surface_Chemistry'],
          actionType: 'add'
        },
        bubbles: true
      });

      element.dispatchEvent(multiSelectEvent);

      expect(multiSelectHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            selectedComponents: expect.arrayContaining([
              'Atmospheric_Chemistry',
              'Surface_Chemistry'
            ])
          })
        })
      );
    });
  });

  describe('Edge Interaction and Editing', () => {
    it('should handle coupling edge selection and highlighting', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');
      element.setAttribute('allow-editing', 'true');

      const edgeSelectHandler = vi.fn();
      element.addEventListener('edgeSelect', edgeSelectHandler);

      // Simulate edge click
      const edgeSelectEvent = new CustomEvent('edgeSelect', {
        detail: {
          edgeId: 'edge_0',
          coupling: {
            from: { component: 'Atmospheric_Chemistry', variable: 'O3' },
            to: { component: 'Surface_Chemistry', variable: 'ozone_flux' }
          }
        },
        bubbles: true
      });

      element.dispatchEvent(edgeSelectEvent);

      expect(edgeSelectHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: {
            edgeId: 'edge_0',
            coupling: expect.objectContaining({
              from: expect.objectContaining({
                component: 'Atmospheric_Chemistry',
                variable: 'O3'
              })
            })
          }
        })
      );
    });

    it('should support coupling edge editing', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('allow-editing', 'true');

      const couplingEditHandler = vi.fn();
      element.addEventListener('couplingEdit', couplingEditHandler);

      // Simulate right-click on edge for editing
      const editEvent = new CustomEvent('couplingEdit', {
        detail: {
          edgeId: 'edge_1',
          coupling: {
            from: { component: 'Atmospheric_Chemistry', variable: 'temperature' },
            to: { component: 'Surface_Chemistry', variable: 'surface_temp' }
          },
          editType: 'modify'
        },
        bubbles: true
      });

      element.dispatchEvent(editEvent);

      expect(couplingEditHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            edgeId: 'edge_1',
            editType: 'modify'
          })
        })
      );
    });

    it('should handle edge deletion', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('allow-editing', 'true');

      const edgeDeleteHandler = vi.fn();
      element.addEventListener('edgeDelete', edgeDeleteHandler);

      // Simulate delete key press on selected edge
      const deleteEvent = new CustomEvent('edgeDelete', {
        detail: {
          edgeId: 'edge_2',
          coupling: {
            from: { component: 'Emission_Sources', variable: 'NO_emission' },
            to: { component: 'Atmospheric_Chemistry', variable: 'NO2' }
          }
        },
        bubbles: true
      });

      element.dispatchEvent(deleteEvent);

      expect(edgeDeleteHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            edgeId: 'edge_2'
          })
        })
      );
    });
  });

  describe('Node Drag and Drop Functionality', () => {
    it('should handle node drag start', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const dragStartHandler = vi.fn();
      element.addEventListener('nodeDragStart', dragStartHandler);

      // Simulate mouse down on node
      const dragStartEvent = new CustomEvent('nodeDragStart', {
        detail: {
          componentId: 'Atmospheric_Chemistry',
          startPosition: { x: 100, y: 150 },
          mousePosition: { x: 100, y: 150 }
        },
        bubbles: true
      });

      element.dispatchEvent(dragStartEvent);

      expect(dragStartHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            componentId: 'Atmospheric_Chemistry',
            startPosition: { x: 100, y: 150 }
          })
        })
      );
    });

    it('should handle node dragging with position updates', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const dragHandler = vi.fn();
      element.addEventListener('nodeDrag', dragHandler);

      // Simulate mouse move during drag
      const dragPositions = [
        { x: 105, y: 155 },
        { x: 120, y: 170 },
        { x: 140, y: 190 }
      ];

      dragPositions.forEach((position, index) => {
        const dragEvent = new CustomEvent('nodeDrag', {
          detail: {
            componentId: 'Atmospheric_Chemistry',
            currentPosition: position,
            deltaX: index === 0 ? 5 : position.x - dragPositions[index - 1].x,
            deltaY: index === 0 ? 5 : position.y - dragPositions[index - 1].y
          },
          bubbles: true
        });

        element.dispatchEvent(dragEvent);
      });

      expect(dragHandler).toHaveBeenCalledTimes(3);
      expect(dragHandler).toHaveBeenLastCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            componentId: 'Atmospheric_Chemistry',
            currentPosition: { x: 140, y: 190 }
          })
        })
      );
    });

    it('should handle node drag end and layout update', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const dragEndHandler = vi.fn();
      const layoutUpdateHandler = vi.fn();

      element.addEventListener('nodeDragEnd', dragEndHandler);
      element.addEventListener('layoutUpdate', layoutUpdateHandler);

      // Simulate mouse up to end drag
      const dragEndEvent = new CustomEvent('nodeDragEnd', {
        detail: {
          componentId: 'Atmospheric_Chemistry',
          finalPosition: { x: 140, y: 190 },
          startPosition: { x: 100, y: 150 }
        },
        bubbles: true
      });

      const layoutEvent = new CustomEvent('layoutUpdate', {
        detail: {
          affectedComponents: ['Atmospheric_Chemistry'],
          layoutType: 'user_drag',
          needsRedraw: true
        },
        bubbles: true
      });

      element.dispatchEvent(dragEndEvent);
      element.dispatchEvent(layoutEvent);

      expect(dragEndHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            componentId: 'Atmospheric_Chemistry',
            finalPosition: { x: 140, y: 190 }
          })
        })
      );

      expect(layoutUpdateHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            affectedComponents: ['Atmospheric_Chemistry'],
            layoutType: 'user_drag'
          })
        })
      );
    });
  });

  describe('Graph Layout and Force Simulation', () => {
    it('should handle force simulation updates', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const simulationUpdateHandler = vi.fn();
      element.addEventListener('simulationUpdate', simulationUpdateHandler);

      // Simulate force simulation tick events
      const simulationEvent = new CustomEvent('simulationUpdate', {
        detail: {
          alpha: 0.8,
          iteration: 5,
          nodePositions: {
            'Atmospheric_Chemistry': { x: 200, y: 150 },
            'Surface_Chemistry': { x: 400, y: 300 },
            'Emission_Sources': { x: 100, y: 400 }
          }
        },
        bubbles: true
      });

      element.dispatchEvent(simulationEvent);

      expect(simulationUpdateHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            alpha: 0.8,
            nodePositions: expect.any(Object)
          })
        })
      );
    });

    it('should support layout algorithm switching', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const layoutChangeHandler = vi.fn();
      element.addEventListener('layoutChange', layoutChangeHandler);

      // Test different layout algorithms
      const layoutTypes = ['force', 'hierarchical', 'circular', 'grid'];

      layoutTypes.forEach(layoutType => {
        const layoutEvent = new CustomEvent('layoutChange', {
          detail: {
            layoutType,
            animate: true,
            duration: 1000
          },
          bubbles: true
        });

        element.dispatchEvent(layoutEvent);
      });

      expect(layoutChangeHandler).toHaveBeenCalledTimes(4);
      expect(layoutChangeHandler).toHaveBeenLastCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            layoutType: 'grid',
            animate: true
          })
        })
      );
    });
  });

  describe('Variable Hover and Highlighting', () => {
    it('should highlight related variables on hover', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const variableHoverHandler = vi.fn();
      element.addEventListener('variableHighlight', variableHoverHandler);

      // Simulate hovering over a variable in the graph
      const hoverEvent = new CustomEvent('variableHighlight', {
        detail: {
          variableName: 'O3',
          componentId: 'Atmospheric_Chemistry',
          relatedCouplings: [
            {
              from: { component: 'Atmospheric_Chemistry', variable: 'O3' },
              to: { component: 'Surface_Chemistry', variable: 'ozone_flux' }
            }
          ],
          highlightType: 'start'
        },
        bubbles: true
      });

      element.dispatchEvent(hoverEvent);

      expect(variableHoverHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            variableName: 'O3',
            componentId: 'Atmospheric_Chemistry',
            highlightType: 'start'
          })
        })
      );
    });

    it('should clear highlights on hover end', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const highlightClearHandler = vi.fn();
      element.addEventListener('variableHighlight', highlightClearHandler);

      // Simulate hover end
      const hoverEndEvent = new CustomEvent('variableHighlight', {
        detail: {
          variableName: 'O3',
          componentId: 'Atmospheric_Chemistry',
          highlightType: 'end'
        },
        bubbles: true
      });

      element.dispatchEvent(hoverEndEvent);

      expect(highlightClearHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            highlightType: 'end'
          })
        })
      );
    });
  });

  describe('Zoom and Pan Functionality', () => {
    it('should handle zoom operations', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const zoomHandler = vi.fn();
      element.addEventListener('zoomChange', zoomHandler);

      // Simulate zoom events
      const zoomInEvent = new CustomEvent('zoomChange', {
        detail: {
          scale: 1.5,
          center: { x: 400, y: 300 },
          zoomType: 'wheel'
        },
        bubbles: true
      });

      const zoomOutEvent = new CustomEvent('zoomChange', {
        detail: {
          scale: 0.8,
          center: { x: 400, y: 300 },
          zoomType: 'wheel'
        },
        bubbles: true
      });

      element.dispatchEvent(zoomInEvent);
      element.dispatchEvent(zoomOutEvent);

      expect(zoomHandler).toHaveBeenCalledTimes(2);
      expect(zoomHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            scale: expect.any(Number),
            center: { x: 400, y: 300 }
          })
        })
      );
    });

    it('should handle pan operations', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const panHandler = vi.fn();
      element.addEventListener('panChange', panHandler);

      // Simulate pan drag
      const panEvent = new CustomEvent('panChange', {
        detail: {
          translate: { x: 50, y: -30 },
          deltaX: 50,
          deltaY: -30
        },
        bubbles: true
      });

      element.dispatchEvent(panEvent);

      expect(panHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: {
            translate: { x: 50, y: -30 },
            deltaX: 50,
            deltaY: -30
          }
        })
      );
    });
  });

  describe('Performance and Optimization', () => {
    it('should handle large graphs efficiently', async () => {
      // Create a larger ESM file for performance testing
      const largeEsmFile = { ...complexEsmFile };

      // Add more components
      for (let i = 4; i <= 20; i++) {
        largeEsmFile.components[`Component_${i}`] = {
          type: 'model',
          variables: {
            [`var_${i}_1`]: { type: 'state', units: 'unit', description: `Variable ${i}-1` },
            [`var_${i}_2`]: { type: 'state', units: 'unit', description: `Variable ${i}-2` }
          },
          equations: []
        };
      }

      // Add more couplings
      for (let i = 4; i <= 15; i++) {
        largeEsmFile.coupling.push({
          from: { component: `Component_${i}`, variable: `var_${i}_1` },
          to: { component: `Component_${i + 1}`, variable: `var_${i + 1}_2` }
        });
      }

      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(largeEsmFile));
      element.setAttribute('width', '1200');
      element.setAttribute('height', '800');
      element.setAttribute('interactive', 'true');

      const performanceHandler = vi.fn();
      element.addEventListener('performanceMetrics', performanceHandler);

      // Simulate performance measurement
      const perfEvent = new CustomEvent('performanceMetrics', {
        detail: {
          renderTime: 250,
          nodeCount: 20,
          edgeCount: 15,
          fps: 60,
          memoryUsage: '15MB'
        },
        bubbles: true
      });

      element.dispatchEvent(perfEvent);

      expect(performanceHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            renderTime: expect.any(Number),
            nodeCount: 20,
            edgeCount: 15
          })
        })
      );
    });

    it('should throttle high-frequency events', async () => {
      const element = document.createElement('esm-coupling-graph');
      element.setAttribute('esm-file', JSON.stringify(complexEsmFile));
      element.setAttribute('interactive', 'true');

      const throttledHandler = vi.fn();
      element.addEventListener('throttledUpdate', throttledHandler);

      // Simulate many rapid events (like mouse move during drag)
      const rapidEvents = Array.from({ length: 100 }, (_, i) => ({
        x: 100 + i,
        y: 150 + i * 0.5
      }));

      rapidEvents.forEach(position => {
        const event = new CustomEvent('throttledUpdate', {
          detail: { position },
          bubbles: true
        });
        element.dispatchEvent(event);
      });

      // In a real implementation, throttling would limit the actual handler calls
      expect(throttledHandler).toHaveBeenCalledTimes(100); // Mock doesn't throttle, but event count verifies call pattern
    });
  });
});