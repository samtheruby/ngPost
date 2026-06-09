# ngpost-hotio

A headless, VPN-protected [ngPost](https://github.com/mbruel/ngPost) container for
automated Usenet posting. Drop a file/folder into a watched directory and ngPost
packs it into a multi-volume, password-protected RAR set with PAR2 recovery,
posts it (with article/filename obfuscation), and writes an NZB whose filename
carries the password so SABnzbd/NZBGet can auto-extract.

Built on [`hotio/base:noblevpn`](https://hotio.dev/containers/base/), so it ships
with s6-overlay init, `PUID`/`PGID` handling, and an integrated WireGuard VPN —
ngPost only ever uploads through the tunnel.

## Why this image builds ngPost from source

The stock ngPost releases don't include **article/filename obfuscation** — the
change proposed upstream as PR #201, which randomises the filename in each
article's yEnc header instead of leaking the real name. So we compile from the
[`samtheruby/ngPost`](https://github.com/samtheruby/ngPost/tree/obfuscation-fix)
fork at a pinned commit. The fork carries the obfuscation code *and* a clean
headless `src/ngPost_cmd.pro`, so **the build applies no patches at all.**

The build also runs `lrelease` to generate the `lang/*.qm` files that
`resources.qrc` references (they aren't committed), and the runtime config sets
`RAR_PATH`/`PAR2_PATH` because a source build — unlike the AppImage — bundles
neither.

We use the **noblevpn (Ubuntu/glibc)** base rather than alpinevpn because
ngPost's `--compress` creates RAR volumes with the proprietary `rar` binary,
which is distributed only as a glibc executable.

## Quick start

See [QUICKSTART.md](QUICKSTART.md) for the short version. In brief:

```bash
docker compose build
# create ./appdata/config, then drop your WireGuard config at
#   ./appdata/config/wireguard/wg0.conf
docker compose up -d
# first boot writes ./appdata/config/ngPost.conf -- edit your server creds:
nano ./appdata/config/ngPost.conf
docker compose restart
```

## Configuration

Two layers:

- **`/config/ngPost.conf`** — server credentials, paths, and the
  compression/par2/obfuscation settings (the `PACK` line, `RAR_SIZE`,
  `PAR2_PCT`, `LENGTH_NAME`, `LENGTH_PASS`, …). Bootstrapped from
  `config/ngPost.conf.example` on first boot and never overwritten. **Secrets
  live here, not in the compose file.**
- **Environment variables** — runtime behaviour:

| Variable | Default | Meaning |
|---|---|---|
| `NGPOST_MODE` | `poll` | `manual` \| `poll` \| `monitor` |
| `NGPOST_INTERVAL` | `300` | poll mode: seconds between scans |
| `NGPOST_INPUT_DIR` | `/watch` | the drop folder |
| `NGPOST_PACK` | `true` | pass `--pack` (apply the conf's `PACK` keywords) |
| `NGPOST_RM_POSTED` | `true` | pass `--rm_posted` (delete sources after a verified post) |
| `NGPOST_ARGS` | _(empty)_ | extra ngPost flags, e.g. `--disp_progress files` |

### Modes

- **`poll` (default, recommended on Unraid).** Every `NGPOST_INTERVAL` seconds
  the service runs `ngPost --pack --rm_posted --auto /watch`. It's a plain
  directory scan, so it works on **any** filesystem including Unraid's
  `/mnt/user` FUSE share. ngPost has no resume database, so `NGPOST_RM_POSTED=true`
  is what stops it re-uploading the same files every cycle — treat `/watch` as a
  drain/spool folder.
- **`monitor`.** Uses ngPost's native `--monitor` (`QFileSystemWatcher`/inotify)
  for lower latency. **inotify does not fire reliably on Unraid `/mnt/user`
  FUSE shares** — use `poll` there.
- **`manual`.** Idle. Trigger uploads yourself:
  ```bash
  docker exec -u hotio ngpost ngpost-run               # post everything in /watch
  docker exec -u hotio ngpost ngpost-run -i /watch/Movie.mkv
  ```

## How the password reaches the download client

`config/ngPost.conf.example` sets:

```ini
NZB_POST_CMD = mv "__nzbPath__" "/output/__nzbName__{{__rarPass__}}.nzb"
```

After each post ngPost renames the NZB to `<RealReleaseName>{{<password>}}.nzb`.
SABnzbd and NZBGet both read a RAR password from the `{{...}}` in the NZB
filename, so they unrar automatically. The real release name (not the hashed
RAR name) is what shows in the client's queue. Every generated password is also
recorded in `POST_HISTORY` (`/config/ngPost_history.csv`).

> Disabling `GEN_PASS` (in `PACK`)? Remove the `NZB_POST_CMD` line, or you'll get
> `Name{{}}.nzb`.

## VPN

Set `VPN_ENABLED=true` and place your WireGuard config at
`/config/wireguard/wg0.conf`. The container needs `--cap-add=NET_ADMIN`,
`/dev/net/tun`, and the `net.ipv4.conf.all.src_valid_mark=1` sysctl (all set in
`docker-compose.yml`). With `VPN_HEALTHCHECK_ENABLED=true` the container dies if
the tunnel drops, so ngPost never posts on your real IP. Full VPN options:
<https://hotio.dev/containers/base/>.

## Large releases

RAR + par2 are staged in `TMP_DIR` (`/config/tmp` by default). A multi-GB remux
needs that much scratch space, so for big posts mount a large/fast disk to
`/config/tmp` (or change `TMP_DIR` and mount accordingly).

## Building a specific ngPost version

```bash
docker compose build --build-arg NGPOST_REF=<commit-sha-or-tag-or-branch>
# or build from a different repo entirely:
docker compose build --build-arg NGPOST_REPO=<git-url> --build-arg NGPOST_REF=<ref>
```

The build is pinned to `samtheruby/ngPost` @
`4547603daa71d35ea5990600fed3b167f92a63f0` (branch `obfuscation-fix`), which
already builds cleanly with no patches.

---

*Only post content you have the right to distribute.*
