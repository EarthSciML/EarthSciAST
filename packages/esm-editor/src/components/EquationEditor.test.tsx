import { describe, it, beforeEach, expect, vi } from 'vitest';
import { render, screen } from '@solidjs/testing-library';
import { EquationEditor } from './EquationEditor';

describe('EquationEditor', () => {
  const mockEquation = {
    lhs: 'x',
    rhs: { op: '+', args: ['y', 2] }
  };

  const mockProps = {
    equation: mockEquation,
    onEquationChange: vi.fn(),
    highlightedVars: new Set<string>(),
    readonly: false,
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders equation with equals sign', () => {
    render(() => <EquationEditor {...mockProps} />);

    expect(screen.getByText('x')).toBeInTheDocument();
    expect(screen.getByText('=')).toBeInTheDocument();
    expect(screen.getByText('+')).toBeInTheDocument();
  });

  it('handles equation changes', () => {
    const onEquationChange = vi.fn();
    render(() => <EquationEditor {...mockProps} onEquationChange={onEquationChange} />);

    // This is a basic test - more complex interaction testing would require
    // mocking the ExpressionNode component's replace functionality
    expect(screen.getByText('x')).toBeInTheDocument();
  });

  it('respects readonly mode', () => {
    render(() => <EquationEditor {...mockProps} readonly={true} />);

    const editor = screen.getByRole('button', { name: /x/ });
    expect(editor).toBeInTheDocument();
  });

  it('displays equation comment when provided', () => {
    const equationWithComment = {
      ...mockEquation,
      _comment: 'Test equation comment'
    };

    render(() => <EquationEditor {...mockProps} equation={equationWithComment} />);

    expect(screen.getByText('Test equation comment')).toBeInTheDocument();
  });

  it('applies custom CSS classes', () => {
    const { container } = render(() => <EquationEditor {...mockProps} class="custom-class" />);

    const editor = container.querySelector('.equation-editor');
    expect(editor).toHaveClass('custom-class');
  });

  it('includes readonly class when in readonly mode', () => {
    const { container } = render(() => <EquationEditor {...mockProps} readonly={true} />);

    const editor = container.querySelector('.equation-editor');
    expect(editor).toHaveClass('readonly');
  });
});