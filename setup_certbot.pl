#!/usr/bin/env perl
#
# Copyright (C) 2026 Jory A. Pratt, W5GLE <geekypenguin@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# Script to install and configure certbot on Debian
# Usage: ./setup_certbot.pl

use strict;
use warnings;
use File::Spec;

# Color codes for output (disabled when stdout is not a TTY)
my $use_color = -t STDOUT;
my $GREEN  = $use_color ? "\033[0;32m" : '';
my $YELLOW = $use_color ? "\033[1;33m" : '';
my $RED    = $use_color ? "\033[0;31m" : '';
my $BLUE   = $use_color ? "\033[0;34m" : '';
my $NC     = $use_color ? "\033[0m" : '';

# Enable autoflush for STDOUT
$| = 1;

# Check if running as root
unless ($< == 0) {
    die "${RED}Error: This script must be run as root (use sudo)${NC}\n";
}

# Reopen STDIN from /dev/tty when piped (e.g. curl | perl) so prompts work
unless (-t STDIN) {
    if (!open(STDIN, "<", "/dev/tty")) {
        die "${RED}Error: This script requires an interactive terminal. Run: curl -sSL <url> -o script.pl && sudo perl script.pl${NC}\n";
    }
}

print "${GREEN}=== Certbot Installation and Configuration Tool ===${NC}\n\n";

# Subroutine to run a command and return success
sub run_cmd {
    my (@cmd) = @_;
    return system(@cmd) == 0;
}

sub command_exists {
    my ($cmd) = @_;
    return system('sh', '-c', 'command -v ' . quotemeta($cmd) . ' >/dev/null 2>&1') == 0;
}

# Check OS
check_debian_os();

# Main menu
while (1) {
    print "\n${BLUE}What would you like to do?${NC}\n";
    print "1) Install certbot\n";
    print "2) Configure certbot for a domain\n";
    print "3) Set up automatic renewal\n";
    print "4) Test automatic renewal\n";
    print "5) List existing certificates\n";
    print "6) Renew certificates manually\n";
    print "7) Revoke a certificate\n";
    print "8) Complete setup (install + configure + auto-renewal)\n";
    print "9) Exit\n";
    
    my $choice = prompt("Enter choice [1-9]: ", "");
    
    if ($choice eq "1") {
        install_certbot();
    } elsif ($choice eq "2") {
        configure_certbot();
    } elsif ($choice eq "3") {
        setup_auto_renewal();
    } elsif ($choice eq "4") {
        test_renewal();
    } elsif ($choice eq "5") {
        list_certificates();
    } elsif ($choice eq "6") {
        renew_certificates();
    } elsif ($choice eq "7") {
        revoke_certificate();
    } elsif ($choice eq "8") {
        complete_setup();
    } elsif ($choice eq "9") {
        print "\n${GREEN}Setup complete!${NC}\n";
        last;
    } else {
        print "${RED}Invalid choice. Please try again.${NC}\n";
    }
}

# Check if running on Debian
sub check_debian_os {
    unless (-f "/etc/debian_version") {
        print "${YELLOW}Warning: This script is designed for Debian-based systems.${NC}\n";
        my $continue = prompt("Continue anyway? [y/N]: ", "n");
        exit 0 unless lc($continue) eq "y";
    }
}

# Install certbot
sub install_certbot {
    print "\n${YELLOW}=== Installing Certbot ===${NC}\n\n";
    
    # Update package list
    print "${BLUE}Updating package list...${NC}\n";
    unless (run_cmd("env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update", "-qq")) {
        print "${RED}Error: apt-get update failed.${NC}\n";
        return;
    }
    
    my $arch = `uname -m 2>/dev/null` || '';
    chomp $arch;
    my $is_arm = $arch =~ /^(arm|aarch64)/;
    
    # Check if snapd is available (recommended method on x86; heavy on ARM Pis)
    my $snap_available = command_exists('snap');
    my $use_snap = 0;
    if ($snap_available && $is_arm) {
        print "${YELLOW}ARM system detected; using apt (lighter than snap on Pi nodes).${NC}\n";
    } elsif ($snap_available) {
        my $method = prompt("Install via snap (recommended) or apt? [snap/apt] (default: snap): ", "snap");
        $use_snap = 1 if lc($method) eq "snap";
    }
    
    if ($use_snap) {
        print "${BLUE}Installing certbot via snap...${NC}\n";
        
        # Install snapd if not present
        unless ($snap_available) {
            print "${YELLOW}Installing snapd...${NC}\n";
            unless (run_cmd("env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "snapd")) {
                print "${RED}Error: snapd installation failed.${NC}\n";
                return;
            }
            run_cmd("systemctl", "enable", "--now", "snapd.socket");
            run_cmd("ln", "-sf", "/var/lib/snapd/snap", "/snap");
        }
        
        # Remove old certbot if installed via apt
        run_cmd("apt-get", "remove", "-y", "certbot");
        
        unless (run_cmd("snap", "install", "core") &&
                run_cmd("snap", "refresh", "core") &&
                run_cmd("snap", "install", "--classic", "certbot")) {
            print "${RED}Error: Certbot snap installation failed.${NC}\n";
            return;
        }
        run_cmd("ln", "-sf", "/snap/bin/certbot", "/usr/bin/certbot");
        
    } else {
        print "${BLUE}Installing certbot via apt...${NC}\n";
        unless (run_cmd("env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "certbot")) {
            print "${RED}Error: apt certbot installation failed.${NC}\n";
            return;
        }
    }
    
    # Check installation
    if (command_exists('certbot')) {
        print "\n${GREEN}✓ Certbot installed successfully!${NC}\n";
        system("certbot --version");
    } else {
        print "${RED}Error: Certbot installation failed!${NC}\n";
        return;
    }
    
    # Ask about web server plugin
    print "\n${BLUE}Do you want to install a web server plugin?${NC}\n";
    print "1) Apache\n";
    print "2) Nginx\n";
    print "3) None (standalone mode)\n";
    my $plugin = prompt("Enter choice [1-3] (default: 3): ", "3");
    
    if ($plugin eq "1") {
        if ($use_snap) {
            run_cmd("snap", "set", "certbot", "trust-plugin-with-root=ok");
            unless (run_cmd("snap", "install", "certbot-apache")) {
                print "${RED}Error: Apache plugin installation failed.${NC}\n";
                return;
            }
        } else {
            unless (run_cmd("env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "python3-certbot-apache")) {
                print "${RED}Error: Apache plugin installation failed.${NC}\n";
                return;
            }
        }
        print "${GREEN}✓ Apache plugin installed${NC}\n";
    } elsif ($plugin eq "2") {
        if ($use_snap) {
            run_cmd("snap", "set", "certbot", "trust-plugin-with-root=ok");
            unless (run_cmd("snap", "install", "certbot-nginx")) {
                print "${RED}Error: Nginx plugin installation failed.${NC}\n";
                return;
            }
        } else {
            unless (run_cmd("env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "python3-certbot-nginx")) {
                print "${RED}Error: Nginx plugin installation failed.${NC}\n";
                return;
            }
        }
        print "${GREEN}✓ Nginx plugin installed${NC}\n";
    }
}

# Configure certbot for a domain
sub configure_certbot {
    print "\n${YELLOW}=== Configure Certbot for Domain ===${NC}\n\n";
    
    # Check if certbot is installed
    unless (system("which certbot > /dev/null 2>&1") == 0) {
        print "${RED}Error: Certbot is not installed. Please install it first.${NC}\n";
        return;
    }
    
    my $domain = prompt("Enter domain name (e.g., example.com): ", "");
    return unless $domain;
    
    my $email = prompt("Enter email address for notifications: ", "");
    return unless $email;
    
    # Build domain list (avoids shell injection)
    my @domains = ($domain);
    my $add_www = prompt("Include www subdomain? [Y/n]: ", "y");
    push @domains, "www.$domain" if lc($add_www) eq "y";
    
    my $more = prompt("Add more domains? [y/N]: ", "n");
    if (lc($more) eq "y") {
        while (1) {
            my $extra = prompt("Enter additional domain (or press Enter to finish): ", "");
            last unless $extra;
            push @domains, $extra;
        }
    }
    
    # Certificate method
    print "\n${BLUE}Select certificate acquisition method:${NC}\n";
    print "1) Standalone (requires port 80/443 to be free)\n";
    print "2) Webroot (existing web server)\n";
    print "3) Apache (automatic configuration)\n";
    print "4) Nginx (automatic configuration)\n";
    print "5) DNS challenge (manual)\n";
    
    my $method = prompt("Enter choice [1-5] (default: 1): ", "1");
    
    my @cmd = ("certbot", "certonly", "--non-interactive", "--agree-tos", "--email", $email);
    for my $d (@domains) {
        push @cmd, "-d", $d;
    }
    
    if ($method eq "1") {
        push @cmd, "--standalone";
    } elsif ($method eq "2") {
        my $webroot = prompt("Enter webroot path (e.g., /var/www/html): ", "/var/www/html");
        push @cmd, "--webroot", "-w", $webroot;
    } elsif ($method eq "3") {
        @cmd = ("certbot", "--apache", "--non-interactive", "--agree-tos", "--email", $email);
        for my $d (@domains) { push @cmd, "-d", $d; }
    } elsif ($method eq "4") {
        @cmd = ("certbot", "--nginx", "--non-interactive", "--agree-tos", "--email", $email);
        for my $d (@domains) { push @cmd, "-d", $d; }
    } elsif ($method eq "5") {
        push @cmd, "--manual", "--preferred-challenges", "dns";
    }
    
    if ($method eq "3" || $method eq "4") {
        my $redirect = prompt("Redirect HTTP to HTTPS? [Y/n]: ", "y");
        push @cmd, (lc($redirect) eq "y") ? "--redirect" : "--no-redirect";
    }
    
    print "\n${BLUE}Executing: certbot " . join(" ", map { /\s/ ? "'$_'" : $_ } @cmd) . "${NC}\n\n";
    my $result = system(@cmd);
    
    if ($result == 0) {
        print "\n${GREEN}✓ Certificate obtained successfully!${NC}\n";
        print "${YELLOW}Certificate location: /etc/letsencrypt/live/$domain/${NC}\n";
        print "${YELLOW}Fullchain: /etc/letsencrypt/live/$domain/fullchain.pem${NC}\n";
        print "${YELLOW}Private key: /etc/letsencrypt/live/$domain/privkey.pem${NC}\n";
    } else {
        print "${RED}Error: Certificate acquisition failed!${NC}\n";
    }
}

# Set up automatic renewal
sub setup_auto_renewal {
    print "\n${YELLOW}=== Setting Up Automatic Renewal ===${NC}\n\n";
    
    # Check if certbot is installed
    unless (system("which certbot > /dev/null 2>&1") == 0) {
        print "${RED}Error: Certbot is not installed.${NC}\n";
        return;
    }
    
    print "${BLUE}Certbot can renew certificates automatically using:${NC}\n";
    print "1) Systemd timer (recommended for most systems)\n";
    print "2) Cron job (traditional method)\n";
    
    my $method = prompt("Enter choice [1-2] (default: 1): ", "1");
    
    if ($method eq "1") {
        setup_systemd_timer();
    } else {
        setup_cron_job();
    }
    
    print "\n${GREEN}✓ Automatic renewal configured!${NC}\n";
    print "${YELLOW}Certificates will be checked for renewal twice daily.${NC}\n";
}

sub certbot_renewal_timer_present {
    my $timers = `systemctl list-timers --all 2>/dev/null` || '';
    return 1 if $timers =~ /certbot\.timer|certbot-renewal\.timer|snap\.certbot\.renew\.timer/;
    return 0;
}

# Set up systemd timer
sub setup_systemd_timer {
    print "${BLUE}Setting up systemd timer...${NC}\n";
    
    if (certbot_renewal_timer_present()) {
        print "${YELLOW}A certbot renewal timer is already present; skipping custom timer.${NC}\n";
        system("systemctl", "list-timers", "--all", "certbot.timer", "certbot-renewal.timer", "snap.certbot.renew.timer");
        return;
    }

    my $service_file = "/etc/systemd/system/certbot-renewal.service";
    my $timer_file = "/etc/systemd/system/certbot-renewal.timer";
    
    open my $svc, '>', $service_file or die "Cannot create service file: $!\n";
    print $svc <<'EOF';
[Unit]
Description=Certbot Renewal Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx || systemctl reload apache2 || true"
EOF
    close $svc;
    
    open my $tmr, '>', $timer_file or die "Cannot create timer file: $!\n";
    print $tmr <<'EOF';
[Unit]
Description=Certbot Renewal Timer
After=network-online.target

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    close $tmr;
    
    run_cmd("systemctl", "daemon-reload");
    run_cmd("systemctl", "enable", "certbot-renewal.timer");
    run_cmd("systemctl", "start", "certbot-renewal.timer");
    
    print "${GREEN}✓ Systemd timer created and enabled${NC}\n";
}

# Set up cron job
sub setup_cron_job {
    print "${BLUE}Setting up cron job...${NC}\n";
    
    my $cron_file = "/etc/cron.d/certbot-renewal";
    
    open my $fh, '>', $cron_file or die "Cannot create cron file: $!\n";
    print $fh "# Certbot automatic renewal\n";
    print $fh "0 0,12 * * * root /usr/bin/certbot renew --quiet --deploy-hook 'systemctl reload nginx || systemctl reload apache2 || true'\n";
    close $fh;
    
    chmod 0644, $cron_file;
    
    print "${GREEN}✓ Cron job created${NC}\n";
}

# Test renewal
sub test_renewal {
    print "\n${YELLOW}=== Testing Certificate Renewal ===${NC}\n\n";
    
    print "${BLUE}Running renewal in dry-run mode (no actual changes)...${NC}\n\n";
    system("certbot renew --dry-run");
    
    if ($? == 0) {
        print "\n${GREEN}✓ Renewal test successful!${NC}\n";
    } else {
        print "\n${RED}Renewal test failed. Please check the output above.${NC}\n";
    }
}

# List certificates
sub list_certificates {
    print "\n${YELLOW}=== Existing Certificates ===${NC}\n\n";
    system("certbot certificates");
}

# Renew certificates manually
sub renew_certificates {
    print "\n${YELLOW}=== Renewing Certificates ===${NC}\n\n";
    
    my $force = prompt("Force renewal even if not due? [y/N]: ", "n");
    
    if (lc($force) eq "y") {
        system("certbot renew --force-renewal");
    } else {
        system("certbot renew");
    }
    
    if ($? == 0) {
        print "\n${GREEN}✓ Renewal completed successfully!${NC}\n";
    } else {
        print "\n${RED}Renewal failed. Please check the output above.${NC}\n";
    }
}

# Revoke certificate
sub revoke_certificate {
    print "\n${YELLOW}=== Revoke Certificate ===${NC}\n\n";
    print "${RED}Warning: This will revoke the certificate permanently!${NC}\n\n";
    
    # List certificates first
    system("certbot certificates");
    
    my $cert_name = prompt("\nEnter certificate name to revoke: ", "");
    return unless $cert_name;
    
    my $confirm = prompt("Are you sure you want to revoke '$cert_name'? [yes/no]: ", "no");
    return unless lc($confirm) eq "yes";
    
    my $delete = prompt("Also delete certificate files? [Y/n]: ", "y");
    
    my @cmd = ("certbot", "revoke", "--cert-name", $cert_name);
    push @cmd, "--delete-after-revoke" if lc($delete) eq "y";
    
    system(@cmd);
    
    if ($? == 0) {
        print "\n${GREEN}✓ Certificate revoked successfully!${NC}\n";
    } else {
        print "\n${RED}Certificate revocation failed!${NC}\n";
    }
}

# Complete setup
sub complete_setup {
    print "\n${GREEN}=== Complete Certbot Setup ===${NC}\n";
    print "${BLUE}This will install certbot, configure a certificate, and set up auto-renewal.${NC}\n\n";
    
    my $confirm = prompt("Continue with complete setup? [Y/n]: ", "y");
    return unless lc($confirm) eq "y";
    
    # Step 1: Install
    install_certbot();
    
    # Step 2: Configure
    print "\n${BLUE}Press Enter to continue with domain configuration...${NC}\n";
    <STDIN>;
    configure_certbot();
    
    # Step 3: Auto-renewal
    print "\n${BLUE}Press Enter to continue with auto-renewal setup...${NC}\n";
    <STDIN>;
    setup_auto_renewal();
    
    print "\n${GREEN}✓✓✓ Complete setup finished! ✓✓✓${NC}\n";
    print "${YELLOW}Your SSL certificates are now configured and will renew automatically.${NC}\n";
}

# Subroutine to prompt user for input with default value
# Uses /dev/tty when STDIN is piped (e.g. curl | perl)
sub prompt {
    my ($message, $default) = @_;
    my $fh = (-t STDIN) ? \*STDIN : do {
        open my $t, "<", "/dev/tty" or die "${RED}Cannot read from terminal. Run interactively.${NC}\n";
        $t;
    };
    print $message;
    my $input = <$fh>;
    chomp $input if defined $input;
    return (defined $input && $input ne "") ? $input : $default;
}

