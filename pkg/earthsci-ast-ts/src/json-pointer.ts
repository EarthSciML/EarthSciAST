/** Escape one JSON Pointer reference token (RFC 6901). */
export function pointerToken(key: string): string {
  return key.replace(/~/g, '~0').replace(/\//g, '~1')
}
