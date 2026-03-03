# asl-misc-scripts

Lightweight, copy-pasteable scripts for AllStarLink admins and operators. Setup, provisioning, and maintenance tasks that run anywhere with `curl | interpreter`—no clone required. Shell, Ruby, Perl, and more.

## Usage

Run directly from GitHub (one-liner, requires curl). Use the appropriate interpreter for each script (`sh`, `ruby`, `perl`, etc.):

```sh
# Shell
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/asl-debian-setup.sh | sudo sh
```

```sh
# Perl
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup_ssh_key.pl | perl
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup_gitconfig.pl | perl
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup_certbot.pl | sudo perl
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/create_gpg_key.pl | perl
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/configure_ssh.pl | perl
```

## Scripts

- `asl-debian-setup.sh` — Configures the AllStarLink repository on Debian 12/13, then optionally installs ASL3 or an appliance package (VM, PC, or Raspberry Pi)
- `setup_ssh_key.pl` — Generates an SSH key (Ed25519 or RSA) and optionally copies it to a remote system
- `setup_gitconfig.pl` — Interactive Git configuration (user name, email, editor, colors, etc.)
- `setup_certbot.pl` — Install and configure certbot on Debian (Let's Encrypt, auto-renewal, certificates)
- `create_gpg_key.pl` — Create a secure GPG key (RSA or Ed25519) with optional expiration
- `configure_ssh.pl` — Configure SSH client (host entries, keep-alive, jump hosts, agent forwarding)
