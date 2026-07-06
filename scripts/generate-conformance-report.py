#!/usr/bin/env python3

"""
HTML conformance report generator for cross-language ESM Format testing.

This script generates a comprehensive HTML report showing conformance
test results, divergences, and overall compatibility across language implementations.
"""

import argparse
import json
from pathlib import Path
from datetime import datetime
from typing import Dict, Any

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ESM Format Cross-Language Conformance Report</title>
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            line-height: 1.6;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
        }}
        .container {{
            max-width: 1200px;
            margin: 0 auto;
            background-color: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }}
        .header {{
            border-bottom: 3px solid #2196F3;
            padding-bottom: 20px;
            margin-bottom: 30px;
        }}
        .header h1 {{
            color: #333;
            margin: 0;
        }}
        .header .subtitle {{
            color: #666;
            font-size: 18px;
            margin-top: 10px;
        }}
        .status {{
            display: inline-block;
            padding: 8px 16px;
            border-radius: 20px;
            font-weight: bold;
            text-transform: uppercase;
            font-size: 12px;
        }}
        .status.pass {{
            background-color: #4CAF50;
            color: white;
        }}
        .status.warn {{
            background-color: #FF9800;
            color: white;
        }}
        .status.fail {{
            background-color: #F44336;
            color: white;
        }}
        .summary-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin: 30px 0;
        }}
        .summary-card {{
            background: #f8f9fa;
            padding: 20px;
            border-radius: 8px;
            border-left: 4px solid #2196F3;
        }}
        .summary-card h3 {{
            margin: 0 0 10px 0;
            color: #333;
        }}
        .metric {{
            font-size: 24px;
            font-weight: bold;
            color: #2196F3;
        }}
        .section {{
            margin: 40px 0;
        }}
        .section h2 {{
            color: #333;
            border-bottom: 2px solid #eee;
            padding-bottom: 10px;
        }}
        .category-results {{
            margin: 30px 0;
        }}
        .category-header {{
            background: #f0f0f0;
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 20px;
        }}
        .category-header h3 {{
            margin: 0;
            color: #333;
        }}
        .divergence-list {{
            background: #fff3cd;
            border: 1px solid #ffeaa7;
            border-radius: 8px;
            padding: 20px;
            margin: 20px 0;
        }}
        .divergence-item {{
            margin: 15px 0;
            padding: 15px;
            background: white;
            border-radius: 4px;
            border-left: 4px solid #ff6b6b;
        }}
        .divergence-item h4 {{
            margin: 0 0 10px 0;
            color: #333;
        }}
        .code-block {{
            background: #f8f8f8;
            padding: 10px;
            border-radius: 4px;
            font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
            font-size: 12px;
            overflow-x: auto;
            margin: 10px 0;
        }}
        .comparison-table {{
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }}
        .comparison-table th,
        .comparison-table td {{
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }}
        .comparison-table th {{
            background-color: #f5f5f5;
            font-weight: bold;
        }}
        .comparison-table tr:hover {{
            background-color: #f9f9f9;
        }}
        .progress-bar {{
            width: 100%;
            height: 20px;
            background-color: #e0e0e0;
            border-radius: 10px;
            overflow: hidden;
            margin: 10px 0;
        }}
        .progress-fill {{
            height: 100%;
            background-color: #4CAF50;
            transition: width 0.3s ease;
        }}
        .progress-fill.warn {{
            background-color: #FF9800;
        }}
        .progress-fill.fail {{
            background-color: #F44336;
        }}
        .accordion {{
            margin: 20px 0;
        }}
        .accordion-item {{
            border: 1px solid #ddd;
            border-radius: 4px;
            margin-bottom: 10px;
        }}
        .accordion-header {{
            background: #f5f5f5;
            padding: 15px;
            cursor: pointer;
            user-select: none;
        }}
        .accordion-header:hover {{
            background: #eeeeee;
        }}
        .accordion-content {{
            padding: 15px;
            display: none;
        }}
        .accordion-content.active {{
            display: block;
        }}
        .footer {{
            margin-top: 50px;
            padding-top: 20px;
            border-top: 1px solid #eee;
            color: #666;
            font-size: 14px;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>ESM Format Cross-Language Conformance Report</h1>
            <div class="subtitle">
                Generated on {timestamp}<br>
                Languages tested: {languages_tested}<br>
                Overall status: <span class="status {overall_status_class}">{overall_status}</span>
            </div>
        </div>

        <div class="summary-grid">
            <div class="summary-card">
                <h3>Overall Consistency</h3>
                <div class="metric">{overall_score:.1%}</div>
                <div class="progress-bar">
                    <div class="progress-fill {progress_class}" style="width: {overall_score:.1%}"></div>
                </div>
            </div>
            <div class="summary-card">
                <h3>Languages Tested</h3>
                <div class="metric">{num_languages}</div>
                <div>{languages_list}</div>
            </div>
            <div class="summary-card">
                <h3>Critical Divergences</h3>
                <div class="metric">{critical_divergences}</div>
                <div>Categories with score < 70%</div>
            </div>
            <div class="summary-card">
                <h3>Test Categories</h3>
                <div class="metric">{total_categories}</div>
                <div>Validation, Display, Substitution, Graph</div>
            </div>
        </div>

        <div class="section">
            <h2>Category Results</h2>
            {category_results}
        </div>

        {divergence_details}

        <div class="footer">
            <p>This report was generated automatically by the ESM Format cross-language conformance testing infrastructure.</p>
            <p>For more information, see the <a href="https://github.com/ctessum/EarthSciSerialization">EarthSciSerialization project</a>.</p>
        </div>
    </div>

    <script>
        // Accordion functionality
        document.querySelectorAll('.accordion-header').forEach(header => {{
            header.addEventListener('click', () => {{
                const content = header.nextElementSibling;
                const isActive = content.classList.contains('active');

                // Close all accordion items
                document.querySelectorAll('.accordion-content').forEach(item => {{
                    item.classList.remove('active');
                }});

                // Open clicked item if it wasn't already open
                if (!isActive) {{
                    content.classList.add('active');
                }}
            }});
        }});
    </script>
</body>
</html>
"""


def format_category_results(analysis_data: Dict[str, Any]) -> str:
    """Format category results for HTML display."""
    html = ""

    categories = [
        ("validation", "Validation Tests", analysis_data.get("validation_analysis", {})),
        ("display", "Display Format Tests", analysis_data.get("display_analysis", {})),
        ("substitution", "Substitution Tests", analysis_data.get("substitution_analysis", {})),
        ("graph", "Graph Generation Tests", analysis_data.get("graph_analysis", {})),
    ]

    for category_id, category_name, category_data in categories:
        if not category_data or "summary" not in category_data:
            continue

        summary = category_data["summary"]
        total_tests = summary.get("total_tests", summary.get("total_files", 0))
        divergent_tests = summary.get("divergent_tests", summary.get("divergent_files", 0))
        consistent_tests = total_tests - divergent_tests

        if total_tests > 0:
            consistency_score = consistent_tests / total_tests
            status_class = (
                "pass"
                if consistency_score >= 0.9
                else "warn"
                if consistency_score >= 0.7
                else "fail"
            )

            html += f"""
            <div class="category-results">
                <div class="category-header">
                    <h3>{category_name} <span class="status {status_class}">{consistency_score:.1%}</span></h3>
                    <div>Total: {total_tests} tests | Consistent: {consistent_tests} | Divergent: {divergent_tests}</div>
                    <div class="progress-bar">
                        <div class="progress-fill {status_class}" style="width: {consistency_score:.1%}"></div>
                    </div>
                </div>
            </div>
            """

    return html


def format_divergence_details(analysis_data: Dict[str, Any]) -> str:
    """Format detailed divergence information for HTML display."""
    html = '<div class="section"><h2>Divergence Details</h2>'

    categories = [
        ("validation", "Validation Divergences", analysis_data.get("validation_analysis", {})),
        ("display", "Display Format Divergences", analysis_data.get("display_analysis", {})),
        (
            "substitution",
            "Substitution Divergences",
            analysis_data.get("substitution_analysis", {}),
        ),
        ("graph", "Graph Generation Divergences", analysis_data.get("graph_analysis", {})),
    ]

    has_divergences = False

    for category_id, category_name, category_data in categories:
        divergences = category_data.get("divergence", {})

        if not divergences:
            continue

        has_divergences = True
        html += f"""
        <div class="accordion">
            <div class="accordion-item">
                <div class="accordion-header">
                    <h3>{category_name} ({len(divergences)} files with divergences)</h3>
                </div>
                <div class="accordion-content">
        """

        for filename, divergence_data in divergences.items():
            html += f'<div class="divergence-item"><h4>{filename}</h4>'

            if category_id == "validation":
                # Validation divergences
                html += f"<p><strong>Languages:</strong> {', '.join(divergence_data.get('languages', []))}</p>"
                if "inconsistencies" in divergence_data:
                    html += "<p><strong>Inconsistencies:</strong></p><ul>"
                    for inconsistency in divergence_data["inconsistencies"]:
                        html += f"<li>{inconsistency}</li>"
                    html += "</ul>"

            elif category_id == "display":
                # Display divergences
                if isinstance(divergence_data, list):
                    for divergence in divergence_data:
                        html += f"""
                        <p><strong>Type:</strong> {divergence.get("type", "Unknown")}</p>
                        <p><strong>Input:</strong> <code>{divergence.get("input", "")}</code></p>
                        <p><strong>Reference ({divergence.get("reference_lang", "")}):</strong>
                           <span class="code-block">{divergence.get("reference_output", "")}</span></p>
                        <p><strong>Divergent ({divergence.get("divergent_lang", "")}):</strong>
                           <span class="code-block">{divergence.get("divergent_output", "")}</span></p>
                        """

            elif category_id == "substitution":
                # Substitution divergences
                if isinstance(divergence_data, list):
                    for divergence in divergence_data:
                        html += f"""
                        <p><strong>Input Expression:</strong> <code>{divergence.get("input", "")}</code></p>
                        <p><strong>Substitutions:</strong> <code>{divergence.get("substitutions", {})}</code></p>
                        <p><strong>Reference ({divergence.get("reference_lang", "")}):</strong>
                           <span class="code-block">{divergence.get("reference_result", "")}</span></p>
                        <p><strong>Divergent ({divergence.get("divergent_lang", "")}):</strong>
                           <span class="code-block">{divergence.get("divergent_result", "")}</span></p>
                        """

            elif category_id == "graph":
                # Graph divergences
                if isinstance(divergence_data, list):
                    for divergence in divergence_data:
                        divergence_type = divergence.get("type", "Unknown")
                        html += f"<p><strong>Type:</strong> {divergence_type}</p>"

                        if divergence_type in ["node_count", "edge_count"]:
                            html += f"""
                            <p><strong>Reference ({divergence.get("reference_lang", "")}):</strong> {divergence.get("reference_count", "N/A")}</p>
                            <p><strong>Divergent ({divergence.get("divergent_lang", "")}):</strong> {divergence.get("divergent_count", "N/A")}</p>
                            """
                        elif divergence_type == "dot_structure":
                            html += f"""
                            <p><strong>Reference Lang:</strong> {divergence.get("reference_lang", "")}</p>
                            <p><strong>Divergent Lang:</strong> {divergence.get("divergent_lang", "")}</p>
                            <p><strong>Diff:</strong></p>
                            <div class="code-block">{"<br>".join(divergence.get("diff", []))}</div>
                            """

            html += "</div>"

        html += """
                </div>
            </div>
        </div>
        """

    if not has_divergences:
        html += "<p>🎉 No divergences found! All language implementations are consistent.</p>"

    html += "</div>"
    return html


def generate_html_report(analysis_file: Path, output_file: Path):
    """Generate HTML conformance report from analysis data."""

    # Load analysis data
    with open(analysis_file, "r") as f:
        analysis_data = json.load(f)

    # Extract key metrics
    languages_tested = analysis_data.get("languages_tested", [])
    divergence_summary = analysis_data.get("divergence_summary", {})
    overall_status = analysis_data.get("overall_status", "UNKNOWN")
    overall_score = divergence_summary.get("overall_score", 0.0)

    # Calculate derived metrics
    num_languages = len(languages_tested)
    languages_list = ", ".join(languages_tested)
    critical_divergences = len(divergence_summary.get("critical_divergences", []))
    total_categories = 4

    # Determine CSS classes based on status
    overall_status_class = overall_status.lower()
    progress_class = "pass" if overall_score >= 0.9 else "warn" if overall_score >= 0.7 else "fail"

    # Generate report sections
    category_results = format_category_results(analysis_data)
    divergence_details = format_divergence_details(analysis_data)

    # Generate final HTML
    html_content = HTML_TEMPLATE.format(
        timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC"),
        languages_tested=languages_list,
        overall_status=overall_status,
        overall_status_class=overall_status_class,
        overall_score=overall_score,
        progress_class=progress_class,
        num_languages=num_languages,
        languages_list=languages_list,
        critical_divergences=critical_divergences,
        total_categories=total_categories,
        category_results=category_results,
        divergence_details=divergence_details,
    )

    # Write HTML file
    output_file.parent.mkdir(parents=True, exist_ok=True)
    with open(output_file, "w") as f:
        f.write(html_content)

    print(f"HTML conformance report generated: {output_file}")


def main():
    parser = argparse.ArgumentParser(description="Generate HTML conformance report")
    parser.add_argument("--analysis-file", required=True, help="JSON analysis file from comparison")
    parser.add_argument("--output-file", required=True, help="Output HTML file path")

    args = parser.parse_args()

    analysis_file = Path(args.analysis_file)
    output_file = Path(args.output_file)

    if not analysis_file.exists():
        print(f"Error: Analysis file not found: {analysis_file}")
        return 1

    try:
        generate_html_report(analysis_file, output_file)
        return 0
    except Exception as e:
        print(f"Error generating HTML report: {e}")
        return 1


if __name__ == "__main__":
    exit(main())
