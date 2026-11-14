import type { ReactNode } from 'react';
import { isMissingEndpoint, type ApiError } from '../api/errors';
import { StatePanel } from './StatePanel';
import { TokenForm } from './TokenForm';

interface ErrorPanelProps {
  error: ApiError;
  /** What could not be loaded, as a title: «Settings could not be loaded». */
  title?: string;
  /**
   * What the page offers, for the note shown when the server lacks the endpoint: «settings
   * that can be changed from the dashboard». Without it a 404 is shown as a server error.
   */
  feature?: string;
  onRetry?: () => void;
  /** Extra actions next to Retry, such as a link back. */
  actions?: ReactNode;
}

/** A full-width message for a page whose data could not be loaded. */
export function ErrorPanel({ error, title, feature, onRetry, actions }: ErrorPanelProps) {
  if (error.kind === 'unauthorized') return <TokenForm detail={error.detail} />;
  if (feature && isMissingEndpoint(error)) return <OlderServerNote feature={feature} />;

  const buttons =
    onRetry || actions ? (
      <>
        {onRetry && (
          <button type="button" className="button" onClick={onRetry}>
            Retry
          </button>
        )}
        {actions}
      </>
    ) : undefined;

  if (error.kind === 'network') {
    return (
      <StatePanel tone="bad" title="Server unreachable" actions={buttons}>
        <p>
          The dashboard got no answer from the LR Remote Previews server. Check that the server is
          running and that this browser can reach it.
        </p>
      </StatePanel>
    );
  }

  const isShape = error.kind === 'bad-response';
  return (
    <StatePanel
      tone="bad"
      title={title ?? (isShape ? 'Unexpected response' : 'Server error')}
      actions={buttons}
    >
      <p>
        {error.message}
        {isShape && ' The server and this dashboard may be different versions.'}
      </p>
      {error.detail && <pre className="error-detail">{error.detail}</pre>}
    </StatePanel>
  );
}

/** Shown instead of a page whose endpoint the server does not have. */
export function OlderServerNote({ feature }: { feature: string }) {
  return (
    <StatePanel tone="neutral" title="This server is older than the dashboard">
      <p>
        It does not offer {feature}. Update the server to version {__APP_VERSION__} or later to
        use this page.
      </p>
    </StatePanel>
  );
}
