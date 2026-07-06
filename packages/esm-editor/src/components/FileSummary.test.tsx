/**
 * Tests for FileSummary component
 */

import { render, screen } from '@solidjs/testing-library';
import { describe, it, expect, vi } from 'vitest';
import type { EsmFile } from 'earthsci-toolkit';
import { FileSummary } from './FileSummary';

describe('FileSummary', () => {
  const basicEsmFile: EsmFile = {
    esm: "1.0.0",
    metadata: {
      name: "Test Model",
      description: "A comprehensive test model",
      authors: ["Test Author 1", "Test Author 2"],
      created: "2024-01-01"
    }
  };

  const complexEsmFile: EsmFile = {
    esm: "1.0.0",
    metadata: {
      name: "Complex Model",
      description: "A complex test model"
    },
    models: {
      TestModel: {
        variables: {
          x: { type: 'state', units: 'm', description: 'Position' },
          v: { type: 'parameter', units: 'm/s', description: 'Velocity' }
        },
        equations: [
          { lhs: { op: 'D', args: ['x', 't'] }, rhs: 'v' }
        ],
        subsystems: {
          SubModel: {
            variables: {
              y: { type: 'state', units: 'm', description: 'Y position' }
            },
            equations: []
          }
        }
      }
    },
    reaction_systems: {
      Chemistry: {
        species: {
          O2: { units: 'mol/L', description: 'Oxygen' },
          CO2: { units: 'mol/L', description: 'Carbon dioxide' }
        },
        parameters: {
          k1: { default: 1.5, units: '1/s', description: 'Rate constant' }
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'O2', stoichiometry: 1 }],
            products: [{ species: 'CO2', stoichiometry: 1 }],
            rate: 'k1'
          }
        ]
      }
    },
    data_loaders: {
      WeatherData: {
        kind: 'grid',
        source: { url_template: 'weather.csv' },
        variables: {
          temperature: { file_variable: 'T', units: 'K' }
        }
      }
    },
    coupling: [
      {
        type: 'operator_compose',
        systems: ['TestModel', 'Chemistry']
      },
      {
        type: 'couple',
        systems: ['TestModel', 'Chemistry'],
        connector: {
          equations: [
            { from: 'TestModel.x', to: 'Chemistry.O2', transform: 'replacement' }
          ]
        }
      },
      {
        type: 'variable_map',
        from: 'TestModel.v',
        to: 'Chemistry.k1',
        transform: 'identity'
      }
    ],
    domain: {
      independent_variable: 't',
      temporal: {
        start: '2024-01-01T00:00:00Z',
        end: '2024-01-02T00:00:00Z'
      },
      element_type: 'Float64'
    }
  };

  it('renders basic file information', () => {
    render(() => <FileSummary esmFile={basicEsmFile} />);

    expect(screen.getByText('File Summary')).toBeInTheDocument();
    expect(screen.getByText('Format Information')).toBeInTheDocument();
    expect(screen.getByText('Version:')).toBeInTheDocument();
    expect(screen.getByText('1.0.0')).toBeInTheDocument();
    expect(screen.getByText('Title:')).toBeInTheDocument();
    expect(screen.getByText('Test Model')).toBeInTheDocument();
    expect(screen.getByText('Description:')).toBeInTheDocument();
    expect(screen.getByText('A comprehensive test model')).toBeInTheDocument();
    expect(screen.getByText('Authors:')).toBeInTheDocument();
    expect(screen.getByText('Test Author 1, Test Author 2')).toBeInTheDocument();
    expect(screen.getByText('Created:')).toBeInTheDocument();
    expect(screen.getByText('2024-01-01')).toBeInTheDocument();
  });

  it('renders models summary', () => {
    render(() => <FileSummary esmFile={complexEsmFile} />);

    expect(screen.getByText(/Models \(\d+\)/)).toBeInTheDocument();
    expect(screen.getByText('TestModel')).toBeInTheDocument();
    expect(screen.getByText('2 variables, 1 equations, 1 subsystems')).toBeInTheDocument();
  });

  it('renders reaction systems summary', () => {
    render(() => <FileSummary esmFile={complexEsmFile} />);

    expect(screen.getByText(/Reaction Systems \(\d+\)/)).toBeInTheDocument();
    expect(screen.getByText('Chemistry')).toBeInTheDocument();
    expect(screen.getByText('2 species, 1 parameters, 1 reactions')).toBeInTheDocument();
  });

  it('renders data loaders summary', () => {
    render(() => <FileSummary esmFile={complexEsmFile} />);

    expect(screen.getByText(/Data Loaders \(\d+\)/)).toBeInTheDocument();
    expect(screen.getByText('WeatherData')).toBeInTheDocument();
    expect(screen.getByText('Type: grid | Source: weather.csv')).toBeInTheDocument();
  });

  it('renders coupling rules summary', () => {
    render(() => <FileSummary esmFile={complexEsmFile} />);

    expect(screen.getByText(/Coupling Rules \(\d+\)/)).toBeInTheDocument();
    expect(screen.getByText('Rule 1')).toBeInTheDocument();
    expect(screen.getByText('Compose: TestModel, Chemistry')).toBeInTheDocument();
    expect(screen.getByText('Rule 2')).toBeInTheDocument();
    expect(screen.getByText('Couple: TestModel, Chemistry')).toBeInTheDocument();
    expect(screen.getByText('Rule 3')).toBeInTheDocument();
    expect(screen.getByText('Map: TestModel.v → Chemistry.k1')).toBeInTheDocument();
  });

  it('renders domain configuration summary', () => {
    render(() => <FileSummary esmFile={complexEsmFile} />);

    expect(screen.getByText(/Domain Configuration/)).toBeInTheDocument();
    expect(screen.getByText('Time:')).toBeInTheDocument();
    expect(screen.getByText(/Start: 2024-01-01T00:00:00Z.*End: 2024-01-02T00:00:00Z/)).toBeInTheDocument();
    expect(screen.getByText('Independent variable:')).toBeInTheDocument();
    expect(screen.getByText('Float64')).toBeInTheDocument();
  });


  it('handles section clicks', () => {
    const onSectionClick = vi.fn();
    render(() => <FileSummary esmFile={complexEsmFile} onSectionClick={onSectionClick} />);

    const modelsHeader = screen.getByText(/Models \(\d+\)/);
    modelsHeader.click();
    expect(onSectionClick).toHaveBeenCalledWith('models', undefined);

    const modelItem = screen.getByText('TestModel');
    modelItem.click();
    expect(onSectionClick).toHaveBeenCalledWith('models', 'TestModel');

    const reactionSystemsHeader = screen.getByText(/Reaction Systems \(\d+\)/);
    reactionSystemsHeader.click();
    expect(onSectionClick).toHaveBeenCalledWith('reaction_systems', undefined);

    const domainHeader = screen.getByText(/Domain Configuration/);
    domainHeader.click();
    expect(onSectionClick).toHaveBeenCalledWith('domain', undefined);
  });

  it('handles keyboard interactions for section headers', () => {
    const onSectionClick = vi.fn();
    render(() => <FileSummary esmFile={complexEsmFile} onSectionClick={onSectionClick} />);

    const modelsHeader = screen.getByText(/Models \(\d+\)/);

    // Simulate Enter key press
    modelsHeader.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })
    );
    expect(onSectionClick).toHaveBeenCalledWith('models', undefined);

    // Simulate Space key press
    onSectionClick.mockClear();
    modelsHeader.dispatchEvent(
      new KeyboardEvent('keydown', { key: ' ', bubbles: true })
    );
    expect(onSectionClick).toHaveBeenCalledWith('models', undefined);
  });

  it('supports collapse/expand functionality', () => {
    const onToggleCollapsed = vi.fn();
    render(() => (
      <FileSummary
        esmFile={complexEsmFile}
        collapsed={false}
        onToggleCollapsed={onToggleCollapsed}
      />
    ));

    const header = screen.getByText('File Summary').closest('.summary-header') as HTMLElement | null;
    expect(header).toBeInTheDocument();

    header?.click();
    expect(onToggleCollapsed).toHaveBeenCalledWith(true);
  });

  it('does not show content when collapsed', () => {
    render(() => <FileSummary esmFile={complexEsmFile} collapsed={true} />);

    expect(screen.getByText('File Summary')).toBeInTheDocument();
    expect(screen.queryByText('Format Information')).not.toBeInTheDocument();
  });

  it('shows empty state for empty ESM file', () => {
    const emptyEsmFile: EsmFile = {
      esm: "1.0.0",
      metadata: { name: "Empty" }
    };

    render(() => <FileSummary esmFile={emptyEsmFile} />);

    expect(screen.getByText('This ESM file appears to be empty or contains no major components.')).toBeInTheDocument();
  });

  it('handles missing metadata gracefully', () => {
    const minimalEsmFile = {
      esm: "1.0.0",
      models: {
        TestModel: {
          variables: {},
          equations: []
        }
      }
    } as unknown as EsmFile;

    render(() => <FileSummary esmFile={minimalEsmFile} />);

    expect(screen.getByText('Version:')).toBeInTheDocument();
    expect(screen.getByText('1.0.0')).toBeInTheDocument();
    expect(screen.queryByText('Title:')).not.toBeInTheDocument();
    expect(screen.queryByText('Description:')).not.toBeInTheDocument();
    expect(screen.queryByText('Authors:')).not.toBeInTheDocument();
  });

  it('applies custom CSS classes', () => {
    const { container } = render(() => (
      <FileSummary esmFile={basicEsmFile} class="custom-class" />
    ));

    expect(container.firstChild).toHaveClass('file-summary');
    expect(container.firstChild).toHaveClass('custom-class');
  });

  it('shows collapsed state in CSS classes', () => {
    const { container } = render(() => (
      <FileSummary esmFile={basicEsmFile} collapsed={true} />
    ));

    expect(container.firstChild).toHaveClass('file-summary');
    expect(container.firstChild).toHaveClass('collapsed');
  });

  it('handles coupling rules with missing systems', () => {
    const esmFileWithIncompleteRules: EsmFile = {
      esm: "1.0.0",
      metadata: { name: "Incomplete" },
      coupling: [
        {
          type: 'operator_compose'
          // missing systems property
        } as any,
        {
          type: 'callback'
          // missing callback_id property
        } as any
      ]
    };

    render(() => <FileSummary esmFile={esmFileWithIncompleteRules} />);

    expect(screen.getByText(/Coupling Rules \(2\)/)).toBeInTheDocument();
    expect(screen.getByText('Compose: N/A')).toBeInTheDocument();
    expect(screen.getByText('Callback: N/A')).toBeInTheDocument();
  });

  it('handles system summaries for empty systems', () => {
    const esmFileWithEmptySystems = {
      esm: "1.0.0",
      metadata: { name: "Empty systems" },
      models: {
        EmptyModel: {}
      },
      reaction_systems: {
        EmptyReactions: {}
      }
    } as unknown as EsmFile;

    render(() => <FileSummary esmFile={esmFileWithEmptySystems} />);

    expect(screen.getByText(/Models \(1\)/)).toBeInTheDocument();
    expect(screen.getAllByText('Empty system').length).toBeGreaterThan(0);
    expect(screen.getByText(/Reaction Systems \(1\)/)).toBeInTheDocument();
  });
});