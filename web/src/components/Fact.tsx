import type { ReactNode } from 'react';

/** One label-over-value pair inside a `<dl className="facts">`. */
export function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="facts__item">
      <dt>{label}</dt>
      <dd>{children}</dd>
    </div>
  );
}
