# 0007. Photos may be added to the catalog through Lightroom's own plug-in interface, on the user's command

Status: accepted (2026-11-14). It makes the wording of 0001 and 0005 about catalog writes exact; their decisions
stand. Amended the same day for plug-in 0.6.0: photos now enter the catalog through Lightroom's own import, not
through `catalog:addPhoto` (see «Amendment» at the end; the sections before it are the decision of plug-in 0.5.0).
Since plug-in 0.7.0 the command no longer waits for the import or sends anything itself (marked in the amendment).

## Context

0001 and 0005 say that the catalog is never written. What they rule out is the project writing a Lightroom catalog or
any other Lightroom database itself: SQL against the database, edits of its files. Lightroom itself already changes
the catalog when the plug-in calls its SDK: `photo:buildSmartPreview()` makes Lightroom register a smart preview the
plug-in placed, and Lightroom creates the catalog row for it (0001).

With the originals on a NAS, the step before smart previews costs time too: Lightroom's import dialog reads every file
over the network and builds at least «Minimal» previews. Users want to add a folder's files to the catalog without the
import dialog and without Lightroom being asked for any preview, so that the server builds the smart previews.

The Lightroom Classic SDK has `catalog:addPhoto(path)`. It must be called inside `catalog:withWriteAccessDo` (or
`withProlongedWriteAccessDo`), returns the photo that was added, and throws an error when the path does not exist or
the format is not supported. An error inside `withWriteAccessDo` makes Lightroom roll back the changes of that write.

## Decision

- No part of the project writes to a Lightroom catalog or any other Lightroom database itself, ever (0001, 0002).
- The plug-in's command «Add a folder without previews...» asks Lightroom to add photos with `catalog:addPhoto`, in
  batches inside `catalog:withWriteAccessDo`: only when the user runs it, only for files of the chosen folders that are
  not in the catalog yet. It passes nothing but the path (no stacking, no metadata or develop preset), changes nothing
  else in the catalog, and asks Lightroom for no preview of any kind.
- The command never opens, changes, moves or deletes a file on disk and writes nothing next to the originals. It only
  reads folder listings.
- The documentation says it this way: the plug-in never writes to your catalog itself; Lightroom changes it through
  its own plug-in interface when it registers a smart preview the plug-in placed, and when you add a folder with this
  command.

## Consequences

- Lightroom keeps its catalog consistent itself (its ids, its folders, what it holds in memory). The danger 0001
  avoids, a second writer next to a running Lightroom, does not arise.
- Photos added this way are taken out with Lightroom's own command, as after an import: select them, Photo > Remove
  Photos, «Remove from Lightroom». The files on disk are not touched.
- What Lightroom does by itself with photos added this way (thumbnails and previews when they are shown, what it reads
  from the NAS for that, whether a JPEG next to a raw file is recorded with the raw photo as in its import) is
  undocumented and has not been measured yet. Until it has, the documentation marks the command as not run in
  Lightroom.
- The SDK names each write as a step in Lightroom's Edit > Undo list; whether Undo takes the photos of a batch out
  again has not been tried.

## Amendment (2026-11-14, plug-in 0.6.0): through Lightroom's own import

### What the first run showed

Plug-in 0.5.0's «Add a folder without previews...» ran once, in Lightroom Classic 15.6 on Windows, on a test catalog
and a folder on a NAS reached over Wi-Fi that held 1384 raw files and 1384 JPEGs:

- Listing the folder (`LrFileUtils.files` and `LrFileUtils.directoryEntries`, 2768 entries each) took 68.7 s, about
  12 ms per entry, with the processor idle and Lightroom's window not responding the whole time.
- `catalog:addPhoto` then took about 37 s per photo (six photos appeared over three minutes; 1384 would have taken
  about 14 hours), with the window «Not responding» throughout, and cancel honoured only between batches of 50.
- A stack of Lightroom's main thread, taken twice a few minutes apart, was both times inside a file-existence check
  of Lightroom's own (`FindFirstFileW` under `AgFileUtilsWin_fileExists`, called from the Lua runtime). So plug-in
  Lua tasks run on Lightroom's main thread, where any blocking call freezes the interface (an `LrTasks.yield()`
  between files did not keep the window alive), and Lightroom's code behind `addPhoto` checks the files of the folder
  one by one on every call (37 s is about one pass over 2768 entries at 12 ms).
- `addPhoto` recorded a JPEG next to its raw file as the raw photo's sidecar, as the import does.
- Lightroom's import dialog on the same folder (Add, previews «Embedded & Sidecar») took 0.17 s per photo, with the
  window responsive.

`addPhoto` on a network folder is therefore unusable, and the plug-in must not do anything slow in its own task.

### Decision

- The command is now «Import a folder without the dialog...». It starts Lightroom's own import of one folder with
  `catalog:triggerImportFromPathWithPreviousSettings(path)` ("Triggers an import, bypassing the import dialog, using
  the settings from the most recent import", SDK 4.0), only on the user's command.
- «The settings from the most recent import» may be «Copy» or «Move», which copy or move files. So before it starts
  anything, the plug-in reads what the catalog records about the previous import (`Adobe_variablesTable`, names
  starting with `AgImportDialog_`, with the read-only `sqlite3` of 0002) and starts the import only when it was «Add»
  (`importBehavior` = `refInPlace`) without «Make a Second Copy To». It reads the record again right before the
  trigger and stops when anything in it changed. If it cannot read it (no `sqlite3`, rows missing, two values for one
  name), it starts nothing. The dialog shows the preview mode and whether smart previews are on.
- With «Add», the import only adds references to the files where they are. The plug-in still writes nothing to the
  catalog itself and never opens, changes, moves or deletes a file; it does not even list the folder. After the
  trigger it shows a short notice and ends (0.7.0; 0.6.0 waited for the import, reading the catalog every few seconds,
  and then sent the new photos itself).
- `addPhoto`, the listing and the batches of 0.5.0 are removed.
- This widens what 0002 reads: besides file UUIDs, the plug-in reads the import settings above and the largest photo
  and import ids (`Adobe_images`, `AgLibraryImport`), so that the automatic send counts every photo of the import as
  new, read-only and one plain `SELECT` per run, as in 0002.
- Sending the photos of the import is left to the automatic send (one checkbox in the dialog shows and sets it). It
  sends what is new in each of its rounds, however long the import takes (0.7.0).
- The documentation says it this way: the plug-in never writes to your catalog itself; Lightroom changes it through
  its own plug-in interface when it registers a smart preview the plug-in placed, and when it imports a folder with
  the plug-in's command after the plug-in checked that the previous import was «Add».

### Consequences

- What the check cannot know: that the trigger uses exactly the values the catalog records (the names say so; Adobe
  documents nothing about them), and what Lightroom decides by itself: whether it takes sub-folders, what it does
  with files of the folder that are in the catalog already, and which previews it builds for a preview setting other
  than «Embedded & Sidecar» (code `bthm`; the meaning of other codes such as `sbig` was not established). A develop or
  metadata preset of the previous import is applied again; the dialog says so (catalog settings only).
- The plug-in does not know when Lightroom's import has finished. 0.6.0 took it as finished when the count of new
  photos had not changed for 20 seconds; its one run (Lightroom Classic 15.6, a network folder of 1384 raw files and
  1384 JPEGs, 9 photos in the catalog already) showed why that fails: the trigger returned after 0.16 s, Lightroom
  scanned the folder for about 2 min 20 s and then committed photos in bursts of about a hundred every 22–26 s (1375
  in 288 s), so the wait ended between two bursts at 425 photos. Preparing the send of those 425 took 226 s
  (`findPhotoByPath` alone 45.8 s) because Lightroom was importing meanwhile. The JPEGs were recorded as sidecars and
  the 9 photos were left alone. 0.7.0 therefore waits for nothing and lets the automatic send pick up each burst.
- Taking the photos out stays Lightroom's job, as after any import: Photo > Remove Photos, «Remove from Lightroom».
