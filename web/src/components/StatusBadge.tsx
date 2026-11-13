import type { ReactNode } from 'react';

export type Tone = 'ok' | 'warn' | 'bad' | 'neutral';

/** A pill with a coloured dot. The text carries the meaning; the colour only reinforces it. */
export function StatusBadge({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span className={`badge badge--${tone}`}>
      <span className="badge__dot" aria-hidden="true" />
      {children}
    </span>
  );
}
