# 0004. The files are made by Adobe DNG Converter under Wine; the converter is not part of the project

Status: accepted (2026-11-13)

## Context

Lightroom Classic 15.6 writes a smart preview as a DNG 1.7 with lossy JPEG XL at 2560 px. Adobe DNG Converter, with
`-lossy -side 2560 -p0`, writes the same file: in our comparison the image data was byte-identical to Lightroom's own
smart preview of the same raw file. No open-source converter was found that reproduces the file, including the
camera-specific data Lightroom expects in it.

Lightroom itself builds smart previews inside its own process; there is no external program in Lightroom to replace.

The converter is a Windows and macOS program. Under Wine 8.0 in a Debian 12 container it runs (with one marker file
that switches its GPU path off) at 0.26–0.35 s per 24 MP photo on a 14-core desktop CPU.

Adobe DNG Converter is Adobe's software under Adobe's licence.

## Decision

The server runs Adobe DNG Converter under Wine. The project does not contain, download or distribute the converter:
not in the repository, not in the container image. Users obtain it from Adobe and place it into the app's Wine
prefix themselves; the documentation describes what the app expects and which way of providing it was verified. The
app reports whether it finds the converter.

## Consequences

- Installing the app has a manual step that we cannot automate away.
- New cameras need a newer converter and camera profiles, provided by the user.
- Only camera raw files can be converted; other formats are reported as unsupported.
- The command line, the process count and the failure modes that were measured are encoded in the worker (never
  `-mp`, never exactly two processes, a missing input fails a whole batch): `server/src/lrrp/converter.py`.
- Verified with converter 17.2 only. Adobe documents the `TempDisableGPU2` marker for Camera Raw 17.4 and earlier;
  whether newer converters honour it, and so whether they run under Wine without a Vulkan device, is unverified.
- No licence text that names the converter was found; `docs/converter.md` lists what Adobe publishes. Whether a
  given use is permitted is for each user to decide.
- If a free encoder ever reproduces the file exactly, it can replace the converter behind the same interface.
