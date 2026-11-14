import { useEffect, useRef, type ReactNode } from 'react';
import { BrandMark } from '../components/BrandMark';
import { TokenForm } from '../components/TokenForm';
import { usePageTitle } from '../hooks/usePageTitle';
import { useApi } from './ApiContext';
import { hrefFor, placeOf, useRoute, type Page, type Route } from './router';
import './layout.css';

/** Top-level sections, in the order of the navigation. */
const SECTIONS = [
  { label: 'Overview', route: { page: 'overview' }, pages: ['overview'] },
  { label: 'Jobs', route: { page: 'jobs', state: null }, pages: ['jobs', 'job'] },
  { label: 'Folders', route: { page: 'folders', root: null, path: '' }, pages: ['folders'] },
  { label: 'Settings', route: { page: 'settings' }, pages: ['settings'] },
  { label: 'Converter', route: { page: 'converter' }, pages: ['converter'] },
  { label: 'Log', route: { page: 'log' }, pages: ['log'] },
] as const satisfies readonly { label: string; route: Route; pages: readonly Page[] }[];

export function Layout({ children }: { children: ReactNode }) {
  const { authRequired } = useApi();
  const route = useRoute();
  const main = useRef<HTMLElement>(null);
  const place = placeOf(route);
  const firstPlace = useRef(place);

  // After a navigation, move focus to the new page's heading so keyboard and screen reader
  // users start there; on the first load the browser's own focus handling stays.
  useEffect(() => {
    if (place === firstPlace.current) return;
    firstPlace.current = '';
    main.current?.querySelector<HTMLElement>('h1')?.focus();
  }, [place]);

  return (
    <div className="app">
      <button
        type="button"
        className="skip-link"
        onClick={() => main.current?.querySelector<HTMLElement>('h1')?.focus()}
      >
        Skip to content
      </button>
      <header className="app-header">
        <div className="app-header__inner">
          <a className="brand" href={hrefFor({ page: 'overview' })}>
            <BrandMark className="brand__mark" />
            <span className="brand__name">LR Remote Previews</span>
          </a>

          <nav className="app-nav" aria-label="Sections">
            <ul className="app-nav__list">
              {SECTIONS.map((section) => {
                const current = (section.pages as readonly Page[]).includes(route.page);
                return (
                  <li key={section.label}>
                    <a
                      className="app-nav__item"
                      href={hrefFor(section.route)}
                      aria-current={current ? 'page' : undefined}
                    >
                      {section.label}
                    </a>
                  </li>
                );
              })}
            </ul>
          </nav>
        </div>
      </header>

      <main className="app-main" ref={main}>
        {authRequired ? <TokenPage detail={authRequired.detail} /> : children}
      </main>
    </div>
  );
}

/** Replaces any page while the server refuses the token. */
function TokenPage({ detail }: { detail: string | null }) {
  usePageTitle('Access token required');
  return (
    <div className="page">
      <TokenForm detail={detail} />
    </div>
  );
}
