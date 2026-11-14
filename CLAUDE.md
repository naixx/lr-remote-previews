# LR Remote Previews: notes for coding agents

Read [README.md](README.md), [docs/plan.md](docs/plan.md) and the decision records in [docs/adr/](docs/adr/) first.
[CONTRIBUTING.md](CONTRIBUTING.md) has the checks CI runs.

## Rules that must not be broken

- No code path writes to a Lightroom catalog or any other Lightroom database itself, or under a root of originals.
  The catalog changes only through Lightroom's own plug-in interface, on the user's command (ADR 0007).
- Nothing from Adobe is added to the repository or to the image, and nothing downloads it. Adobe DNG Converter is
  the user's to install; we only describe.
- The repository is English only: code, comments, documentation, commit messages. No translated copies.
- The repository becomes public. No personal data anywhere, including tests and examples: no real names, user names,
  host names, network addresses, local paths, catalog names, photographs. Use neutral examples
  (`C:\Photos\Main\Main.lrcat`, `nas.local`, root id `archive`).
- A statement about Lightroom's behaviour needs the Lightroom version and the test that showed it; that behaviour is
  undocumented. Mark anything unverified as unverified.

## Where things are

- `server/` Python package `lrrp` (FastAPI). `server/src/lrrp/converter.py` records the measured facts about running
  the converter under Wine; keep them when changing the runner.
- `web/` the dashboard (React + TypeScript + Vite), served by the server as static files.
- `plugin/LRRemotePreviews.lrplugin/` the Lightroom Classic plug-in. Lightroom's Lua is 5.1. Every module sits at
  the top level of that folder (Lightroom's `require` takes a script name, not a path). Logic that does not need the
  SDK goes into modules without `import`, with tests in `plugin/spec/`.
- `docs/protocol.md` is the contract between the three parts. Change it together with the code.

## Testing

CI cannot run Lightroom or the converter. Plug-in changes that touch the SDK are tried by hand on a test catalog.
Converter runs are tried on a machine that has the converter; never add converter output or raw files to the
repository.
