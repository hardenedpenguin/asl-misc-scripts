# asl-misc-scripts

A collection of miscellaneous shell scripts that can be run directly with `sh`.

## Usage

Run directly from GitHub (one-liner, requires curl):

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/asl-debian-setup.sh | sudo sh
```

## Scripts

- `asl-debian-setup.sh` — Configures the AllStarLink repository on Debian 12/13, then optionally installs ASL3 or an appliance package (VM, PC, or Raspberry Pi)
