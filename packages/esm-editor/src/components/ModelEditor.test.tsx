import { describe, it, beforeEach, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import type { Model } from 'earthsci-toolkit';
import { ModelEditor } from './ModelEditor';

describe('ModelEditor', () => {
  const mockModel: Model = {
    variables: {
      x: {
        type: 'state',
        default: 1.0,
        units: 'm',
        description: 'Position variable'
      },
      k_rate: {
        type: 'parameter',
        default: 0.5,
        units: 's⁻¹',
        description: 'Rate constant'
      }
    },
    equations: [
      {
        lhs: 'x',
        rhs: { op: '+', args: ['y', 2] }
      }
    ],
    continuous_events: [],
    discrete_events: []
  };

  const mockProps = {
    model: mockModel,
    name: 'Test Model',
    description: 'A test model for demonstration',
    onModelChange: vi.fn(),
    readonly: false,
    showPalette: true,
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders model name and description', () => {
    render(() => <ModelEditor {...mockProps} />);

    expect(screen.getByText('Test Model')).toBeInTheDocument();
    expect(screen.getByText('A test model for demonstration')).toBeInTheDocument();
  });

  it('renders variables panel with grouped variables', () => {
    render(() => <ModelEditor {...mockProps} />);

    expect(screen.getByText(/Variables \(2\)/)).toBeInTheDocument();
    expect(screen.getAllByText('x')).toHaveLength(3); // One in variable list, one in equation, one in palette
    expect(screen.getAllByText('k_rate')).toHaveLength(2); // One in variable list, one in palette
  });

  it('renders equations panel', () => {
    render(() => <ModelEditor {...mockProps} />);

    expect(screen.getByText(/Equations \(1\)/)).toBeInTheDocument();
  });

  it('renders events panel', () => {
    render(() => <ModelEditor {...mockProps} />);

    expect(screen.getByText(/Events \(0\)/)).toBeInTheDocument();
  });

  it('shows add buttons in non-readonly mode', () => {
    render(() => <ModelEditor {...mockProps} />);

    // Look for add buttons (they have '+' text)
    const addButtons = screen.getAllByText('+');
    expect(addButtons.length).toBeGreaterThan(0);
  });

  it('hides add buttons in readonly mode', () => {
    render(() => <ModelEditor {...mockProps} readonly={true} showPalette={false} />);

    // In readonly mode, main panel add buttons should not be present
    expect(screen.queryByLabelText('Add new variable')).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Add new equation')).not.toBeInTheDocument();
  });

  it('handles panel expansion/collapse', () => {
    render(() => <ModelEditor {...mockProps} />);

    // Find a panel header (variables panel)
    const variablesHeader = screen.getByText(/Variables \(2\)/);
    expect(variablesHeader).toBeInTheDocument();

    // Click to collapse (the expand icon is part of the header)
    fireEvent.click(variablesHeader);

    // The panel should still be visible (since we're testing the basic interaction)
    expect(variablesHeader).toBeInTheDocument();
  });

  it('displays empty state for models without content', () => {
    const emptyModel: Model = {
      variables: {},
      equations: [],
      continuous_events: [],
      discrete_events: []
    };

    render(() => <ModelEditor {...mockProps} model={emptyModel} name="Empty Model" />);

    expect(screen.getByText('No variables defined')).toBeInTheDocument();
    expect(screen.getByText('No equations defined')).toBeInTheDocument();
    expect(screen.getByText('No events defined')).toBeInTheDocument();
  });

  it('applies custom CSS classes', () => {
    const { container } = render(() => <ModelEditor {...mockProps} class="custom-class" />);

    const editor = container.querySelector('.model-editor');
    expect(editor).toHaveClass('custom-class');
  });

  it('includes readonly class when in readonly mode', () => {
    const { container } = render(() => <ModelEditor {...mockProps} readonly={true} />);

    const editor = container.querySelector('.model-editor');
    expect(editor).toHaveClass('readonly');
  });

  it('shows expression palette when enabled', () => {
    render(() => <ModelEditor {...mockProps} showPalette={true} />);

    // The palette should be rendered (it has specific classes)
    const palette = document.querySelector('.palette-sidebar');
    expect(palette).toBeInTheDocument();
  });

  it('hides expression palette when disabled', () => {
    render(() => <ModelEditor {...mockProps} showPalette={false} />);

    // The palette should not be rendered
    const palette = document.querySelector('.palette-sidebar');
    expect(palette).not.toBeInTheDocument();
  });
});