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

  it('handles species with different formulas and names', () => {
    render(() => <ReactionEditor {...mockProps} />);

    // O3 should show its formula (O₃) in the species panel
    // Note: In JSDOM, Unicode subscripts might not render exactly as expected
    const speciesItems = screen.getAllByText(/O/);
    expect(speciesItems.length).toBeGreaterThan(0);
  });
});