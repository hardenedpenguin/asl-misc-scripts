#!/usr/bin/env perl
use strict;
use warnings;

# Input handle: use /dev/tty when STDIN is piped (e.g. curl | perl)
my $input_fh = \*STDIN;
unless (-t STDIN) {
    if (open my $tty, '<', '/dev/tty') {
        $input_fh = $tty;
    } else {
        die "Error: This script requires an interactive terminal.\nRun: curl -sSL <url> -o script.pl && perl script.pl\n";
    }
}

# Try Term::ReadLine for better input; fallback to simple read
# Pass $input_fh so it works when piped (curl | perl)
my $term;
if (eval { require Term::ReadLine; 1 }) {
    $term = Term::ReadLine->new('Git Config Setup', $input_fh, \*STDOUT);
}

print "=== Git Configuration Setup ===\n\n";
print "This script will help you configure your Git settings.\n";
print "Press Enter to use default values (shown in brackets).\n\n";

sub prompt {
    my ($question, $default) = @_;
    my $prompt_str = $default ? "$question [$default]: " : "$question: ";
    my $answer;
    if ($term) {
        $answer = $term->readline($prompt_str);
    } else {
        print $prompt_str;
        $answer = <$input_fh>;
    }
    chomp($answer) if defined $answer;
    return (defined $answer && $answer ne "") ? $answer : $default || '';
}

sub prompt_yes_no {
    my ($question, $default) = @_;
    $default = $default ? 'y' : 'n';
    my $prompt_str = "$question (y/n) [$default]: ";
    my $answer;
    if ($term) {
        $answer = $term->readline($prompt_str);
    } else {
        print $prompt_str;
        $answer = <$input_fh>;
    }
    chomp($answer) if defined $answer;
    $answer = lc($answer || "");
    return ($answer eq 'y' || $answer eq 'yes' || ($answer eq '' && $default eq 'y'));
}

# Collect configuration
my %config;

print "\n--- User Information ---\n";
$config{user_name} = prompt("Your name");
$config{user_email} = prompt("Your email");

print "\n--- Core Settings ---\n";
$config{editor} = prompt("Preferred editor", "nano");
$config{excludesfile} = prompt("Global gitignore file path", "~/.gitignore_global");
$config{fileMode} = prompt_yes_no("Set fileMode to false (recommended for Windows/WSL)", 1);

print "\n--- Color Settings ---\n";
$config{color_ui} = prompt("Color UI (auto/always/never)", "auto");

print "\n--- Help Settings ---\n";
$config{autocorrect} = prompt("Help autocorrect (0-100, 0=off)", "1");

print "\n--- Push Settings ---\n";
$config{push_default} = prompt("Push default (simple/upstream/current/nothing)", "simple");

print "\n--- Init Settings ---\n";
$config{default_branch} = prompt("Default branch name", "main");

print "\n--- Status Settings ---\n";
$config{show_branch} = prompt_yes_no("Always show branch in status", 1);

print "\n--- Merge Settings ---\n";
$config{merge_tool} = prompt("Merge tool (vimdiff/kdiff3/meld/etc)", "vimdiff");

print "\n--- Credential Settings ---\n";
$config{credential_helper} = prompt("Credential helper", "cache --timeout=3600");

print "\n--- Pull Settings ---\n";
$config{pull_rebase} = prompt_yes_no("Rebase on pull", 1);

print "\n--- GPG Signing ---\n";
$config{sign_commits} = prompt_yes_no("Sign commits with GPG", 0);
if ($config{sign_commits}) {
    $config{gpg_program} = prompt("GPG program path", "gpg");
    $config{signing_key} = prompt("GPG signing key ID (leave empty to auto-detect)");
}

print "\n--- Aliases ---\n";
$config{aliases} = prompt_yes_no("Set up common aliases (st, co, br, ci, lg)", 1);

print "\n--- Review ---\n";
print "\nConfiguration summary:\n";
print "  Name: $config{user_name}\n";
print "  Email: $config{user_email}\n";
print "  Editor: $config{editor}\n";
print "  Sign commits: " . ($config{sign_commits} ? "Yes" : "No") . "\n";
if ($config{sign_commits}) {
    print "  Signing key: " . ($config{signing_key} || "auto-detect") . "\n";
}

unless (prompt_yes_no("\nApply these settings?", 1)) {
    print "Cancelled.\n";
    exit 0;
}

# Generate git config commands
print "\n--- Applying Configuration ---\n";

# User settings
system("git", "config", "--global", "user.name", $config{user_name}) == 0 or die "Failed to set user.name\n";
system("git", "config", "--global", "user.email", $config{user_email}) == 0 or die "Failed to set user.email\n";

# Core settings
system("git", "config", "--global", "core.editor", $config{editor}) == 0 or die "Failed to set core.editor\n";
system("git", "config", "--global", "core.excludesfile", $config{excludesfile}) == 0 or die "Failed to set core.excludesfile\n";
system("git", "config", "--global", "core.fileMode", $config{fileMode} ? "false" : "true") == 0 or die "Failed to set core.fileMode\n";

# Color settings
system("git", "config", "--global", "color.ui", $config{color_ui}) == 0 or die "Failed to set color.ui\n";

# Help settings
system("git", "config", "--global", "help.autocorrect", $config{autocorrect}) == 0 or die "Failed to set help.autocorrect\n";

# Push settings
system("git", "config", "--global", "push.default", $config{push_default}) == 0 or die "Failed to set push.default\n";

# Init settings
system("git", "config", "--global", "init.defaultBranch", $config{default_branch}) == 0 or die "Failed to set init.defaultBranch\n";

# Status settings
if ($config{show_branch}) {
    system("git", "config", "--global", "status.showBranch", "always") == 0 or die "Failed to set status.showBranch\n";
}

# Merge settings
system("git", "config", "--global", "merge.tool", $config{merge_tool}) == 0 or die "Failed to set merge.tool\n";

# Credential settings
system("git", "config", "--global", "credential.helper", $config{credential_helper}) == 0 or die "Failed to set credential.helper\n";

# Pull settings
system("git", "config", "--global", "pull.rebase", $config{pull_rebase} ? "true" : "false") == 0 or die "Failed to set pull.rebase\n";

# GPG signing
if ($config{sign_commits}) {
    system("git", "config", "--global", "commit.gpgsign", "true") == 0 or die "Failed to set commit.gpgsign\n";
    system("git", "config", "--global", "gpg.program", $config{gpg_program}) == 0 or die "Failed to set gpg.program\n";
    if ($config{signing_key}) {
        system("git", "config", "--global", "user.signingkey", $config{signing_key}) == 0 or die "Failed to set user.signingkey\n";
    } else {
        print "Note: No signing key specified. Git will use your default GPG key.\n";
        print "      You can set it later with: git config --global user.signingkey <key-id>\n";
    }
}

# Aliases
if ($config{aliases}) {
    system("git", "config", "--global", "alias.st", "status") == 0 or die "Failed to set alias.st\n";
    system("git", "config", "--global", "alias.co", "checkout") == 0 or die "Failed to set alias.co\n";
    system("git", "config", "--global", "alias.br", "branch") == 0 or die "Failed to set alias.br\n";
    system("git", "config", "--global", "alias.ci", "commit") == 0 or die "Failed to set alias.ci\n";
    system("git", "config", "--global", "alias.lg", "log --oneline --graph --decorate --all") == 0 or die "Failed to set alias.lg\n";
}

print "\n=== Configuration Complete! ===\n";
print "Your Git configuration has been applied.\n";
print "You can review it with: git config --list --global\n";

