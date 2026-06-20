# asl-misc-scripts

Lightweight, copy-pasteable scripts for AllStarLink admins and operators. Setup, provisioning, and maintenance tasks that run anywhere with `curl | interpreter`—no clone required. Shell, Ruby, Perl, and more.

## License

All scripts and other code in this repository are free software distributed under the **GNU General Public License version 2 or later** (GPL-2.0-or-later). You may copy, redistribute, and modify them under the terms of the GPL. The full license text is in [LICENSE](LICENSE).

Copyright © 2026 Jory A. Pratt, W5GLE

## Scripts

Run directly from GitHub with curl. Copy the line for the script you need.

### asl-debian-setup.sh

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/asl-debian-setup.sh | sudo sh
```

Configures the AllStarLink repository on Debian 12/13, then optionally installs ASL3 or an appliance package (VM, PC, or Raspberry Pi).

### setup-asl3-gps.rb

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup-asl3-gps.rb | sudo ruby
```

Interactive setup for **APRS-IS position beacons** on an ASL3 node via Asterisk `app_gps`. Run from a TTY as root (`sudo ruby` or the curl one-liner above). The script walks through prompts, shows a full configuration summary (with PHG values decoded), and asks for confirmation before writing anything.

#### Station modes

| Mode | GPS hardware | gpsd installed? | Position source |
|------|--------------|-----------------|-----------------|
| **Fixed** | No | No | Fixed `lat` / `lon` / `elev` in `gps.conf` |
| **Mobile** | USB dongle | Yes (if not already) | Live GPS via gpsd; fallback lat/lon when unlocked |

Both modes support **radioless** nodes (hubs, links, GPS-only trackers): skip RF frequency and tone, set `freq = 0.0` / `tone = 0.0`, and use a plain map comment. Mobile + radioless still installs gpsd and the NMEA bridge so APRS tracks the dongle without pretending the node has RF.

#### What the script configures

**Always (fixed and mobile):**

- `/etc/asterisk/gps.conf` — callsign/SSID, APRS-IS passcode (computed; masked as `*****` on screen), server region, beacon interval, map icon, PHG power/height/gain/dir, comment, lat/lon/elev
- `/etc/asterisk/modules.conf` — enables `app_gps.so` if still set to `noload`
- Restarts Asterisk

**Mobile only:**

- Installs `gpsd`, `gpsd-clients`, and `socat` if missing
- `/etc/default/gpsd` — USB device (default `/dev/ttyACM0`)
- `gpsd-nmea-bridge.service` — replays NMEA to `/dev/rptgps` (because `app_gps` reads a serial stream, not gpsd directly)
- Shared GPS on `127.0.0.1:2947` for saytime, SkywarnPlus-NG, `cgps`, and similar clients
- Adds `asterisk` to group `dialout` if needed; Asterisk starts after the bridge on boot

**Not changed:** `rpt.conf` (APRSStt is separate; not required for standard beacons).

#### Prompts and clarity

- **Decimal precision** — tells you how many places to use: lat/lon (4), elevation in meters MSL (1, not HAAT), MHz (3), tone Hz (1)
- **PHG fields** — shows the full 0–9 digit tables; enter a digit or a real-world value (watts, feet HAAT, dBi, degrees); reports what APRS maps will actually display
- **Elevation vs HAAT** — `elev` is meters above sea level; antenna height above terrain is the separate PHG `height` digit
- **Re-run safety** — backs up existing `gps.conf` to `gps.conf.bak`; abort at the final confirmation leaves the system unchanged

#### Defaults by mode

| Setting | Fixed | Mobile |
|---------|-------|--------|
| SSID | `-1` | `-10` |
| Beacon interval | 1800 s | 180 s |
| Map icon | `-` (house) | `>` (car) |
| PHG power/height/gain | 3 / 5 / 3 | 2 / 1 / 1 |

#### After setup

```text
asterisk -rx 'gps show status'
```

Mobile: `cgps -s` and `ls -l /dev/rptgps`. Map: `https://aprs.fi/#!call=YOURCALL-SSID`

### setup_ssh_key.pl

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup_ssh_key.pl | perl
```

Generates an SSH key (Ed25519 or RSA) and optionally copies it to a remote system.

### setup_gitconfig.pl

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup_gitconfig.pl | perl
```

Interactive Git configuration (user name, email, editor, colors, etc.).

### setup_certbot.pl

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup_certbot.pl | sudo perl
```

Install and configure certbot on Debian (Let's Encrypt, auto-renewal, certificates).

### create_gpg_key.pl

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/create_gpg_key.pl | perl
```

Create a secure GPG key (RSA or Ed25519) with optional expiration.

### configure_ssh.pl

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/configure_ssh.pl | perl
```

Configure SSH client (host entries, keep-alive, jump hosts, agent forwarding).

### cleanup_old_logs.rb

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/cleanup_old_logs.rb | sudo ruby
```

Deletes **regular files** under `/var/log` whose modification time is older than three days (default). Directories, symlinks, and other non-file entries are left alone; `/var/log/journal` is excluded by default. Use `--dry-run` to preview, `--days N` to change retention, and `--exclude PATH` for additional skip paths. Exits non-zero if permission errors occur. Run with `sudo` when you need permission to remove protected logs. Intended for periodic maintenance (for example from cron), not for interactive confirmation.
