import { useEffect, useId, useRef, type ReactNode } from 'react';

interface ConfirmPanelProps {
  title: string;
  children: ReactNode;
  confirmLabel: string;
  cancelLabel?: string;
  /** `danger` for a change that cannot be undone. */
  tone?: 'danger' | 'normal';
  pending?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * Asks before a destructive or load-heavy action, in place, under the button that asked.
 * Focus goes to the safe choice, so a stray Enter does not confirm; Escape cancels.
 */
export function ConfirmPanel({
  title,
  children,
  confirmLabel,
  cancelLabel = 'Back',
  tone = 'normal',
  pending = false,
  onConfirm,
  onCancel,
}: ConfirmPanelProps) {
  const titleId = useId();
  const cancelRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    cancelRef.current?.focus();
  }, []);

  return (
    <div
      className={`confirm confirm--${tone}`}
      role="group"
      aria-labelledby={titleId}
      onKeyDown={(event) => {
        if (event.key === 'Escape' && !pending) {
          event.stopPropagation();
          onCancel();
        }
      }}
    >
      <p className="confirm__title" id={titleId}>
        {title}
      </p>
      <div className="confirm__body">{children}</div>
      <div className="confirm__actions">
        <button
          type="button"
          className={tone === 'danger' ? 'button button--danger' : 'button'}
          disabled={pending}
          onClick={onConfirm}
        >
          {pending && <span className="spinner spinner--small" aria-hidden="true" />}
          {confirmLabel}
        </button>
        <button
          type="button"
          ref={cancelRef}
          className="button button--quiet"
          disabled={pending}
          onClick={onCancel}
        >
          {cancelLabel}
        </button>
      </div>
    </div>
  );
}
