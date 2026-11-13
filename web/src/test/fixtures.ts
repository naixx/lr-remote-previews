import { vi } from 'vitest';

/** A valid `GET /api/v1/info` body, matching the server contract. */
export function sampleInfo() {
  return {
    name: 'LR Remote Previews',
    version: '0.1.0',
    api: 1,
    auth: 'token',
    converter: {
      installed: false,
      path: 'C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe',
      version: null,
    },
    roots: [
      { id: 'archive', label: 'Archive', available: true },
      { id: 'offsite', label: 'Offsite copy', available: false },
    ],
    capabilities: { extensions: ['.arw', '.cr2'], previewLongEdge: 2560 },
  };
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

export function mockFetch() {
  return vi.fn<typeof globalThis.fetch>();
}

/** The Authorization header of the n-th call to a fetch mock, or null. */
export function authHeaderOf(fetchMock: ReturnType<typeof mockFetch>, call = 0): string | null {
  const init = fetchMock.mock.calls[call]?.[1];
  return new Headers(init?.headers).get('Authorization');
}
