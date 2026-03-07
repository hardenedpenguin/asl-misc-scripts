#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use File::Temp qw(tempfile);

# Script to create a secure GPG key on Debian 13
# Usage: ./create_gpg_key.pl [--name "Your Name"] [--email "your@email.com"] [--key-type RSA|ED25519] [--expire-days N]

my $name = '';
my $email = '';
my $key_type = 'RSA';
my $expire_days = 0;  # 0 = no expiration
my $help = 0;

GetOptions(
    'name=s'       => \$name,
    'email=s'     => \$email,
    'key-type=s'  => \$key_type,
    'expire-days=i' => \$expire_days,
    'help'        => \$help,
) or die "Error in command line arguments\n";

if ($help) {
    print_help();
    exit 0;
}

# Validate key type
unless ($key_type =~ /^(RSA|ED25519)$/i) {
    die "Error: key-type must be either RSA or ED25519\n";
}

# Check if gpg is installed
unless (system('which gpg > /dev/null 2>&1') == 0) {
    die "Error: gpg is not installed. Please install it with: sudo apt-get install gnupg\n";
}

# Require interactive terminal (fails when piped: curl | perl)
my $input_fh = \*STDIN;
unless (-t STDIN) {
    if (open my $tty, '<', '/dev/tty') {
        $input_fh = $tty;
    } else {
        die "Error: This script requires an interactive terminal.\nRun: curl -sSL <url> -o script.pl && perl script.pl\n";
    }
}

# Get user information if not provided
unless ($name) {
    print "Enter your name (for GPG key): ";
    $name = <$input_fh>;
    chomp $name;
    die "Error: Name cannot be empty\n" unless $name;
}

unless ($email) {
    print "Enter your email address (for GPG key): ";
    $email = <$input_fh>;
    chomp $email;
    die "Error: Email cannot be empty\n" unless $email;
}

# Get passphrase (stty uses /dev/tty when piped)
my $read_passphrase = sub {
    my ($prompt) = @_;
    print $prompt;
    system('stty -echo </dev/tty 2>/dev/null');
    my $line = <$input_fh>;
    chomp $line if defined $line;
    system('stty echo </dev/tty 2>/dev/null');
    print "\n";
    return $line;
};

my $passphrase = $read_passphrase->("Enter passphrase for your GPG key (will be hidden): ");
my $passphrase_confirm = $read_passphrase->("Confirm passphrase: ");

unless ($passphrase eq $passphrase_confirm) {
    die "Error: Passphrases do not match\n";
}

unless (length($passphrase) >= 8) {
    die "Error: Passphrase must be at least 8 characters long\n";
}

# Create temporary batch file for gpg (UNLINK=>0: we unlink after gpg, secure perms)
my ($fh, $batch_file) = tempfile('gpg_batch_XXXXXX', SUFFIX => '.txt', TMPDIR => 1, UNLINK => 0);

# Generate batch file content based on key type
if ($key_type =~ /^RSA$/i) {
    # RSA 4096-bit key (secure and widely compatible)
    print $fh <<EOF;
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: $name
Name-Email: $email
Expire-Date: $expire_days
Passphrase: $passphrase
EOF
} else {
    # Ed25519 key (modern, secure, smaller)
    print $fh <<EOF;
Key-Type: ed25519
Subkey-Type: ed25519
Name-Real: $name
Name-Email: $email
Expire-Date: $expire_days
Passphrase: $passphrase
EOF
}

# Add additional secure settings
print $fh <<EOF;
Preferences: SHA512 SHA384 SHA256 SHA224 AES256 AES192 AES CAST5 ZLIB BZIP2 ZIP Uncompressed
EOF

close $fh;
chmod 0600, $batch_file;

# Ensure .gnupg directory exists with proper permissions
my $gnupg_dir = $ENV{HOME} . '/.gnupg';
unless (-d $gnupg_dir) {
    mkdir $gnupg_dir or die "Error: Cannot create .gnupg directory: $!\n";
}
chmod 0700, $gnupg_dir;

# Generate the key
print "\nGenerating GPG key (this may take a few minutes)...\n";
my $output = `gpg --batch --gen-key "$batch_file" 2>&1`;
my $exit_code = $? >> 8;

# Securely remove batch file (contains passphrase) immediately after use
unlink $batch_file or warn "Warning: Could not remove batch file: $!\n";

if ($exit_code != 0) {
    print STDERR "Error generating GPG key:\n$output\n";
    exit 1;
}

# Get the key ID using Perl regex instead of sed
my $key_list = `gpg --list-keys --keyid-format LONG "$email" 2>/dev/null`;
my $key_id = '';

# Extract key ID from output (format: pub   rsa4096/XXXXXXXX 2024-01-01 [SC])
if ($key_list =~ /^(?:pub|sec)\s+\w+\/([A-F0-9]{16,})/m) {
    $key_id = $1;
}

# If that didn't work, try alternative format
unless ($key_id) {
    if ($key_list =~ /Key fingerprint = ([A-F0-9 ]+)/) {
        my $fingerprint = $1;
        $fingerprint =~ s/\s+//g;
        # Use last 16 characters of fingerprint as short key ID
        $key_id = substr($fingerprint, -16) if length($fingerprint) >= 16;
    }
}

# Last resort: try to get it from gpg directly
unless ($key_id) {
    my $fingerprint = `gpg --fingerprint "$email" 2>/dev/null | grep -A1 "^pub" | tail -1`;
    if ($fingerprint =~ /([A-F0-9]{16,})/) {
        $key_id = substr($1, -16);
    }
}

unless ($key_id) {
    print STDERR "Warning: Could not determine key ID. Key may have been created successfully.\n";
    print "Attempting to list keys to verify creation...\n";
    system("gpg --list-keys --keyid-format LONG \"$email\"");
    exit 0;
}

print "\n✓ GPG key created successfully!\n";
print "  Key ID: $key_id\n";
print "  Name: $name\n";
print "  Email: $email\n";
print "  Type: $key_type\n";
print "\n";

# Display key information
print "Your GPG keys:\n";
system("gpg --list-keys --keyid-format LONG \"$email\"");

print "\nTo export your public key, use:\n";
print "  gpg --armor --export $key_id\n";
print "\nTo export your public key to a file:\n";
print "  gpg --armor --export $key_id > my_public_key.asc\n";

sub print_help {
    print <<EOF;
Usage: $0 [OPTIONS]

Create a secure GPG key for the current user.

OPTIONS:
    --name NAME          Your name for the GPG key
    --email EMAIL        Your email address for the GPG key
    --key-type TYPE      Key type: RSA (default) or ED25519
    --expire-days DAYS   Number of days until key expires (0 = no expiration, default)
    --help               Show this help message

EXAMPLES:
    $0
    $0 --name "John Doe" --email "john\@example.com"
    $0 --name "Jane Doe" --email "jane\@example.com" --key-type ED25519
    $0 --name "Bob Smith" --email "bob\@example.com" --expire-days 365

NOTES:
    - RSA keys are 4096-bit for maximum security and compatibility
    - ED25519 keys are modern, secure, and smaller
    - You will be prompted for a passphrase if not provided via options
    - The script ensures proper permissions on ~/.gnupg directory

EOF
}

