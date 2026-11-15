# User guide

This guide takes you from nothing to a first smart preview that was built on your NAS and delivered into your
Lightroom Classic catalog. It assumes that you are comfortable with a NAS, Docker and a command line, and that you
have never seen this project. When something does not work, see [troubleshooting.md](troubleshooting.md).

> **State of the project: server 0.6.0, plug-in 0.8.4.** Verified with Lightroom Classic 15.6 on Windows and Adobe
> DNG Converter 17.2 under Wine 8.0 on a TrueNAS SCALE machine: the server builds smart previews (0.26–0.35 s per
> 24 MP photo on a 14-core desktop CPU) and survives a restart in the middle of a job; its dashboard, the folder
> queue, the automatic scan and the cache clean-up ran there with the real converter. In Lightroom, «Build smart
> previews on the server» (0.2.0) placed and registered 157 smart previews, and «Send to the server» with «Fetch
> ready smart previews» for the selection (0.3.0) 143 more, from originals on the NAS. Plug-in 0.7.0 ran end to end:
> an import of 1384 raw files from the NAS with «Import a folder without the dialog...», sent by the automatic send
> and fetched by the automatic fetch, 1384 smart previews placed and registered in 16.5 minutes. Plug-in 0.8.0
> rebuilt that automatic path for speed and ran once with server 0.6.0: the photos it sent were placed a median 2.5 s
> after they were built, but it sent only 650 of the 1384 photos (Lightroom made their rows visible out of order). 0.8.1
> fixes that; 0.8.2 downloads nothing while an import is in progress and registers with one call. Neither has been run
> in Lightroom yet; to repair a catalog 0.8.0 left short, see [troubleshooting.md](troubleshooting.md). The status dialog has passed tests outside Lightroom only.
> 0.6.0's «Import a folder without the dialog...» ran once (its trigger and gate worked; its waiting was dropped),
> 0.5.0's «Add a folder without previews...» ran once and was dropped (far too slow on a NAS). Parts of this guide
> still describe the dashboard as it was in server 0.3.0. macOS and other Lightroom versions are untested. Try
> everything on a test catalog first.

## 1. What it does and what you need

When your originals live on a NAS and your catalog on another computer, Lightroom builds every smart preview by
reading the whole raw file over the network. LR Remote Previews builds the same file on the machine that holds the
originals, and Lightroom only receives the finished smart preview: a DNG of 0.3–0.7 MB for a 24 MP photo.

It has three parts:

- **The server**, a container on the machine with the originals. It turns raw files into smart preview DNGs with
  Adobe DNG Converter running under Wine, and keeps them in a cache.
- **The plug-in** for Lightroom Classic. It tells the server which files you want, fetches the finished DNGs, puts
  them into the catalog's smart preview folder and asks Lightroom to register them.
- **The dashboard**, a web page the server serves. It shows what the server is doing.

### What you need

| What | Details |
|---|---|
| A machine that holds the originals and runs containers | Docker with Compose. The verified machine is an x86-64 computer with TrueNAS SCALE; other systems and processor architectures are untested. Space: the image is about 1 GB; the data volume about 1.5 GB once the converter is in it; the cache about 0.5 MB per photo |
| Lightroom Classic on another computer | Verified: 15.6 on Windows |
| The originals reachable from Lightroom by a path | A mapped network drive such as `Z:\`, or a network path such as `\\nas.local\photos\`. The photos in your catalog point to the same files the server reads |
| Adobe DNG Converter | Adobe's free converter, the Windows x64 build. You obtain it from Adobe and put it into the server yourself; the project does not contain or download it. Verified version: 17.2. The verified way to provide it copies an installation from a Windows computer (section 4) |
| A `sqlite3` command-line tool on the Lightroom computer | `sqlite3.exe` from the "sqlite-tools" download for Windows at [sqlite.org](https://sqlite.org/download.html). The plug-in reads the catalog with it, read-only. It is not included in the plug-in |
| A network between the two | The server listens on port 8787 and speaks plain HTTP |

For the steps below you also need `git` on the NAS, to get the repository, and optionally Python 3 on any computer,
for a test job without Lightroom.

### What it never does

- **It never writes to your catalog itself.** The plug-in reads the catalog, and (since plug-in 0.8.3) Lightroom's
  preview index `<catalog name> Previews.lrdata\previews.db` next to it, with `sqlite3` in read-only mode, and puts
  files into the smart preview folder next to the catalog. It writes neither database. Lightroom changes its catalog itself, through its own
  plug-in interface: it registers those files, and, when you run **Import a folder without the dialog...**, it
  imports the folder you chose. The plug-in starts that import only after checking that your previous import was
  «Add», so the import only adds references to the files where they are
  ([decision record 0007](adr/0007-photos-added-through-lightroom-on-the-users-command.md)).
- **It never changes your originals.** The container mounts them read-only, and no part of the server writes under a
  root.
- **It never uploads anything from your computer.** The server reads originals it already has. All that travels from
  Lightroom to the server is the name of each file: a root id and a path.
- **It never replaces a smart preview that exists**, also not one Lightroom built itself.
- It does not contain or download any Adobe software.
- It converts camera raw files only. JPEG, HEIC, TIFF and video files stay with Lightroom, which builds their smart
  previews itself.
- It does not build standard previews. Section 6 shows how to import so that you do not have to wait for them.

## 2. How it works

```
 The Lightroom computer                         The NAS (one container)
 ──────────────────────                         ───────────────────────
 photo Z:\2026\2026.06.20 - shoot\IMG_0001.ARW
   │  path mapping Z:\ → archive
   ▼
 root  archive                    ── text ──►   /sources/archive/2026/2026.06.20 - shoot/IMG_0001.ARW
 path  2026/2026.06.20 - shoot/IMG_0001.ARW     (its own read-only mount of the same folder)
                                                  │  Adobe DNG Converter
                                                  ▼
 checked, written into            ◄── DNG ───   2560 px smart preview, 0.3–0.7 MB, kept in the cache
 C:\Photos\Main\Main Smart Previews.lrdata\6\6282\<file id>.dng,
 registered by Lightroom
```

1. You select photos in Lightroom and give a command. For every photo the plug-in takes the path the catalog
   records and, with your path mapping, turns it into a root id and a path relative to that root. Only that text
   goes to the server.
2. The server finds the file under its own mount of the same folder, checks that it exists and is a camera raw file,
   and builds the smart preview with Adobe DNG Converter. The result goes into the server's cache, under a key made
   of the root, the path, the file size and the modification time. A file that is already in the cache costs nothing.
3. The plug-in downloads each finished DNG and checks that it was made from that photo's file: the original file name
   and the original pixel size recorded inside the DNG must match the photo. It writes the file into the catalog's
   smart preview folder under a temporary name, renames it, and asks Lightroom to register it. Lightroom answers that
   the smart preview «existed».

**The raw files are never uploaded and never travel from your computer.** They are on the NAS already, which is
where Lightroom reads them from too. The server reads them there, locally.

### Roots and path mappings

- A **root** is a folder with originals as the server (the container) sees it, with a short id. You list the roots in
  a file `roots.yaml`. An id is 1 to 32 lower-case letters, digits, `-` or `_`, starting with a letter or digit. The
  server never tells a client its own paths; a client names a root by its id.
- A **path mapping** in the plug-in says which folder on the Lightroom computer is which root: local prefix `Z:\` →
  root id `archive`. The plug-in has room for three. The longest matching prefix wins, and a prefix matches whole
  folder names only (`Z:\Photos` does not cover `Z:\Photos2`). Windows paths match without regard to case; the rest
  of the path is sent exactly as the catalog spells it.

Both ends must name the same folder: the folder that Lightroom calls `Z:\` must be the folder the container mounts as
the root.

### The example used in this guide

| | Example |
|---|---|
| The folder with the originals, on the NAS | `/path/to/originals` |
| The same folder on the Lightroom computer | `Z:\` (a mapped network drive) |
| The same folder inside the container | `/sources/archive` (mounted read-only) |
| The root in `roots.yaml` | id `archive`, path `/sources/archive` |
| The path mapping in the plug-in | `Z:\` → `archive` |
| The catalog | `C:\Photos\Main\Main.lrcat` |

One photo on its way:

| Step | Path |
|---|---|
| What the catalog records | `Z:\2026\2026.06.20 - shoot\IMG_0001.ARW` |
| What the plug-in sends | root `archive`, path `2026/2026.06.20 - shoot/IMG_0001.ARW` |
| What the server reads | `/sources/archive/2026/2026.06.20 - shoot/IMG_0001.ARW`, which is `/path/to/originals/2026/2026.06.20 - shoot/IMG_0001.ARW` on the NAS |
| Where the plug-in puts the smart preview | `C:\Photos\Main\Main Smart Previews.lrdata\6\6282\62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng`, named after the file's id in the catalog |

## 3. Run the server

No image is published yet. You build it on the NAS from a copy of the repository, with Docker Compose and the files
in `deploy/`. (For TrueNAS SCALE, [truenas.md](truenas.md) describes an install through «Install via YAML». It is
part of the work in progress; that page says the YAML has not been installed through the TrueNAS interface yet.)

### 3.1 Get the repository

On the NAS:

```sh
git clone https://github.com/naixx/lr-remote-previews.git
cd lr-remote-previews/deploy
```

The `docker compose` commands in this guide run in this `deploy` folder, where `compose.yaml` is.

### 3.2 The token

```sh
cp .env.example .env
openssl rand -hex 32
```

Put the output into `.env` as `LRRP_TOKEN=<the string>`. Every request to the API must carry this token; the plug-in
and the dashboard ask you for it. Without a token the API is open to anyone who can reach the port, and the server
prints a warning at start; that is meant for development only.

### 3.3 The originals and the roots

1. In `compose.yaml`, replace `/path/to/originals` in the line `- /path/to/originals:/sources/archive:ro` with the
   folder that holds your originals on the NAS. Keep `:ro`: the server never writes there, and the read-only mount
   makes sure of it.
2. Create `roots.yaml` next to `compose.yaml`:

   ```yaml
   roots:
     - id: archive
       path: /sources/archive
       label: Archive
   ```

3. In `compose.yaml`, uncomment `environment:` with `LRRP_CONFIG: /config/roots.yaml`, and the volume line
   `- ./roots.yaml:/config/roots.yaml:ro`.

The service then looks like this (comments left out):

```yaml
services:
  lrrp:
    build:
      context: ..
      dockerfile: deploy/Dockerfile
    image: lr-remote-previews:local
    restart: unless-stopped
    env_file: .env
    environment:
      LRRP_CONFIG: /config/roots.yaml
    ports:
      - "8787:8787"
    volumes:
      - data:/data
      - cache:/cache
      - /path/to/originals:/sources/archive:ro
      - ./roots.yaml:/config/roots.yaml:ro
```

For more roots, add one read-only mount under `/sources` and one entry in `roots.yaml` for each. If your originals
span several file systems (on TrueNAS: several datasets), read the note about that in [truenas.md](truenas.md).
`/data` and `/cache` must not lie inside a root; the server refuses to start if they do.

### 3.4 The user the server runs as

The container runs as uid 1000, gid 1000, unless you say otherwise. That user must:

- **read the originals**: enter every folder on the way and read every raw file. With the wrong user, every file is
  reported as `not_found`, because the server treats a file it may not read as missing;
- **write `/data` and `/cache`**;
- **stay the same**. On the first start the container creates the Wine prefix in `/data/wine`, where the converter
  will live, and it belongs to that uid. Wine refuses a prefix that belongs to another uid.

So decide before the first start.

**Find out who can read the originals.** On the NAS:

```sh
ls -ln /path/to/originals
ls -ln "/path/to/originals/2026/2026.06.20 - shoot" | head
```

`-n` shows numeric ids. A folder shown as `drwxr-x--- 5 1001 100 …` can be entered and read by uid 1001 (its owner)
and by members of group 100; a file shown as `-rw-r----- 1 1001 100 …` can be read by the same. If your NAS uses
access control lists, these bits do not tell the whole story. Test it.

**Test a uid before you commit to it.** This starts a shell in the image as uid 1001, gid 100, without the
container's start-up script, so no Wine prefix is created yet:

```sh
docker compose build
docker compose run --rm --user 1001:100 --entrypoint sh lrrp -c \
  'id; ls /sources/archive | head; cat "/sources/archive/2026/2026.06.20 - shoot/IMG_0001.ARW" > /dev/null && echo readable'
```

Use a real file of yours. `readable` at the end means this uid will do; `Permission denied` means it will not.

**Set it.**

- If uid 1000, gid 1000 can read the originals, there is nothing to do.
- Otherwise add `user: "1001:100"` (your ids) to the service. The named volumes `data` and `cache` of the example
  belong to uid 1000, so replace them with folders on the NAS that belong to your uid, for example
  `- /path/to/app/data:/data` and `- /path/to/app/cache:/cache`, after
  `chown -R 1001:100 /path/to/app/data /path/to/app/cache`. If the originals are readable through a group other than
  the user's own, Compose's `group_add` adds it (shown in `deploy/truenas/app.yaml`). The build arguments `LRRP_UID`
  and `LRRP_GID` are another way: they build the image for another user ([deploy/README.md](../deploy/README.md)).

### 3.5 Start and check

```sh
docker compose up -d --build
docker compose logs -f lrrp
```

The first start creates the Wine prefix, which takes about a minute:
`entrypoint: creating the Wine prefix in /data/wine (first start, may take a minute)`. Then the server logs how many
converter processes it will run, for example `4 converter process(es) side by side, batches of up to 8 files`, and
starts listening. Stop following the log with Ctrl+C; the container keeps running.

Check it from any computer:

```sh
curl http://nas.local:8787/healthz
curl -H "Authorization: Bearer <token>" http://nas.local:8787/api/v1/info
```

The first answers `{"status":"ok"}`. The second describes the server as JSON: `auth` is `token`,
`converter.installed` is `false` (until section 4), and `roots` lists your roots, each with `available` `true`.

Then open `http://nas.local:8787/` in a browser. The dashboard asks for the token («Access token required»); paste it
and press **Save token**. The token is kept in that browser only; **Forget token** in the header removes it. The
**Overview** page shows the queue, the latest jobs, the server, the DNG converter (**Not installed** for now), your
library roots (`archive` should say **Available**) and the raw formats the server accepts.

Since server 0.4.0 the dashboard also has pages for the jobs, for putting a whole folder into the queue, for the
settings that change while the server runs (number of processes, pause, working hours, the automatic scan, the
cache limits), for a converter self-test and for the log. This guide does not describe them page by page yet.

Until then, the server's settings are environment variables in `compose.yaml` (`LRRP_WORKERS`, `LRRP_BATCH_SIZE`,
`LRRP_JOB_RETENTION_DAYS`; all of them in [server/README.md](../server/README.md)). After a change,
`docker compose up -d` starts the container again with the new values.

### 3.6 The status widget

The dashboard has a compact page for a frame inside another dashboard (the TrueNAS SCALE dashboard, Homepage, Homarr,
Home Assistant) or for a small pinned browser tab:

```
http://nas.example:8787/#/widget
http://nas.example:8787/#/widget?theme=dark
```

`theme=light` or `theme=dark` sets its colours to match the page around it; without it the widget follows the system
setting, as the dashboard does. It is designed for frames of about 265×150, 540×195 and 540×400 CSS pixels and fits
the sizes in between. It never scrolls: in a smaller frame the less important lines give way first. In that order it
shows:

- the name, which opens the full dashboard in a new tab, and the state the Overview shows (Running, Idle, Paused,
  Waiting for working hours, Converter missing);
- a line only when something is wrong: the server cannot be reached or answered with an error, Adobe DNG Converter is
  not installed, a root is unavailable;
- what is queued and being built, the photos per minute, the time left and the progress of the job being built, or
  «Nothing is queued.»;
- the photos built and failed today (the failures link to the Jobs page);
- the cache: its files and size;
- at about 540×400 also up to three active jobs, the converter processes at work and the automatic scan's last and
  next run.

It only reads; nothing on it changes the server. In a page of your own:

```html
<iframe src="http://nas.example:8787/#/widget?theme=dark"
        width="540" height="195" style="border: 0"
        title="LR Remote Previews"></iframe>
```

A page served over HTTPS cannot show a frame over plain HTTP (browsers block it), so such a dashboard needs the
server behind an HTTPS address too.

**When the server stops answering, the widget stops asking.** The server often runs on a NAS that sleeps when idle and
wakes up on requests, and a widget stays open for days. While the server answers, the widget asks as often as the
Overview does (every 2 s while building, every 10 s otherwise, the server's facts once a minute), and only while the
page that shows it is visible. When no answer comes, which usually means the NAS went to sleep, it tries three more
times, after 5, 15 and 60 seconds, then shows «Server not reachable» with a **Check again** button and sends nothing
more by itself: no timer and no showing of the tab sends a request that could wake the NAS. Press **Check again** to
see it again. An error answer from a running server does not count: the widget goes on asking and shows the error.

**The token.** When the server needs one, the widget asks for it once, in the frame, unless the browser already keeps
it for that address. Browsers keep the storage of a page shown inside another site apart from that of the same page
opened directly, so the widget may ask once in each dashboard that shows it. As in the dashboard, the token stays in
that browser only.

## 4. Provide Adobe DNG Converter

The server needs Adobe DNG Converter, and you provide it. [converter.md](converter.md) is the full description: what
the server expects, the verified way, how to check it, how to update it for new cameras, and what Adobe's published
terms say. Read its section «Licence and terms»: you obtain the converter from Adobe and are responsible for
complying with Adobe's terms. In short, the verified way is:

1. Install the converter (Windows x64) on a Windows computer from Adobe's download page.
2. Copy two folders from there to the NAS: `C:\Program Files\Adobe\Adobe DNG Converter\` and
   `C:\ProgramData\Adobe\CameraRaw\CameraProfiles\`.
3. Copy them into the Wine prefix in the data volume, at the same paths, as the container's user. converter.md has
   a ready `docker compose run` command for that.
4. Reload the dashboard. The DNG converter card says **Installed** and shows the converter's version. No restart
   is needed.

Two things converter.md explains and the server already handles for you:

- The converter needs an empty marker file, `TempDisableGPU2`, to stay off the graphics card, which the container
  does not have. The container creates it at every start.
- **The converter's first run in a fresh Wine prefix always fails** (exit code 3), whatever the input. The server
  knows this: before its first build it runs the converter once on purpose and only then starts the real work. You
  see it once in the server log:

  ```
  Adobe DNG Converter has not run in this Wine prefix yet (no 'Camera Raw GPU Config.txt'); warming it up
  warm-up done (the run exited with code 3)
  ```

  Exit code 3 there is expected. The first job on a new installation therefore takes a few seconds longer.

**Check the whole chain without Lightroom.** On any computer with Python 3 and a copy of the repository, from the
repository's top folder:

```sh
python tools/submit_job.py --server http://nas.local:8787 --token <token> --root archive \
    "2026/2026.06.20 - shoot/IMG_0001.ARW" --download out
```

Use a real raw file under the root, as a path relative to the root with forward slashes. The tool sends one job,
follows it and downloads the DNG into `out`. The server log shows a line such as
`wave: 1 file(s) in 1 converter process(es), 1 built, 0 to retry, 2.3 s`. Only version 17.2 of the converter is
verified.

## 5. Install the plug-in

On the Lightroom computer:

1. Get the folder `LRRemotePreviews.lrplugin`: `plugin/LRRemotePreviews.lrplugin` from a copy of the repository, or
   unzip `LRRemotePreviews-<version>.zip` (`python tools/package_plugin.py` builds it into `dist/`). Put the folder
   where it can stay; Lightroom loads the plug-in from there.
2. In Lightroom Classic: **File > Plug-in Manager > Add**, and pick the `LRRemotePreviews.lrplugin` folder.
3. Select **LR Remote Previews** in the Plug-in Manager's list. Its settings appear on the right.

### 5.1 sqlite3

A smart preview's file is named after the file's id in the catalog, and Lightroom's plug-in interface does not give
that id. The plug-in reads it from the catalog with the `sqlite3` command-line tool, in read-only mode, while
Lightroom has the catalog open. **Import a folder without the dialog...** also reads with it how the previous import
was set up and which photos Lightroom's import has added. The plug-in never writes to the catalog itself.

Download the "sqlite-tools" archive for Windows from [sqlite.org](https://sqlite.org/download.html) and take
`sqlite3.exe` out of it. The plug-in looks for the tool in this order:

1. the path in the setting **sqlite3 tool:** (when it is filled in, only this one is tried);
2. `sqlite3.exe` in the plug-in folder, next to `Info.lua`;
3. `sqlite3` on the PATH.

With Lightroom Classic 15.6 on Windows, a `sqlite3` found on the PATH worked. The other two places have not been tried
in Lightroom yet.

### 5.2 Settings

| Setting | Example | Meaning |
|---|---|---|
| **Server URL:** | `http://nas.local:8787` | The server's address. A path after the host is allowed, for a server behind a reverse proxy |
| **Access token:** | the token from `.env` | Leave empty only when the server runs without a token. Lightroom keeps it in plain text in its preferences |
| **Path mappings:** 1 to 3, **local prefix** → **server root id** | `Z:\` → `archive` | Photos under the local prefix are found on the server under the root with that id |
| **sqlite3 tool:** | empty, or `C:\Tools\sqlite3.exe` | Optional; see above |
| **Downloads at once:** | `4` | 1 to 8. How many smart previews are downloaded at the same time while fetching. They are still checked, written and registered one at a time |
| **Automatic fetch:** | on | **Fetch ready smart previews while Lightroom runs, every** 30 seconds to 30 minutes; it asks the server only while this catalog waits for smart previews it sent; see section 6 |

The local prefix is the beginning of the path your catalog records for the photos: `Z:\` in the example, or a network
path such as `\\nas.local\photos\` if that is how the catalog knows them. If some photos are recorded under `Z:\` and
others under `\\nas.local\photos\`, enter both as two mappings to the same root id. When a photo is left out as «not
under any local prefix», the plug-in's log names its path.

The settings are saved when you close the Plug-in Manager or select another plug-in.

### 5.3 Test connection and Check sqlite3

Both buttons use what is in the fields now, so you can try before you close the Plug-in Manager.

- **Check sqlite3** finds the tool and runs `sqlite3 -version`. Next to the button you see, for example,
  `Found sqlite3 3.50.6`; a dialog says where it was found («sqlite3 on the PATH», «next to the plug-in: …» or «set in
  the plug-in settings: …»).
- **Test connection** asks the server for `GET /api/v1/info`. Next to the button you see, for example,
  `Connected: LR Remote Previews 0.3.0, converter installed, 1 root`. The dialog shows the server's version, whether
  it needs a token, whether Adobe DNG Converter is installed, its roots, and one line per mapping, for example
  `Path mapping: Z:\ -> archive (available)`. It also names mapping rows that are half filled in.

## 6. Use it

The three everyday commands are under **Library > Plug-in Extras**: **Import a folder without the dialog...**, **Build
smart previews on the server** and **Fetch ready smart previews**. **Server status...**, **Check the server against
Lightroom** and the diagnostics are under **Help > Plug-in Extras**. In both menus every item of the plug-in starts
with `LRRP: ` (for example `LRRP: Server status...`), so that it stands out among the items of other plug-ins; the
text below names the commands without it. (Plug-in 0.7.0 moved the second group to the Help menu, which worked in
its run, and added the prefix.)

### Originals on a NAS: a workflow without the waiting

Smart previews are half of the waiting. The other half is the import: with «Minimal» or «Standard» previews
Lightroom reads every original over the network and renders it on your computer. It does not have to:

1. **Import with Add and Build Previews: «Embedded & Sidecar»**, with «Build Smart Previews» unchecked. Lightroom
   then shows the JPEG the camera made instead of rendering one: the JPEG next to the raw file when the camera wrote
   RAW+JPEG pairs, otherwise the one inside the raw file. Nothing is rendered, and only a few megabytes per photo
   travel over the network.
2. Let the task «Fetching Initial Previews» finish. A photo it has not reached keeps a tiny thumbnail, and Lightroom
   renders that photo from its original as soon as it comes into view.
3. Select the imported photos and **Build smart previews on the server**; the automatic fetch brings their smart
   previews in when they are built (or use **Fetch ready smart previews**).
4. Choose your picks in the Library. Lightroom keeps the camera's previews (the badge «Embedded Preview») and reads
   an original only when you zoom to 1:1.

Measured on Lightroom Classic 15.6 with 24-megapixel Sony raw files on a NAS reached over Wi-Fi, 1384 photos:
0.17 s per photo to add them to the catalog, 0.34 s per photo for the previews, about 4 MB read per photo instead
of 25 MB. The size of these previews is the camera's choice: 3008 px from the paired JPEGs of that camera, 1616 px
from the JPEG inside its raw files.

**Steps 1 and 3 in one go:** once you have imported one folder as in step 1, **Import a folder without the
dialog...** starts the same import for the next folder without the dialog, with the settings of that previous import,
and with «Send new photos to the server automatically» the automatic send does step 3 in the background while
Lightroom imports. It refuses to start unless the previous import was «Add». The command ran in Lightroom with
plug-ins 0.6.0 and 0.7.0. See the command's description below.

Two settings matter:

- Leave **Preferences > General > «Replace embedded previews with standard previews during idle time»** off, or
  Lightroom reads and renders every original in the background after all.
- «Build Standard-Sized Previews» always works from the originals while they are reachable, also for photos that
  have a smart preview. Do not start it for a whole import unless you want exactly that.

Lightroom's **Preferences > Performance > «Use Smart Previews instead of Originals for image editing»** is meant to
keep the Develop module on the smart previews. Its effect in this workflow has not been measured yet.

### Which command when

| Command | Use it when | Lightroom must stay open |
|---|---|---|
| **Build smart previews on the server** | You want smart previews for the selected photos: it sends them and returns at once; the automatic fetch brings the smart previews in while Lightroom runs | No (only for the automatic fetch) |
| **Fetch ready smart previews** | You want what the server has finished now, or for photos sent from anywhere else | Only while it fetches |
| **Import a folder without the dialog...** | A folder on the NAS is not in the catalog yet: Lightroom imports it as your previous import did (which must have been «Add»), without the dialog; the automatic send (one checkbox) sends the new photos while Lightroom imports | Yes, while Lightroom imports and the automatic send sends |

The first two leave out photos that already have a smart preview and never replace a file, so running one of them
again, or another one after it, is harmless. In its one run, Lightroom's import started by **Import a folder without
the dialog...** left the photos that were in the catalog already alone. The first time, try **Build smart previews on
the server** on a few raw photos of a test catalog.

**Build smart previews on the server** works on Lightroom's target photos: the selected photos, or, when nothing is
selected, every photo in the filmstrip. It asks for no confirmation.

**Build smart previews on the server.** The plug-in asks the server whether it can build (it stops with a message when
the converter is not installed, no mapping is set up, or no mapped root is available), leaves out the photos it cannot
send, reads the file ids from the catalog, creates the job (one job per 5000 photos) and returns at once. When every
photo was taken, it shows only a short notice that fades by itself:

```
5 photos sent to the server; their smart previews arrive by themselves
```

(«fetch their smart previews with «Fetch ready smart previews» when they are ready» when the automatic fetch is off).
When photos were left out or refused by the server, or a part could not be sent, a dialog says so:

```
4 photos were sent to the server (job 7). The server builds the smart previews in the background; Lightroom does not
have to stay open.

The automatic fetch brings their smart previews in by itself when they are ready (it is set in File > Plug-in Manager
> LR Remote Previews); Library > Plug-in Extras > Fetch ready smart previews does it at once.

Not sent (1):
    videos: 1
```

Nothing is downloaded by the command. The automatic fetch brings the smart previews in when they are ready (see
«Automatic fetch» below); close Lightroom if you like, they come in the next time it runs.

**Fetch ready smart previews.** A dialog asks which photos:

- **Selected photos**: the plug-in asks the server about exactly these files, whoever asked for them (this catalog,
  another catalog, a test job), and fetches what is ready. Nothing is built by asking.
- **Everything this catalog sent**: the plug-in goes through the jobs this catalog sent with version 0.3.0 or newer
  and fetches what is ready. This is the only choice when nothing is selected.

A fetch can be cancelled and continues where it stopped the next time: photos that got their smart preview are left
out, and nothing is overwritten. Only one fetch runs at a time; a second one says
`Smart previews are already being fetched by …`.

**Import a folder without the dialog...** It works on one folder, not on selected photos, and it uses Lightroom's own
import. It ran in Lightroom with plug-ins 0.6.0 and 0.7.0 (0.7.0's run: the start of the import took 0.17 s, and the
1384 photos were sent and fetched by the automatic send and fetch):

1. Choose the folder. The plug-in then reads, with `sqlite3` and read-only, how the previous import in this catalog
   was set up. It goes on only if that was **Add** (the files stay where they are; only references are added) without
   «Make a Second Copy To». Otherwise it says so and starts nothing: import one folder through Lightroom's dialog with
   «Add» first. Without `sqlite3`, or when the catalog holds no such record, it starts nothing either.
2. A dialog shows what Lightroom will do: «Add», the previews it will build (`Embedded & Sidecar`, or that Lightroom
   builds its own for another setting), whether it builds smart previews itself (with a warning: switch that off in
   the dialog if the server is to build them), and a develop or metadata preset if the previous import applied one.
   One checkbox, **Send new photos to the server automatically**, shows and sets the plug-in's automatic send (the
   same setting as in the Plug-in Manager). The line under it says what it does, or why it cannot send (no server set
   up, the folder under none of your path mappings); switched off, send the photos later with **Build smart previews
   on the server**.
3. Right before it starts, the plug-in reads the record again and stops if anything changed. Then it asks Lightroom
   to import the folder (`catalog:triggerImportFromPathWithPreviousSettings`), shows a short notice
   (`Lightroom is importing <folder>; the automatic send sends the new photos`) and is done. Lightroom imports by
   itself, with its own progress bars, as after its own dialog; the plug-in never lists the folder and never touches a
   file. There is no summary afterwards.
4. With the checkbox on, the automatic send reads the catalog every 3 seconds from the trigger on (while Lightroom
   imports it gets to run only between Lightroom's bursts, about every 20-26 s), until no new photo has come for 2
   minutes, and sends each burst as soon as it finds it, all photos of the import into one job: the
   plug-in notes the catalog's largest photo id before the import, so every photo of it counts as new. The automatic
   fetch places their smart previews as they are built and has Lightroom register them when the import is over (see
   «Automatic fetch» below).

What the one run showed (plug-in 0.6.0, Lightroom Classic 15.6, a network folder of 1384 raw files with 1384 paired
JPEGs, 9 of the photos in the catalog already): Lightroom started the import within 0.16 s, scanned the folder for
about 2 min 20 s, then added the photos in bursts of about a hundred every 22–26 s (1375 photos in 288 s), recorded the
JPEGs as sidecars and left the 9 photos alone. Lightroom lists the photos in the Library's **Folders** panel. To take
them out again, select them, choose **Photo > Remove Photos** and then «Remove from Lightroom» (never «Delete from
Disk»); the files on disk are not touched. Not seen yet: whether Lightroom takes the sub-folders.

### What is left out, and why

The dialog after a send (shown only when something was left out or refused) and the fetch summary list the photos
that were not sent (or, when fetching, «Left out»), with the count per reason; the plug-in's log names each photo:

| Line | Why |
|---|---|
| `videos` | Videos are not converted |
| `no file path in the catalog` | Lightroom gave no path for the photo |
| `already have a smart preview` | Lightroom already has one, also one it built itself. It is never replaced |
| `a file type the server does not take` | Not a camera raw file: JPEG, HEIC, TIFF and so on. The accepted extensions are on the dashboard under «Raw formats». Lightroom builds these itself |
| `not under any local prefix of the path mappings` | The photo's path starts with none of your local prefixes. The log names the path |
| `their server root is missing or not available` | The mapping names a root the server does not have, or whose folder is missing in the container |
| `same file as another selected photo (virtual copies)` | A virtual copy and its master share one file and so one smart preview; the master is sent |
| `Lightroom gave no catalog id`, `not found in the catalog database`, `the catalog database names a different file` | The file id could not be read reliably with `sqlite3`; the photo is left out rather than risk a wrong file |
| `built on the server, but not in this catalog (removed, or the path mappings changed)` | Fetching «everything this catalog sent»: the server built the file, but no photo of this catalog has that path any more |
| `built on the server, but the path cannot be mapped to this computer` | Fetching «everything this catalog sent»: no mapping leads to that root |

### The summary

**Fetch ready smart previews** ends with a summary. A good run for five selected photos looks like this:

```
5 photo(s) selected, 5 looked up on the server.

    Smart previews placed and registered by Lightroom: 5
```

The automatic fetch writes the same counts as one line to the log and shows at most a short notice, for example
`5 smart previews arrived from the server`.

The lines that can appear:

| Line | Meaning |
|---|---|
| `Smart previews placed and registered by Lightroom` | Done: the file is in place and Lightroom answered «existed» |
| `Placed, but Lightroom did not answer "existed"` | The file is in place, but Lightroom answered something else; the log says what. Check it as in section 7 |
| `A smart preview file was already there (left alone)` | A file with that name was in the smart preview folder already; nothing was written |
| `Discarded: the file did not pass the check` | The downloaded DNG did not match the photo (length, original file name or original size). It was never written. See [troubleshooting.md](troubleshooting.md) |
| `Download failed` | The download did not complete. Fetch again |
| `Gone from the server's cache since it was looked up (fetch again)` | The server no longer had the file when it was downloaded |
| `Could not be written into the smart preview folder` | Writing next to the catalog failed; the log says why |
| `The server could not build them` | Items that failed on the server, with the server's codes, for example `(converter_failed: 2)` |
| `The server refused them` | Items the server did not accept, with codes such as `(not_found: 3)` |
| `Still being built on the server` | Not ready yet. Fetch later |
| `Not on the server (never sent, or the original changed since; send them again)` | The server has no DNG for the file as it is now |
| `Cancelled on the server` | The job was cancelled before these were built |
| `Not finished: the run stopped first` | You cancelled, or the run stopped; fetch later |

The server's codes are explained in [troubleshooting.md](troubleshooting.md). Every photo also gets one line in the
plug-in's log, `LRRemotePreviews.log` in Lightroom's log folder; with Lightroom Classic 15.6 on Windows that is
`%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs`.

### Server status

**Server status...** (under **Help > Plug-in Extras**) shows what the server says about itself, the state of the root
of each of your mappings, this
catalog's jobs that still matter (for example
`Job 7 "Lightroom selection", sent 3 h ago: ready 190, building 8, queued 300, failed 2`), and how many smart
previews are ready and not fetched by this catalog yet. It has three actions:

- **Fetch now**: fetches everything this catalog sent.
- **Retry** (only when a job has failed items): pick the job and press **Retry**; the server builds its failed items
  again, each from the file as it is now, and the automatic fetch waits for that job again.
- **Open the dashboard**: opens the server's address in your browser.

The server deletes a job 30 days after it finished (`LRRP_JOB_RETENTION_DAYS`); its DNGs stay in the cache, and
**Fetch ready smart previews** for the selected photos still finds them.

### Automatic fetch

**Automatic fetch** in the Plug-in Manager is on by default (plug-in 0.7.0 also switches it on once in settings of
older versions). While Lightroom runs, the plug-in fetches what this catalog is waiting for. It is quiet: no dialogs and
no progress bar, lines in the log, and a short notice that fades by itself when the smart previews of a job are in
(`600 smart previews arrived from the server`). It never places at the same time as a manual fetch, never replaces a smart preview, and
checks every DNG as a manual fetch does.

With server 0.6.0 or newer, the plug-in keeps one request per job open that the server answers as soon as a smart
preview is ready (at most 25 seconds, then the next one). An older server is asked at the chosen interval instead.
**While an import is in progress, nothing is downloaded** (Lightroom reads the originals over the same link): the
plug-in only sends, and the server builds meanwhile. The import counts as over when no new photo has come for two
minutes and Lightroom's own previews of the new photos («Fetching Initial Previews») have stopped coming too (at most 15
minutes later); then everything ready is fetched in one go, «Downloads at once» files at a time; what becomes ready later, and the jobs of
**Build smart previews on the server** while no import runs, are fetched as they become ready. The files are placed
without asking Lightroom anything; then Lightroom is asked to register them, with one call for all the photos of the
go (one progress bar in Lightroom). Lightroom does not take a placed file by itself, so until then **Server status...**
counts it as placed and not registered. The log has a line per photo with the times: `sent (... first seen in the
catalog -> sent 2.1 s)`, `placed (... ready -> placed 0.8 s; not registered yet)`, `registered (... ready ->
registered 152 s)`, the totals per job, and lines for the import judged over, the fetch in one go (files, MB, seconds)
and the registration call (seconds, answer).

While there are more than a few smart previews to bring in, a progress bar **LRRP: smart previews** in Lightroom's
activity area says how many are fetched and how many are still being built, or, while the plug-in waits for an import
or for Lightroom's previews of it, what it waits for and the latest time it waits. Cancelling it pauses the automatic fetch until **Fetch ready smart previews** or the next start of
Lightroom.

An interrupted fetch finishes by itself; **nothing needs to be done** after one. When Lightroom quits in the middle,
the next start goes on with what is missing, without downloading again what is already placed, and registers what
was placed. When the NAS sleeps or the network is gone, the downloads wait (as below) and go on when the server
answers. A failed download, or a file that fails the check, is tried three times in all and then logged; a temporary
file left by an interrupted download is deleted and never taken for a finished smart preview.

It asks the server only while this catalog waits for something, so that an idle Lightroom never wakes a sleeping NAS
or keeps it awake:

- A job is **pending** from the moment this catalog sends it (**Build smart previews on the server**, the automatic
  send, or **Retry** in **Server status...**). The plug-in keeps the list per catalog in its preferences, so it
  survives a restart of Lightroom.
- A job stops being pending when the fetch finds it done (the server no longer works on it and every built smart preview
  was placed or dealt with), when the server no longer knows it, or **7 days** after it was sent, whatever its state.
  Its files can still be fetched with **Fetch ready smart previews** or **Fetch now**.
- With **nothing pending, it makes no request at all**, not even a status check; the log says once
  `automatic fetch: nothing pending for this catalog; the server is not asked`.
- When the server does not answer (or answers with an error), the next try waits **1, 2, 5, 10, 30 minutes, then
  every hour**; the log says `next try at 14:05`. No dialog: the next answer resets it.
- Jobs this catalog sent with a plug-in older than 0.7.0 are not pending; fetch them with **Fetch ready smart
  previews**.

The automatic send (off by default) reads the catalog itself, every 3 seconds while an import comes in and at the
chosen interval otherwise, and asks the server only when it has photos to send; the photos of one Lightroom import go
into one job, `Lightroom import 2026-11-14 15:15, <folder>`. Plug-in 0.8.1's changes to the automatic send and 0.8.2's
to the automatic fetch have passed tests outside Lightroom only.

## 7. Check the result, and undo it

How to see that it worked:

- **The summary** says `Smart previews placed and registered by Lightroom`.
- **The plug-in's log** has a line per photo with the file it wrote, for example
  `IMG_0001.ARW: delivered (DNG 1.7.0.0, C:\Photos\Main\Main Smart Previews.lrdata\6\6282\62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng)`.
- **Lightroom itself** shows a photo's smart preview status in the Library module's Histogram panel, for example
  «Original + Smart Preview».
- **The plug-in's diagnostics report**: **Help > Plug-in Extras > Diagnostics: smart preview report (all photos)**
  writes `smart-preview-report-<time>.txt` next to the catalog. It is a tab-separated table with, for every photo,
  the file name, the plug-in interface's image id, and the size and path of the smart preview as Lightroom reports
  them. An empty path means Lightroom sees no smart preview for that photo. It changes nothing.
- **To compare the content** with what Lightroom builds itself, follow «Checking a server-built smart preview against
  Lightroom» in [tools/README.md](../tools/README.md).

In the verified test (Lightroom Classic 15.6, plug-in 0.2.0, 157 photos), every placed file was answered with
«existed» and afterwards counted by the catalog as a smart preview. A file placed while Lightroom runs is taken up
without a restart, and at the latest when the catalog is opened again.

**To undo it**, use Lightroom's own command: select the photos and choose **Library > Previews > Discard Smart
Previews**. The project never deletes smart previews itself. Discarding smart previews that this project placed has
not been tested; Lightroom treats them as its own in every test so far. Apart from those files, the catalog changes
only when you run **Import a folder without the dialog...**, and then by Lightroom's own import: take its photos out
with Lightroom's own command, as after any import (select them, **Photo > Remove Photos**, then «Remove from
Lightroom»; nothing on disk is touched). There is nothing else to undo. To remove the plug-in, select it in the
Plug-in Manager and
press **Remove**. To remove the server, run `docker compose down` in `deploy/`; `docker compose down -v` also deletes
the named volumes with the database, the cache and the converter.

## 8. Updating

**The server.** In the repository on the NAS:

```sh
git pull
cd deploy
docker compose up -d --build
```

The database is brought up to date in place at start; nothing is dropped. An older server refuses a database that a
newer one has brought up to date, so going back to an older version after an update may not be possible with the
same `/data`. The converter stays in the data volume. The dashboard's Server card and `GET /api/v1/info` show the version.

**The plug-in.** Quit Lightroom, replace the contents of the `LRRemotePreviews.lrplugin` folder with the new version
(keep `sqlite3.exe` if you put it there), start Lightroom, and press **Test connection**. Your settings are kept:
Lightroom stores them under the plug-in's identifier, not in its folder (the settings of 0.1.0 appeared in 0.2.0, in
Lightroom Classic 15.6). Update the plug-in and the server together. The plug-in checks the server's protocol version
(API 1); there is no check of the server's version yet, and fetching the selected photos needs server 0.3.0 or newer.

**The converter, for new cameras.** New camera models need a newer converter and newer camera profiles. Follow
«Updating for new cameras» in [converter.md](converter.md). Keep a copy of the two old folders, so that you can go
back: only 17.2 is verified, and Adobe documents the `TempDisableGPU2` marker only for Camera Raw 17.4 and earlier.
DNGs already in the cache are not built again after a converter update: the cache key contains the converter's
options, not its version.

**After an update of Lightroom.** Everything this project does rests on behaviour Adobe does not document: where
Lightroom keeps smart previews and how it names them, that it takes a file placed there, and the layout of the
catalog tables the plug-in reads with `sqlite3`. Any Lightroom release may change that. The automatic check that
will guard against it is planned (stage 5) and does not exist yet. After every Lightroom update, before you fetch into
a catalog you care about:

1. On a test catalog, run **Build smart previews on the server** on a few raw photos, then, once they are built,
   **Fetch ready smart previews** for them. Its summary must say `Smart previews placed and registered by Lightroom`
   for all of them.
2. Run the diagnostics report and check that those photos now have a smart preview path.
3. Optionally, compare one server-built DNG with a smart preview Lightroom built itself ([tools/README.md](../tools/README.md)).

If any step fails, stop using the plug-in on that Lightroom version and report it. Because the plug-in never writes to
the catalog itself, the expected worst case is that smart previews are not picked up, not a damaged catalog.

## 9. Limits and what is not verified

Limits of this version:

- Camera raw files only. The server accepts the extensions listed on the dashboard; among them is `.dng`, but only
  Sony ARW files from two camera models have been converted so far.
- No standard previews (what to use instead: «Originals on a NAS» in section 6).
- An existing smart preview is never replaced, even if it is out of date. Removing smart previews is Lightroom's job.
- One job holds at most 5000 photos. **Build smart previews on the server** splits more into several jobs.
- The automatic fetch stops waiting for a job 7 days after it was sent.
- At most three path mappings.
- «Everything this catalog sent» looks at the newest 200 jobs of the catalog. A catalog that is moved or renamed gets
  a new identity and no longer finds its old jobs; fetch by selection instead.
- The plug-in checks the length, the original file name and the original pixel size of each DNG, not its SHA-256.
- Jobs are deleted 30 days after they finished (configurable). The cache is cleaned once a day of DNGs whose
  original is gone or changed; limits on its size and on the age of unused DNGs are off until you set them on the
  dashboard.
- The server speaks plain HTTP, and the token is sent with every request. Keep the port inside your home network. A
  reverse proxy with HTTPS in front of it should work, since the plug-in accepts an `https://` address with a path,
  but this has not been tried.
- The server's own time zone decides when the working hours begin; a container without a time zone runs on UTC.

Not verified:

- **Server status...** and **Check the server against Lightroom** in Lightroom, the short notices, the back-off of
  the automatic fetch and the `LRRP: ` prefix. (The automatic send, the automatic fetch with its pending jobs, the
  Help menu and the settings upgrade ran with plug-in 0.7.0; sending and **Fetch ready smart previews** for the
  selection with 0.3.0.) They passed tests outside Lightroom only.
- Plug-in 0.8.1 in Lightroom: every photo of an import sent once, into one job, with the rows coming out of order;
  how long LrHttp really lets a waiting request wait.
- Plug-in 0.8.2 in Lightroom: no download during an import, the fetch in one go after it, the registration with one
  `catalog:buildSmartPreviews` call (never called in Lightroom yet: its time, its progress bar, its answer when
  cancelled), and an interrupted fetch finishing at the next start.
- **Import a folder without the dialog...**: whether Lightroom takes sub-folders has not been seen. (0.5.0's «Add a
  folder without previews...» ran once: about 37 s per photo on a NAS folder, with Lightroom's window frozen; it was
  dropped.)
- Lightroom Classic versions other than 15.6, and the plug-in on macOS.
- Adobe DNG Converter versions other than 17.2, Adobe's installer under Wine, and Wine versions other than 8.0.
- Raw formats other than Sony ARW.
- Build speed on other processors than the 14-core desktop CPU of the reference setup.
- What happens when the NAS sleeps in the middle of a job (a restart of the server in the middle of a job loses
  nothing; that was tested).
- Discarding smart previews placed by this project with Lightroom's own command.
- `sqlite3.exe` next to the plug-in or set by path in the settings, and catalogs whose path contains non-ASCII
  characters.
