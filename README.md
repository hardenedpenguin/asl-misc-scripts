# asl-misc-scripts

Lightweight, copy-pasteable scripts for AllStarLink admins and operators. Setup, provisioning, and maintenance tasks that run anywhere with `curl | interpreter`—no clone required. Shell, Ruby, Perl, and more.

## Scripts

Run directly from GitHub with curl. Copy the line for the script you need.

### asl-debian-setup.sh

```sh
curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/asl-debian-setup.sh | sudo sh
```

Configures the AllStarLink repository on Debian 12/13, then optionally installs ASL3 or an appliance package (VM, PC, or Raspberry Pi).

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

Deletes **regular files** under `/var/log` whose modification time is older than three days. Directories, symlinks, and other non-file entries are left alone. Run with `sudo` when you need permission to remove protected logs. Intended for periodic maintenance (for example from cron), not for interactive confirmation.
