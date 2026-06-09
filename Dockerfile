# syntax=docker/dockerfile:1

###############################################################################
# ngPost (command-line build) on top of hotio/base (Ubuntu/noble) with a
# built-in WireGuard VPN.
#
# Why noblevpn (glibc) and NOT alpinevpn (musl):
#   ngPost's --compress produces the multi-volume, password-protected RAR set
#   (Name.part01.rar ... + .par2) using the *proprietary* `rar` binary, which
#   is only distributed as a glibc executable. On Alpine/musl it needs gcompat
#   shims and is fragile. par2 and rar both come straight from apt on noble.
#
# hotio/base gives us, for free:
#   * s6-overlay v3 init (entrypoint /init) and PUID/PGID drop to user "hotio"
#   * a fully wired WireGuard VPN  ->  set VPN_ENABLED=true and drop in wg0.conf
#       (init-wireguard brings the tunnel up; service-ngpost depends on it, so
#        ngPost never uploads outside the tunnel = no IP leak)
#
# We build ngPost from source (samtheruby/ngPost fork, branch obfuscation-fix)
# because it carries article/filename obfuscation -- the change proposed upstream
# as PR #201 -- which the official binaries don't have. The fork contains the fix
# and a clean headless src/ngPost_cmd.pro, so the build applies NO patches.
###############################################################################

# ---------------------------------------------------------------------------
# Stage 1: build the headless ngPost binary on a plain Ubuntu 24.04 (noble).
# Same Qt 5.15 ABI as the hotio noblevpn base, so the binary runs there as-is.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS builder

# Build from the fork that already contains the obfuscation change. Pin the exact
# commit so builds are reproducible (a bare branch name would move under us).
# Override with --build-arg NGPOST_REPO=<url> / NGPOST_REF=<sha|tag|branch>.
ARG NGPOST_REPO=https://github.com/samtheruby/ngPost.git
ARG NGPOST_REF=4547603daa71d35ea5990600fed3b167f92a63f0

ENV DEBIAN_FRONTEND=noninteractive QT_SELECT=qt5

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates git build-essential \
        qtbase5-dev qt5-qmake qtbase5-dev-tools qttools5-dev-tools; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone "${NGPOST_REPO}" . && git checkout "${NGPOST_REF}"

WORKDIR /build/src
# resources/resources.qrc references lang/*.qm which are NOT committed (only the
# .ts sources are). Generate them, or the RCC step fails with "cannot find .qm".
RUN lrelease ngPost_cmd.pro || lrelease lang/*.ts

RUN qmake ngPost_cmd.pro CONFIG+=release && make -j"$(nproc)"
RUN strip --strip-unneeded ngPost && test -x ./ngPost

# ---------------------------------------------------------------------------
# Stage 2: final image on the hotio noblevpn base.
# ---------------------------------------------------------------------------
FROM ghcr.io/hotio/base:noblevpn

# Runtime deps:
#   libqt5network5/libqt5core5a - the only Qt libs the headless binary links
#   par2                        - PAR2 recovery (REQUIRED: source build has none bundled)
#   rar                         - multi-volume RAR creation (multiverse, non-free)
#   p7zip-full                  - 7z, an alternative compressor (RAR_PATH=/usr/bin/7z)
# `rar` lives in Ubuntu's "multiverse" component, which we enable first. The
# noble base uses the deb822 sources file; fall back to the legacy list.
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i 's/^Components:.*/Components: main restricted universe multiverse/' /etc/apt/sources.list.d/ubuntu.sources; \
    else \
        sed -i 's/^deb \(.*\) \(main.*\)$/deb \1 main restricted universe multiverse/' /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libqt5core5a libqt5network5 par2 p7zip-full rar; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/src/ngPost /usr/local/bin/ngPost

# --- overlay: s6 services, config bootstrap default, helper script ----------
# The default config lands in /app and is copied into the mounted /config on
# first boot by init-ngpost, so secrets are never baked into the image.
COPY root/ /
COPY config/ngPost.conf.example /app/ngPost.conf

RUN set -eux; \
    find /etc/s6-overlay/s6-rc.d -name run -exec chmod +x {} +; \
    chmod +x /usr/local/bin/ngpost-run /usr/local/bin/ngPost

ENV \
    NGPOST_CONF="/config/ngPost.conf" \
    # NGPOST_MODE: manual | poll | monitor  (see service-ngpost/run)
    NGPOST_MODE="poll" \
    # poll mode: seconds between scans of NGPOST_INPUT_DIR
    NGPOST_INTERVAL="300" \
    # folder ngPost watches/scans for files to upload
    NGPOST_INPUT_DIR="/watch" \
    # pass --pack so the conf's "PACK = COMPRESS, GEN_NAME, GEN_PASS, GEN_PAR2"
    # is applied (and satisfies ngPost's --auto/--monitor compress requirement).
    NGPOST_PACK="true" \
    # NGPOST_RM_POSTED=true adds --rm_posted: delete each file/folder after it
    # is successfully posted. HARD-REQUIRED for poll mode (no resume DB) --
    # the service refuses to start in that combo. Destructive: treat
    # NGPOST_INPUT_DIR as a drain/spool folder.
    NGPOST_RM_POSTED="true" \
    # extra ngPost flags appended to every run (e.g. --disp_progress files)
    NGPOST_ARGS=""

# Two-part healthcheck:
#   1. s6 is actually supervising service-ngpost (so a crashed service / bad
#      NGPOST_MODE is not silently reported as healthy)
#   2. ngPost binary still loads (catches a broken Qt link after a base update)
# The VPN kill switch is enforced separately by hotio's service-healthcheck.
HEALTHCHECK --interval=1m --timeout=15s --start-period=30s \
    CMD pgrep -f 's6-supervise service-ngpost' >/dev/null \
        && ngPost --help >/dev/null 2>&1 \
        || exit 1
