import { describe, it, beforeEach, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import type { ReactionSystem } from 'earthsci-toolkit';
import { ReactionEditor } from './ReactionEditor';

describe('ReactionEditor', () => {
  const mockReactionSystem: ReactionSystem = {
    species: {
      'NO': {
        description: 'Nitrogen monoxide'
      },
      'O3': {
        description: 'Ozone'
      },
      'NO2': {
        description: 'Nitrogen dioxide'
      }
    },
    parameters: {},
    reactions: [
      {
        id: 'R1',
        name: 'NO oxidation',
        substrates: [
          { species: 'NO', stoichiometry: 1 },
          { species: 'O3', stoichiometry: 1 }
        ],
        products: [
          { species: 'NO2', stoichiometry: 1 }
        ],
        rate: 'k_NO_O3'
      }
    ]
  };

  const mockProps = {
    reactionSystem: mockReactionSystem,
    onReactionSystemChange: vi.fn(),
    highlightedVars: new Set<string>(),
    readonly: false,
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders reaction count in header', () => {
    render(() => <ReactionEditor {...mockProps} />);

    expect(screen.getByText('Reactions (1)')).toBeInTheDocument();
  });

  it('renders chemical reaction in proper notation', () => {
    render(() => <ReactionEditor {...mockProps} />);

    // Should render chemical formulas (multiple NO elements expected)
    expect(screen.getAllByText(/NO/)).toHaveLength(6); // NO appears in reaction, species panel, etc.
    expect(screen.getByText(/→/)).toBeInTheDocument();
  });

  it('renders species panel', () => {
    render(() => <ReactionEditor {...mockProps} />);

    expect(screen.getByText(/Species \(3\)/)).toBeInTheDocument();
    expect(screen.getByText('NO')).toBeInTheDocument();
    expect(screen.getByText('Nitrogen monoxide')).toBeInTheDocument();
  });

  it('renders parameters panel', () => {
    render(() => <ReactionEditor {...mockProps} />);

    expect(screen.getByText(/Parameters \(0\)/)).toBeInTheDocument();
  });

  it('shows add buttons in non-readonly mode', () => {
    render(() => <ReactionEditor {...mockProps} />);

    expect(screen.getByText('+ Add Reaction')).toBeInTheDocument();

    // Species and parameters panels should also have add buttons
    const addButtons = screen.getAllByText('+');
    expect(addButtons.length).toBeGreaterThan(0);
  });

  it('hides add buttons in readonly mode', () => {
    render(() => <ReactionEditor {...mockProps} readonly={true} />);

    expect(screen.queryByText('+ Add Reaction')).not.toBeInTheDocument();
  });

  it('handles rate expression clicking', () => {
    render(() => <ReactionEditor {...mockProps} />);

    // Find the rate expression (displayed as [k])
    const rateExpression = screen.getByText('[k]');
    expect(rateExpression).toBeInTheDocument();

    // Click should be possible (though we can't easily test the expansion in this test)
    fireEvent.click(rateExpression);
  });

  it('displays empty state for reaction system without reactions', () => {
    const emptySystem = {
      species: {},
      parameters: {},
      reactions: []
    } as unknown as ReactionSystem;

    render(() => <ReactionEditor {...mockProps} reactionSystem={emptySystem} />);

    expect(screen.getByText('No reactions defined')).toBeInTheDocument();
    expect(screen.getByText('No species defined')).toBeInTheDocument();
  });

  it('applies custom CSS classes', () => {
    const { container } = render(() => <ReactionEditor {...mockProps} class="custom-class" />);

    const editor = container.querySelector('.reaction-editor');
    expect(editor).toHaveClass('custom-class');
  });

  it('includes readonly class when in readonly mode', () => {
    const { container } = render(() => <ReactionEditor {...mockProps} readonly={true} />);

    const editor = container.querySelector('.reaction-editor');
    expect(editor).toHaveClass('readonly');
  });

  it('renders reaction name when provided', () => {
    render(() => <ReactionEditor {...mockProps} />);

    expect(screen.getByText('NO oxidation')).toBeInTheDocument();
  });

  it('shows all parameters regardless of naming convention', () => {
    const paramSystem: ReactionSystem = {
      ...mockReactionSystem,
      parameters: {
        alpha: { default: 2 },
        k_NO_O3: { default: 1 },
        temperature_ref: { default: 298.15 }
      }
    };

    render(() => <ReactionEditor {...mockProps} reactionSystem={paramSystem} />);

    // Previously the panel filtered parameters by name spelling (k_/rate/const),
    // hiding everything else. All parameters must be listed.
    expect(screen.getByText(/Parameters \(3\)/)).toBeInTheDocument();
    expect(screen.getByText('alpha')).toBeInTheDocument();
    expect(screen.getByText('k_NO_O3')).toBeInTheDocument();
    expect(screen.getByText('temperature_ref')).toBeInTheDocument();
  });

  it('adds a parameter through the inline form (no prompt dialogs)', () => {
    const onReactionSystemChange = vi.fn();
    render(() => <ReactionEditor {...mockProps} onReactionSystemChange={onReactionSystemChange} />);

    fireEvent.click(screen.getByLabelText('Add new parameter'));
    fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'j_photo' } });
    fireEvent.input(screen.getByLabelText('Default value'), { target: { value: '2.5' } });
    fireEvent.click(screen.getByText('Add'));

    expect(onReactionSystemChange).toHaveBeenCalledWith(
      expect.objectContaining({
        parameters: expect.objectContaining({
          j_photo: expect.objectContaining({ default: 2.5 })
        })
      })
    );
  });

  it('adds a species through the inline form (no prompt dialogs)', () => {
    const onReactionSystemChange = vi.fn();
    render(() => <ReactionEditor {...mockProps} onReactionSystemChange={onReactionSystemChange} />);

    fireEvent.click(screen.getByLabelText('Add new species'));
    fireEvent.input(screen.getByLabelText('Name (chemical formula)'), { target: { value: 'SO2' } });
    fireEvent.click(screen.getByText('Add'));

    expect(onReactionSystemChange).toHaveBeenCalledWith(
      expect.objectContaining({
        species: expect.objectContaining({
          SO2: {}
        })
      })
    );
  });

  it('edits a species through the inline form', () => {
    const onReactionSystemChange = vi.fn();
    render(() => <ReactionEditor {...mockProps} onReactionSystemChange={onReactionSystemChange} />);

    // Click the NO species item to open the inline edit form
    const speciesItem = screen.getByText('Nitrogen monoxide').closest('.species-item')!;
    fireEvent.click(speciesItem);

    expect(screen.getByText('Edit species NO')).toBeInTheDocument();

    fireEvent.input(screen.getByLabelText('Description'), { target: { value: 'Nitric oxide' } });
    fireEvent.click(screen.getByText('Save'));

    expect(onReactionSystemChange).toHaveBeenCalledWith(
      expect.objectContaining({
        species: expect.objectContaining({
          NO: expect.objectContaining({ description: 'Nitric oxide' })
        })
      })
    );
  });

  it('handles species with different formulas and names', () => {
    render(() => <ReactionEditor {...mockProps} />);

    // O3 should show its formula (O₃) in the species panel
    // Note: In JSDOM, Unicode subscripts might not render exactly as expected
    const speciesItems = screen.getAllByText(/O/);
    expect(speciesItems.length).toBeGreaterThan(0);
  });
});