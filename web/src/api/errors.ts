export type ApiErrorKind =
  /** No HTTP response at all: server down, wrong address, network or CORS failure. */
  | 'network'
  /** HTTP 401: the access token is missing or wrong. */
  | 'unauthorized'
  /** Any other status outside 2xx. */
  | 'http'
  /** A 2xx response whose body is not JSON or does not have the expected shape. */
  | 'bad-response';

export interface ApiErrorOptions {
  status?: number;
  detail?: string | null;
  code?: string | null;
  cause?: unknown;
}

/** The only error type the API client throws, apart from an abort the caller asked for. */
export class ApiError extends Error {
  readonly kind: ApiErrorKind;
  /** HTTP status, when a response arrived. */
  readonly status: number | null;
  /** The server's `detail` text for error statuses, or the shape mismatch for bad responses. */
  readonly detail: string | null;
  /** The server's `code` for error statuses where a program has to tell cases apart. */
  readonly code: string | null;

  constructor(kind: ApiErrorKind, message: string, options: ApiErrorOptions = {}) {
    super(message, { cause: options.cause });
    this.name = 'ApiError';
    this.kind = kind;
    this.status = options.status ?? null;
    this.detail = options.detail ?? null;
    this.code = options.code ?? null;
  }
}

/** Normalises anything thrown by a request into an ApiError. */
export function toApiError(error: unknown): ApiError {
  if (error instanceof ApiError) return error;
  const message = error instanceof Error ? error.message : String(error);
  return new ApiError('bad-response', 'The response could not be processed.', {
    detail: message,
    cause: error,
  });
}

/**
 * True when the server does not have the endpoint at all: a 404 without a `code`. Unknown API
 * paths answer that way, while every 404 the protocol defines for the endpoints added in stage 3
 * carries a `code`. Do not use it for job and item ids, whose 404 has no code either.
 */
export function isMissingEndpoint(error: ApiError | null): boolean {
  return error !== null && error.kind === 'http' && error.status === 404 && error.code === null;
}

/** One sentence for a failed request: the server's own words where it sent any. */
export function describeError(error: ApiError): string {
  switch (error.kind) {
    case 'network':
      return 'The server could not be reached.';
    case 'unauthorized':
      return error.detail ?? error.message;
    case 'http':
      return error.detail ?? error.message;
    case 'bad-response':
      return error.detail ? `${error.message} ${error.detail}` : error.message;
  }
}
