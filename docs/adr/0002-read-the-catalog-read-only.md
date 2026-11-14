# 0002. The plug-in reads the catalog read-only to get file UUIDs

Status: accepted (2026-11-13). Amended by [0007](0007-photos-added-through-lightroom-on-the-users-command.md)
(2026-11-14, plug-in 0.6.0): «It reads nothing else» no longer holds. For «Import a folder without the dialog...» the
plug-in also reads, in the same read-only way, the settings of the previous import (`Adobe_variablesTable`, names
starting with `AgImportDialog_`) and the largest photo and import ids (`Adobe_images`, `AgLibraryImport`); 0.6.0 also
read the photos and imports added since that mark, which 0.7.0 no longer does. Since plug-in 0.8.0 the automatic send
and fetch find new photos this way too, instead of through the SDK (whose calls into the catalog are very slow while
Lightroom imports): one plain `SELECT` per look gives the photos above a mark, or with given ids, with their folder
(`AgLibraryFolder`, `AgLibraryRootFolder`), file name and file UUID (`AgLibraryFile`), import
(`AgLibraryImportImage`), pixel size, video and virtual copy flags (`Adobe_images`) and whether Lightroom knows a smart
preview for them (`AgDNGProxyInfo`, any status but `D`), plus the import records above the mark (`AgLibraryImport`);
see `CatalogRead.lua`. It still writes nothing. Since plug-in 0.8.3 the automatic fetch also reads a second Lightroom
database, the preview index `<catalog name> Previews.lrdata/previews.db` next to the catalog, the same read-only way
(`sqlite3 -readonly`, `.open --readonly`, one plain `SELECT`): how many of the file UUIDs it sent have a row in
`Pyramid` with a `quality` other than `thumbnail`, so that it starts fetching after Lightroom's own preview task for an
import; see `PreviewWatch.lua`. It writes nothing there either.

## Context

The smart preview's file name is the file UUID (`AgLibraryFile.id_global`). The SDK exposes a different identifier:
`photo:getRawMetadata('uuid')` is the image's UUID. `smartPreviewInfo.smartPreviewPath` contains the file UUID only
for photos that already have a smart preview. So the SDK alone cannot tell the plug-in where a new smart preview
belongs.

The catalog is a SQLite database in write-ahead-log mode. Lightroom has not placed an operating-system lock on it for
many versions, and plug-ins by other authors read it with the `sqlite3` command-line tool while Lightroom runs. In our
test a read-only connection to a catalog that Lightroom had open worked.

## Decision

The plug-in runs a `sqlite3` command-line tool against the open catalog, read-only, and reads `id_global` of the
files behind the photos it is about to send (`Adobe_images.id_local` = the SDK's `photo.localIdentifier`, joined to
`AgLibraryFile` through `rootFile`). It reads nothing else and writes nothing.

The `sqlite3` tool is public-domain software. The plug-in looks for it in three places: a path given in its
settings, next to the plug-in's own files, and on the PATH (macOS ships one). No copy is in the repository. Whether
the Windows build is put into the release package is decided when the first release is made; until then the user
provides it.

## Consequences

- The schema of the catalog is undocumented; the query is small and is covered by the compatibility self-test.
- The read happens in short transactions, so it does not hold up Lightroom's own writes for any length of time.
- Users who do not want a tool reading their catalog cannot use the plug-in; there is no other way to learn the UUID.
