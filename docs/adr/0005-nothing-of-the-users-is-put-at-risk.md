# 0005. Nothing of the user's is put at risk: read-only originals, checked deliveries, no overwrites

Status: accepted (2026-11-13)

## Context

The project works next to two things people cannot afford to lose: their originals and their catalog. And Lightroom
does not check the content of a smart preview: in our test a DNG made from one photo, placed under another photo's
UUID, was shown and used for that other photo, in the Library and in Develop.

## Decision

1. The server mounts the originals read-only and has no code path that writes under a root.
2. The catalog is only read (0002) and never written (0001).
3. Before the plug-in places a DNG it checks that the file belongs to the photo: the original file name recorded in
   the DNG and the original pixel dimensions recorded in the DNG must match the photo. A mismatch is an error, the
   file is discarded and reported.
4. The plug-in writes under a temporary name in the same folder and renames, so Lightroom never sees a partial file.
5. The plug-in never replaces an existing smart preview.
6. The API asks for a token whenever one is configured, and every path a client sends is checked against escaping
   its root. A server without a token accepts every request and says so; that is for development only.

## Consequences

- A mix-up needs two different photos with the same file name and the same dimensions under the wrong key; the cache
  key (0003) makes that a server bug, and tests target it.
- Smart previews that Lightroom or the user already made are left alone, even if they are stale.
- There is no «repair» feature that deletes or rewrites smart previews; removing them stays Lightroom's job.
