import { useMemo, useSyncExternalStore } from 'react';
import { ITEM_STATES, JOB_STATES, type ItemState, type JobState } from '../api/jobs';

/**
 * Hash routes (`#/jobs/7`), so the dashboard works under any path prefix a reverse proxy gives
 * it and a reload of a deep link never reaches the server as an unknown path. Links are plain
 * `<a href={hrefFor(...)}>`; nothing navigates programmatically.
 */
export type Route =
  | { page: 'overview' }
  | { page: 'jobs'; state: JobState | null }
  | { page: 'job'; id: number; itemState: ItemState | null }
  /** `root` null lists the roots; `path` is relative to the root, `""` for the root itself. */
  | { page: 'folders'; root: string | null; path: string }
  | { page: 'settings' }
  | { page: 'converter' }
  | { page: 'log' }
  | { page: 'not-found'; path: string };

export type Page = Route['page'];

function oneOf<const T extends readonly string[]>(value: string | null, options: T): T[number] | null {
  return options.find((option) => option === value) ?? null;
}

function decodeSegments(path: string): string[] | null {
  try {
    return path
      .split('/')
      .filter((segment) => segment !== '')
      .map((segment) => decodeURIComponent(segment));
  } catch {
    return null; // A malformed escape such as `%E0%A4%A`.
  }
}

/** Reads a route from `location.hash` (with or without the leading `#`). */
export function parseRoute(hash: string): Route {
  const raw = hash.startsWith('#') ? hash.slice(1) : hash;
  const queryAt = raw.indexOf('?');
  const path = queryAt === -1 ? raw : raw.slice(0, queryAt);
  const query = new URLSearchParams(queryAt === -1 ? '' : raw.slice(queryAt + 1));
  const segments = decodeSegments(path);
  const notFound: Route = { page: 'not-found', path: raw };
  if (segments === null) return notFound;

  const [first, second, ...rest] = segments;
  switch (first) {
    case undefined:
      return { page: 'overview' };
    case 'jobs':
      if (second === undefined) return { page: 'jobs', state: oneOf(query.get('state'), JOB_STATES) };
      if (/^[1-9]\d{0,15}$/.test(second) && rest.length === 0) {
        return {
          page: 'job',
          id: Number(second),
          itemState: oneOf(query.get('state'), ITEM_STATES),
        };
      }
      return notFound;
    case 'folders':
      return { page: 'folders', root: second ?? null, path: rest.join('/') };
    case 'settings':
    case 'converter':
    case 'log':
      return second === undefined ? { page: first } : notFound;
    default:
      return notFound;
  }
}

const encodePath = (path: string) =>
  path
    .split('/')
    .filter((segment) => segment !== '')
    .map((segment) => encodeURIComponent(segment))
    .join('/');

/** The `href` of a route, for a plain link. */
export function hrefFor(route: Route): string {
  switch (route.page) {
    case 'overview':
      return '#/';
    case 'jobs':
      return route.state ? `#/jobs?state=${route.state}` : '#/jobs';
    case 'job':
      return route.itemState ? `#/jobs/${route.id}?state=${route.itemState}` : `#/jobs/${route.id}`;
    case 'folders': {
      if (route.root === null) return '#/folders';
      const path = encodePath(route.path);
      return `#/folders/${encodeURIComponent(route.root)}${path ? `/${path}` : ''}`;
    }
    case 'settings':
    case 'converter':
    case 'log':
      return `#/${route.page}`;
    case 'not-found':
      return `#${route.path}`;
  }
}

/** Short helpers for the links used across pages. */
export const links = {
  overview: () => hrefFor({ page: 'overview' }),
  jobs: (state: JobState | null = null) => hrefFor({ page: 'jobs', state }),
  job: (id: number, itemState: ItemState | null = null) => hrefFor({ page: 'job', id, itemState }),
  folder: (root: string | null, path = '') => hrefFor({ page: 'folders', root, path }),
  settings: () => hrefFor({ page: 'settings' }),
  converter: () => hrefFor({ page: 'converter' }),
  log: () => hrefFor({ page: 'log' }),
};

function subscribe(onChange: () => void): () => void {
  window.addEventListener('hashchange', onChange);
  window.addEventListener('popstate', onChange);
  return () => {
    window.removeEventListener('hashchange', onChange);
    window.removeEventListener('popstate', onChange);
  };
}

const readHash = () => window.location.hash;

/** The current route; re-renders when the hash changes. */
export function useRoute(): Route {
  const hash = useSyncExternalStore(subscribe, readHash, readHash);
  return useMemo(() => parseRoute(hash), [hash]);
}

/**
 * Identifies the place a route shows, without its filters: focus moves to the new page's heading
 * when this changes, and stays on a filter link when only the filter changes.
 */
export function placeOf(route: Route): string {
  switch (route.page) {
    case 'job':
      return `job:${route.id}`;
    case 'folders':
      return `folders:${route.root ?? ''}:${route.path}`;
    case 'not-found':
      return `not-found:${route.path}`;
    default:
      return route.page;
  }
}
