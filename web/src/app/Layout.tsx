import type { ReactNode } from 'react';
import { BrandMark } from '../components/BrandMark';
import { useApi } from './ApiContext';
import './layout.css';

/**
 * Top-level sections. Later stages add Queue, Jobs, Folders and Settings here, together with a
 * router; until then the only section is the current page.
 */
const SECTIONS = [{ id: 'overview', label: 'Overview' }] as const;

export function Layout({ children }: { children: ReactNode }) {
  const { token, tokenPersisted, forgetToken } = useApi();

  return (
    <div className="app">
      <header className="app-header">
        <div className="app-header__inner">
          <div className="brand">
            <BrandMark className="brand__mark" />
            <span className="brand__name">LR Remote Previews</span>
          </div>

          <nav className="app-nav" aria-label="Sections">
            <ul className="app-nav__list">
              {SECTIONS.map((section) => (
                <li key={section.id}>
                  <span className="app-nav__item" aria-current="page">
                    {section.label}
                  </span>
                </li>
              ))}
            </ul>
          </nav>

          {token !== null && (
            <div className="session">
              <span className="session__state">
                {tokenPersisted ? 'Token saved in this browser' : 'Token kept until this tab closes'}
              </span>
              <button type="button" className="button button--quiet" onClick={forgetToken}>
                Forget token
              </button>
            </div>
          )}
        </div>
      </header>

      <main className="app-main">{children}</main>
    </div>
  );
}
