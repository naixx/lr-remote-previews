# How Lightroom Classic stores smart previews, and what we tested

Everything here was observed on **Lightroom Classic 15.6 on Windows** and **Adobe DNG Converter 17.2** on
2026-11-13. None of it is documented by Adobe; each point may change with any release. Where something was not
tested, it says so.

## What a smart preview is

- A file `<catalog folder>\<catalog name> Smart Previews.lrdata\<U[0]>\<U[0..3]>\<U>.dng`. `U` is the file's UUID,
  `AgLibraryFile.id_global` in the catalog database, upper case with dashes. For example:
  `Main Smart Previews.lrdata\6\6282\62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng`. The store holds nothing else: no
  index, no database.
- The file is a DNG 1.7:
  - the image: 2560 px on the long side, three 16-bit linear samples per pixel, lossy **JPEG XL** (compression
    52546; distance 1.0, effort 7, decode speed 4), in tiles of 368×432;
  - a 256 px JPEG thumbnail;
  - the camera profile tables, colour matrices, noise profile;
  - `OriginalRawFileName`, `OriginalDefaultFinalSize` (the full size of the original), `RawDataUniqueID`,
    `NewRawImageDigest`;
  - an XMP packet with no develop settings (`crs:HasSettings="False"`).
- Typical size: 0.3–0.7 MB for a 24 MP raw file (0.23–4.6 MB seen).
- Nothing in the file comes from the catalog: no UUID, no settings, no digest.

## How the catalog tracks them

One table: `AgDNGProxyInfo (id_local, fileUUID, status, statusDateTime)`.

- `fileUUID` = `AgLibraryFile.id_global`.
- `status`: `'V'` on every smart preview Lightroom has checked; `'U'` is the column default and what a trigger sets
  when a file row is inserted again; `'D'` is set by a trigger when a file row is deleted.
- `statusDateTime`: UTC text. In an old catalog all rows carried the time of the last catalog upgrade, years after the
  files were built, so Lightroom re-checks them in bulk.
- `id_local` comes from the catalog-wide counter `Adobe_entityIDCounter`.
- No other table or column mentions smart previews.

The SDK's `photo:getRawMetadata('uuid')` is **not** the file UUID: one photo had `7986510A-…` in the SDK and
`62823DFE-…` as the name of its smart preview.

## Adobe DNG Converter writes the same file

`"Adobe DNG Converter.exe" -lossy -side 2560 -p0 -d <out dir> <raw files>`

Compared with the smart previews Lightroom built from the same raw files (`tools/dng_compare.py`):

| Converter run | Image tiles identical to Lightroom's | Other differences |
|---|---|---|
| On Windows, 7 photos | 18–26 of 28 per photo; the rest the same size within a few bytes | program name and version, dates, document ids, `RawDataUniqueID`, `NewRawImageDigest` |
| Under Wine 8.0 on Linux, 1 photo | 28 of 28; raw image directory identical, both identifiers identical | program name and version, dates, document ids, the 256 px thumbnail (5891 against 6049 bytes) |
| Under Wine 8.0 on Linux through the server's queue, 7 photos | 28 of 28 for six photos; 27 of 28 for one, whose two identifiers also differ | as above |

Why the Windows run differs in a few tiles and the Wine run does not was not investigated.

## Does Lightroom accept a file it did not build? Yes

Test catalogs with 157 raw photos; DNGs made by the converter were placed in the store in different ways.

| Case | Result |
|---|---|
| File in the store, row with status `V` written by us | Counted as a smart preview |
| File in the store, row with status `U` written by us | Counted; Lightroom changed the status to `V` |
| **File in the store, no row** | **Counted; Lightroom created the row itself when the catalog was opened** |
| Row without a file | Ignored and left as it was |
| File made from another photo (a canary) | Counted and **shown as that other photo**, in the Library and in Develop: the content is not checked |
| Originals unreachable | The photos with such files work as «smart preview only», Develop included |
| **File placed while Lightroom was running, no row** | **Listed by the SDK 94 s later without a restart**; one was visibly picked up by itself |
| `photo:buildSmartPreview()` on a photo whose file was placed by hand | Returns `'existed'`; the file is untouched; the row is present afterwards |
| `photo:buildSmartPreview()` with no file and no original | Returns `'failed'` |

Nothing we placed was deleted or rewritten by Lightroom.

Not known: whether the row for a file placed during a session is written when Lightroom first notices the file or
only by the `buildSmartPreview()` call (both happened within the same second in the test). Seen later, with plug-in
0.8.0: files placed while Lightroom ran got no row within 10 minutes; the rows came with the `buildSmartPreview()`
calls.

Reading the catalog with SQLite in read-only mode while Lightroom had it open worked.

## The converter under Wine

- Wine 8.0 (Debian 12, 64-bit only) with Xvfb. The converter was copied from a Windows installation together with the
  `CameraProfiles` folder; Adobe's installer was not run under Wine.
- Without a Vulkan device Wine aborts when the converter asks for Direct3D 12 (assertion in `vkd3d/device.c`). The
  converter's own switch fixes it: an empty file `TempDisableGPU2` in
  `C:\users\<user>\AppData\Roaming\Adobe\CameraRaw\GPU\Adobe DNG Converter\`.
- In a prefix where the converter has never run, its first run aborts with exit code 3 (the same assertion) in
  spite of the marker and whatever the input is, and writes `Camera Raw GPU Config.txt` next to the marker. From
  the second run on it works. Seen twice more after deleting that file.
- One missing input file makes the converter exit with code 1 and write nothing for the whole batch.
- The output is named after the input's base name.

Speed on a 14-core (20-thread) desktop CPU, 60 raw files of 24 MP, wall time per photo:

| How | Per photo | CPU time per photo |
|---|---|---|
| One converter process, files one after another | 0.41–0.42 s | 6 s |
| 3 processes side by side | 0.37–0.38 s | 6 s |
| 4 processes | 0.31–0.35 s | 5–6 s |
| 6 processes | 0.26 s | 4.5 s |
| The converter's own `-mp` option | 1.3–1.5 s | 26 s |
| Exactly 2 processes | 0.67–0.76 s | 11–14 s |

Through the server's queue (stage 1 code, 4 processes, waves of 32 files, the same machine): 154 raw files of
24 MP built in 51 s, 0.32 s per photo, no failures.

The last two rows of the table are repeatable and unexplained. For comparison, Lightroom on a laptop built the same smart previews in
0.9–1.2 s per photo with the originals on the NAS over Wi-Fi; that time was the network.

## What Lightroom itself does

- Smart previews and standard previews are built inside the Lightroom process by its raw engine library. During a
  build no helper process does any work, and Lightroom ships no converter executable. There is nothing to swap.
- The SDK: `photo:getRawMetadata('smartPreviewInfo')` gives the path and size of a smart preview (an empty table when
  there is none); `photo:buildSmartPreview()` makes Lightroom build one from the original and returns `'created'`,
  `'existed'` or `'failed'`. No call hands Lightroom a finished file.

## Not tested

- Any other Lightroom Classic version, and macOS.
- Raw formats other than Sony ARW from two camera models.
- Whether «Build Standard-Sized Previews» runs at local speed from smart previews when the originals are
  unreachable, and what happens to such previews when the originals return.
- Adobe's installer under Wine; converter versions other than 17.2; Wine versions other than 8.0.
- The converter's GPU path under Wine.
- Converters newer than 17.4: Adobe documents the `TempDisableGPU2` marker for Camera Raw 17.4 and earlier only.
- The option `-dng1.7`, which Adobe's command-line examples for lossy JPEG XL include; our runs relied on the
  default and got DNG 1.7.
