# Contributing

The project is in early development. The [plan](docs/plan.md) says what is being built and in which order; the
[decision records](docs/adr/) say why. Read both before proposing a change of direction.

## Ground rules

- **Never commit Adobe software**, camera raw files, Lightroom catalogs, smart previews or anything from a real photo
  library. The `.gitignore` blocks the common extensions; do not work around it. Test data: see
  [docs/test-data.md](docs/test-data.md).
- **No code path may write to a Lightroom catalog or to the originals.** See decision records 0001 and 0005. The
  catalog changes only through Lightroom's own plug-in interface, on the user's command: registering a placed smart
  preview, and Lightroom's own import started by «Import a folder without the dialog...» after the check that the
  previous import was «Add» (decision record 0007).
- Everything in the repository is in English: code, comments, commit messages, documentation.
- No personal data in code, tests, fixtures or documentation: no real names, user names, host names, network
  addresses or local paths. Use neutral examples (`C:\Photos\Main\Main.lrcat`, `nas.local`, `archive`).
- State what was verified and how. Behaviour of Lightroom Classic that we rely on is undocumented, so a claim about
  it needs the Lightroom version and the test that showed it.

## Layout and checks

Each part has its own README with details. CI runs exactly these commands; run them before you push.

| Part | Folder | Checks |
|---|---|---|
| Server | `server/` | `pip install -e ".[dev]"`, `ruff check .`, `ruff format --check .`, `pytest` |
| Dashboard | `web/` | `npm ci`, `npm run lint`, `npm run typecheck`, `npm run test`, `npm run build` (Node 22; the tests need at least 20.19) |
| Plug-in | `plugin/` | `luacheck --config plugin/.luacheckrc plugin`, `busted plugin/spec`, `python tools/package_plugin.py` (all from the repository root; Lua 5.1) |
| Image | `deploy/` | `docker build -f deploy/Dockerfile .` (from the repository root) |

## Changes

- Small, focused commits with a message that says what changed and why.
- A change in behaviour comes with a test. A change in a decision comes with a new decision record that supersedes
  the old one; do not edit history.
- The API between the plug-in and the server is versioned (`/api/v1`). A breaking change needs a new version or a
  compatible transition.
- Third-party code keeps its licence header and is listed in a `THIRD-PARTY.md` next to where it is used.

## Testing against Lightroom

Nothing in CI can run Lightroom Classic. A change to the plug-in that touches the SDK has to be tried by hand in
Lightroom on a **test catalog**, never on a catalog you care about, and the pull request should say on which
Lightroom version and platform it was tried.
