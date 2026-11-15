import { useId, useState, type FormEvent } from 'react';
import { useApi } from '../app/ApiContext';

interface TokenFormProps {
  /** The server's explanation from the 401 response, if it sent one. */
  detail: string | null;
  /**
   * For a small frame (the widget): no panel around it, the field's label only for assistive
   * technology, and room for the hint only where the frame is tall enough.
   */
  compact?: boolean;
}

/** Asks for the access token after the server answered 401. */
export function TokenForm({ detail, compact = false }: TokenFormProps) {
  const { token, setToken } = useApi();
  const [value, setValue] = useState('');
  const inputId = useId();
  const hintId = useId();
  const rejected = token !== null;

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (value.trim()) setToken(value);
  }

  return (
    <form
      className={compact ? 'token-form token-form--compact' : 'panel panel--neutral token-form'}
      onSubmit={handleSubmit}
    >
      <h2 className="panel__title">Access token required</h2>
      <div className="panel__body">
        <p>
          {rejected
            ? 'The server did not accept the saved token. Enter the current one.'
            : 'This server only answers requests that carry its access token.'}
        </p>
        {detail && <p className="muted">Server message: {detail}</p>}
      </div>

      <label className={compact ? 'visually-hidden' : 'field-label'} htmlFor={inputId}>
        Access token
      </label>
      <div className="field-row">
        <input
          id={inputId}
          className="input"
          type="password"
          autoComplete="off"
          spellCheck={false}
          aria-describedby={hintId}
          value={value}
          onChange={(event) => setValue(event.target.value)}
        />
        <button type="submit" className="button" disabled={!value.trim()}>
          Save token
        </button>
      </div>
      <p className="field-hint" id={hintId}>
        Use the token configured on the server. It is stored only in this browser.
      </p>
    </form>
  );
}
