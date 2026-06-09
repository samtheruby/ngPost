# Quick start

## 1. Build

```bash
cd ngpost-hotio
docker compose build
```

This compiles ngPost (CLI build) from a pinned commit of the
`samtheruby/ngPost` fork (which includes PR #201 article/filename obfuscation),
then assembles it on `hotio/base:noblevpn`. First build pulls Qt5 + a compiler,
so it takes a few minutes.

## 2. Add your WireGuard config

```bash
mkdir -p appdata/config/wireguard
cp /path/to/your/wg0.conf appdata/config/wireguard/wg0.conf
```

(Or set `VPN_ENABLED=false` in `docker-compose.yml` to run without a VPN.)

## 3. First run — writes the default config

```bash
docker compose up -d
docker compose logs -f          # watch it bootstrap, then Ctrl-C
```

## 4. Set your server credentials

Edit the config that was just created and fill in the `[server]` block
(`host`, `user`, `pass`) plus your group:

```bash
nano appdata/config/ngPost.conf
```

Tune to taste: `RAR_SIZE` (volume size), `PAR2_PCT` (recovery %),
`LENGTH_NAME` / `LENGTH_PASS`, and the `PACK` line.

## 5. Point the volumes at your folders

In `docker-compose.yml`:

```yaml
    volumes:
      - ./appdata/config:/config
      - /host/path/to/watch:/watch     # drop files here to upload them
      - /host/path/to/nzb:/output      # finished NZBs land here
```

## 6. Restart and use it

```bash
docker compose restart
```

Drop a file or folder into your `/watch` mount. In `poll` mode (default) it's
picked up within `NGPOST_INTERVAL` seconds, posted as a passworded multi-volume
RAR set + par2, and — because `NGPOST_RM_POSTED=true` — removed from `/watch`
afterwards. The NZB appears in `/output` as `RealName{{password}}.nzb`.

### On-demand (manual mode)

Set `NGPOST_MODE=manual`, then:

```bash
docker exec -u hotio ngpost ngpost-run                 # post everything in /watch
docker exec -u hotio ngpost ngpost-run -i /watch/Movie.mkv --help
```

> **`NGPOST_RM_POSTED=true` deletes source files after a successful post.** It's
> required for `poll` mode (no resume DB) — keep `/watch` a spool folder, not your
> only copy.
