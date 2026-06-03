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
# Removes regular files under /var/log older than 3 days.
# Run with sufficient privileges (e.g., sudo) to delete protected logs.

require "find"

LOG_ROOT = "/var/log".freeze
AGE_DAYS = 3

cutoff = Time.now - (AGE_DAYS * 24 * 60 * 60)

deleted = 0
kept_recent = 0 # regular files, still within retention window
ignored = 0     # directories and non-regular files (not candidates for deletion)
errors = 0

Find.find(LOG_ROOT) do |path|
  begin
    stat = File.lstat(path)

    # Skip directories and non-regular files (symlinks, sockets, etc.)
    if stat.directory? || !stat.file?
      ignored += 1
      next
    end

    if stat.mtime < cutoff
      File.delete(path)
      deleted += 1
    else
      kept_recent += 1
    end
  rescue Errno::EACCES, Errno::EPERM, Errno::ENOENT => e
    warn "Skipping #{path}: #{e.class} #{e.message}"
    errors += 1
  end
end

puts "Deleted: #{deleted}"
puts "Kept (recent files): #{kept_recent}"
puts "Ignored (dirs/special): #{ignored}"
puts "Errors: #{errors}"
