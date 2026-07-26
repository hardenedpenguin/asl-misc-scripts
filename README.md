# asl-misc-scripts

Lightweight, copy-pasteable scripts for AllStarLink admins and operators. Setup, provisioning, and maintenance tasks that run anywhere with `curl | interpreter`—no clone required. Shell, Ruby, Perl, and more.

## License

All scripts and other code in this repository are free software distributed under the **GNU General Public License version 2 or later** (GPL-2.0-or-later). You may copy, redistribute, and modify them under the terms of the GPL. The full license text is in [LICENSE](LICENSE).

Copyright © 2026 Jory A. Pratt, W5GLE

## Scripts

Run directly from GitHub with curl. Copy the line for the script you need.

| Script | Root | ASL3 | Experimental | Notes |
|--------|------|------|--------------|-------|
| `asl-debian-setup.sh` | yes | — | no | Debian 12/13 repo + optional install |
| `setup-asl3-gps.rb` | yes | yes | no | Interactive APRS setup |
| `gpsd-nmea-bridge` | — | yes | no | Installed to `/usr/local/sbin` by setup script |
| `check-asl3-gps.rb` | yes | yes | no | Read-only APRS/GPS diagnostic |
| `setup-asl3-tlb.rb` | yes | yes | **yes** | TheLinkBox / chan_tlb |
| `setup-44connect-forward.rb` | yes | yes | **yes** | 44Net firewalld forwards |
| `setup_ssh_key.pl` | no | — | no | Run as your user, not root |
| `setup_gitconfig.pl` | no | — | no | Run as your user |
| `configure_ssh.pl` | no | — | no | Run as your user |
| `create_gpg_key.pl` | no | — | no | Run as your user |
| `setup_certbot.pl` | yes | — | no | Let's Encrypt |
| `cleanup_old_logs.rb` | yes† | — | no | †sudo for protected logs |
| `fasterAsteriskSounds.sh` | yes | yes | no | Speed up stock prompts into custom sounds dir |
| `write_node_callsigns.sh` | yes | yes | no | Speak callsigns instead of node numbers |

**Do not** run the Perl user tools (`setup_gitconfig`, `configure_ssh`, `create_gpg_key`, `setup_ssh_key`) as bare `root` — use your normal account, or `sudo -u $USER` so files land in your home directory.

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
- `/usr/local/sbin/gpsd-nmea-bridge` — bridge helper (written by the setup script; also kept as a repo file for review)
- `gpsd-nmea-bridge.service` — replays NMEA to `/dev/rptgps` (because `app_gps` reads a serial stream, not gpsd directly)
- Asterisk waits for `/dev/rptgps` before starting, avoiding transient `Cannot open serial port` log spam on restart
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

### check-asl3-gps.rb

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/check-asl3-gps.rb | sudo ruby
```

Read-only diagnostic for APRS/GPS on an ASL3 node: `gps.conf`, `app_gps` module state, `gps show status`, and (when configured) gpsd, the NMEA bridge, and `/dev/rptgps`. Requires **root** (`sudo ruby`) to query the Asterisk CLI. Exits non-zero if critical issues are found. Safe to run anytime; does not change configuration.

### setup-asl3-tlb.rb

> **Experimental and untested.** New script; not yet validated on production ASL3 nodes. Review generated config and test on a non-critical system first.

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup-asl3-tlb.rb | sudo ruby
```

Interactive setup for **TheLinkBox (chan_tlb)** on an ASL3 node. TLB bridges AllStar to EchoLink, IRLP, conferences, and other RTP peers. ASL3 includes `chan_tlb` but ships with it disabled in `modules.conf`.

**What the script does:**

- Enables `load => chan_tlb.so` in `/etc/asterisk/modules.conf`
- Writes `/etc/asterisk/tlb.conf` (`[tlb0]` + remote `[nodes]` peers)
- Backs up prior config under `/var/asl-backups/tlb-setup/`
- Opens UDP ports in **firewalld** default zone when active (on ASL3 this is usually `allstarlink`; permanent rules, idempotent re-runs)
- Optionally installs a periodic disconnect/reconnect cron (stability workaround reported on [community.allstarlink.org](https://community.allstarlink.org/t/tlb-conf-configuration/23504))
- Restarts Asterisk

**Non-interactive example:**

```sh
ASL_NODE=63001 ASL_CALL=W5GLE-R \
TLB_PEERS='1001=REF9550,44.190.8.10,44966,ULAW' \
TLB_KEEPALIVE=1 TLB_KEEPALIVE_PRIV=1001 \
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup-asl3-tlb.rb | sudo ruby
```

**Remote TLB server:** allow this node in `tlb.acl` and set `RTP_Port` to match. Do **not** change `rxchannel` to `tlb/tlb0` on a normal SimpleUSB node unless you intend a TLB-dedicated setup ([tlb.conf manual](https://allstarlink.github.io/config/tlb_conf/)).

**Connect test:**

```text
asterisk -rx 'rpt connect YOURNODE 1001'
```

### setup-44connect-forward.rb

> **Experimental and untested.** New script; firewalld forwarding has not been validated end-to-end on a 44Net Connect node yet. Review rules before applying on production hardware.

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup-44connect-forward.rb | sudo ruby
```

Interactive **firewalld** port-forward setup for [44Net Connect](https://44net.cloud/) (WireGuard/AMPR) on **Debian 12 or 13** (ASL3 / appliance). Forwards traffic arriving on your **44.x.x.x** address and port to an internal LAN host — for example exposing an AllStar node, web UI, or other service to the AMPR network.

**What the script does:**

- Stores forwards in `/etc/44connect-forwards.json`
- Adds **firewalld** `forward-port` rules on the WireGuard interface zone (masquerade + `net.ipv4.ip_forward`)
- Assigns the WireGuard interface to the `allstarlink` firewalld zone if unassigned (ASL3 default; falls back to the system default zone)
- Saves a copy of this script to `/usr/local/sbin/` when run via curl (for WireGuard PostDown hooks)
- Installs `/usr/local/sbin/44connect-forward-apply` for WireGuard `PostUp` hooks

**Requirements:** Debian Bookworm (12) or Trixie (13), `firewalld` running, WireGuard up with a 44net address. Ensure your LAN router sends `44.0.0.0/9` and `44.128.0.0/10` toward this host.

**Non-interactive example:**

```sh
FWD_ACTION=add FWD_WG_IF=44net-pop FWD_LAN_IF=eth0 FWD_44_IP=44.33.1.32 \
FWD_EXT_PORT=44966 FWD_INT_IP=192.168.1.50 FWD_INT_PORT=44966 FWD_PROTO=udp \
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup-44connect-forward.rb | sudo ruby
```

**WireGuard persistence** (add to your 44Connect `[Interface]` section after saving the script to `/usr/local/sbin/`):

```ini
PostUp = /usr/local/sbin/44connect-forward-apply
PostDown = /usr/bin/env ruby /usr/local/sbin/setup-44connect-forward.rb --flush-only
```

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

Preview first:

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/cleanup_old_logs.rb | sudo ruby -- --dry-run
```

### fasterAsteriskSounds.sh

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/fasterAsteriskSounds.sh | sudo bash
```

Speeds up stock Asterisk English prompts (default **1.1×** tempo) and writes overrides under `/usr/local/share/asterisk/sounds` so package upgrades of `/usr/share/asterisk/sounds/en` are never overwritten. ASL3 plays these first when `sounds_search_custom_dir = yes` (default).

**Requires:** `sox`, root (or write access to `DEST_DIR`).

**Options:**

| Flag / env | Purpose |
|------------|---------|
| `--dry-run` | Count files without writing |
| `--tempo N` | Tempo multiplier (default `1.1`) |
| `--no-silence` | Skip leading/trailing silence trim |
| `SOURCE_DIR` / `DEST_DIR` | Override input/output trees |

Preview:

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/fasterAsteriskSounds.sh | sudo bash -s -- --dry-run
```

### write_node_callsigns.sh

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/write_node_callsigns.sh | sudo bash
```

Builds per-node `.gsm` prompts so app_rpt telemetry speaks **callsigns** instead of node numbers (original by N5LSN; parallel/resume updates for ASL3). Reads `astdb.txt` from `/var/lib/asterisk` or `/var/log/asterisk` and writes under `/usr/share/asterisk/sounds/en/rpt/nodenames`.

**Requires:** `sox`, ASL3 sound letter/digit files, root for the default destination.

**Common usage:**

```sh
# First full build (no prompt)
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/write_node_callsigns.sh | sudo bash -s -- -a -f

# Only new/changed nodes
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/write_node_callsigns.sh | sudo bash -s -- -f

# Rebuild one node
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/write_node_callsigns.sh | sudo bash -s -- -n 40000 -r
```

Useful flags: `-j N` (parallel sox jobs), `-i` (append “node” + number after callsign), `-r` (force regenerate), `-v` (verbose), `-d PATH` / `-s PATH` (custom dest / astdb dir).
