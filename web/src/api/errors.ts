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
  cause?: unknown;
}

/** The only error type the API client throws, apart from an abort the caller asked for. */
export class ApiError extends Error {
  readonly kind: ApiErrorKind;
  /** HTTP status, when a response arrived. */
  readonly status: number | null;
  /** The server's `detail` text for error statuses, or the shape mismatch for bad responses. */
  readonly detail: string | null;

  constructor(kind: ApiErrorKind, message: string, options: ApiErrorOptions = {}) {
    super(message, { cause: options.cause });
    this.name = 'ApiError';
    this.kind = kind;
    this.status = options.status ?? null;
    this.detail = options.detail ?? null;
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
