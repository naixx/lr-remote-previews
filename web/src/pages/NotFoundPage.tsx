import { links } from '../app/router';
import { PageHeader } from '../components/PageHeader';
import { StatePanel } from '../components/StatePanel';

/** A hash that names no page, for example from an old bookmark. */
export function NotFoundPage({ path }: { path: string }) {
  return (
    <div className="page">
      <PageHeader title="Page not found" />
      <StatePanel
        tone="neutral"
        title="The dashboard has no such page"
        actions={
          <a className="button" href={links.overview()}>
            Go to the overview
          </a>
        }
      >
        <p>
          The address ends in <code>#{path}</code>, which does not name a page of this dashboard.
        </p>
      </StatePanel>
    </div>
  );
}
