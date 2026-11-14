# Installing on TrueNAS SCALE

The server runs on TrueNAS SCALE as a custom app installed from a YAML file
([deploy/truenas/app.yaml](../deploy/truenas/app.yaml)). This page is the path from an empty system to a dashboard
that shows «converter installed». Everything after that, from the plug-in's settings to the first delivered smart
preview, is in the [guide](guide.md).

*Tried on:* TrueNAS SCALE 25.10 with Docker 28. The image was built on the NAS and the server ran there as a plain
container with the same settings this file gives the app; **the YAML itself has not been installed through the
TrueNAS interface yet.** The `x-portals` block is the form a custom app on that system uses.

## 1. Folders

Create a dataset for the app (any name; `lr-remote-previews` below) with three folders in it:

| Folder | What it holds | Size |
|---|---|---|
| `data` | The queue database and the Wine prefix with the converter | about 1.5 GB with the converter and its camera profiles |
| `cache` | The built DNGs | about 0.5 MB per photo |
| `config` | `roots.yaml` | tiny |

`data` must be on a local file system (the database needs working file locks). An SSD pool suits `cache`.

## 2. The user

Decide which user the server runs as. Two things matter:

- **It must be able to read the originals.** Look at the owner and the permissions of a few original files
  (`ls -ln /mnt/POOL/DATASET/…`) and pick a uid (and, if needed, a group) that can read them. With the wrong user
  every file is reported as `not_found`.
- **It must own `data` and `cache`.** `chown -R UID:GID` those two folders.

Keep the user the same afterwards: Wine refuses a prefix that belongs to somebody else.

The originals are mounted read-only, so the choice of user cannot put them at risk.

## 3. The roots

A root is a folder with originals as the server sees it. Put a file `roots.yaml` into `config`:

```yaml
roots:
  - id: archive
    path: /sources/archive
    label: Archive
```

`id` is the short name the Lightroom plug-in refers to; `path` is where the YAML below mounts the originals inside
the container. One root is usually enough: map the same share that Lightroom sees.

If the originals span several datasets, remember that each dataset is its own mount: add one volume entry and one
root per dataset, or mount the parent (child datasets that are mounted when the app starts are included).

## 4. The image

Until images are published, build the image on the NAS from a checkout of the repository:

```
sudo docker build -f deploy/Dockerfile -t lr-remote-previews:local .
```

## 5. The app

Copy [deploy/truenas/app.yaml](../deploy/truenas/app.yaml), replace every placeholder written in capitals (the
user, the token, the time zone, the four folder paths), then: **Apps → Discover Apps → ⋮ → Install via YAML**, give
it a name, paste the YAML, save.

When the app is running, its **Web UI** button opens the dashboard. Enter the token there. The first start takes
about a minute longer, because the Wine prefix is created.

## 6. The converter

The dashboard now says that the converter is not installed. Place it as [converter.md](converter.md) describes,
into the `data` folder's Wine prefix, owned by the app's user. No restart is needed; the dashboard shows the change
after a reload.

## 7. Check

- The dashboard shows the converter as installed and every root as available.
- From any computer, a small job proves the whole chain without Lightroom:

  ```
  python tools/submit_job.py --server http://NAS:8787 --token TOKEN --root archive "PATH/UNDER/THE/ROOT/FILE.ARW" --download out
  ```

  The first job on a new installation takes a few seconds longer (the converter is warmed up once).

## Things specific to TrueNAS

- **The Web UI button** comes from the `x-portals` block, which TrueNAS reads only when the app is created. To
  change the port, delete the app (the folders stay, nothing is lost) and install the YAML again.
- **A NAS that sleeps when idle** has to know that the server is working. `GET /healthz` answers without a token
  and includes `"busy": true` while the queue is being built.
- **Updating:** build (later: pull) the new image and restart the app. The database is migrated in place. The
  converter stays in the `data` folder.
