# 0007. Photos may be added to the catalog through Lightroom's own plug-in interface, on the user's command

Status: accepted (2026-11-14). It makes the wording of 0001 and 0005 about catalog writes exact; their decisions
stand.

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
