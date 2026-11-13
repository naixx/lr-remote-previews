# Test data

The repository becomes public. Photographs are personal data, and camera raw files from someone's own library can
reveal where they live, who they are with and what they own. This document says what test data the project uses and
how to add more.

Sources were read on 2026-11-14; every claim about them links to the source.

## The rule

- **No photographs of contributors or users in the repository.** That covers raw files, DNGs, smart previews,
  JPEGs, crops and thumbnails of them, Lightroom catalogs, and anything the converter or Lightroom produced from a
  real photo. The [`.gitignore`](../.gitignore) blocks the common raw, DNG and catalog extensions; do not force-add
  such files.
- **Unit tests use tiny synthetic fixtures** that the test builds itself.
- **Tests that need real raw files download freely licensed samples at test time**, check them against a recorded
  SHA-256 and keep them outside the repository. Such tests also need Adobe DNG Converter, so they run only where it is
  installed, never in public CI ([plan](plan.md), stage 5). When a sample or the converter is not available, the
  test is skipped with a message that says why.
- **Samples must not show people**, whatever their licence says.
- **Prefer samples released under CC0.** Licences that require attribution would put the author's name into the
  repository, which conflicts with the project's rule of no personal names; ask the maintainers before adding such a
  sample. Do not use samples under non-commercial or other restricted licences: the project's licence (the AGPL) allows
  commercial use.

## Synthetic fixtures

Most tests need a file with the right name, the right path or the right structure, not a real photo. Build it in the
test, in a temporary folder:

- a few bytes in a file named `x.arw` for extension and path logic;
- a minimal TIFF or DNG structure written by the test for code that reads tags;
- a small SQLite file with only the tables and columns the code reads, instead of a real Lightroom catalog.

Do not commit binary fixtures with raw or DNG extensions; generating them keeps the repository free of anything that
could be mistaken for a photo.

## Real raw files, downloaded at test time

- Each sample is recorded in the test suite with the fields listed in [Adding a sample](#adding-a-sample). The
  repository holds that record, never the file.
- The test downloads the file into a cache folder outside the repository, checks its SHA-256 and refuses a file that
  does not match.
- Converter output and smart previews built during a test stay in temporary or cache folders and are never committed.

## Sources

### raw.pixls.us

[raw.pixls.us](https://raw.pixls.us/) is a public collection of raw samples, mostly one or a few per camera model and
recording mode, collected for developers of raw software.

- **Not every file is CC0.** The licence is stated per file. The table on the front page has a "License" column, and
  the front page links to a view of only the samples that are not under CC0 (<https://raw.pixls.us/?noncc0#repo>).
  On 2026-11-14 the data behind that table (<https://raw.pixls.us/json/getrepository.php?set=all>) listed 2020
  files: 1874 marked CC0 1.0 (linking to <https://creativecommons.org/publicdomain/zero/1.0/>) and 146 marked
  CC BY-NC-SA 4.0 (linking to <http://creativecommons.org/licenses/by-nc-sa/4.0/>).
- **What contributors declare.** The upload form on the front page asks the contributor to confirm that they own
  full rights to the file and release it into the public domain under CC0.
- **No people.** The front page lists photographs of people among the files the site does not want, for legal
  reasons.
- **Checksums.** Each row of the table gives the file's SHA-256 and size next to its download link.

Use only files whose own row says CC0. Check the licence of the file you take, not of the site as a whole.

### Play Raw on discuss.pixls.us

[Play Raw](https://discuss.pixls.us/c/processing/playraw/30) is a forum category where people share raw files for
others to edit.

- The category's rules say that raw files must be freely licensed and that most use a Creative Commons licence
  ([About the Play Raw category](https://discuss.pixls.us/t/about-the-play-raw-category/11956)).
- Each topic states the licence of its file. The recent topics we looked at said "This file is licensed Creative
  Commons, By-Attribution, Share-Alike" (for example
  <https://discuss.pixls.us/t/early-morning-at-the-lake-pond/62274>); some others gave only a vague statement.
- CC BY-SA requires attribution, so these files fall under the "ask the maintainers first" rule above. Skip files
  whose licence statement is vague, and check the picture for people.

### Not suitable

- **MIT-Adobe FiveK** ([dataset page](https://data.csail.mit.edu/graphics/fivek/)): its licence files
  ([LicenseAdobe.txt](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobe.txt),
  [LicenseAdobeMIT.txt](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobeMIT.txt)) allow use only for
  your own research and not for commercial advantage or monetary compensation. That is a restricted licence.
- Sample images from camera makers, shops and review sites, unless the page states a free licence for the file.

## Adding a sample

1. Find a file under CC0, for example a row on raw.pixls.us whose licence column says CC0.
2. Download it yourself and compute its SHA-256 (`sha256sum <file>` on Linux, `Get-FileHash <file>` in PowerShell).
   Compare it with the checksum the source gives, if it gives one.
3. Look at the picture: no people.
4. Add a record to the test suite's list of samples, next to the tests that use it. The format is up to the test
   suite; these fields are required:

   | Field | What |
   |---|---|
   | Source page | Where the file is listed, such as `https://raw.pixls.us/` |
   | Download URL | The direct link the test downloads |
   | Licence | The licence stated for this file, with its version and link, such as CC0 1.0, `https://creativecommons.org/publicdomain/zero/1.0/` |
   | Camera and mode | Make, model and recording mode, as the source names them |
   | Size | In bytes, measured on your download |
   | SHA-256 | Computed on your download |
   | Retrieved | The date you downloaded and checked it |
   | Content checked | That the picture shows no people |
   | Used for | Which tests need it, and why a synthetic fixture is not enough |

5. Never commit the file itself. In the pull request, say what you checked.

For illustration only (this file has not been vetted as a test sample, and its picture was not checked by us), a
record built from the raw.pixls.us listing of 2026-11-14:

```yaml
- source: https://raw.pixls.us/
  url: "https://raw.pixls.us/getfile.php/2414/nice/Sony - ILCE-7M3 - 14bit 14bit compressed (3:2).ARW"
  licence: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
  camera: Sony ILCE-7M3, 14bit compressed (3:2)
  size: <bytes, measured on download>       # the listing says 24.45 MB
  sha256: 250784580ea527442c09004417bb0eead484f2bf3ee8f9121a776ac65bb50d0f
  retrieved: <date>
  content_checked: <no people: yes/no>
  used_for: <tests>
```
