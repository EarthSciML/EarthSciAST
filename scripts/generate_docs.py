#!/usr/bin/env python3
"""
ESM Format Documentation Generation System

Comprehensive documentation generator that:
1. Extracts API documentation from source code across all languages
2. Generates cross-language documentation with linking
3. Creates example code generation
4. Sets up automated documentation building infrastructure
"""

import json
import re
import argparse
from pathlib import Path
from typing import Dict, List, Any, Tuple
from dataclasses import dataclass, asdict
from collections import defaultdict


@dataclass
class APIFunction:
    """Represents a documented API function."""

    name: str
    language: str
    file_path: str
    line_number: int
    signature: str
    docstring: str
    parameters: List[Dict[str, str]]
    return_type: str
    examples: List[str]
    see_also: List[str]
    tags: List[str]


@dataclass
class APIType:
    """Represents a documented type/struct/class."""

    name: str
    language: str
    file_path: str
    line_number: int
    definition: str
    docstring: str
    fields: List[Dict[str, str]]
    methods: List[str]
    examples: List[str]
    tags: List[str]


class DocumentationExtractor:
    """Extracts documentation from source code across multiple languages."""

    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.packages_dir = project_root / "pkg"
        self.docs_dir = project_root / "docs"

    def extract_all(self) -> Dict[str, Any]:
        """Extract documentation from all supported languages."""
        docs = {
            "functions": [],
            "types": [],
            "languages": [],
            "cross_references": {},
            "examples": [],
        }

        # Extract from each language package
        language_extractors = {
            "julia": self._extract_julia_docs,
            "python": self._extract_python_docs,
            "typescript": self._extract_typescript_docs,
            "rust": self._extract_rust_docs,
        }

        for lang_name, extractor in language_extractors.items():
            lang_docs = extractor()
            docs["functions"].extend(lang_docs["functions"])
            docs["types"].extend(lang_docs["types"])
            docs["languages"].append(lang_name)
            docs["examples"].extend(lang_docs.get("examples", []))

        # Build cross-references between languages
        docs["cross_references"] = self._build_cross_references(docs["functions"], docs["types"])

        return docs

    def _extract_julia_docs(self) -> Dict[str, Any]:
        """Extract documentation from Julia package."""
        julia_dir = self.packages_dir / "EarthSciAST.jl"
        src_dir = julia_dir / "src"

        functions = []
        types = []
        examples = []

        if not src_dir.exists():
            return {"functions": functions, "types": types, "examples": examples}

        # Extract from main module file
        main_file = src_dir / "EarthSciAST.jl"
        if main_file.exists():
            functions.extend(self._parse_julia_exports(main_file))

        # Extract from all source files
        for julia_file in src_dir.rglob("*.jl"):
            file_functions, file_types = self._parse_julia_file(julia_file)
            functions.extend(file_functions)
            types.extend(file_types)

        # Extract examples from test files
        test_dir = julia_dir / "test"
        if test_dir.exists():
            examples.extend(self._extract_julia_examples(test_dir))

        return {"functions": functions, "types": types, "examples": examples}

    def _parse_julia_exports(self, file_path: Path) -> List[APIFunction]:
        """Parse Julia export statements to identify public API."""
        functions = []

        try:
            content = file_path.read_text()

            # Find export block
            export_match = re.search(
                r"export\s+(.*?)(?=\n\n|\nend|\ninclude|\Z)", content, re.DOTALL
            )
            if not export_match:
                return functions

            exports_text = export_match.group(1)

            # Extract individual exports
            export_items = re.findall(r"([a-zA-Z_][a-zA-Z0-9_!]*)", exports_text)

            for item in export_items:
                # Create basic function entry for exported items
                functions.append(
                    APIFunction(
                        name=item,
                        language="julia",
                        file_path=str(file_path),
                        line_number=0,
                        signature=f"{item}(...)",
                        docstring="",
                        parameters=[],
                        return_type="",
                        examples=[],
                        see_also=[],
                        tags=["exported"],
                    )
                )

        except Exception as e:
            print(f"Warning: Could not parse Julia exports from {file_path}: {e}")

        return functions

    def _parse_julia_file(self, file_path: Path) -> Tuple[List[APIFunction], List[APIType]]:
        """Parse Julia file for functions and types with documentation."""
        functions = []
        types = []

        try:
            content = file_path.read_text()
            lines = content.split("\n")

            i = 0
            while i < len(lines):
                line = lines[i].strip()

                # Look for docstrings (triple quotes)
                if line.startswith('"""'):
                    doc_lines = []
                    i += 1

                    # Collect docstring content
                    while i < len(lines) and not lines[i].strip().endswith('"""'):
                        doc_lines.append(lines[i])
                        i += 1

                    if i < len(lines):
                        doc_lines.append(lines[i].replace('"""', ""))
                        i += 1

                    docstring = "\n".join(doc_lines).strip()

                    # Look for function or type definition after docstring
                    while i < len(lines) and not lines[i].strip():
                        i += 1

                    if i < len(lines):
                        def_line = lines[i].strip()

                        # Function definition
                        func_match = re.match(r"function\s+([a-zA-Z_][a-zA-Z0-9_!]*)", def_line)
                        if func_match:
                            functions.append(
                                APIFunction(
                                    name=func_match.group(1),
                                    language="julia",
                                    file_path=str(file_path),
                                    line_number=i + 1,
                                    signature=def_line,
                                    docstring=docstring,
                                    parameters=[],
                                    return_type="",
                                    examples=[],
                                    see_also=[],
                                    tags=["documented"],
                                )
                            )

                        # Type definition
                        type_match = re.match(
                            r"(?:struct|mutable struct)\s+([a-zA-Z_][a-zA-Z0-9_]*)", def_line
                        )
                        if type_match:
                            types.append(
                                APIType(
                                    name=type_match.group(1),
                                    language="julia",
                                    file_path=str(file_path),
                                    line_number=i + 1,
                                    definition=def_line,
                                    docstring=docstring,
                                    fields=[],
                                    methods=[],
                                    examples=[],
                                    tags=["documented"],
                                )
                            )

                i += 1

        except Exception as e:
            print(f"Warning: Could not parse Julia file {file_path}: {e}")

        return functions, types

    def _extract_julia_examples(self, test_dir: Path) -> List[Dict[str, str]]:
        """Extract examples from Julia test files."""
        examples = []

        for test_file in test_dir.glob("*.jl"):
            try:
                content = test_file.read_text()

                # Look for @testset blocks
                testset_matches = re.finditer(
                    r'@testset\s+"([^"]+)"\s+begin(.*?)end', content, re.DOTALL
                )

                for match in testset_matches:
                    test_name = match.group(1)
                    test_code = match.group(2).strip()

                    examples.append(
                        {
                            "name": test_name,
                            "language": "julia",
                            "code": test_code,
                            "file": str(test_file),
                            "type": "test",
                        }
                    )

            except Exception as e:
                print(f"Warning: Could not extract examples from {test_file}: {e}")

        return examples

    def _extract_python_docs(self) -> Dict[str, Any]:
        """Extract documentation from Python package."""
        python_dir = self.packages_dir / "earthsci-ast-py"

        functions = []
        types = []
        examples = []

        if not python_dir.exists():
            return {"functions": functions, "types": types, "examples": examples}

        # Find all Python files
        for py_file in python_dir.rglob("*.py"):
            if "__pycache__" in str(py_file):
                continue

            file_functions, file_types = self._parse_python_file(py_file)
            functions.extend(file_functions)
            types.extend(file_types)

        return {"functions": functions, "types": types, "examples": examples}

    def _parse_python_file(self, file_path: Path) -> Tuple[List[APIFunction], List[APIType]]:
        """Parse Python file for functions and classes with docstrings."""
        functions = []
        types = []

        try:
            content = file_path.read_text()
            lines = content.split("\n")

            i = 0
            while i < len(lines):
                line = lines[i].strip()

                # Function definition
                func_match = re.match(r"def\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\((.*?)\):", line)
                if func_match:
                    func_name = func_match.group(1)
                    params = func_match.group(2)

                    # Look for docstring
                    i += 1
                    docstring = ""
                    if i < len(lines) and ('"""' in lines[i] or "'''" in lines[i]):
                        quote_char = '"""' if '"""' in lines[i] else "'''"
                        doc_lines = []

                        if lines[i].strip().count(quote_char) == 2:
                            # Single line docstring
                            docstring = lines[i].strip().replace(quote_char, "")
                        else:
                            # Multi-line docstring
                            doc_lines.append(lines[i].replace(quote_char, ""))
                            i += 1
                            while i < len(lines) and quote_char not in lines[i]:
                                doc_lines.append(lines[i])
                                i += 1
                            if i < len(lines):
                                doc_lines.append(lines[i].replace(quote_char, ""))
                            docstring = "\n".join(doc_lines).strip()

                    functions.append(
                        APIFunction(
                            name=func_name,
                            language="python",
                            file_path=str(file_path),
                            line_number=i + 1,
                            signature=f"def {func_name}({params}):",
                            docstring=docstring,
                            parameters=[],
                            return_type="",
                            examples=[],
                            see_also=[],
                            tags=[],
                        )
                    )

                # Class definition
                class_match = re.match(r"class\s+([a-zA-Z_][a-zA-Z0-9_]*)", line)
                if class_match:
                    class_name = class_match.group(1)

                    # Look for docstring
                    i += 1
                    docstring = ""
                    if i < len(lines) and ('"""' in lines[i] or "'''" in lines[i]):
                        quote_char = '"""' if '"""' in lines[i] else "'''"
                        doc_lines = []

                        if lines[i].strip().count(quote_char) == 2:
                            docstring = lines[i].strip().replace(quote_char, "")
                        else:
                            doc_lines.append(lines[i].replace(quote_char, ""))
                            i += 1
                            while i < len(lines) and quote_char not in lines[i]:
                                doc_lines.append(lines[i])
                                i += 1
                            if i < len(lines):
                                doc_lines.append(lines[i].replace(quote_char, ""))
                            docstring = "\n".join(doc_lines).strip()

                    types.append(
                        APIType(
                            name=class_name,
                            language="python",
                            file_path=str(file_path),
                            line_number=i + 1,
                            definition=f"class {class_name}:",
                            docstring=docstring,
                            fields=[],
                            methods=[],
                            examples=[],
                            tags=[],
                        )
                    )

                i += 1

        except Exception as e:
            print(f"Warning: Could not parse Python file {file_path}: {e}")

        return functions, types

    def _extract_typescript_docs(self) -> Dict[str, Any]:
        """Extract documentation from TypeScript package."""
        ts_dirs = [self.packages_dir / "earthsci-ast-ts", self.packages_dir / "earthsci-ast-editor"]

        functions = []
        types = []
        examples = []

        for ts_dir in ts_dirs:
            if not ts_dir.exists():
                continue

            # Find TypeScript files
            for ts_file in ts_dir.rglob("*.ts"):
                if "node_modules" in str(ts_file) or ".d.ts" in str(ts_file):
                    continue

                file_functions, file_types = self._parse_typescript_file(ts_file)
                functions.extend(file_functions)
                types.extend(file_types)

        return {"functions": functions, "types": types, "examples": examples}

    def _parse_typescript_file(self, file_path: Path) -> Tuple[List[APIFunction], List[APIType]]:
        """Parse TypeScript file for functions and interfaces."""
        functions = []
        types = []

        try:
            content = file_path.read_text()
            lines = content.split("\n")

            i = 0
            while i < len(lines):
                line = lines[i].strip()

                # Function definition
                func_match = re.match(
                    r"export\s+(?:function\s+)?([a-zA-Z_][a-zA-Z0-9_]*)\s*\(", line
                )
                if func_match:
                    func_name = func_match.group(1)

                    # Look for JSDoc comment above
                    docstring = ""
                    j = i - 1
                    if j >= 0 and lines[j].strip() == "*/":
                        doc_lines = []
                        while j >= 0 and not lines[j].strip().startswith("/**"):
                            if lines[j].strip().startswith("*"):
                                doc_lines.insert(0, lines[j].strip()[1:].strip())
                            j -= 1
                        if j >= 0 and lines[j].strip().startswith("/**"):
                            doc_lines.insert(0, lines[j].strip()[3:].strip())
                        docstring = "\n".join(doc_lines).strip()

                    functions.append(
                        APIFunction(
                            name=func_name,
                            language="typescript",
                            file_path=str(file_path),
                            line_number=i + 1,
                            signature=line,
                            docstring=docstring,
                            parameters=[],
                            return_type="",
                            examples=[],
                            see_also=[],
                            tags=["exported"] if "export" in line else [],
                        )
                    )

                # Interface definition
                interface_match = re.match(r"export\s+interface\s+([a-zA-Z_][a-zA-Z0-9_]*)", line)
                if interface_match:
                    interface_name = interface_match.group(1)

                    # Look for JSDoc comment above
                    docstring = ""
                    j = i - 1
                    if j >= 0 and lines[j].strip() == "*/":
                        doc_lines = []
                        while j >= 0 and not lines[j].strip().startswith("/**"):
                            if lines[j].strip().startswith("*"):
                                doc_lines.insert(0, lines[j].strip()[1:].strip())
                            j -= 1
                        if j >= 0 and lines[j].strip().startswith("/**"):
                            doc_lines.insert(0, lines[j].strip()[3:].strip())
                        docstring = "\n".join(doc_lines).strip()

                    types.append(
                        APIType(
                            name=interface_name,
                            language="typescript",
                            file_path=str(file_path),
                            line_number=i + 1,
                            definition=line,
                            docstring=docstring,
                            fields=[],
                            methods=[],
                            examples=[],
                            tags=["exported"],
                        )
                    )

                i += 1

        except Exception as e:
            print(f"Warning: Could not parse TypeScript file {file_path}: {e}")

        return functions, types

    def _extract_rust_docs(self) -> Dict[str, Any]:
        """Extract documentation from Rust package."""
        rust_dir = self.packages_dir / "earthsci-ast-ts"

        functions = []
        types = []
        examples = []

        if not rust_dir.exists():
            return {"functions": functions, "types": types, "examples": examples}

        src_dir = rust_dir / "src"
        if src_dir.exists():
            for rust_file in src_dir.rglob("*.rs"):
                file_functions, file_types = self._parse_rust_file(rust_file)
                functions.extend(file_functions)
                types.extend(file_types)

        return {"functions": functions, "types": types, "examples": examples}

    def _parse_rust_file(self, file_path: Path) -> Tuple[List[APIFunction], List[APIType]]:
        """Parse Rust file for functions and structs."""
        functions = []
        types = []

        try:
            content = file_path.read_text()
            lines = content.split("\n")

            i = 0
            while i < len(lines):
                line = lines[i].strip()

                # Look for doc comments
                doc_lines = []
                while i < len(lines) and lines[i].strip().startswith("///"):
                    doc_lines.append(lines[i].strip()[3:].strip())
                    i += 1

                if i >= len(lines):
                    break

                docstring = "\n".join(doc_lines).strip()
                line = lines[i].strip()

                # Function definition
                func_match = re.match(r"pub\s+fn\s+([a-zA-Z_][a-zA-Z0-9_]*)", line)
                if func_match:
                    func_name = func_match.group(1)

                    functions.append(
                        APIFunction(
                            name=func_name,
                            language="rust",
                            file_path=str(file_path),
                            line_number=i + 1,
                            signature=line,
                            docstring=docstring,
                            parameters=[],
                            return_type="",
                            examples=[],
                            see_also=[],
                            tags=["public"],
                        )
                    )

                # Struct definition
                struct_match = re.match(r"pub\s+struct\s+([a-zA-Z_][a-zA-Z0-9_]*)", line)
                if struct_match:
                    struct_name = struct_match.group(1)

                    types.append(
                        APIType(
                            name=struct_name,
                            language="rust",
                            file_path=str(file_path),
                            line_number=i + 1,
                            definition=line,
                            docstring=docstring,
                            fields=[],
                            methods=[],
                            examples=[],
                            tags=["public"],
                        )
                    )

                i += 1

        except Exception as e:
            print(f"Warning: Could not parse Rust file {file_path}: {e}")

        return functions, types

    def _build_cross_references(
        self, functions: List[APIFunction], types: List[APIType]
    ) -> Dict[str, Dict[str, List[str]]]:
        """Build cross-references between functions and types across languages."""
        cross_refs = defaultdict(lambda: defaultdict(list))

        # Group by name
        func_by_name = defaultdict(list)
        type_by_name = defaultdict(list)

        for func in functions:
            func_by_name[func.name].append(func)

        for typ in types:
            type_by_name[typ.name].append(typ)

        # Find cross-language equivalents
        for name, funcs in func_by_name.items():
            if len(funcs) > 1:
                languages = [f.language for f in funcs]
                for func in funcs:
                    other_langs = [lang for lang in languages if lang != func.language]
                    cross_refs[func.language][name] = other_langs

        for name, types in type_by_name.items():
            if len(types) > 1:
                languages = [t.language for t in types]
                for typ in types:
                    other_langs = [lang for lang in languages if lang != typ.language]
                    cross_refs[typ.language][name].extend(other_langs)

        return dict(cross_refs)


class DocumentationGenerator:
    """Generates comprehensive documentation from extracted API information."""

    # Julia Documenter.jl `[text](@ref)` / `[text](@ref target)` cross-references
    # are meaningful only inside a Documenter.jl-built site. In our Hugo build
    # they render as broken `<a href="@ref">` links and fail the lychee gate.
    # Unwrap them to plain `text` so the prose still reads naturally.
    _DOCUMENTER_REF_RE = re.compile(r"\[([^\]]+)\]\(@ref(?:\s+[^)]*)?\)")

    @classmethod
    def _sanitize_docstring(cls, text: str) -> str:
        if not text:
            return text
        return cls._DOCUMENTER_REF_RE.sub(r"\1", text)

    def __init__(self, project_root: Path, output_dir: Path):
        self.project_root = project_root
        self.output_dir = output_dir
        self.api_docs = {}

    def generate_all_documentation(self, docs_data: Dict[str, Any]):
        """Generate all documentation formats."""
        self.api_docs = docs_data

        # Ensure output directories exist
        (self.output_dir / "api").mkdir(parents=True, exist_ok=True)
        (self.output_dir / "examples").mkdir(parents=True, exist_ok=True)
        (self.output_dir / "generated").mkdir(parents=True, exist_ok=True)

        # Generate API reference documentation
        self._generate_api_reference()

        # Generate cross-language comparison
        self._generate_cross_language_comparison()

        # Generate example documentation
        self._generate_examples_documentation()

        # Generate index pages
        self._generate_index_pages()

        print(f"Documentation generated in: {self.output_dir}")

    def _generate_api_reference(self):
        """Generate API reference documentation for each language."""
        api_dir = self.output_dir / "api"

        # Group by language
        functions_by_lang = defaultdict(list)
        types_by_lang = defaultdict(list)

        for func in self.api_docs["functions"]:
            functions_by_lang[func.language].append(func)

        for typ in self.api_docs["types"]:
            types_by_lang[typ.language].append(typ)

        # Generate for each language
        for lang in self.api_docs["languages"]:
            lang_file = api_dir / f"{lang}.md"

            with open(lang_file, "w") as f:
                f.write(f"# {lang.title()} API Reference\n\n")
                f.write(f"Complete API reference for the ESM Format {lang.title()} library.\n\n")

                # Functions
                funcs = functions_by_lang[lang]
                if funcs:
                    f.write("## Functions\n\n")

                    for func in sorted(funcs, key=lambda x: x.name):
                        f.write(f"### {func.name}\n\n")
                        f.write(f"**File:** `{func.file_path}:{func.line_number}`\n\n")
                        f.write(f"**Signature:**\n```{lang}\n{func.signature}\n```\n\n")

                        if func.docstring:
                            f.write(
                                f"**Description:**\n{self._sanitize_docstring(func.docstring)}\n\n"
                            )

                        # Cross-language references
                        cross_refs = (
                            self.api_docs["cross_references"].get(lang, {}).get(func.name, [])
                        )
                        if cross_refs:
                            f.write("**Available in other languages:**\n")
                            for other_lang in cross_refs:
                                f.write(
                                    f"- [{other_lang.title()}]({other_lang}.md#{func.name.lower()})\n"
                                )
                            f.write("\n")

                        f.write("---\n\n")

                # Types
                types = types_by_lang[lang]
                if types:
                    f.write("## Types\n\n")

                    for typ in sorted(types, key=lambda x: x.name):
                        f.write(f"### {typ.name}\n\n")
                        f.write(f"**File:** `{typ.file_path}:{typ.line_number}`\n\n")
                        f.write(f"**Definition:**\n```{lang}\n{typ.definition}\n```\n\n")

                        if typ.docstring:
                            f.write(
                                f"**Description:**\n{self._sanitize_docstring(typ.docstring)}\n\n"
                            )

                        # Cross-language references
                        cross_refs = (
                            self.api_docs["cross_references"].get(lang, {}).get(typ.name, [])
                        )
                        if cross_refs:
                            f.write("**Available in other languages:**\n")
                            for other_lang in cross_refs:
                                f.write(
                                    f"- [{other_lang.title()}]({other_lang}.md#{typ.name.lower()})\n"
                                )
                            f.write("\n")

                        f.write("---\n\n")

    def _generate_cross_language_comparison(self):
        """Generate cross-language comparison documentation."""
        comparison_file = self.output_dir / "generated" / "cross-language-comparison.md"

        with open(comparison_file, "w") as f:
            f.write("# Cross-Language API Comparison\n\n")
            f.write(
                "This document shows equivalent functionality across different ESM Format language implementations.\n\n"
            )

            # Find common function names
            func_names = defaultdict(list)
            for func in self.api_docs["functions"]:
                func_names[func.name].append(func)

            # Show functions available in multiple languages
            multi_lang_funcs = {name: funcs for name, funcs in func_names.items() if len(funcs) > 1}

            if multi_lang_funcs:
                f.write("## Functions Available in Multiple Languages\n\n")

                for func_name, funcs in sorted(multi_lang_funcs.items()):
                    f.write(f"### {func_name}\n\n")

                    for func in sorted(funcs, key=lambda x: x.language):
                        f.write(f"**{func.language.title()}:**\n")
                        f.write(f"```{func.language}\n{func.signature}\n```\n\n")
                        if func.docstring:
                            f.write(
                                f"> {self._sanitize_docstring(func.docstring).split('.')[0]}.\n\n"
                            )

                    f.write("---\n\n")

            # Find common type names
            type_names = defaultdict(list)
            for typ in self.api_docs["types"]:
                type_names[typ.name].append(typ)

            # Show types available in multiple languages
            multi_lang_types = {name: types for name, types in type_names.items() if len(types) > 1}

            if multi_lang_types:
                f.write("## Types Available in Multiple Languages\n\n")

                for type_name, types in sorted(multi_lang_types.items()):
                    f.write(f"### {type_name}\n\n")

                    for typ in sorted(types, key=lambda x: x.language):
                        f.write(f"**{typ.language.title()}:**\n")
                        f.write(f"```{typ.language}\n{typ.definition}\n```\n\n")
                        if typ.docstring:
                            f.write(
                                f"> {self._sanitize_docstring(typ.docstring).split('.')[0]}.\n\n"
                            )

                    f.write("---\n\n")

    def _generate_examples_documentation(self):
        """Generate examples documentation from test cases and fixtures."""
        examples_dir = self.output_dir / "examples"

        # Generate examples index. Use Hugo's branch-bundle convention
        # (`_index.md`); a plain `index.md` would mark the directory a *leaf*
        # bundle, which causes sibling per-language `.md` files to be treated as
        # page resources rather than rendered pages — leaving every link from
        # this index a 404 on the live site.
        index_file = examples_dir / "_index.md"
        with open(index_file, "w") as f:
            f.write("# Examples Index\n\n")
            f.write("Collection of examples showing how to use the ESM Format libraries.\n\n")

            # Extract examples from the docs data
            examples = self.api_docs.get("examples", [])

            if examples:
                # Group by language
                examples_by_lang = defaultdict(list)
                for example in examples:
                    examples_by_lang[example["language"]].append(example)

                for lang in sorted(examples_by_lang.keys()):
                    f.write(f"## {lang.title()} Examples\n\n")

                    for example in examples_by_lang[lang]:
                        example_name = example["name"]
                        safe_name = re.sub(
                            r"[^a-zA-Z0-9\-_]", "-", example_name.lower().replace(" ", "-")
                        )
                        f.write(f"- [{example_name}]({lang}-{safe_name}.md)\n")
                    f.write("\n")

                    # Generate individual example files
                    for example in examples_by_lang[lang]:
                        # Clean filename to avoid filesystem issues
                        safe_name = re.sub(
                            r"[^a-zA-Z0-9\-_]", "-", example["name"].lower().replace(" ", "-")
                        )
                        example_file = examples_dir / f"{lang}-{safe_name}.md"

                        with open(example_file, "w") as ef:
                            ef.write(f"# {example['name']} ({lang.title()})\n\n")
                            ef.write(f"**Source:** `{example['file']}`\n\n")
                            ef.write(f"```{lang}\n{example['code']}\n```\n\n")

    def _generate_index_pages(self):
        """Generate main index pages linking all documentation."""

        # Generate API index — branch bundle (`_index.md`), not a leaf bundle.
        # See note in `_generate_examples_documentation`.
        api_index = self.output_dir / "api" / "_index.md"
        with open(api_index, "w") as f:
            f.write("# API Reference Index\n\n")
            f.write("Complete API documentation for all ESM Format language implementations.\n\n")

            for lang in sorted(self.api_docs["languages"]):
                func_count = len([f for f in self.api_docs["functions"] if f.language == lang])
                type_count = len([t for t in self.api_docs["types"] if t.language == lang])

                f.write(f"## [{lang.title()}]({lang}.md)\n")
                f.write(f"- {func_count} functions\n")
                f.write(f"- {type_count} types\n\n")

            f.write("## Cross-Language Resources\n\n")
            f.write("- [Cross-Language Comparison](../generated/cross-language-comparison.md)\n")
            f.write("- [Examples Index](../examples/)\n\n")


def setup_documentation_infrastructure(project_root: Path):
    """Set up automated documentation building infrastructure."""

    # Create GitHub Actions workflow for documentation
    workflows_dir = project_root / ".github" / "workflows"
    workflows_dir.mkdir(parents=True, exist_ok=True)

    docs_workflow = workflows_dir / "docs.yml"

    with open(docs_workflow, "w") as f:
        f.write("""name: Generate Documentation

on:
  push:
    branches: [ main ]
    paths:
      - 'pkg/**'
      - 'docs/**'
      - 'scripts/generate_docs.py'
  pull_request:
    branches: [ main ]
    paths:
      - 'pkg/**'
      - 'docs/**'
      - 'scripts/generate_docs.py'

jobs:
  generate-docs:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v4

    - name: Set up Python
      uses: actions/setup-python@v4
      with:
        python-version: '3.11'

    - name: Set up Julia
      uses: julia-actions/setup-julia@v1
      with:
        version: '1.9'

    - name: Set up Node.js
      uses: actions/setup-node@v4
      with:
        node-version: '18'

    - name: Set up Rust
      uses: actions-rs/toolchain@v1
      with:
        toolchain: stable
        override: true

    - name: Generate documentation
      run: |
        python scripts/generate_docs.py --output docs/generated

    - name: Check documentation changes
      run: |
        git diff --exit-code docs/ || echo "Documentation updated"

    - name: Commit documentation updates
      if: github.event_name == 'push' && github.ref == 'refs/heads/main'
      run: |
        git config --local user.email "action@github.com"
        git config --local user.name "GitHub Action"
        git add docs/
        git diff --staged --quiet || git commit -m "Auto-update generated documentation"
        git push
""")

    # Create documentation configuration
    docs_config = project_root / "docs" / "_config.yml"

    with open(docs_config, "w") as f:
        f.write("""# ESM Format Documentation Configuration

# Site settings
title: "ESM Format Documentation"
description: "Complete documentation for the EarthSciML Serialization Format"
baseurl: ""
url: ""

# Build settings
markdown: kramdown
highlighter: rouge
theme: minima

# Navigation
header_pages:
  - getting-started/installation.md
  - api/index.md
  - examples/index.md
  - troubleshooting/index.md

# Plugins
plugins:
  - jekyll-feed
  - jekyll-sitemap
  - jekyll-seo-tag

# Exclude from processing
exclude:
  - .sass-cache/
  - .jekyll-cache/
  - gemfiles/
  - Gemfile
  - Gemfile.lock
  - node_modules/
  - vendor/

# Code highlighting
kramdown:
  syntax_highlighter: rouge
  syntax_highlighter_opts:
    line_numbers: true
""")


def main():
    """Main entry point for documentation generation."""
    parser = argparse.ArgumentParser(description="Generate ESM Format documentation")
    parser.add_argument(
        "--project-root", type=Path, default=Path.cwd(), help="Path to project root directory"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output directory for generated docs (default: docs/generated)",
    )
    parser.add_argument(
        "--setup-infrastructure",
        action="store_true",
        help="Set up automated documentation infrastructure",
    )

    args = parser.parse_args()

    project_root = args.project_root.resolve()
    output_dir = args.output or (project_root / "docs")

    print(f"Generating documentation for project: {project_root}")

    # Set up infrastructure if requested
    if args.setup_infrastructure:
        print("Setting up documentation infrastructure...")
        setup_documentation_infrastructure(project_root)

    # Extract documentation from source code
    print("Extracting documentation from source code...")
    extractor = DocumentationExtractor(project_root)
    docs_data = extractor.extract_all()

    print(f"Extracted {len(docs_data['functions'])} functions and {len(docs_data['types'])} types")
    print(f"Languages: {', '.join(docs_data['languages'])}")

    # Generate documentation
    print("Generating documentation files...")
    generator = DocumentationGenerator(project_root, output_dir)
    generator.generate_all_documentation(docs_data)

    # Save raw documentation data for future use
    docs_json = output_dir / "generated" / "api-data.json"
    docs_json.parent.mkdir(parents=True, exist_ok=True)

    with open(docs_json, "w") as f:
        # Convert dataclasses to dictionaries for JSON serialization
        serializable_data = {
            "functions": [asdict(func) for func in docs_data["functions"]],
            "types": [asdict(typ) for typ in docs_data["types"]],
            "languages": docs_data["languages"],
            "cross_references": docs_data["cross_references"],
            "examples": docs_data["examples"],
        }
        json.dump(serializable_data, f, indent=2, default=str)

    print(f"Raw documentation data saved to: {docs_json}")
    print("Documentation generation complete!")


if __name__ == "__main__":
    main()
