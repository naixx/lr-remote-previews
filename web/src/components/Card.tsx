import { useId, type ReactNode } from 'react';

interface CardProps {
  title: string;
  /** Shown at the right of the title: a status badge or a short count. */
  aside?: ReactNode;
  wide?: boolean;
  children: ReactNode;
}

export function Card({ title, aside, wide = false, children }: CardProps) {
  const titleId = useId();
  return (
    <section className={wide ? 'card card--wide' : 'card'} aria-labelledby={titleId}>
      <header className="card__header">
        <h2 className="card__title" id={titleId}>
          {title}
        </h2>
        {aside}
      </header>
      <div className="card__body">{children}</div>
    </section>
  );
}
