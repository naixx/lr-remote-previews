# LR Remote Previews: web dashboard

The browser dashboard of the LR Remote Previews server. It is a static single-page app
(Vite, React, TypeScript). In production the server serves the built files from `web/dist` at `/`
and the dashboard talks to the same server through relative URLs, so it needs no configuration.

Stage 0 has one page, **Overview**, which shows what `GET /api/v1/info` reports: server name and
versions, whether Adobe DNG Converter is installed, the library roots and the supported raw
formats.

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
localStorage. **Forget token** in the header removes it.

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
  main.tsx                 Entry point: mounts <App /> and the global styles.
  app/
    App.tsx                Composition root: provider, layout, current page.
    Layout.tsx, layout.css Header (brand, section navigation, token action) and content area.
    ApiProvider.tsx        Owns the access token and the API client.
    ApiContext.ts          useApi(): the client, the token and the actions to set or forget it.
  api/
    client.ts              createApiClient(): typed requests; throws ApiError on failure.
    errors.ts              ApiError and its kinds: network, unauthorized, http, bad-response.
    info.ts                ServerInfo types and parseServerInfo(), the runtime shape check.
    validate.ts            Small validators that name the failing field (roots[0].available).
    token.ts               Token storage in localStorage, every access guarded.
  hooks/
    useApiResource.ts      Loads one resource: loading / ready / error, reload, abort on change.
  components/              Shared UI: Card, StatusBadge, StatePanel, TokenForm, BrandMark.
  pages/
    overview/              The Overview page, its styles and tests.
  styles/
    index.css              Design tokens (light and dark), base styles, shared primitives.
  test/                    Test setup and fixtures (sample info response, fetch mock).
```

### Adding a page or an endpoint

- **Endpoint:** add the response type and a `parse…` function next to `info.ts` (built from the
  helpers in `validate.ts`), then a method on the client in `client.ts`. Every response is checked
  at runtime, so a server change shows up as a precise "unexpected response" message, not as
  broken UI.
- **Page:** create `src/pages/<name>/`, load data with `useApiResource` and a `useCallback` that
  calls the client, and handle `error.kind === 'unauthorized'` by rendering `<TokenForm />`. Add
  the section to `SECTIONS` in `Layout.tsx`. A router comes with the second page; keep request
  paths relative (no leading slash) and prefer hash-based routes, so the dashboard keeps working
  when a reverse proxy serves it under a sub-path.

## Styling

Plain CSS with custom properties; no UI library, no CSS framework, no web fonts, nothing loaded
from a CDN. Colours, spacing and radii are tokens in `src/styles/index.css`; dark mode redefines
the colour tokens under `prefers-color-scheme: dark`. Component styles sit next to their
components and use only the tokens.
