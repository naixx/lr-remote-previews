# Tools

Helpers for development and verification. Python 3, standard library only.

| Tool | What it does |
|---|---|
| `dng_compare.py <a.dng> <b.dng> [--all]` | Compares two DNG files: tags, compressed image tiles, XMP. Used to prove that a server-built smart preview equals the one Lightroom Classic builds from the same raw file, and to repeat the proof after an update of Lightroom or of the converter. |
| `package_plugin.py` | Packs `plugin/LRRemotePreviews.lrplugin` into `dist/LRRemotePreviews-<version>.zip`. |

## Checking a server-built smart preview against Lightroom

1. In Lightroom Classic, on a **test catalog**, build a smart preview for one raw photo the usual way (Library >
   Previews > Build Smart Previews).
2. Find its file: the plug-in's diagnostic report lists the path of every smart preview.
3. Convert the same raw file on the server.
4. `python tools/dng_compare.py <Lightroom's file> <the server's file>`

Expected: every image tile byte-identical; the differing tags are the program name and version, the dates, the
document identifiers and the small embedded thumbnail. Anything else means the two programs no longer write the
same file, and deliveries must stop until it is understood.
