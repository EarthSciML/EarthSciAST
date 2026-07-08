// Host-side bridge between the earthsci-ast wasm build and the s2bindings
// Emscripten module (s2geometry compiled to WebAssembly).
//
// The toolkit is built for `wasm32-unknown-unknown` (wasm-bindgen); the s2
// kernel is a *separate* Emscripten module (`wasm/dist/s2bindings.mjs`) with an
// async `load()`. The two can't be statically linked, so the toolkit's Rust
// `crate::geometry` calls a small synchronous interface installed here on
// `globalThis.__earthsci_s2`. Install it ONCE, before running any model whose
// `intersect_polygon`/`polygon_area` uses a spherical or geodesic manifold.
//
//   import { load } from "<path>/s2bindings.mjs";     // s2bindings' async loader
//   import { installS2 } from "./s2_interop.mjs";
//   await installS2(load);                            // sets globalThis.__earthsci_s2
//   // ... now toolkit.simulate(...) can run spherical-geometry models
//
// `load` is injected so the caller controls where the s2 module (its `.mjs` +
// `.core.wasm`) resolves from — a bundler alias, a vendored copy, or a URL via
// `moduleArg.locateFile`. Coordinates are (lon, lat) in degrees throughout.

/** Wrap a loaded s2 module in the flat `{ clip, area }` shape Rust expects. */
export function makeInterface(s2) {
  return {
    // Clip shells `a` and `b` (flat [lon,lat,…], degrees) on the sphere and
    // return the overlap shell's vertices as a flat Float64Array (holes
    // dropped; empty for a disjoint / edge-touching clip). Matches the native
    // `geometry::intersect_polygon` shell concatenation.
    clip(a, b) {
      const pa = s2.SphericalPolygon.fromLonLat(a);
      const pb = s2.SphericalPolygon.fromLonLat(b);
      try {
        const c = pa.intersection(pb);
        try {
          if (c.isEmpty()) return new Float64Array(0);
          const out = [];
          for (const ring of c.rings()) {
            if (!ring.isHole) out.push(...ring.vertices);
          }
          return new Float64Array(out);
        } finally {
          c.free();
        }
      } finally {
        pa.free();
        pb.free();
      }
    },
    // Enclosed area of a shell (flat [lon,lat,…], degrees) in steradians.
    area(ring) {
      const p = s2.SphericalPolygon.fromLonLat(ring);
      try {
        return p.area();
      } finally {
        p.free();
      }
    },
  };
}

/**
 * Load the s2bindings module and install the sync interface on globalThis.
 * @param {(moduleArg?: object) => Promise<object>} load  s2bindings' async loader
 * @param {object} [moduleArg]  optional Emscripten overrides (e.g. locateFile)
 * @returns {Promise<{clip: Function, area: Function}>} the installed interface
 */
export async function installS2(load, moduleArg) {
  const s2 = await load(moduleArg);
  globalThis.__earthsci_s2 = makeInterface(s2);
  return globalThis.__earthsci_s2;
}
