import { describeError, isMissingEndpoint, type ApiError } from '../api/errors';

interface ActionErrorProps {
  error: ApiError | null;
  /** What the button tried, for the first words: «Could not cancel the job». */
  action: string;
  /** A plain-language explanation of the error's code, where the caller knows one. */
  explain?: (error: ApiError) => string | null;
}

/** The failure of a button's request, next to the button. Renders nothing without an error. */
export function ActionError({ error, action, explain }: ActionErrorProps) {
  if (!error) return null;
  const explanation = explain?.(error) ?? null;
  const older = isMissingEndpoint(error)
    ? ' This server is older than the dashboard and does not offer this.'
    : '';
  return (
    <div className="action-error" role="alert">
      <p>
        <strong>{action}.</strong> {explanation ?? describeError(error)}
        {older}
      </p>
      {explanation && error.detail && <p className="action-error__detail">{error.detail}</p>}
    </div>
  );
}
