#!/usr/bin/env perl

# Script to generate a secure SSH key and copy it to a remote system
# Usage: ./setup_ssh_key.pl

use strict;
use warnings;
use File::Spec;

# Color codes for output
my $GREEN  = "\033[0;32m";
my $YELLOW = "\033[1;33m";
my $RED    = "\033[0;31m";
my $NC     = "\033[0m";  # No Color

# Enable autoflush for STDOUT
$| = 1;

# Use /dev/tty when STDIN is piped (e.g. curl | perl)
my $input_fh = (-t STDIN) ? \*STDIN : do {
    open my $t, '<', '/dev/tty' or die "${RED}Error: Interactive terminal required. Run: curl -sSL <url> -o script.pl && perl script.pl${NC}\n";
    $t;
};

print "${GREEN}=== SSH Key Generation and Setup ===${NC}\n\n";

# Prompt for key type
print "Select SSH key type:\n";
print "1) Ed25519 (recommended - modern, secure, fast)\n";
print "2) RSA 4096-bit (widely compatible)\n";
my $key_choice = prompt("Enter choice [1-2] (default: 1): ", "1");

# Prompt for key location
my $key_path = prompt("Enter key file path (default: ~/.ssh/id_ed25519 or ~/.ssh/id_rsa): ", "");

# Prompt for optional passphrase
my $use_passphrase = prompt("Would you like to set a passphrase for extra security? [y/N]: ", "n");

# Prompt for comment (email/identifier)
my $comment = prompt("Enter a comment/identifier for the key (e.g., your email): ", "");

# Generate the SSH key based on selection
print "\n${YELLOW}Generating SSH key...${NC}\n";

my $key_type;
my @ssh_keygen_cmd;

if ($key_choice eq "1") {
    # Ed25519 key (recommended)
    $key_path = expand_tilde($key_path || "~/.ssh/id_ed25519");
    $key_type = "ed25519";
    
    if (lc($use_passphrase) eq "y") {
        @ssh_keygen_cmd = ("ssh-keygen", "-t", "ed25519", "-C", $comment, "-f", $key_path);
    } else {
        @ssh_keygen_cmd = ("ssh-keygen", "-t", "ed25519", "-C", $comment, "-f", $key_path, "-N", "");
    }
} else {
    # RSA 4096-bit key
    $key_path = expand_tilde($key_path || "~/.ssh/id_rsa");
    $key_type = "rsa";
    
    if (lc($use_passphrase) eq "y") {
        @ssh_keygen_cmd = ("ssh-keygen", "-t", "rsa", "-b", "4096", "-C", $comment, "-f", $key_path);
    } else {
        @ssh_keygen_cmd = ("ssh-keygen", "-t", "rsa", "-b", "4096", "-C", $comment, "-f", $key_path, "-N", "");
    }
}

# Execute ssh-keygen
my $result = system(@ssh_keygen_cmd);
if ($result != 0) {
    die "${RED}Error: SSH key generation failed!${NC}\n";
}

# Check if key was created successfully
unless (-f $key_path) {
    die "${RED}Error: SSH key generation failed!${NC}\n";
}

print "${GREEN}✓ SSH key generated successfully at: $key_path${NC}\n\n";

# Set proper permissions
chmod 0600, $key_path;
chmod 0644, "$key_path.pub";

# Display the public key
print "${YELLOW}Your public key:${NC}\n";
if (open my $pub_fh, '<', "$key_path.pub") {
    print while <$pub_fh>;
    close $pub_fh;
}
print "\n";

# Prompt for remote system details
my $copy_key = prompt("Do you want to copy the key to a remote system now? [Y/n]: ", "y");

if (lc($copy_key) eq "y") {
    my $remote_user = prompt("Enter remote username: ", "");
    my $remote_host = prompt("Enter remote host (IP or hostname): ", "");
    my $remote_port = prompt("Enter remote SSH port (default: 22): ", "22");
    
    print "\n${YELLOW}Copying SSH key to $remote_user\@$remote_host...${NC}\n";
    
    # Use ssh-copy-id to copy the key
    my @ssh_copy_cmd;
    if ($remote_port eq "22") {
        @ssh_copy_cmd = ("ssh-copy-id", "-i", "$key_path.pub", "$remote_user\@$remote_host");
    } else {
        @ssh_copy_cmd = ("ssh-copy-id", "-i", "$key_path.pub", "-p", $remote_port, "$remote_user\@$remote_host");
    }
    
    my $copy_result = system(@ssh_copy_cmd);
    
    if ($copy_result == 0) {
        print "\n${GREEN}✓ SSH key successfully copied to remote system!${NC}\n";
        print "${GREEN}You can now connect using: ssh $remote_user\@$remote_host${NC}\n\n";
        
        # Test the connection
        my $test_conn = prompt("Would you like to test the SSH connection now? [Y/n]: ", "y");
        
        if (lc($test_conn) eq "y") {
            print "\n${YELLOW}Testing SSH connection...${NC}\n";
            my @ssh_test_cmd;
            if ($remote_port eq "22") {
                @ssh_test_cmd = ("ssh", "-o", "StrictHostKeyChecking=accept-new", 
                               "$remote_user\@$remote_host", "echo 'Connection successful!'");
            } else {
                @ssh_test_cmd = ("ssh", "-p", $remote_port, "-o", "StrictHostKeyChecking=accept-new",
                               "$remote_user\@$remote_host", "echo 'Connection successful!'");
            }
            system(@ssh_test_cmd);
        }
    } else {
        print "${RED}Error: Failed to copy SSH key to remote system${NC}\n";
        print "${YELLOW}You can manually copy it later using:${NC}\n";
        print "ssh-copy-id -i $key_path.pub $remote_user\@$remote_host\n";
        exit 1;
    }
} else {
    print "\n${YELLOW}Key generation complete. You can copy it later using:${NC}\n";
    print "ssh-copy-id -i $key_path.pub user\@hostname\n";
}

print "\n${GREEN}=== Setup Complete ===${NC}\n";

# Subroutine to prompt user for input with default value
sub prompt {
    my ($message, $default) = @_;
    print $message;
    my $input = <$input_fh>;
    chomp $input if defined $input;
    return (defined $input && $input ne "") ? $input : $default;
}

# Subroutine to expand tilde (~) in paths
sub expand_tilde {
    my ($path) = @_;
    return $path unless $path =~ /^~/;
    my $home = $ENV{HOME} || (getpwuid($<))[7];
    $path =~ s/^~/$home/;
    return $path;
}

