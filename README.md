# selfsteal-jitsi

Jitsi Meet behind an existing Remnawave/Xray Reality + `nginx-selfsteal` installation.

> This project currently targets the nginx-selfsteal layout used by the script: `/opt/nginx-selfsteal`, `/opt/nginx-selfsteal/conf.d/selfsteal.conf`, and container `nginx-selfsteal`.

## Direct run from GitHub

```bash
sudo bash <(curl -Ls https://github.com/khalif-abd/selfsteal-jitsi/raw/main/selfsteal-jitsi.sh) \
  install \
  --domain meet.example.com \
  --ip 203.0.213.10 \
  --clean
```

With internal authentication:

```bash
sudo bash <(curl -Ls https://github.com/khalif-abd/selfsteal-jitsi/raw/main/selfsteal-jitsi.sh) \
  install --domain meet.example.com --ip 203.0.213.10 --auth --clean
```

Without authentication:

```bash
sudo bash <(curl -Ls https://github.com/khalif-abd/selfsteal-jitsi/raw/main/selfsteal-jitsi.sh) \
  install --domain meet.example.com --ip 203.0.213.10 --no-auth --clean
```

Optional ports:

```bash
sudo bash <(curl -Ls https://github.com/khalif-abd/selfsteal-jitsi/raw/main/selfsteal-jitsi.sh) \
  install --domain meet.example.com --ip 203.0.213.10 \
  --http-port 8000 --jvb-port 10000 --clean
```

If `--domain` or `--ip` is omitted, the script attempts to detect it.

## Install as a system command

```bash
sudo bash <(curl -Ls https://github.com/khalif-abd/selfsteal-jitsi/raw/main/selfsteal-jitsi.sh) setup
```

Then:

```bash
sudo selfsteal-jitsi install --domain meet.example.com --ip 203.0.213.10 --clean
sudo selfsteal-jitsi status
sudo selfsteal-jitsi repair
sudo selfsteal-jitsi logs
sudo selfsteal-jitsi logs jvb
sudo selfsteal-jitsi update
sudo selfsteal-jitsi update-script
sudo selfsteal-jitsi version
sudo selfsteal-jitsi uninstall
```

The installed executable is `/usr/local/bin/selfsteal-jitsi`.

## What it changes

- Keeps public TCP/443 owned by Xray Reality.
- Runs Jitsi web only on `127.0.0.1:8000` by default.
- Forces Jitsi to IPv4-only mode (`ENABLE_IPV6=0`), so it also works on hosts with IPv6 disabled.
- Creates Prosody persistent storage with uid/gid `1000:1000` to prevent `/var/lib/prosody` startup failures.
- Publishes Jitsi Videobridge UDP/10000 by default.
- Rewrites the nginx selfsteal virtual host to proxy the fallback to local Jitsi.
- Backs up the existing `selfsteal.conf` before rewriting it.
- Stores state in `/etc/selfsteal-jitsi/state.env`.
- Stores the Jitsi checkout in `/opt/jitsi` and generated config in `/root/.jitsi-meet-cfg`.

## Requirements

- root
- Docker
- Docker Compose v2.24.4+
- curl
- git
- an existing nginx-selfsteal installation

## Important

`uninstall` removes the Jitsi stack/config but intentionally does not remove Remnawave, Xray or nginx-selfsteal. It also does not automatically restore the old nginx config; use the timestamped `.bak` created during installation if restoration is required.

`update` updates Jitsi images. `update-script` replaces `/usr/local/bin/selfsteal-jitsi` with the current script from this repository.

### IPv4-only mode

`selfsteal-jitsi` intentionally operates in IPv4-only mode. It sets `ENABLE_IPV6=0` for Jitsi and the generated nginx-selfsteal HTTP server listens only on IPv4 (`listen 80;`). This allows installation on hosts where IPv6 is disabled at kernel/sysctl level.
