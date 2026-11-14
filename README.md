# LR Remote Previews

Build Lightroom Classic smart previews on the machine that holds your originals, not on the computer you edit on.

**Status: early development (stages 2 and 3 of the [plan](docs/plan.md) in progress).** It is not released and
has only been used on its authors' own setup. The idea
itself is proven by experiment; see [docs/research/smart-previews.md](docs/research/smart-previews.md).

## The problem

When the originals live on a NAS and the catalog on a laptop, Lightroom Classic builds every smart preview by pulling
the whole raw file across the network: a 25 MB file travels to become a 0.5 MB one. On Wi-Fi that takes about a second
per photo, and the laptop is busy the whole time.

## The idea

- A **server** runs next to the originals (a container; packaged for TrueNAS). It turns raw files into the same DNG
  files Lightroom makes as smart previews, in the background, and keeps them in a cache.
- A **Lightroom Classic plug-in** sends the selected photos to the server and later fetches the finished files into
  the catalog's smart preview store. Lightroom picks them up as its own.
- A **dashboard** shows what the server is doing and lets you queue whole folders.

Measured on the reference setup (Lightroom Classic 15.6, 24 MP raw files, a NAS with a 14-core desktop CPU, Wi-Fi
between the two): 0.26–0.35 s per photo on the server against 0.9–1.2 s through Lightroom on the laptop.

## What it does not do

- It never writes to your catalog itself. It reads it (read-only) to learn where each smart preview belongs. Lightroom
  changes the catalog through its own plug-in interface: it registers the smart previews, and adds photos when you run
  the plug-in's «Add a folder without previews...» ([decision record 0007](docs/adr/0007-photos-added-through-lightroom-on-the-users-command.md)).
- It never changes your originals; the server mounts them read-only.
- It does not contain Adobe software. The server needs **Adobe DNG Converter**, which you obtain from Adobe and install
  into the app yourself: [docs/converter.md](docs/converter.md).
- It converts camera raw files only. JPEG, HEIC, TIFF and video stay with Lightroom.
- Standard previews are not built by the server. Importing with «Embedded & Sidecar» previews makes them
  unnecessary for choosing picks: see «Originals on a NAS» in the [user guide](docs/guide.md).

## Parts

| Folder | What |
|---|---|
| [`plugin/`](plugin/) | The Lightroom Classic plug-in (Lua) |
| [`server/`](server/) | The server: API, queue, converter runner, cache (Python) |
| [`web/`](web/) | The dashboard (React + TypeScript) |
| [`deploy/`](deploy/) | Container image and compose files |
| [`tools/`](tools/) | Helpers for development and verification |
| [`docs/`](docs/) | Plan, decision records, research, guides |

## Documentation

- [Guide](docs/guide.md): from nothing to the first delivered smart preview.
- [Troubleshooting](docs/troubleshooting.md).
- [Installing on TrueNAS SCALE](docs/truenas.md).
- [Plan](docs/plan.md): the stages from the minimum to the complete product.
- [Decision records](docs/adr/): why it is built the way it is.
- [How Lightroom stores smart previews, and what we tested](docs/research/smart-previews.md).
- [Adobe DNG Converter: what the server needs](docs/converter.md).
- [Contributing](CONTRIBUTING.md).

## Licence and trademarks

GNU Affero General Public License, version 3 or later (AGPL-3.0-or-later): see [LICENSE](LICENSE).
Copyright (C) 2026 the LR Remote Previews contributors. Third-party code keeps its own licence and is
listed next to where it is used.

Adobe, Lightroom and DNG are trademarks of Adobe. This project is independent: it is not affiliated with, endorsed
by or supported by Adobe. It relies on behaviour of Lightroom Classic that Adobe does not document and may change.
