import { useCallback } from 'react';
import type { ServerSettings } from '../api/settings';
import { useApi } from '../app/ApiContext';
import { useAction } from '../hooks/useAction';
import { ActionError } from './ActionError';

interface PauseButtonProps {
  /** The `paused` setting as last read. */
  paused: boolean;
  /** Called with the settings the server answered after the change. */
  onChanged: (settings: ServerSettings) => void;
}

/**
 * Pauses or resumes building (`PATCH api/v1/settings` with `paused`). Pausing lets a running
 * wave finish; no new one starts until resumed.
 */
export function PauseButton({ paused, onChanged }: PauseButtonProps) {
  const { client } = useApi();
  const toggle = useCallback(
    (next: boolean) => client.updateSettings({ paused: next }),
    [client],
  );
  const action = useAction(toggle);

  async function handleClick() {
    const settings = await action.run(!paused);
    if (settings) onChanged(settings);
  }

  return (
    <div className="pause-control">
      <button
        type="button"
        className={paused ? 'button' : 'button button--secondary'}
        disabled={action.pending}
        onClick={() => void handleClick()}
      >
        {action.pending && <span className="spinner spinner--small" aria-hidden="true" />}
        {paused ? 'Resume' : 'Pause'}
      </button>
      <ActionError
        error={action.error}
        action={paused ? 'Could not resume' : 'Could not pause'}
      />
    </div>
  );
}
