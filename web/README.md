# LR Remote Previews: web dashboard

The browser dashboard of the LR Remote Previews server. It is a static single-page app
(Vite, React, TypeScript). In production the server serves the built files from `web/dist` at `/`
and the dashboard talks to the same server through relative URLs, so it needs no configuration.

## Pages

Pages are hash routes (`#/jobs/7`), so the dashboard works under any path prefix a reverse proxy
gives it, and reloading a page or opening a bookmark never asks the server for an unknown path.
Each page sets the document title; after a navigation, focus moves to the page heading.

| Route | Page |
| --- | --- |
| `#/` | **Overview**: what the server does now (Running, Idle, Paused, Waiting for working hours), the time left, the CPU temperature when the server can read it, a **Pause / Resume** button, the queue figures, one line on the automatic scan (running, off, or when the next scan is due, and what the last one queued), the ten newest jobs (each links to its page) and what `GET /api/v1/info` reports. |
| `#/jobs`, `#/jobs?state=active` | **Jobs**: every job, newest first, with a state filter and **Load more** (50 more each time, up to the 200 the server lists). A background job carries a «Background» badge; the sender is named, with the automatic scan's jobs as «Automatic scan». |
| `#/jobs/7`, `#/jobs/7?state=failed` | **Job**: its facts (with the priority), progress, **Cancel** (active jobs, after a confirmation) and **Retry failed items**; its items, 100 to a page, paged with `since`/`limit` and filtered by state through links that show the counts. Failed and rejected items show their error code, the server's message and an explanation. |
| `#/folders`, `#/folders/<root>/<path>` | **Folders**: the roots, then one folder at a time with a breadcrumb, its raw, built and other files, its sub-folders (filter by name, 200 shown at a time), and **Queue this folder** with «Include sub-folders» and a choice of normal or background priority, a confirmation that says what will happen and a result that links the jobs made. |
| `#/settings` | **Settings**: converter processes (automatic or a number, never 2), files per process, working hours, pause; the **automatic scan** (on or off, the roots to scan, interval, settle time, files per scan; the last and the next scan; **Scan now**); the **cache** (its size and files, the size and age limits, and **Clean up now**: a count of what would be removed, then a confirmation); the access token (**Forget token**); the server's facts (versions, roots, raw formats, limits, retention). Each form saves on its own: the automatic scan and the cache limits as whole objects. |
| `#/converter` | **Converter**: whether Adobe DNG Converter is installed, the path the server expects, its version, and a **self-test**, optionally converting one raw file, shown as a checklist. |
| `#/log` | **Log**: the server's recent log lines, refreshed every 3 s with a pause switch; it stays at the newest line unless you scrolled up. |
| `#/widget`, `#/widget?theme=dark` | **Widget**: a compact status page for a frame in another dashboard or a small pinned tab, without the header and the navigation: the state badge, what is queued and built now (the pace, the time left, the job being built), today's built and failed, the cache, and a line only when something is wrong; at about 540×400 also up to three active jobs, the converter processes and the automatic scan. `theme=light` or `dark` overrides the system's colour scheme. It only reads; its links open the dashboard in a new tab. |

Live data refreshes by itself: the overview every 2 s while anything is queued or building and
every 10 s when idle (status, jobs and settings together), the job list and a job page every 2 s
while a job is active and every 15 s otherwise, an open folder every 30 s, the log every 3 s, and
the status on the Settings page (the scan's state, the cache's size) every 30 s, every 2 s while a
scan runs and for 10 s after **Scan now**.
A refresh starts only after the previous one has finished; polling pauses while the tab is hidden
and resumes at once when it is shown again. If a refresh fails, the last data stays on screen with
a "Connection lost, retrying" note.

The widget polls like the overview (and `GET /api/v1/info` once a minute), with one difference:
when the server gives no answer at all, it tries again after 5, 15 and 60 s and then stops, until
**Check again** is pressed; neither a timer nor showing the tab again sends a request. The server
often runs on a NAS that sleeps when idle and wakes on requests, and a widget stays open for days.

Buttons that change something on the server are disabled while their request runs and show the
server's own error text when it fails. Cancelling a job and queueing a folder ask first; **Clean up
now** first asks the server what it would remove (a dry run) and removes only after a
confirmation. **Scan now** does not ask: it queues at most the files-per-scan limit, at background
priority, as the automatic scan does.

A 401 from any request replaces the page with the token form until a token is entered (entering
the same one again retries). A server older than the dashboard that lacks an endpoint (a 404
without a `code`) gets a «this server is older than the dashboard» note on the page that needs it;
the overview then works without the pause button and without the server state, time left and
temperature. A 0.4 server, whose settings have no `autoScan` and `cache` and whose status has no
`autoScan`, gets that note in the automatic scan and cache sections of the Settings page only
(the cache's size still shows); its jobs show no priority, and a folder queued at background
priority there is built at normal priority, which the result says.

## Requirements

- Node.js 20.19 or newer (`^20.19.0 || >=22.12.0`, as Vite, ESLint and jsdom require), npm 10.

## Develop against a local server

1. Start the server on its default port, 8787 (see `server/`).
2. In this folder:

   ```sh
   npm ci
   npm run dev
   ```

3. Open the URL Vite prints (usually <http://localhost:5173>).

The dev server forwards `/api` and `/healthz` to `http://localhost:8787`. To use a server
elsewhere, for example on the NAS, set `LRRP_SERVER_URL`:

```sh
LRRP_SERVER_URL=http://nas.example:8787 npm run dev
```

If the server requires a token, the dashboard asks for it and keeps it in the browser's
localStorage. **Forget token** on the Settings page removes it.

## Scripts

| Script              | What it does                                                         |
| ------------------- | -------------------------------------------------------------------- |
| `npm run dev`       | Dev server with hot reload and the API proxy.                        |
| `npm run build`     | Type-check, then a production build into `dist/`.                    |
| `npm run preview`   | Serve `dist/` locally, with the same API proxy as `dev`.             |
| `npm run lint`      | ESLint (flat config, type-aware TypeScript and React hooks rules). Any warning fails the run. |
| `npm run typecheck` | `tsc -b` over the app, the tests and `vite.config.ts`.               |
| `npm run test`      | Vitest, once, in jsdom with Testing Library.                         |

CI runs `npm ci`, then `lint`, `typecheck`, `test` and `build`.

## Where things live

```
src/
  main.tsx                 Entry point: the global styles, then <App />.
  env.d.ts                 __APP_VERSION__, the dashboard's version from package.json.
  app/
    App.tsx                Composition root: provider, layout, the page the hash names; the
                           widget without the layout.
    router.ts              parseRoute(), hrefFor(), links, useRoute(): the hash routes.
    Layout.tsx, layout.css Header (brand, section navigation), skip link, content area; the
                           token form in place of the page after a 401.
    ApiProvider.tsx        Owns the access token and the API client; notices every 401.
    ApiContext.ts          useApi(): the client, the token, authRequired, set or forget it.
  api/
    client.ts              createApiClient(): typed requests; throws ApiError on failure.
    errors.ts              ApiError (kind, status, detail, code), isMissingEndpoint(),
                           describeError().
    info.ts, status.ts, jobs.ts, settings.ts, browse.ts, converter.ts, log.ts,
    autoscan.ts, cache.ts  Response types and their parse…() runtime shape checks.
                           autoscan.ts: Scan now; cache.ts: the clean-up.
    validate.ts            Small validators that name the failing field (roots[0].available).
    together.ts            loadTogether(): requests side by side, the others cancelled when one
                           fails.
    token.ts               Token storage in localStorage, every access guarded.
  hooks/
    useApiResource.ts      Loads one resource: loading / ready / error, reload, abort on change.
    usePolling.ts          Loads a resource again and again: never overlapping, paused while
                           hidden, keeps the last data when a refresh fails, stops on 401;
                           with keepPrevious, keeps the old page on screen while the next loads;
                           with retryDelays, gives up after network failures in a row.
    useAction.ts           One request a button starts: pending, error, never two at once.
    usePageTitle.ts        The document title per page.
  lib/
    format.ts              Numbers, rates, sizes (decimal units), times, time left or until,
                           temperature.
    codes.ts               Plain-language explanations of the protocol's error codes.
  components/              Shared UI: Card, StatusBadge, StatePanel, PageHeader, ErrorPanel
                           (with the older-server note), ActionError, ConfirmPanel,
                           ConnectionNote, JobList (job rows, progress bar, state badge),
                           PauseButton, Fact, TokenForm, BrandMark.
  pages/
    overview/ jobs/ folders/ settings/ converter/ log/ widget/
                           One folder per page: its components, what it polls and how often,
                           its styles and its tests. NotFoundPage.tsx for unknown routes.
    widget/                WidgetPage.tsx (no layout; the compact token form after a 401),
                           live.ts (what it loads, the retries and why it stops), widget.css
                           (the frame sizes, and how the least important blocks give way).
    settings/              SettingsPage.tsx with AutoScanCard.tsx and CacheCard.tsx; the form
                           rules in form.ts, scanForm.ts and cacheForm.ts (sizes in GB with one
                           decimal, a saved limit sent back to the byte while its text is
                           unchanged).
  styles/
    index.css              Design tokens (light and dark; data-theme on the root element forces
                           one), base styles, shared primitives.
  test/
    fixtures.ts            Sample responses for every endpoint; fakeServer(): a fetch mock that
                           tells endpoints apart by method and path and answers each with what
                           the test last set (a body, a handler, a network failure, a hang, or
                           a hold until released); fullServer(): one with every endpoint of
                           the current protocol; stage3Settings(), stage3Status(), stage3Job():
                           bodies as a 0.4 server sends them.
    render.tsx             installFakeClock(), advance(), settle(), renderPage().
    setup.ts               Testing Library cleanup and storage reset.
```

### Adding a page or an endpoint

- **Endpoint:** add the response type and a `parse…` function in `src/api/` (built from the
  helpers in `validate.ts`), the path to `API_PATHS` and a method on the client in `client.ts`,
  and the route to `ROUTES` in `test/fixtures.ts`. Every response is checked at runtime, so a
  server change shows up as a precise "unexpected response" message, not as broken UI. Unknown
  fields are ignored; a field that older servers do not send is read with `optional()` and given
  a fallback in the UI.
- **Live data:** use `usePolling` with a stable loader and a module-level `interval` function.
  Test it with `installFakeClock()` and `advance(ms)` from `test/render.tsx` instead of
  `findBy…` queries, which wait on timers.
- **Actions:** wrap the client call in `useAction` (with a `useCallback`), disable the button
  while `pending`, and show `<ActionError>` under it. Ask first with `<ConfirmPanel>` when the
  action cannot be undone or puts load on the server.
- **Page:** create `src/pages/<name>/`, start it with `<PageHeader>`, load data with
  `useApiResource` or `usePolling`, show failures with `<ErrorPanel>` (pass `feature` so an older
  server gets the older-server note). The layout handles 401 (the widget, outside it, does so
  itself). Add the route to `router.ts`, the page to `CurrentPage` in `App.tsx` and the section
  to `SECTIONS` in `Layout.tsx`. Keep request
  paths relative (no leading slash) and links as `hrefFor(...)` hashes.

## Styling

Plain CSS with custom properties; no UI library, no CSS framework, no web fonts, nothing loaded
from a CDN. Colours, spacing and radii are tokens in `src/styles/index.css`; dark mode redefines
the colour tokens under `prefers-color-scheme: dark`, and `data-theme="light"` or `"dark"` on the
root element overrides the system (the widget sets it from `?theme=`). Component styles sit next
to their components and use only the tokens; they load after `index.css`, so they can refine it.

Figures that change while the page is open use tabular digits, and space for them is reserved
where their growth would move something else (the progress bars of all jobs end at the same
place); the page keeps room for a scroll bar, so the header does not shift between pages. Below
640 px tables turn into stacked rows and the section navigation scrolls sideways if it does not
fit. States are written out (badges, log levels, self-test steps); colour only reinforces them.
Under `prefers-reduced-motion: reduce` the progress bars jump instead of sliding and the loading
spinner turns slowly. Numbers are formatted in English to match the text; clock times use the
browser's locale and time zone (log lines always on the 24-hour clock).
