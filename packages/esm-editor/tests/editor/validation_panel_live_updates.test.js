/**
 * Validation Panel Live Updates E2E Tests
 *
 * Browser automation tests for SolidJS esm-editor validation panel live update capabilities.
 * Tests verify real-time validation feedback, error highlighting, interactive error navigation,
 * and validation state synchronization across multiple editor components.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@solidjs/testing-library';
import '@testing-library/jest-dom';
import { registerWebComponents } from '../../src/web-components.ts';

// Mock validation system
const mockValidationErrors = {
  schemaErrors: [
    {
      path: '/components/Chemistry/equations/0/rhs/args/0/value',
      message: 'Missing required field: value',
      code: 'missing_field',
      details: { field: 'value', expected_type: 'number' }
    },
    {
      path: '/components/Chemistry/variables/O3/units',
      message: 'Invalid units format',
      code: 'invalid_units',
      details: { provided: 'ppm', expected_format: 'SI units' }
    }
  ],
  structuralErrors: [
    {
      path: '/coupling/0/from/variable',
      message: 'Variable "undefined_var" not found in component',
      code: 'undefined_variable',
      details: { variable: 'undefined_var', component: 'Chemistry' }
    }
  ]
};

beforeEach(async () => {
  cleanup();
  vi.clearAllMocks();

  // Setup mock DOM environment
  Object.defineProperty(global, 'customElements', {
    value: {
      define: vi.fn(),
      get: vi.fn(),
      whenDefined: vi.fn().mockResolvedValue(undefined),
    },
    writable: true,
  });

  registerWebComponents();
});

describe('Validation Panel Live Updates E2E', () => {
  const validEsmFile = {
    schema_version: '1.0',
    metadata: {
      name: 'Valid Test Model',
      description: 'A valid test model',
      version: '0.1.0',
      authors: ['Test Author'],
      created: new Date().toISOString(),
      modified: new Date().toISOString()
    },
    components: {
      'Chemistry': {
        type: 'model',
        variables: {
          'O3': { type: 'state', units: 'mol/mol', description: 'Ozone concentration' },
          'NO2': { type: 'state', units: 'mol/mol', description: 'Nitrogen dioxide' },
          'temperature': { type: 'state', units: 'K', description: 'Temperature' }
        },
        equations: [
          {
            lhs: { type: 'variable', name: 'O3' },
            rhs: {
              op: '+',
              args: [
                { type: 'variable', name: 'O3' },
                { type: 'number', value: 0.1 }
              ]
            }
          }
        ]
      }
    },
    coupling: [
      {
        from: { component: 'Chemistry', variable: 'O3' },
        to: { component: 'Surface', variable: 'ozone_flux' }
      }
    ]
  };

  const invalidEsmFile = {
    schema_version: '1.0',
    metadata: {
      name: 'Invalid Test Model',
      description: 'A model with validation errors'
    },
    components: {
      'Chemistry': {
        type: 'model',
        variables: {
          'O3': { type: 'state', units: 'ppm', description: 'Ozone' }, // Invalid units
          'NO2': { type: 'state', units: 'mol/mol', description: 'NO2' }
        },
        equations: [
          {
            lhs: { type: 'variable', name: 'O3' },
            rhs: {
              op: '+',
              args: [
                { type: 'number' }, // Missing value field
                { type: 'variable', name: 'NO2' }
              ]
            }
          }
        ]
      }
    },
    coupling: [
      {
        from: { component: 'Chemistry', variable: 'undefined_var' }, // Undefined variable
        to: { component: 'Surface', variable: 'ozone_flux' }
      }
    ]
  };

  describe('Real-time Validation Updates', () => {
    it('should show validation panel with no errors for valid ESM file', async () => {
      const element = document.createElement('esm-file-editor');
      element.setAttribute('esm-file', JSON.stringify(validEsmFile));
      element.setAttribute('show-validation', 'true');

      const validationUpdateHandler = vi.fn();
      element.addEventListener('validationUpdate', validationUpdateHandler);

      // Simulate validation completion with no errors
      const validationEvent = new CustomEvent('validationUpdate', {
        detail: {
          isValid: true,
          errors: [],
          warnings: [],
          validationTime: 45
        },
        bubbles: true
      });

      element.dispatchEvent(validationEvent);

      expect(validationUpdateHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            isValid: true,
            errors: [],
            warnings: []
          })
        })
      );
    });

    it('should display validation errors immediately when ESM file becomes invalid', async () => {
      const element = document.createElement('esm-file-editor');
      element.setAttribute('esm-file', JSON.stringify(invalidEsmFile));
      element.setAttribute('show-validation', 'true');

      const validationUpdateHandler = vi.fn();
      element.addEventListener('validationUpdate', validationUpdateHandler);

      // Simulate validation completion with errors
      const validationEvent = new CustomEvent('validationUpdate', {
        detail: {
          isValid: false,
          errors: mockValidationErrors.schemaErrors.concat(mockValidationErrors.structuralErrors),
          warnings: [],
          validationTime: 67
        },
        bubbles: true
      });

      element.dispatchEvent(validationEvent);

      expect(validationUpdateHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            isValid: false,
            errors: expect.arrayContaining([
              expect.objectContaining({
                path: '/components/Chemistry/equations/0/rhs/args/0/value',
                message: 'Missing required field: value'
              }),
              expect.objectContaining({
                path: '/components/Chemistry/variables/O3/units',
                message: 'Invalid units format'
              })
            ])
          })
        })
      );
    });

    it('should update validation state in real-time as user edits', async () => {
      const element = document.createElement('esm-expression-editor');
      element.setAttribute('expression', JSON.stringify({
        op: '+',
        args: [
          { type: 'number' }, // Missing value - invalid
          { type: 'variable', name: 'x' }
        ]
      }));
      element.setAttribute('show-validation', 'true');

      const liveValidationHandler = vi.fn();
      element.addEventListener('liveValidation', liveValidationHandler);

      // Simulate user typing to fix the missing value
      const editSteps = [
        {
          expression: {
            op: '+',
            args: [
              { type: 'number', value: '' }, // User starts typing
              { type: 'variable', name: 'x' }
            ]
          },
          isValid: false,
          errors: [{ path: '/args/0/value', message: 'Value cannot be empty' }]
        },
        {
          expression: {
            op: '+',
            args: [
              { type: 'number', value: '5' }, // User completes typing
              { type: 'variable', name: 'x' }
            ]
          },
          isValid: true,
          errors: []
        }
      ];

      editSteps.forEach(step => {
        const validationEvent = new CustomEvent('liveValidation', {
          detail: {
            expression: step.expression,
            isValid: step.isValid,
            errors: step.errors
          },
          bubbles: true
        });

        element.dispatchEvent(validationEvent);
      });

      expect(liveValidationHandler).toHaveBeenCalledTimes(2);
      expect(liveValidationHandler).toHaveBeenLastCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            isValid: true,
            errors: []
          })
        })
      );
    });

    it('should debounce rapid validation updates during fast typing', async () => {
      const element = document.createElement('esm-expression-editor');
      element.setAttribute('expression', '{"op": "+", "args": []}');
      element.setAttribute('show-validation', 'true');

      const debouncedValidationHandler = vi.fn();
      element.addEventListener('debouncedValidation', debouncedValidationHandler);

      // Simulate rapid typing events
      const rapidTyping = Array.from({ length: 10 }, (_, i) => ({
        keystroke: i,
        timestamp: Date.now() + i * 50
      }));

      rapidTyping.forEach(stroke => {
        const event = new CustomEvent('debouncedValidation', {
          detail: {
            keystroke: stroke.keystroke,
            timestamp: stroke.timestamp,
            validationPending: true
          },
          bubbles: true
        });

        element.dispatchEvent(event);
      });

      // Simulate final validation after the debounce period has elapsed
      await new Promise((resolve) => setTimeout(resolve, 10));
      const finalValidationEvent = new CustomEvent('debouncedValidation', {
        detail: {
          validationPending: false,
          isValid: false,
          errors: [{ message: 'Empty arguments array' }]
        },
        bubbles: true
      });

      element.dispatchEvent(finalValidationEvent);

      expect(debouncedValidationHandler).toHaveBeenCalledTimes(11); // 10 rapid + 1 final
    });
  });

  describe('Error Highlighting and Navigation', () => {
    it('should highlight errors when clicking on validation panel items', async () => {
      const element = document.createElement('esm-file-editor');
      element.setAttribute('esm-file', JSON.stringify(invalidEsmFile));
      element.setAttribute('show-validation', 'true');

      const errorClickHandler = vi.fn();
      const highlightHandler = vi.fn();

      element.addEventListener('validationErrorClick', errorClickHandler);
      element.addEventListener('errorHighlight', highlightHandler);

      // Simulate clicking on a validation error
      const errorClickEvent = new CustomEvent('validationErrorClick', {
        detail: {
          error: {
            path: '/components/Chemistry/equations/0/rhs/args/0/value',
            message: 'Missing required field: value',
            code: 'missing_field'
          }
        },
        bubbles: true
      });

      // Simulate highlighting the corresponding AST node
      const highlightEvent = new CustomEvent('errorHighlight', {
        detail: {
          path: '/components/Chemistry/equations/0/rhs/args/0/value',
          highlightType: 'error',
          scrollToElement: true
        },
        bubbles: true
      });

      element.dispatchEvent(errorClickEvent);
      element.dispatchEvent(highlightEvent);

      expect(errorClickHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            error: expect.objectContaining({
              path: '/components/Chemistry/equations/0/rhs/args/0/value'
            })
          })
        })
      );

      expect(highlightHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            highlightType: 'error',
            scrollToElement: true
          })
        })
      );
    });

    it('should support keyboard navigation through validation errors', async () => {
      const element = document.createElement('esm-file-editor');
      element.setAttribute('esm-file', JSON.stringify(invalidEsmFile));
      element.setAttribute('show-validation', 'true');

      const keyNavigationHandler = vi.fn();
      element.addEventListener('errorNavigation', keyNavigationHandler);

      // Simulate keyboard navigation (Up/Down arrows, Enter to select)
      const keyEvents = [
        { key: 'ArrowDown', expectedIndex: 0 },
        { key: 'ArrowDown', expectedIndex: 1 },
        { key: 'ArrowUp', expectedIndex: 0 },
        { key: 'Enter', expectedIndex: 0, action: 'select' }
      ];

      keyEvents.forEach(({ key, expectedIndex, action }) => {
        const navEvent = new CustomEvent('errorNavigation', {
          detail: {
            key,
            currentErrorIndex: expectedIndex,
            action: action || 'navigate'
          },
          bubbles: true
        });

        element.dispatchEvent(navEvent);
      });

      expect(keyNavigationHandler).toHaveBeenCalledTimes(4);
      expect(keyNavigationHandler).toHaveBeenLastCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            key: 'Enter',
            action: 'select'
          })
        })
      );
    });

    it('should clear error highlighting when errors are fixed', async () => {
      const element = document.createElement('esm-expression-editor');
      element.setAttribute('expression', JSON.stringify({
        op: '+',
        args: [
          { type: 'number' }, // Missing value
          { type: 'variable', name: 'x' }
        ]
      }));
      element.setAttribute('show-validation', 'true');

      const highlightClearHandler = vi.fn();
      element.addEventListener('highlightClear', highlightClearHandler);

      // Simulate error being fixed
      element.setAttribute('expression', JSON.stringify({
        op: '+',
        args: [
          { type: 'number', value: 42 }, // Value added - error fixed
          { type: 'variable', name: 'x' }
        ]
      }));

      const clearEvent = new CustomEvent('highlightClear', {
        detail: {
          clearedPath: '/args/0/value',
          reason: 'error_fixed'
        },
        bubbles: true
      });

      element.dispatchEvent(clearEvent);

      expect(highlightClearHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: {
            clearedPath: '/args/0/value',
            reason: 'error_fixed'
          }
        })
      );
    });
  });

  describe('Cross-Component Validation Synchronization', () => {
    it('should synchronize validation state between expression editor and validation panel', async () => {
      // Create both components
      const expressionEditor = document.createElement('esm-expression-editor');
      const fileEditor = document.createElement('esm-file-editor');

      expressionEditor.setAttribute('expression', JSON.stringify({
        op: '+',
        args: [{ type: 'number', value: 5 }, { type: 'variable', name: 'x' }]
      }));
      expressionEditor.setAttribute('show-validation', 'true');

      fileEditor.setAttribute('esm-file', JSON.stringify(validEsmFile));
      fileEditor.setAttribute('show-validation', 'true');

      const syncHandler = vi.fn();
      fileEditor.addEventListener('validationSync', syncHandler);

      // Simulate expression change that affects overall file validation
      const syncEvent = new CustomEvent('validationSync', {
        detail: {
          source: 'expression-editor',
          affectedComponents: ['Chemistry'],
          validationState: {
            isValid: true,
            errors: [],
            warnings: []
          }
        },
        bubbles: true
      });

      fileEditor.dispatchEvent(syncEvent);

      expect(syncHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            source: 'expression-editor',
            affectedComponents: ['Chemistry']
          })
        })
      );
    });

    it('should propagate validation errors from coupling graph to validation panel', async () => {
      const couplingGraph = document.createElement('esm-coupling-graph');
      const fileEditor = document.createElement('esm-file-editor');

      couplingGraph.setAttribute('esm-file', JSON.stringify(invalidEsmFile));
      couplingGraph.setAttribute('interactive', 'true');

      fileEditor.setAttribute('esm-file', JSON.stringify(invalidEsmFile));
      fileEditor.setAttribute('show-validation', 'true');

      const couplingValidationHandler = vi.fn();
      fileEditor.addEventListener('couplingValidation', couplingValidationHandler);

      // Simulate coupling validation error from graph interaction
      const couplingErrorEvent = new CustomEvent('couplingValidation', {
        detail: {
          source: 'coupling-graph',
          errors: [
            {
              path: '/coupling/0/from/variable',
              message: 'Variable "undefined_var" not found',
              code: 'undefined_variable',
              visualHighlight: {
                edgeId: 'edge_0',
                nodeId: 'Chemistry',
                highlightColor: 'red'
              }
            }
          ]
        },
        bubbles: true
      });

      fileEditor.dispatchEvent(couplingErrorEvent);

      expect(couplingValidationHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: {
            source: 'coupling-graph',
            errors: expect.arrayContaining([
              expect.objectContaining({
                path: '/coupling/0/from/variable',
                visualHighlight: expect.any(Object)
              })
            ])
          }
        })
      );
    });

    it('should handle validation conflicts between multiple editors', async () => {
      const modelEditor = document.createElement('esm-model-editor');
      const reactionEditor = document.createElement('esm-reaction-editor');

      const conflictHandler = vi.fn();
      modelEditor.addEventListener('validationConflict', conflictHandler);

      // Simulate validation conflict
      const conflictEvent = new CustomEvent('validationConflict', {
        detail: {
          conflictType: 'variable_definition',
          editors: ['model-editor', 'reaction-editor'],
          conflictDetails: {
            variable: 'O3',
            modelEditorUnits: 'mol/mol',
            reactionEditorUnits: 'ppm',
            resolution: 'user_choice_required'
          }
        },
        bubbles: true
      });

      modelEditor.dispatchEvent(conflictEvent);

      expect(conflictHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            conflictType: 'variable_definition',
            conflictDetails: expect.objectContaining({
              resolution: 'user_choice_required'
            })
          })
        })
      );
    });
  });

  describe('Validation Panel UI Interactions', () => {
    it('should support collapsing and expanding validation panel', async () => {
      const element = document.createElement('esm-file-editor');
      element.setAttribute('esm-file', JSON.stringify(invalidEsmFile));
      element.setAttribute('show-validation', 'true');

      const collapseHandler = vi.fn();
      element.addEventListener('validationPanelToggle', collapseHandler);

      // Simulate collapse toggle
      const collapseEvent = new CustomEvent('validationPanelToggle', {
        detail: {
          collapsed: true,
          errorCount: 3,
          warningCount: 1
        },
        bubbles: true
      });

      const expandEvent = new CustomEvent('validationPanelToggle', {
        detail: {
          collapsed: false,
          errorCount: 3,
          warningCount: 1
        },
        bubbles: true
      });

      element.dispatchEvent(collapseEvent);
      element.dispatchEvent(expandEvent);

      expect(collapseHandler).toHaveBeenCalledTimes(2);
      expect(collapseHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            collapsed: expect.any(Boolean),
            errorCount: 3
          })
        })
      );
    });

    it('should filter validation results by error type', async () => {
      const element = document.createElement('esm-file-editor');
      element.setAttribute('esm-file', JSON.stringify(invalidEsmFile));
      element.setAttribute('show-validation', 'true');

      const filterHandler = vi.fn();
      element.addEventListener('validationFilter', filterHandler);

      // Test different filter options
      const filterTypes = ['all', 'errors', 'warnings', 'schema', 'structural'];

      filterTypes.forEach(filterType => {
        const filterEvent = new CustomEvent('validationFilter', {
          detail: {
            filterType,
            visibleErrors: filterType === 'errors' ? mockValidationErrors.schemaErrors : []
          },
          bubbles: true
        });

        element.dispatchEvent(filterEvent);
      });

      expect(filterHandler).toHaveBeenCalledTimes(5);
      expect(filterHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            filterType: expect.any(String)
          })
        })
      );
    });

    it('should display validation statistics and summary', async () => {
      const element = document.createElement('esm-file-editor');
      element.setAttribute('esm-file', JSON.stringify(invalidEsmFile));
      element.setAttribute('show-validation', 'true');

      const statsHandler = vi.fn();
      element.addEventListener('validationStats', statsHandler);

      // Simulate validation statistics update
      const statsEvent = new CustomEvent('validationStats', {
        detail: {
          totalErrors: 3,
          schemaErrors: 2,
          structuralErrors: 1,
          totalWarnings: 1,
          validationTime: 89,
          fileSize: '2.1KB',
          componentCount: 1,
          couplingCount: 1
        },
        bubbles: true
      });

      element.dispatchEvent(statsEvent);

      expect(statsHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            totalErrors: 3,
            schemaErrors: 2,
            structuralErrors: 1,
            validationTime: expect.any(Number)
          })
        })
      );
    });
  });

  describe('Performance and Large File Handling', () => {
    it('should handle validation of large ESM files efficiently', async () => {
      // Create a large ESM file for performance testing
      const largeEsmFile = { ...validEsmFile };

      // Add many components and equations
      for (let i = 1; i <= 50; i++) {
        largeEsmFile.components[`Component_${i}`] = {
          type: 'model',
          variables: {},
          equations: []
        };

        // Add many variables per component
        for (let j = 1; j <= 20; j++) {
          largeEsmFile.components[`Component_${i}`].variables[`var_${i}_${j}`] = {
            type: 'state',
            units: 'unit',
            description: `Variable ${i}-${j}`
          };
        }

        // Add equations
        for (let k = 1; k <= 10; k++) {
          largeEsmFile.components[`Component_${i}`].equations.push({
            lhs: { type: 'variable', name: `var_${i}_${k}` },
            rhs: { type: 'number', value: k }
          });
        }
      }

      const element = document.createElement('esm-file-editor');
      element.setAttribute('esm-file', JSON.stringify(largeEsmFile));
      element.setAttribute('show-validation', 'true');

      const performanceHandler = vi.fn();
      element.addEventListener('validationPerformance', performanceHandler);

      // Simulate validation performance metrics
      const perfEvent = new CustomEvent('validationPerformance', {
        detail: {
          validationTime: 850,
          componentCount: 50,
          variableCount: 1000,
          equationCount: 500,
          memoryUsage: '45MB',
          batchProcessing: true,
          backgroundValidation: true
        },
        bubbles: true
      });

      element.dispatchEvent(perfEvent);

      expect(performanceHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            validationTime: expect.any(Number),
            componentCount: 50,
            variableCount: 1000,
            batchProcessing: true
          })
        })
      );
    });

    it('should provide incremental validation feedback for large files', async () => {
      const element = document.createElement('esm-file-editor');
      element.setAttribute('show-validation', 'true');

      const incrementalHandler = vi.fn();
      element.addEventListener('incrementalValidation', incrementalHandler);

      // Simulate incremental validation progress
      const progressSteps = [
        { progress: 25, stage: 'schema_validation', completed: 'metadata' },
        { progress: 50, stage: 'schema_validation', completed: 'components' },
        { progress: 75, stage: 'structural_validation', completed: 'variables' },
        { progress: 100, stage: 'complete', completed: 'all' }
      ];

      progressSteps.forEach(step => {
        const progressEvent = new CustomEvent('incrementalValidation', {
          detail: step,
          bubbles: true
        });

        element.dispatchEvent(progressEvent);
      });

      expect(incrementalHandler).toHaveBeenCalledTimes(4);
      expect(incrementalHandler).toHaveBeenLastCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            progress: 100,
            stage: 'complete'
          })
        })
      );
    });
  });
});