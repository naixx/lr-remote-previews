# Adobe DNG Converter

LR Remote Previews builds Lightroom Classic smart previews on the server with **Adobe DNG Converter**, Adobe's
converter for camera raw files, running under Wine. This document explains why the server needs it, why the project
does not include it, what the server expects, the one way of providing it that we verified, how to check that the
server finds it, and what Adobe's published terms say.

What this project observed itself is marked as *verified*, with the versions; those tests were run on 2026-11-13.
Web sources were read on 2026-11-14, and every claim about them links to the source. Anything we could not confirm
from a primary source is marked *unconfirmed*.

## What it is and why the server needs it

- Adobe DNG Converter is a Windows and macOS program that converts raw files from supported cameras to DNG. Adobe
  offers it for download on its help pages ([Adobe Digital Negative Converter][help-converter]) and describes it as a
  free utility ([Digital Negative (DNG)][help-dng]).
- A Lightroom Classic smart preview is a DNG 1.7 with lossy JPEG XL, 2560 px on the long edge
  ([research notes](research/smart-previews.md)). *Verified:* with the options `-lossy -side 2560 -p0`, Adobe DNG
  Converter 17.2 wrote a DNG 1.7 with lossy JPEG XL at 2560 px whose image data was byte-identical to the smart
  preview Lightroom Classic 15.6 built from the same raw file: all 28 image tiles. Only the program name, dates,
  document ids and the small embedded thumbnail differed. That comparison under Wine was made on one Sony ARW file;
  see the research notes for the other runs.
- No open-source converter was found that writes the same file ([decision 0004](adr/0004-adobe-dng-converter-under-wine-not-bundled.md)).
- The server is a Linux container, so it runs the Windows build of the converter under Wine.

## The converter is not included

**The project does not contain, download or distribute Adobe DNG Converter**: not in the repository, not in the
container image, not through any script. Users obtain it from Adobe and put it into the app's Wine prefix
themselves. This document only describes what the app expects and what we verified. The decision is recorded in
[decision 0004](adr/0004-adobe-dng-converter-under-wine-not-bundled.md).

The reasons: the converter is Adobe's software under Adobe's terms, and none of the Adobe texts we found grants a
right to redistribute it (see [Licence and terms](#licence-and-terms)).

What this means for you:

- Installing the app includes a manual step: placing the converter into the Wine prefix.
- You obtain the converter from Adobe yourself and are responsible for complying with Adobe's terms.
- Keep the converter in the app's data volume. The project's images never contain it; if you build your own image,
  do not publish an image that contains it.

## What the app expects

| What | Windows path inside the Wine prefix | In the provided container |
|---|---|---|
| The Wine prefix | – | `/data/wine` (setting `LRRP_WINEPREFIX`, default `<LRRP_DATA_DIR>/wine`) |
| The converter | `C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe` (setting `LRRP_CONVERTER_EXE`) | `/data/wine/drive_c/Program Files/Adobe/Adobe DNG Converter/Adobe DNG Converter.exe` |
| Camera profiles | `C:\ProgramData\Adobe\CameraRaw\CameraProfiles\` | `/data/wine/drive_c/ProgramData/Adobe/CameraRaw/CameraProfiles/` |
| GPU marker, an empty file | `C:\users\<user>\AppData\Roaming\Adobe\CameraRaw\GPU\Adobe DNG Converter\TempDisableGPU2` | `/data/wine/drive_c/users/lrrp/AppData/Roaming/Adobe/CameraRaw/GPU/Adobe DNG Converter/TempDisableGPU2`, created by the app |
| An X display | – | Xvfb, included in the image |

The settings are described in [server/README.md](../server/README.md), the volumes in
[deploy/README.md](../deploy/README.md).

### The Wine prefix

The container creates the prefix in `/data/wine` on its first start. Wine refuses a prefix that belongs to another
user, so the prefix and the files you copy into it must belong to the uid the container runs as (1000 by default;
see "Running as another user" in [deploy/README.md](../deploy/README.md)).

### The GPU marker

*Verified:* without a Vulkan device, Wine aborts when the converter asks for Direct3D 12 (an assertion in
`vkd3d/device.c`). The converter has its own switch for this: when an empty file named `TempDisableGPU2` exists in
`C:\users\<user>\AppData\Roaming\Adobe\CameraRaw\GPU\Adobe DNG Converter\` inside the prefix, it prints
`Special file 'TempDisableGPU2' found -- skipping GPU2` and runs on the CPU.

**The app creates this marker itself.** The container's entrypoint creates it at every start, for the container's
user (`lrrp`) and for any other user profile already in the prefix. You only need to create it yourself if you run the
converter outside the provided container.

*Verified (converter 17.2, Wine 8.0):* **the first run of the converter in a prefix where it has never run fails
anyway.** It aborts with exit code 3 and the same `vkd3d` assertion although the marker is there, whatever the input
is, and during that run it writes `Camera Raw GPU Config.txt` next to the marker. Every later run, with that file
present, honours the marker and works. So after placing the converter, expect one failed run. The server does this
warm-up run itself before it builds anything; if you run the converter by hand, run it twice. Do not copy
`Camera Raw GPU Config.txt` from another machine: it contains a digest of the machine it was written on.

Adobe documents these marker files for Camera Raw: if GPU initialisation fails fatally, Camera Raw or Lightroom
leaves a `TempDisableGPU3` file (or `TempDisableGPU2` in some cases), and while such a file exists Camera Raw disables
GPU acceleration. Adobe's page says this applies to Camera Raw 17.4 and earlier and that Camera Raw 17.5 and later has
a "Reset GPU Support" button instead ([Camera Raw GPU FAQ][gpu-faq], step 7). Whether converter versions after 17.2
still honour the marker was not tested; see [Not verified](#not-verified).

### The X display

*Verified:* the converter needs an X display even when it only runs from the command line. We started it through
`xvfb-run`. The image contains Xvfb.

## The verified way to provide it: copy an existing Windows installation

*Verified:* Adobe DNG Converter **17.2** (Windows, 64-bit) runs under **Wine 8.0** (the `wine` and `wine64`
packages of Debian 12 "bookworm", 64-bit only; [Debian sources][debian-wine]) in a container, started through
`xvfb-run`. It was put there by copying an existing Windows installation. Adobe's installer was **not** run under
Wine; whether it works there was not tested.

1. **Install the converter on a Windows computer** from Adobe's download page ([Adobe Digital Negative
   Converter][help-converter]; the Windows x64 build). You accept Adobe's terms there yourself. If the converter is
   already installed on a Windows computer, use that installation.
2. **Copy two folders from that computer:**
   - `C:\Program Files\Adobe\Adobe DNG Converter\`. In version 17.2 it holds `Adobe DNG Converter.exe` (about
     227 MB), `vcruntime140.dll` and `vcruntime140_1.dll`.
   - `C:\ProgramData\Adobe\CameraRaw\CameraProfiles\` (about 900 MB in our copy). `C:\ProgramData` is a hidden
     folder in Windows Explorer; type the path into the address bar.

   Adobe's help page says the installer also installs a set of colour profiles that the converter needs to work
   properly, into a common resource location ([Adobe Digital Negative Converter][help-converter], "Installation").
   The other folders in `C:\ProgramData\Adobe\CameraRaw\` (`LensProfiles`, `ModelZoo`, `Settings`) were not copied
   in our test, and the image data still came out right. Running without `CameraProfiles` was not tried, and we
   copied both folders from the same installation.
3. **Put both folders at the same paths inside the Wine prefix** in the app's data volume (see the table above), so
   that the files belong to the container's uid. For example, after copying the two folders into a folder
   `/path/to/import` on the server, run this in the `deploy` folder (where `compose.yaml` is):

   ```sh
   docker compose run --rm -v /path/to/import:/import:ro lrrp sh -c '
     mkdir -p "$WINEPREFIX/drive_c/Program Files/Adobe" "$WINEPREFIX/drive_c/ProgramData/Adobe/CameraRaw" &&
     cp -R "/import/Adobe DNG Converter" "$WINEPREFIX/drive_c/Program Files/Adobe/" &&
     cp -R /import/CameraProfiles "$WINEPREFIX/drive_c/ProgramData/Adobe/CameraRaw/"'
   ```

   The command runs as the container's user, inside the same environment as the server; the entrypoint creates the
   prefix first if it does not exist yet. This command is an example; what matters is the resulting layout. If the
   data volume is a bind mount on the host, you can also copy into `<data folder>/wine/drive_c/...` directly and then
   give the files to the container's uid. Delete `/path/to/import` afterwards.
4. **Check** that the app finds the converter and that it runs, as described in the next section.

## How to check that the app sees it

- **Dashboard:** the overview page has a "DNG converter" card. It says "Installed" or "Not installed" and shows the
  path where the server looks for the converter.
- **API:** `GET /api/v1/info` ([docs/protocol.md](protocol.md)) returns a `converter` object:

  ```sh
  curl -H "Authorization: Bearer <token>" http://<host>:8787/api/v1/info
  ```

  `converter.installed` is `true` when the file named by `converter.path` exists in the Wine prefix.
  `converter.version` is not determined yet and is always `null`.
- No restart is needed: the server looks for the file on every request.

The server only checks that the program file exists. It does not check the camera profiles and does not run the
converter. To see that the converter really works, convert one raw file by hand with the same options the server
uses. Run this in the `deploy` folder and replace `<folder>\<file>` with a raw file under one of your roots:

```sh
docker compose run --rm lrrp sh -c '
  mkdir -p /tmp/out &&
  xvfb-run -a wine "C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe" \
    -lossy -side 2560 -p0 -d "Z:\tmp\out" "Z:\sources\archive\<folder>\<file>" &&
  ls -l /tmp/out'
```

Wine shows the Linux file system as drive `Z:`, so `/sources/archive/x.arw` is `Z:\sources\archive\x.arw`. A DNG with
the input's base name should appear in `/tmp/out` (which is discarded when the command ends).

What to expect in the output (*verified* with 17.2):

- Errors about missing machine-learning models at start. They are harmless; the converter prints the same on Windows.
- `Special file 'TempDisableGPU2' found -- skipping GPU2`. If this line is missing and Wine aborts in `vkd3d`, the
  marker file is not where the converter looks for it.
- If an input file does not exist, the converter exits with code 1 and writes nothing for the whole batch.

To confirm that the output matches what Lightroom builds, compare a converted file with a smart preview Lightroom
Classic built from the same raw file, using `tools/dng_compare.py` ([tools/README.md](../tools/README.md)). Never add
either file to the repository.

## How the server calls the converter

The server runs `wine "<converter>" -lossy -side 2560 -p0 -d <output folder> <raw files...>`, with Linux paths passed
as `Z:\...` paths ([server/src/lrrp/converter.py](../server/src/lrrp/converter.py), which also records the measured
facts the runner relies on).

Adobe documents the converter's command line in a PDF linked from the [Digital Negative (DNG)][help-dng] page, where it
is labelled as valid for Adobe DNG Converter 16.0 and later: [Command Line Support in Adobe DNG Converter
16][cli-pdf]. The options this project uses or deliberately avoids are all documented there:

| Option | Adobe's documentation says | This project |
|---|---|---|
| `-lossy` | Use lossy compression | Used |
| `-side <num>` | Limit the size to `<num>` pixels per side | Used with 2560 |
| `-p0` | Set the JPEG preview size to none | Used |
| `-d <directory>` | Write the converted files to that directory (default: the input file's directory) | Used; one output folder per batch |
| `-mp` | Process several raw files in parallel (default: one at a time) | **Never used**: *verified* 1.3–1.5 s per photo with it, against 0.26–0.42 s without it ([research notes](research/smart-previews.md)) |

Adobe's document also says that on Windows at least one option must be given, or the converter shows its window.

We do not pass `-dng1.7`. *Verified:* 17.2 wrote DNG 1.7 with JPEG XL from `-lossy -side 2560 -p0` alone. Adobe's
examples for lossy JPEG XL output add `-dng1.7` explicitly ([command-line PDF][cli-pdf], "Examples"), so another
converter version might choose a different default. This is not verified.

An older edition of Adobe's command-line document (copyright 2009–2014, for converter 3.2 and later) describes
`-lossy`, `-side`, `-p0` and `-d`, but not `-mp` ([archived copy][cli-pdf-old]).

## Updating for new cameras

- New camera models need a newer converter **and** newer camera profiles. Adobe lists the supported cameras with the
  minimum Camera Raw version each one requires ([Cameras supported by Camera Raw][help-cameras]). That the converter's
  version numbers follow Camera Raw's is our reading, not confirmed by an Adobe source.
- Only camera raw files are converted. JPEG, HEIC, TIFF and video files are not; Lightroom builds smart previews of
  those itself. The server lists the file extensions it accepts in `capabilities.extensions` of `GET /api/v1/info`.

To update:

1. Install the newer converter on the Windows computer.
2. Stop the container, or make sure no conversion is running.
3. Delete the old `Adobe DNG Converter` and `CameraProfiles` folders from the prefix, then copy the new ones as in the
   steps above, so that no files of the old version remain.
4. Check as described above, including a comparison with a smart preview Lightroom built. Only 17.2 is verified.

## Not verified

- Adobe's installer under Wine. Others report that it works with some versions (see
  [Others' reports](#others-reports-of-the-converter-under-wine)); we did not test it.
- Converter versions other than 17.2, the ARM64 build, and Wine versions other than 8.0.
- Whether converter versions after 17.2 still honour the `TempDisableGPU2` marker. Adobe's GPU page describes the
  marker files only for Camera Raw 17.4 and earlier ([Camera Raw GPU FAQ][gpu-faq]).
- The converter's GPU path under Wine, with a Vulkan device.
- Running without the `CameraProfiles` folder, or with profiles from another version than the program.
- Raw formats other than Sony ARW from two camera models.

## Licence and terms

This section reports what Adobe's published texts say, as read on 2026-11-14. It is not legal advice. **Each user is
responsible for reading and complying with the terms that apply to their copy of the converter.**

**We did not find a licence text that Adobe identifies as the licence of Adobe DNG Converter.** What we found:

- **Download pages.** The converter's help page ([Adobe Digital Negative Converter][help-converter], last updated
  6 January 2025) links the installers for macOS, Windows x64 (<https://www.adobe.com/go/dng_converter_win>) and
  Windows ARM64 (<https://www.adobe.com/go/dng_converter_winarm>), with system requirements and installation steps. It
  shows no licence or EULA text for the converter; the only legal link is the site-wide "Terms of Use" in the footer.
  The [Digital Negative (DNG)][help-dng] page (last updated 10 November 2026) links the same Windows and macOS
  downloads and describes the converter as a free utility; it shows no licence text for it either.
- **Adobe's list of product licences.** The [Product Licenses and Terms of Use][adobe-licenses] page does not list
  Adobe DNG Converter.
- **Adobe General Terms of Use** ([adobe.com/legal/terms.html][adobe-terms], published and effective 3 October 2025).
  They say they govern the use of Adobe's websites, products and services (the "Services") and the installation and
  use of any software Adobe includes as part of the Services (the "Software"). Section 3.1 grants a non-exclusive,
  limited, revocable right to install, access and use the Services and Software that Adobe makes available to you,
  and says that each licence is for one person and cannot be shared. Section 1.2 says that product-specific terms
  may also apply and take precedence where they conflict.
- **Software Product Specific Terms** ([PDF][adobe-software-terms], last updated 18 June 2024; linked as "Software"
  from section 1.2 of the General Terms). Section 1.4(B) lists what you must not do unless the Terms permit it, among
  them: hosting or streaming the Software; "allow third parties to access the Software remotely"; and renting,
  leasing, selling, sublicensing, assigning or transferring any portion of the Software. We point these clauses out
  because this project runs the converter on a server; we do not interpret them.
- **Neither document names Adobe DNG Converter**, and we found no Adobe statement saying whether these documents are
  the terms for it.
- **The installer** may show its own terms. We did not run or unpack it, and the project does not download it, so we
  cannot say what it shows. Read whatever it presents.
- **Historical.** Adobe's former download page for converter 8.7.1 (an archived copy from 2020; the page is no longer
  online) showed generic terms for Adobe downloads. Among other things they said that the terms of an end user licence
  agreement accompanying a particular software file supersede the terms on the page ([archived page][old-download]).

None of the texts above grants a right to redistribute the converter. That is one reason the project never includes
it.

## Others' reports of the converter under Wine

These are other people's reports, not verified by us. Versions are as reported.

- **RawPedia** (RawTherapee's wiki; [archived copy, captured 2025-12-07][rawpedia-archived]): says that Wine 8.21 was
  confirmed to work well with Adobe DNG Converter 16.0.1; runs Adobe's installer under Wine in a dedicated prefix
  with the Windows version set to Windows 10. The current page ([rawpedia.pixls.us][rawpedia]) showed only the heading
  of that section when we read it.
- **WineHQ bug 46972** ([link][bug-46972]): converter 11.2 and later aborted on an unimplemented Windows function
  (`GetRestrictedErrorInfo`); fixed in Wine 5.0-rc5.
- **WineHQ bug 49563** ([link][bug-49563]): converter 12.4 crashed with Wine 5.12; fixed in Wine 5.13.
- **WineHQ bug 50392** ([link][bug-50392]): the 13.x installer reported success but installed no program files on Wine
  before 5.12; it refused to run unless the Windows version was set to Windows 10. Closed as a duplicate of a fixed
  bug.
- **discuss.pixls.us, 2021** ([thread][pixls-24934]): converter 13.2 installed after a Wine 6.8 update; an error
  about a missing `api-ms-win-core-versionansi-l1-1-1.dll`; Wine 7.3 was said to make converter 14.2 work.
- **discuss.pixls.us, 2021** ([thread][pixls-27445]): converter 13.4; its folder picker fails under Wine; passing the
  folder on the command line works, with Windows-style paths whose backslashes are escaped for the shell. One
  participant could not get a headless run to work.
- **Manjaro forum, 2023** ([thread][manjaro]): converter 14.x and 15.2 reported "This program does not support the
  version of Windows your computer is running" on some Wine versions; Wine 8.0 worked.
- **discuss.pixls.us, 2023** ([thread][pixls-38987]): converter 15.0 reported a missing component; another user ran
  15.3.1 with Wine 8.13 on Arch Linux.
- **discuss.pixls.us, 2024** ([thread][pixls-45551]): command-line conversion through Bottles (a Wine manager, as a
  Flatpak) failed with "Invalid source file" and "Failed to convert"; no solution was posted, others said it worked in
  plain Wine.
- **adobe-dngconverter-docker** ([GitHub][jarnoh], last change 2018): a Docker image with 32-bit Ubuntu 16.04,
  Wine 1.8 and converter 10.5, which runs Adobe's installer while building the image.

We did not check WineHQ's application database: its site answered with a bot challenge.

## Sources

Read on 2026-11-14 unless noted otherwise.

- Adobe Digital Negative Converter (help page): <https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/adobe-dng-converter.html>
- Digital Negative (DNG): <https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/digital-negative.html>
- Command Line Support in Adobe DNG Converter 16 (PDF): <https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section/download-1/dng_converter_commandline.pdf>
- Older command-line document, archived 2023: <https://web.archive.org/web/20230327082002/https://helpx.adobe.com/content/dam/help/en/photoshop/pdf/dng_commandline.pdf>
- Cameras supported by Camera Raw: <https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/camera-raw-plug-supported-cameras.html>
- Camera Raw GPU FAQ and troubleshooting: <https://helpx.adobe.com/camera-raw/desktop/troubleshoot/acr-gpu-faq.html>
- Product Licenses and Terms of Use: <https://www.adobe.com/legal/licenses-terms.html>
- Adobe General Terms of Use: <https://www.adobe.com/legal/terms.html>
- Software Product Specific Terms: <https://www.adobe.com/go/softwareterms>, which redirects to <https://wwwimages2.adobe.com/content/dam/cc/en/legal/servicetou/Software-Product-Specific-Terms-en_US-20240618.pdf>
- Former download page for converter 8.7.1, archived 2020: <https://web.archive.org/web/20201025055239/https://supportdownloads.adobe.com/detail.jsp?ftpID=5864>
- Debian sources, wine (8.0~repack-4 in bookworm): <https://sources.debian.org/src/wine/>

[help-converter]: https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/adobe-dng-converter.html
[help-dng]: https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/digital-negative.html
[help-cameras]: https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/camera-raw-plug-supported-cameras.html
[gpu-faq]: https://helpx.adobe.com/camera-raw/desktop/troubleshoot/acr-gpu-faq.html
[cli-pdf]: https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section/download-1/dng_converter_commandline.pdf
[cli-pdf-old]: https://web.archive.org/web/20230327082002/https://helpx.adobe.com/content/dam/help/en/photoshop/pdf/dng_commandline.pdf
[adobe-licenses]: https://www.adobe.com/legal/licenses-terms.html
[adobe-terms]: https://www.adobe.com/legal/terms.html
[adobe-software-terms]: https://wwwimages2.adobe.com/content/dam/cc/en/legal/servicetou/Software-Product-Specific-Terms-en_US-20240618.pdf
[old-download]: https://web.archive.org/web/20201025055239/https://supportdownloads.adobe.com/detail.jsp?ftpID=5864
[debian-wine]: https://sources.debian.org/src/wine/
[rawpedia-archived]: https://web.archive.org/web/20251207234630/https://rawpedia.rawtherapee.com/How_to_convert_raw_formats_to_DNG
[rawpedia]: https://rawpedia.pixls.us/how_to_convert_raw_formats_to_dng/
[bug-46972]: https://bugs.winehq.org/show_bug.cgi?id=46972
[bug-49563]: https://bugs.winehq.org/show_bug.cgi?id=49563
[bug-50392]: https://bugs.winehq.org/show_bug.cgi?id=50392
[pixls-24934]: https://discuss.pixls.us/t/wine-adobedngconverter/24934
[pixls-27445]: https://discuss.pixls.us/t/adobe-dng-converter-and-wine-cannot-select-folder/27445
[pixls-38987]: https://discuss.pixls.us/t/wine-and-adobe-dng/38987
[pixls-45551]: https://discuss.pixls.us/t/adobe-dng-converter-via-flatpak-bottles/45551
[manjaro]: https://forum.manjaro.org/t/dngconverter-does-not-work-anymore/135433
[jarnoh]: https://github.com/jarnoh/adobe-dngconverter-docker
