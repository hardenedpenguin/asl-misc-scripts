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

Interactive setup for **gpsd**, shared GPS on `127.0.0.1:2947`, and **APRS** via `app_gps` on an ASL3 node. gpsd owns the USB receiver (for saytime, SkywarnPlus, `cgps`, and similar clients). A `gpsd-nmea-bridge` systemd unit replays NMEA to `/dev/rptgps` because `app_gps` only reads a serial-style stream.

The script installs `gpsd`, `gpsd-clients`, and `socat`; writes `/etc/default/gpsd` and `/etc/asterisk/gps.conf` (APRS passcode from callsign); enables `app_gps.so` in `modules.conf`; and restarts gpsd and Asterisk. Defaults target **Shari PiHat-class** low-power Pi nodes (~5W HT, rubber duck, omni): 180s beacon interval, car icon (`>`), and PHG power/height/gain of 2/1/1. Run as root and answer prompts for callsign, SSID, USB device (`/dev/ttyACM0` default), RF frequency, tone, beacon comment, and interval.

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
