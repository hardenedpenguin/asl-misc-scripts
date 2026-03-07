#!/usr/bin/env perl

# Script to configure SSH client settings
# Usage: ./configure_ssh.pl

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use File::Copy;

# Color codes for output
my $GREEN  = "\033[0;32m";
my $YELLOW = "\033[1;33m";
my $RED    = "\033[0;31m";
my $BLUE   = "\033[0;34m";
my $NC     = "\033[0m";  # No Color

# Enable autoflush for STDOUT
$| = 1;

# Input handle: use /dev/tty when STDIN is piped (e.g. curl | perl)
my $input_fh = \*STDIN;
unless (-t STDIN) {
    if (open my $tty, '<', '/dev/tty') {
        $input_fh = $tty;
    } else {
        die "${RED}Error: This script requires an interactive terminal.${NC}\nRun: curl -sSL <url> -o script.pl && perl script.pl\n";
    }
}

print "${GREEN}=== SSH Configuration Tool ===${NC}\n\n";

# Expand home directory
my $home = $ENV{HOME} || (getpwuid($<))[7];
my $ssh_dir = File::Spec->catdir($home, '.ssh');
my $config_file = File::Spec->catfile($ssh_dir, 'config');

# Ensure .ssh directory exists
unless (-d $ssh_dir) {
    print "${YELLOW}Creating ~/.ssh directory...${NC}\n";
    make_path($ssh_dir, { mode => 0700 });
}

# Backup existing config if it exists
if (-f $config_file) {
    my $backup = "$config_file.backup." . time();
    copy($config_file, $backup) or die "Cannot backup config file: $!\n";
    print "${GREEN}✓ Backed up existing config to: $backup${NC}\n\n";
}

# Main menu
while (1) {
    print "\n${BLUE}What would you like to configure?${NC}\n";
    print "1) Add a new host configuration\n";
    print "2) Configure global SSH settings\n";
    print "3) View current SSH config\n";
    print "4) Set up SSH agent forwarding\n";
    print "5) Configure connection keep-alive\n";
    print "6) Set up jump host (bastion)\n";
    print "7) Exit\n";
    
    my $choice = prompt("Enter choice [1-7]: ", "");
    
    if ($choice eq "1") {
        add_host_config();
    } elsif ($choice eq "2") {
        configure_global_settings();
    } elsif ($choice eq "3") {
        view_config();
    } elsif ($choice eq "4") {
        configure_agent_forwarding();
    } elsif ($choice eq "5") {
        configure_keepalive();
    } elsif ($choice eq "6") {
        configure_jump_host();
    } elsif ($choice eq "7") {
        print "\n${GREEN}Configuration complete!${NC}\n";
        last;
    } else {
        print "${RED}Invalid choice. Please try again.${NC}\n";
    }
}

# Subroutine to add a host configuration
sub add_host_config {
    print "\n${YELLOW}=== Add New Host Configuration ===${NC}\n";
    
    my $alias = prompt("Enter host alias (e.g., myserver): ", "");
    return unless $alias;
    
    my $hostname = prompt("Enter hostname or IP address: ", "");
    return unless $hostname;
    
    my $user = prompt("Enter username (leave empty for default): ", "");
    my $port = prompt("Enter port number (default: 22): ", "22");
    my $key_file = prompt("Enter path to identity file (leave empty for default): ", "");
    
    # Optional advanced settings
    print "\n${BLUE}Optional settings (press Enter to skip):${NC}\n";
    my $forward_agent = prompt("Enable agent forwarding? [y/N]: ", "n");
    my $forward_x11 = prompt("Enable X11 forwarding? [y/N]: ", "n");
    my $compression = prompt("Enable compression? [y/N]: ", "n");
    my $strict_host_check = prompt("Strict host key checking? [yes/no/ask] (default: ask): ", "ask");
    
    # Build the host configuration
    my $config = "\n# Configuration for $alias\n";
    $config .= "Host $alias\n";
    $config .= "    HostName $hostname\n";
    $config .= "    Port $port\n" if $port ne "22";
    $config .= "    User $user\n" if $user;
    $config .= "    IdentityFile $key_file\n" if $key_file;
    $config .= "    ForwardAgent " . (lc($forward_agent) eq "y" ? "yes" : "no") . "\n";
    $config .= "    ForwardX11 " . (lc($forward_x11) eq "y" ? "yes" : "no") . "\n";
    $config .= "    Compression " . (lc($compression) eq "y" ? "yes" : "no") . "\n";
    $config .= "    StrictHostKeyChecking $strict_host_check\n";
    
    # Add connection optimization
    $config .= "    ServerAliveInterval 60\n";
    $config .= "    ServerAliveCountMax 3\n";
    
    # Append to config file
    if (open my $fh, '>>', $config_file) {
        print $fh $config;
        close $fh;
        chmod 0600, $config_file;
        
        print "\n${GREEN}✓ Host configuration added successfully!${NC}\n";
        print "${YELLOW}You can now connect using: ${NC}ssh $alias\n";
    } else {
        print "${RED}Error: Cannot write to config file: $!${NC}\n";
    }
}

# Subroutine to configure global settings
sub configure_global_settings {
    print "\n${YELLOW}=== Configure Global SSH Settings ===${NC}\n";
    
    print "${BLUE}These settings will apply to all SSH connections by default.${NC}\n\n";
    
    my $hash_known_hosts = prompt("Hash known hosts for privacy? [y/N]: ", "n");
    my $control_master = prompt("Enable connection multiplexing (faster reconnects)? [y/N]: ", "n");
    my $tcp_keepalive = prompt("Enable TCP keepalive? [Y/n]: ", "y");
    my $gssapi_auth = prompt("Enable GSSAPI authentication? [y/N]: ", "n");
    my $pubkey_auth = prompt("Enable public key authentication? [Y/n]: ", "y");
    my $password_auth = prompt("Enable password authentication? [Y/n]: ", "y");
    
    my $config = "\n# Global SSH settings\n";
    $config .= "Host *\n";
    $config .= "    HashKnownHosts " . (lc($hash_known_hosts) eq "y" ? "yes" : "no") . "\n";
    $config .= "    TCPKeepAlive " . (lc($tcp_keepalive) eq "y" ? "yes" : "no") . "\n";
    $config .= "    GSSAPIAuthentication " . (lc($gssapi_auth) eq "y" ? "yes" : "no") . "\n";
    $config .= "    PubkeyAuthentication " . (lc($pubkey_auth) eq "y" ? "yes" : "no") . "\n";
    $config .= "    PasswordAuthentication " . (lc($password_auth) eq "y" ? "yes" : "no") . "\n";
    
    if (lc($control_master) eq "y") {
        $config .= "    ControlMaster auto\n";
        $config .= "    ControlPath ~/.ssh/control-%r@%h:%p\n";
        $config .= "    ControlPersist 10m\n";
    }
    
    if (open my $fh, '>>', $config_file) {
        print $fh $config;
        close $fh;
        chmod 0600, $config_file;
        
        print "\n${GREEN}✓ Global settings configured successfully!${NC}\n";
    } else {
        print "${RED}Error: Cannot write to config file: $!${NC}\n";
    }
}

# Subroutine to view current config
sub view_config {
    print "\n${YELLOW}=== Current SSH Configuration ===${NC}\n\n";
    
    if (-f $config_file) {
        if (open my $fh, '<', $config_file) {
            print while <$fh>;
            close $fh;
        } else {
            print "${RED}Error: Cannot read config file: $!${NC}\n";
        }
    } else {
        print "${YELLOW}No SSH config file exists yet.${NC}\n";
    }
}

# Subroutine to configure agent forwarding
sub configure_agent_forwarding {
    print "\n${YELLOW}=== Configure SSH Agent Forwarding ===${NC}\n";
    print "${BLUE}Agent forwarding allows you to use your local SSH keys on remote servers.${NC}\n";
    print "${RED}Warning: Only enable this for trusted hosts!${NC}\n\n";
    
    my $host = prompt("Enter host alias or pattern (e.g., trusted-*, or * for all): ", "");
    return unless $host;
    
    my $config = "\n# Agent forwarding for $host\n";
    $config .= "Host $host\n";
    $config .= "    ForwardAgent yes\n";
    
    if (open my $fh, '>>', $config_file) {
        print $fh $config;
        close $fh;
        chmod 0600, $config_file;
        
        print "\n${GREEN}✓ Agent forwarding configured for: $host${NC}\n";
    } else {
        print "${RED}Error: Cannot write to config file: $!${NC}\n";
    }
}

# Subroutine to configure connection keep-alive
sub configure_keepalive {
    print "\n${YELLOW}=== Configure Connection Keep-Alive ===${NC}\n";
    print "${BLUE}Keep-alive prevents SSH connections from timing out.${NC}\n\n";
    
    my $host = prompt("Enter host alias or pattern (* for all hosts): ", "*");
    my $interval = prompt("Server alive interval in seconds (default: 60): ", "60");
    my $count_max = prompt("Max server alive checks (default: 3): ", "3");
    
    my $config = "\n# Keep-alive settings for $host\n";
    $config .= "Host $host\n";
    $config .= "    ServerAliveInterval $interval\n";
    $config .= "    ServerAliveCountMax $count_max\n";
    
    if (open my $fh, '>>', $config_file) {
        print $fh $config;
        close $fh;
        chmod 0600, $config_file;
        
        print "\n${GREEN}✓ Keep-alive configured for: $host${NC}\n";
        print "${YELLOW}Connection will timeout after " . ($interval * $count_max) . " seconds of inactivity.${NC}\n";
    } else {
        print "${RED}Error: Cannot write to config file: $!${NC}\n";
    }
}

# Subroutine to configure jump host (bastion)
sub configure_jump_host {
    print "\n${YELLOW}=== Configure Jump Host (Bastion) ===${NC}\n";
    print "${BLUE}Jump hosts allow you to access servers through an intermediate host.${NC}\n\n";
    
    my $target_alias = prompt("Enter alias for target server: ", "");
    return unless $target_alias;
    
    my $target_host = prompt("Enter target server hostname/IP: ", "");
    return unless $target_host;
    
    my $jump_host = prompt("Enter jump/bastion host (can be an alias): ", "");
    return unless $jump_host;
    
    my $target_user = prompt("Enter username for target server (leave empty for default): ", "");
    my $target_port = prompt("Enter port for target server (default: 22): ", "22");
    
    my $config = "\n# Jump host configuration for $target_alias\n";
    $config .= "Host $target_alias\n";
    $config .= "    HostName $target_host\n";
    $config .= "    Port $target_port\n" if $target_port ne "22";
    $config .= "    User $target_user\n" if $target_user;
    $config .= "    ProxyJump $jump_host\n";
    
    if (open my $fh, '>>', $config_file) {
        print $fh $config;
        close $fh;
        chmod 0600, $config_file;
        
        print "\n${GREEN}✓ Jump host configured successfully!${NC}\n";
        print "${YELLOW}You can now connect using: ${NC}ssh $target_alias\n";
        print "${BLUE}This will automatically jump through: $jump_host${NC}\n";
    } else {
        print "${RED}Error: Cannot write to config file: $!${NC}\n";
    }
}

# Subroutine to prompt user for input with default value
# Uses $input_fh (STDIN or /dev/tty when piped)
sub prompt {
    my ($message, $default) = @_;
    print $message;
    my $input = <$input_fh>;
    chomp $input if defined $input;
    return (defined $input && $input ne "") ? $input : $default;
}

