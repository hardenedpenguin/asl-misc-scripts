#!/usr/bin/env ruby
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
# Removes regular files under /var/log older than N days.
# Run with sufficient privileges (e.g., sudo) to delete protected logs.

require 'find'
require 'optparse'

LOG_ROOT = '/var/log'
DEFAULT_AGE_DAYS = 3
DEFAULT_EXCLUDES = [
  File.join(LOG_ROOT, 'journal')
].freeze

options = {
  age_days: DEFAULT_AGE_DAYS,
  dry_run: false,
  excludes: DEFAULT_EXCLUDES.dup
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [options]"
  opts.on('--days N', Integer, "Delete files older than N days (default: #{DEFAULT_AGE_DAYS})") do |n|
    options[:age_days] = n
  end
  opts.on('--dry-run', 'List files that would be deleted without removing them') do
    options[:dry_run] = true
  end
  opts.on('--exclude PATH', 'Skip PATH and its contents (repeatable)') do |path|
    options[:excludes] << File.expand_path(path)
  end
end.parse!

if Process.uid != 0
  warn 'Warning: not running as root; many files under /var/log may be skipped.'
end

cutoff = Time.now - (options[:age_days] * 24 * 60 * 60)

def excluded?(path, excludes)
  real = File.expand_path(path)
  excludes.any? do |ex|
    ex == real || real.start_with?("#{ex}/")
  end
end

deleted = 0
kept_recent = 0
ignored = 0
errors = 0
would_delete = 0

Find.find(LOG_ROOT) do |path|
  if excluded?(path, options[:excludes])
    Find.prune
    next
  end

  if File.symlink?(path)
    ignored += 1
    Find.prune
    next
  end

  begin
    stat = File.lstat(path)

    if stat.directory?
      next
    end

    unless stat.file?
      ignored += 1
      next
    end

    if stat.mtime < cutoff
      if options[:dry_run]
        puts "would delete: #{path}"
        would_delete += 1
      else
        File.delete(path)
        deleted += 1
      end
    else
      kept_recent += 1
    end
  rescue Errno::EACCES, Errno::EPERM, Errno::ENOENT => e
    warn "Skipping #{path}: #{e.class} #{e.message}"
    errors += 1
  end
end

if options[:dry_run]
  puts "Would delete: #{would_delete}"
else
  puts "Deleted: #{deleted}"
end
puts "Kept (recent files): #{kept_recent}"
puts "Ignored (dirs/special/symlinks): #{ignored}"
puts "Errors: #{errors}"

exit 1 if errors.positive?
