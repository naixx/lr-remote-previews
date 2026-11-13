# 0003. The server knows files, not catalogs; the cache key is the source file's identity

Status: accepted (2026-11-13)

## Context

A smart preview DNG contains nothing from the catalog: no UUID, no develop settings. It depends only on the raw file
and on the converter. Builds are wanted from several directions: photos selected in Lightroom, a folder picked on the
dashboard, new files noticed by the server itself, photos just imported.

## Decision

The server's unit of work is «the file at this path under this root». It stores each result in a cache under a key
derived from the source's identity: root id, relative path, size and modification time. It never sees catalog
identifiers. The plug-in keeps the mapping from its photos to the files it asked for and names the delivered DNGs by
file UUID on its own side.

## Consequences

- One cache serves every catalog and every client, and every kind of trigger. A file built in advance is delivered
  instantly when Lightroom asks for it.
- A changed original (new size or time) gets a new key; the old entry is garbage.
- Moving or renaming originals invalidates their cache entries. Acceptable: rebuilding is cheap.
- The key does not hash file contents, so building a job list costs one `stat` per file.
