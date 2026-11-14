# 0001. A smart preview is registered by placing the file; the catalog is never written

Status: accepted (2026-11-13). Amended by [0007](0007-photos-added-through-lightroom-on-the-users-command.md)
(2026-11-14): «never written» means never by the project itself; Lightroom changes its catalog through its own plug-in
interface when it registers a placed smart preview and when it imports a folder with «Import a folder without the
dialog...» (plug-in 0.6.0; 0.5.0's «Add a folder without previews...» used `catalog:addPhoto`).

## Context

Lightroom Classic keeps a smart preview as a DNG file in `<catalog> Smart Previews.lrdata`, named by the file's UUID,
and one row per smart preview in the catalog table `AgDNGProxyInfo`. The SDK can ask Lightroom to build a smart
preview (`photo:buildSmartPreview()`), but has no call that hands Lightroom a finished one.

Three ways to make Lightroom accept a file built elsewhere were considered: place the file and nothing else; insert
the row into the catalog database ourselves; go through «Import from Another Catalog».

Tested with Lightroom Classic 15.6 on Windows (details in `docs/research/smart-previews.md`):

- A correctly named DNG placed in the store is accepted when the catalog is opened: Lightroom creates the row itself.
- A DNG placed while Lightroom is running is accepted without a restart.
- `photo:buildSmartPreview()` then returns `'existed'`, leaves the file alone, and the row is present.

## Decision

The plug-in places the DNG in the store under the file UUID and then calls `photo:buildSmartPreview()`. No part of
the project writes to the catalog database or to any other Lightroom database, ever.

## Consequences

- The worst outcome of a Lightroom change is «smart previews are no longer picked up», not a damaged catalog.
- The behaviour is undocumented. It has to be re-verified on every Lightroom Classic release; the verified versions
  are listed in the documentation and a self-test guards deliveries (stage 5 of the plan).
- Lightroom does not validate the content of the file, so correctness of «which file goes under which UUID» is
  entirely ours: see 0005.
