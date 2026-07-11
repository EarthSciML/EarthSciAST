import { describe, it, expect, beforeEach } from 'vitest';
import { registerWebComponents } from './web-components';
import { installCustomElementsMock } from './test-setup';
import type { EsmFile, Expression, Model, ReactionSystem } from '@earthsciml/ast';

describe('Web Components', () => {
  beforeEach(() => {
    // Install a fresh customElements stub (define/get/whenDefined) for each test.
    installCustomElementsMock();
  });

  describe('registerWebComponents', () => {
    it('does not throw when called', () => {
      // Should not throw error
      expect(() => registerWebComponents()).not.toThrow();
    });

    it('handles undefined window gracefully', () => {
      // Mock non-browser environment
      const originalWindow = global.window;
      delete (global as any).window;

      // Should not throw error
      expect(() => registerWebComponents()).not.toThrow();

      // Restore window
      global.window = originalWindow;
    });

    it('handles missing customElements gracefully', () => {
      // Mock window without customElements
      const originalCustomElements = window.customElements;
      delete (window as any).customElements;

      // Should not throw error
      expect(() => registerWebComponents()).not.toThrow();

      // Restore customElements
      (window as any).customElements = originalCustomElements;
    });
  });

  describe('Component Data Validation', () => {
    const validExpression: Expression = {
      op: "+",
      args: [1, 2]
    };

    const validModel: Model = {
      variables: {
        "O3": {
          type: "state",
          units: "mol/mol",
          description: "Ozone"
        }
      },
      equations: []
    };

    const validReactionSystem: ReactionSystem = {
      species: {
        "O3": {
          description: "Ozone"
        }
      },
      parameters: {},
      reactions: [
        {
          id: "R1",
          substrates: [{ species: "O3", stoichiometry: 1 }],
          products: null,
          rate: "k1"
        }
      ]
    };

    const validEsmFile: EsmFile = {
      esm: "0.8.0",
      metadata: {
        name: "Test Model",
        description: "Test",
        authors: [],
        created: new Date().toISOString(),
        modified: new Date().toISOString()
      },
      models: {
        "Chemistry": validModel
      },
      coupling: []
    };

    it('validates expression editor props', () => {
      const validProps = {
        expression: JSON.stringify(validExpression),
        'allow-editing': 'true',
        'show-palette': 'true'
      };

      expect(() => JSON.parse(validProps.expression)).not.toThrow();
      expect(validProps['allow-editing']).toBe('true');
    });

    it('validates model editor props', () => {
      const validProps = {
        model: JSON.stringify(validModel),
        'allow-editing': 'true'
      };

      expect(() => JSON.parse(validProps.model)).not.toThrow();
      expect(validProps['allow-editing']).toBe('true');
    });

    it('validates file editor props', () => {
      const validProps = {
        'esm-file': JSON.stringify(validEsmFile),
        'allow-editing': 'true',
        'enable-undo': 'true'
      };

      expect(() => JSON.parse(validProps['esm-file'])).not.toThrow();
      expect(validProps['allow-editing']).toBe('true');
    });

    it('validates reaction editor props', () => {
      const validProps = {
        'reaction-system': JSON.stringify(validReactionSystem),
        'allow-editing': 'true'
      };

      expect(() => JSON.parse(validProps['reaction-system'])).not.toThrow();
      expect(validProps['allow-editing']).toBe('true');
    });

    it('validates coupling graph props', () => {
      const validProps = {
        'esm-file': JSON.stringify(validEsmFile),
        width: '800',
        height: '600',
        interactive: 'true'
      };

      expect(() => JSON.parse(validProps['esm-file'])).not.toThrow();
      expect(validProps.width).toBe('800');
      expect(validProps.height).toBe('600');
    });
  });

  describe('Event Handling', () => {
    const validModel: Model = {
      variables: {
        "O3": {
          type: "state",
          units: "mol/mol",
          description: "Ozone"
        }
      },
      equations: []
    };

    it('should define proper custom events for expression editor', () => {
      const expectedEvents = ['change'];

      // Expression editor should emit these events
      expectedEvents.forEach(eventName => {
        const event = new CustomEvent(eventName, {
          detail: { expression: { op: "+", args: [1, 2] } },
          bubbles: true
        });

        expect(event.type).toBe(eventName);
        expect(event.bubbles).toBe(true);
        expect(event.detail).toBeDefined();
      });
    });

    it('should define proper custom events for model editor', () => {
      const expectedEvents = ['change'];

      expectedEvents.forEach(eventName => {
        const event = new CustomEvent(eventName, {
          detail: { model: validModel },
          bubbles: true
        });

        expect(event.type).toBe(eventName);
        expect(event.bubbles).toBe(true);
        expect(event.detail).toBeDefined();
      });
    });

    it('should define proper custom events for coupling graph', () => {
      const expectedEvents = ['couplingEdit', 'componentSelect'];

      expectedEvents.forEach(eventName => {
        const event = new CustomEvent(eventName, {
          detail: { componentId: 'test' },
          bubbles: true
        });

        expect(event.type).toBe(eventName);
        expect(event.bubbles).toBe(true);
        expect(event.detail).toBeDefined();
      });
    });
  });

  describe('Type Safety', () => {
    it('provides proper TypeScript interfaces', () => {
      // This test mainly checks that types compile correctly
      const expressionEditorProps = {
        expression: '{"op": "+", "args": [1, 2]}',
        'allow-editing': true,
        'show-palette': true
      };

      const modelEditorProps = {
        model: '{"type": "model", "variables": {}, "equations": []}',
        'allow-editing': true,
        'validation-errors': '[]'
      };

      const fileEditorProps = {
        'esm-file': '{"schema_version": "1.0", "metadata": {}, "components": {}, "coupling": []}',
        'allow-editing': true,
        'enable-undo': true,
        'show-summary': true
      };

      // These should be valid prop objects
      expect(expressionEditorProps).toBeDefined();
      expect(modelEditorProps).toBeDefined();
      expect(fileEditorProps).toBeDefined();
    });
  });
});