// Render every math piece of every printed Markdown document in a directory with KaTeX
// (strict mode, mhchem loaded), as a Markdown renderer with remark-math and rehype-katex
// would. Used by doc-corpus.py --katex; needs the `katex` npm package on NODE_PATH.
//
//   NODE_PATH=<dir>/node_modules node katex-check.cjs <dir with .md files>
//
// The pieces: each display (`$$` lines, or `$$…$$` on one line) and each `[$…$]`
// directive label, outside the front matter and fenced blocks.

const fs = require("fs");
const path = require("path");
const katex = require("katex");
require("katex/contrib/mhchem");

// The escape form `\esm{op}{fields}{args}` (Notation.lean, design choice 10).
const macros = { "\\esm": "\\operatorname{#1}_{#2}\\left(#3\\right)" };

function pieces(text) {
  const out = [];
  const lines = text.split("\n");
  let i = 0;
  if (lines[0] === "---") {
    i = 1;
    while (i < lines.length && lines[i] !== "---") i++;
    i++;
  }
  for (; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith("```")) {
      i++;
      while (i < lines.length && !lines[i].startsWith("```")) i++;
      continue;
    }
    const one = l.match(/^\$\$(.+)\$\$/);
    if (one) {
      out.push(one[1]);
      continue;
    }
    if (l.startsWith("$$")) {
      const body = [];
      i++;
      while (i < lines.length && !lines[i].startsWith("$$")) body.push(lines[i++]);
      out.push(body.join("\n"));
      continue;
    }
    for (const m of l.matchAll(/\[\$([^$\n]+)\$\]/g)) out.push(m[1]);
  }
  return out;
}

const dir = process.argv[2];
let n = 0;
const fails = [];
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".md")).sort()) {
  for (const p of pieces(fs.readFileSync(path.join(dir, f), "utf8"))) {
    n++;
    try {
      katex.renderToString(p, { displayMode: true, throwOnError: true, strict: "error", macros: { ...macros } });
    } catch (e) {
      fails.push(`${f}: ${e.message.split("\n")[0]}\n    ${p.slice(0, 200)}`);
    }
  }
}
console.log(`KaTeX: ${n - fails.length} / ${n} math pieces render`);
if (fails.length) {
  console.error(fails.slice(0, 20).join("\n"));
  process.exit(1);
}
