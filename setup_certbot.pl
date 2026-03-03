#!/usr/bin/perl

# Script to install and configure certbot on Debian
# Usage: ./setup_certbot.pl

use strict;
use warnings;
use File::Spec;

# Color codes for output
my $GREEN  = "\033[0;32m";
my $YELLOW = "\033[1;33m";
my $RED    = "\033[0;31m";
my $BLUE   = "\033[0;34m";
my $NC     = "\033[0m";  # No Color

# Enable autoflush for STDOUT
$| = 1;

# Check if running as root
unless ($< == 0) {
    die "${RED}Error: This script must be run as root (use sudo)${NC}\n";
}

print "${GREEN}=== Certbot Installation and Configuration Tool ===${NC}\n\n";

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
    system("apt-get update -qq");
    
    # Check if snapd is available (recommended method)
    my $use_snap = 0;
    if (system("which snap > /dev/null 2>&1") == 0) {
        my $method = prompt("Install via snap (recommended) or apt? [snap/apt] (default: snap): ", "snap");
        $use_snap = 1 if lc($method) eq "snap";
    }
    
    if ($use_snap) {
        print "${BLUE}Installing certbot via snap...${NC}\n";
        
        # Install snapd if not present
        if (system("which snap > /dev/null 2>&1") != 0) {
            print "${YELLOW}Installing snapd...${NC}\n";
            system("apt-get install -y snapd");
            system("systemctl enable --now snapd.socket");
            system("ln -sf /var/lib/snapd/snap /snap");
        }
        
        # Remove old certbot if installed via apt
        system("apt-get remove -y certbot 2>/dev/null");
        
        # Install certbot via snap
        system("snap install core");
        system("snap refresh core");
        system("snap install --classic certbot");
        system("ln -sf /snap/bin/certbot /usr/bin/certbot");
        
    } else {
        print "${BLUE}Installing certbot via apt...${NC}\n";
        system("apt-get install -y certbot");
    }
    
    # Check installation
    if (system("which certbot > /dev/null 2>&1") == 0) {
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
            system("snap set certbot trust-plugin-with-root=ok");
            system("snap install certbot-dns-apache");
        } else {
            system("apt-get install -y python3-certbot-apache");
        }
        print "${GREEN}✓ Apache plugin installed${NC}\n";
    } elsif ($plugin eq "2") {
        if ($use_snap) {
            system("snap set certbot trust-plugin-with-root=ok");
            system("snap install certbot-dns-nginx");
        } else {
            system("apt-get install -y python3-certbot-nginx");
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
    
    # Additional domains
    my $add_www = prompt("Include www subdomain? [Y/n]: ", "y");
    my $domain_args = "-d $domain";
    $domain_args .= " -d www.$domain" if lc($add_www) eq "y";
    
    # Check for additional domains
    my $more = prompt("Add more domains? [y/N]: ", "n");
    if (lc($more) eq "y") {
        while (1) {
            my $extra = prompt("Enter additional domain (or press Enter to finish): ", "");
            last unless $extra;
            $domain_args .= " -d $extra";
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
    
    my $cmd = "certbot certonly --non-interactive --agree-tos --email $email $domain_args";
    
    if ($method eq "1") {
        $cmd .= " --standalone";
    } elsif ($method eq "2") {
        my $webroot = prompt("Enter webroot path (e.g., /var/www/html): ", "/var/www/html");
        $cmd .= " --webroot -w $webroot";
    } elsif ($method eq "3") {
        $cmd = "certbot --apache --non-interactive --agree-tos --email $email $domain_args";
    } elsif ($method eq "4") {
        $cmd = "certbot --nginx --non-interactive --agree-tos --email $email $domain_args";
    } elsif ($method eq "5") {
        $cmd .= " --manual --preferred-challenges dns";
    }
    
    # Add redirect option for Apache/Nginx
    if ($method eq "3" || $method eq "4") {
        my $redirect = prompt("Redirect HTTP to HTTPS? [Y/n]: ", "y");
        if (lc($redirect) eq "y") {
            $cmd .= " --redirect";
        } else {
            $cmd .= " --no-redirect";
        }
    }
    
    print "\n${BLUE}Executing: $cmd${NC}\n\n";
    my $result = system($cmd);
    
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

# Set up systemd timer
sub setup_systemd_timer {
    print "${BLUE}Setting up systemd timer...${NC}\n";
    
    # Check if timer already exists
    if (system("systemctl list-timers | grep -q certbot") == 0) {
        print "${YELLOW}Certbot timer already exists.${NC}\n";
        system("systemctl status certbot.timer --no-pager");
    } else {
        # Create timer and service files
        my $service_file = "/etc/systemd/system/certbot-renewal.service";
        my $timer_file = "/etc/systemd/system/certbot-renewal.timer";
        
        # Service file
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
        
        # Timer file
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
        
        # Enable and start timer
        system("systemctl daemon-reload");
        system("systemctl enable certbot-renewal.timer");
        system("systemctl start certbot-renewal.timer");
        
        print "${GREEN}✓ Systemd timer created and enabled${NC}\n";
    }
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
    
    my $cmd = "certbot revoke --cert-name $cert_name";
    $cmd .= " --delete-after-revoke" if lc($delete) eq "y";
    
    system($cmd);
    
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
sub prompt {
    my ($message, $default) = @_;
    print $message;
    my $input = <STDIN>;
    chomp $input;
    return $input || $default;
}

