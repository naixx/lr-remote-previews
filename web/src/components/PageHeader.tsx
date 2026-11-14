import type { ReactNode } from 'react';
import { usePageTitle } from '../hooks/usePageTitle';

interface PageHeaderProps {
  title: string;
  lead?: ReactNode;
  /** Shown at the right of the title on wide screens, below it on narrow ones. */
  actions?: ReactNode;
  /** The document title, when it should differ from `title`. */
  documentTitle?: string;
}

/**
 * The heading of a page. It also sets the document title, and takes focus after a navigation
 * (the layout moves focus to it), so it can be focused but is not in the tab order.
 */
export function PageHeader({ title, lead, actions, documentTitle }: PageHeaderProps) {
  usePageTitle(documentTitle ?? title);
  return (
    <header className="page-header">
      <div className="page-header__text">
        <h1 className="page-title" tabIndex={-1}>
          {title}
        </h1>
        {lead && <p className="page-lead">{lead}</p>}
      </div>
      {actions && <div className="page-header__actions">{actions}</div>}
    </header>
  );
}
