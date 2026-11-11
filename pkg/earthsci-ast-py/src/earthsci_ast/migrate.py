"""Command line for the esm 2.0.0 codemod: ``python -m earthsci_ast.migrate``.

A thin entry point over :func:`earthsci_ast.migration.main`. The project ships
one command-line tool, the Rust ``esm`` binary; the codemod has a single
reference implementation, in Python, so its command line is this module.
"""

from __future__ import annotations

import sys

from .migration import main

if __name__ == "__main__":
    sys.exit(main())
