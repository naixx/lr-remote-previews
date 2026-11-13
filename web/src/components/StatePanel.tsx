import type { ReactNode } from 'react';

interface StatePanelProps {
  tone: 'neutral' | 'bad';
  title: string;
  /** Shows a spinner and announces the panel politely instead of as an alert. */
  busy?: boolean;
  actions?: ReactNode;
  children?: ReactNode;
}

/** A full-width message for a page that cannot show its content: loading, errors. */
export function StatePanel({ tone, title, busy = false, actions, children }: StatePanelProps) {
  return (
    <div className={`panel panel--${tone}`} role={busy ? 'status' : 'alert'}>
      <div className="panel__heading">
        {busy && <span className="spinner" aria-hidden="true" />}
        <h2 className="panel__title">{title}</h2>
      </div>
      {children && <div className="panel__body">{children}</div>}
      {actions && <div className="panel__actions">{actions}</div>}
    </div>
  );
}
