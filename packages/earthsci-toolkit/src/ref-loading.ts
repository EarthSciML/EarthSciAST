/**
 * Subsystem Reference Loading for the ESM format
 *
 * Resolves subsystem references (`ref` fields) by loading referenced ESM files
 * from local filesystem paths or remote URLs. Supports recursive resolution
 * and circular reference detection.
 *
 * Works in both Node.js (using dynamic fs import) and browser (using fetch)
 * environments.
 */

import type { DataLoader, EsmFile, Model, ReactionSystem } from './types.js'

/**
 * Error thrown when a circular reference is detected during subsystem resolution.
 */
export class CircularReferenceError extends Error {
  /** The chain of references that form the cycle */
  public readonly chain: string[]

  constructor(chain: string[]) {
    super(`Circular reference detected: ${chain.join(' -> ')}`)
    this.name = 'CircularReferenceError'
    this.chain = chain
  }
}

/**
 * Error thrown when a referenced file cannot be loaded or parsed.
 */
export class RefLoadError extends Error {
  /** The reference path or URL that failed to load */
  public readonly ref: string

  constructor(ref: string, cause?: Error) {
    const message = cause
      ? `Failed to load ref "${ref}": ${cause.message}`
      : `Failed to load ref "${ref}"`
    super(message)
    this.name = 'RefLoadError'
    this.ref = ref
  }
}

/**
 * Resolve all subsystem references in an ESM file by loading and inlining
 * the referenced content.
 *
 * For each subsystem with a `ref` field:
 * - If the ref starts with `http://` or `https://`, fetch from the URL
 * - Otherwise, resolve as a local file path relative to basePath and read with fs
 *
 * The function mutates the input file in place, replacing ref-only subsystems
 * with the resolved content. Resolution is recursive: if a loaded subsystem
 * itself contains refs, those are resolved too.
 *
 * @param file - The ESM file to resolve (mutated in place)
 * @param basePath - Base directory for resolving relative file paths
 * @throws CircularReferenceError if a circular reference chain is detected
 * @throws RefLoadError if a referenced file cannot be loaded or parsed
 */
export async function resolveSubsystemRefs(
  file: EsmFile,
  basePath: string
): Promise<void> {
  const visited = new Set<string>()
  const resolving = new Set<string>()

  // Process all models
  if (file.models) {
    for (const [name, model] of Object.entries(file.models)) {
      await resolveModelRefs(model, basePath, visited, resolving, [name])
    }
  }

  // Process all reaction systems
  if (file.reaction_systems) {
    for (const [name, rs] of Object.entries(file.reaction_systems)) {
      await resolveReactionSystemRefs(rs, basePath, visited, resolving, [name])
    }
  }
}

/**
 * Recursively resolve refs in a Model's subsystems.
 */
async function resolveModelRefs(
  model: Model,
  basePath: string,
  visited: Set<string>,
  resolving: Set<string>,
  refChain: string[]
): Promise<void> {
  if (!model.subsystems) return

  for (const [subName, subsystem] of Object.entries(model.subsystems)) {
    const sub = subsystem as Model & { ref?: string }
    if (sub.ref) {
      const ref = sub.ref
      const chainKey = normalizeRef(ref, basePath)

      // Check for circular references
      if (resolving.has(chainKey)) {
        throw new CircularReferenceError([...refChain, subName, ref])
      }

      resolving.add(chainKey)

      try {
        const content = await loadRef(ref, basePath)
        const parsed = JSON.parse(content) as EsmFile

        // Extract the first model from the referenced file
        if (parsed.models) {
          const modelEntries = Object.entries(parsed.models)
          const firstEntry = modelEntries[0]
          if (firstEntry) {
            const resolvedModel = firstEntry[1]
            // Replace the ref subsystem with the resolved model content
            model.subsystems![subName] = resolvedModel

            // Compute new basePath for recursive resolution
            const newBasePath = isRemoteRef(ref) ? getRemoteBase(ref) : getLocalBase(ref, basePath)

            // Recursively resolve any refs in the resolved model
            await resolveModelRefs(
              resolvedModel,
              newBasePath,
              visited,
              resolving,
              [...refChain, subName]
            )
          }
        } else if (parsed.data_loaders) {
          // Loader-only file (RFC pure-io-data-loaders §4.3): the referenced
          // file's sole component is `data_loaders`. The schema allows a
          // DataLoader inside Model.subsystems, so inline the first loader
          // keyed by the parent subName. A loader has no subsystems, so there
          // is nothing to recurse into.
          const loaderEntries = Object.entries(parsed.data_loaders)
          const firstEntry = loaderEntries[0]
          if (firstEntry) {
            const resolvedLoader = firstEntry[1] as DataLoader
            model.subsystems![subName] = resolvedLoader
          }
        }
      } finally {
        resolving.delete(chainKey)
      }

      visited.add(chainKey)
    } else {
      // Even if there's no ref, recurse into subsystems
      await resolveModelRefs(sub, basePath, visited, resolving, [...refChain, subName])
    }
  }
}

/**
 * Recursively resolve refs in a ReactionSystem's subsystems.
 */
async function resolveReactionSystemRefs(
  rs: ReactionSystem,
  basePath: string,
  visited: Set<string>,
  resolving: Set<string>,
  refChain: string[]
): Promise<void> {
  if (!rs.subsystems) return

  for (const [subName, subsystem] of Object.entries(rs.subsystems)) {
    const sub = subsystem as ReactionSystem & { ref?: string }
    if (sub.ref) {
      const ref = sub.ref
      const chainKey = normalizeRef(ref, basePath)

      // Check for circular references
      if (resolving.has(chainKey)) {
        throw new CircularReferenceError([...refChain, subName, ref])
      }

      resolving.add(chainKey)

      try {
        const content = await loadRef(ref, basePath)
        const parsed = JSON.parse(content) as EsmFile

        // Extract the first reaction system from the referenced file
        if (parsed.reaction_systems) {
          const rsEntries = Object.entries(parsed.reaction_systems)
          const firstEntry = rsEntries[0]
          if (firstEntry) {
            const resolvedRs = firstEntry[1]
            // Replace the ref subsystem with the resolved reaction system content
            rs.subsystems![subName] = resolvedRs

            // Compute new basePath for recursive resolution
            const newBasePath = isRemoteRef(ref) ? getRemoteBase(ref) : getLocalBase(ref, basePath)

            // Recursively resolve any refs in the resolved system
            await resolveReactionSystemRefs(
              resolvedRs,
              newBasePath,
              visited,
              resolving,
              [...refChain, subName]
            )
          }
        }
      } finally {
        resolving.delete(chainKey)
      }

      visited.add(chainKey)
    } else {
      // Even if there's no ref, recurse into subsystems
      await resolveReactionSystemRefs(sub, basePath, visited, resolving, [...refChain, subName])
    }
  }
}

/**
 * Load content from a ref, dispatching to fetch() for URLs or fs for local paths.
 */
async function loadRef(ref: string, basePath: string): Promise<string> {
  if (isRemoteRef(ref)) {
    return loadRemoteRef(ref)
  }
  return loadLocalRef(ref, basePath)
}

/**
 * Load a remote reference via fetch().
 */
async function loadRemoteRef(url: string): Promise<string> {
  try {
    const response = await fetch(url)
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`)
    }
    return await response.text()
  } catch (error) {
    throw new RefLoadError(url, error instanceof Error ? error : new Error(String(error)))
  }
}

/**
 * Load a local file reference using dynamic fs import.
 * Uses dynamic import so the module can be loaded in browser environments
 * without failing at parse time.
 */
async function loadLocalRef(ref: string, basePath: string): Promise<string> {
  try {
    // Dynamic import of Node.js fs and path modules
    const fs = await import('node:fs/promises')
    const path = await import('node:path')

    const fullPath = path.resolve(basePath, ref)
    return await fs.readFile(fullPath, 'utf-8')
  } catch (error) {
    throw new RefLoadError(ref, error instanceof Error ? error : new Error(String(error)))
  }
}

/**
 * Check if a ref is a remote URL.
 */
function isRemoteRef(ref: string): boolean {
  return ref.startsWith('http://') || ref.startsWith('https://')
}

/**
 * Normalize a ref to a canonical key for cycle detection.
 * Local paths are resolved against basePath and collapsed (../, ./);
 * URLs are returned as-is.
 */
function normalizeRef(ref: string, basePath: string): string {
  if (isRemoteRef(ref)) {
    return ref
  }
  return canonicalizePath(joinPath(basePath, ref))
}

/**
 * Get the base directory of a remote URL for recursive resolution.
 */
function getRemoteBase(url: string): string {
  const lastSlash = url.lastIndexOf('/')
  return lastSlash >= 0 ? url.substring(0, lastSlash) : url
}

/**
 * Get the base directory of a local ref for recursive resolution.
 */
function getLocalBase(ref: string, basePath: string): string {
  const resolved = canonicalizePath(joinPath(basePath, ref))
  const lastSlash = resolved.lastIndexOf('/')
  return lastSlash > 0 ? resolved.substring(0, lastSlash) : '/'
}

/**
 * Join two POSIX-style paths.
 */
function joinPath(a: string, b: string): string {
  if (b.startsWith('/')) return b
  if (a.endsWith('/')) return `${a}${b}`
  return `${a}/${b}`
}

/**
 * Collapse "." and ".." segments in a POSIX-style path.
 */
function canonicalizePath(p: string): string {
  const isAbs = p.startsWith('/')
  const parts = p.split('/').filter(seg => seg.length > 0 && seg !== '.')
  const stack: string[] = []
  for (const seg of parts) {
    if (seg === '..') {
      if (stack.length > 0 && stack[stack.length - 1] !== '..') {
        stack.pop()
      } else if (!isAbs) {
        stack.push('..')
      }
    } else {
      stack.push(seg)
    }
  }
  const joined = stack.join('/')
  return isAbs ? `/${joined}` : joined || '.'
}
