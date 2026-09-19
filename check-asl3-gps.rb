#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Copyright (C) 2026 Jory A. Pratt, W5GLE <geekypenguin@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# check-asl3-gps.rb - Read-only APRS/GPS diagnostic for ASL3 nodes

GPS_CONF = '/etc/asterisk/gps.conf'
MODULES_CONF = '/etc/asterisk/modules.conf'
LEGACY_BRIDGE_UNIT = 'gpsd-nmea-bridge.service'
LEGACY_BRIDGE_SCRIPT = '/usr/local/sbin/gpsd-nmea-bridge'
LEGACY_GPS_BRIDGE_DROPIN = '/etc/systemd/system/asterisk.service.d/gps-bridge.conf'
ASTERISK_GPSD_DROPIN = '/etc/systemd/system/asterisk.service.d/gpsd.conf'
RPT_GPS_PTY = '/dev/rptgps'
SETUP_CURL = 'curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup-asl3-gps.rb | sudo ruby'
CHECK_CURL = 'curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/check-asl3-gps.rb | sudo ruby'

def ok(msg) = puts "[OK] #{msg}"
def warn(msg) = puts "[WARN] #{msg}"
def fail(msg) = puts "[FAIL] #{msg}"

def service_active?(unit)
  system('systemctl', 'is-active', '--quiet', unit)
end

def asterisk_binary
  candidates = %w[
    /usr/sbin/asterisk
    /usr/bin/asterisk
    /usr/local/sbin/asterisk
    /usr/local/bin/asterisk
  ]
  found = candidates.find { |path| File.executable?(path) }
  return found if found

  path_dirs = ENV.fetch('PATH', '').split(':') + %w[/usr/sbin /sbin]
  path_dirs.uniq.each do |dir|
    candidate = File.join(dir, 'asterisk')
    return candidate if File.executable?(candidate)
  end
  nil
end

def read_gps_conf
  return {} unless File.file?(GPS_CONF)

  conf = {}
  File.foreach(GPS_CONF) do |line|
    next if line.strip.empty? || line.strip.start_with?(';', '#')

    key, value = line.split('=', 2)
    next unless key && value

    # Strip inline comments (value ; comment) and surrounding whitespace
    value = value.split(';', 2).first.to_s.strip
    conf[key.strip.downcase] = value
  end
  conf
end

def asterisk_command(cmd)
  bin = asterisk_binary
  return ['', false] if bin.nil?

  output = `#{bin} -rx #{cmd} 2>&1`.strip
  [output, $?.success?]
end

issues = 0
warns = 0
root = Process.uid.zero?

puts '=== ASL3 APRS / GPS diagnostic ==='
puts

unless root
  warn 'Not running as root — Asterisk CLI checks will be skipped.'
  puts "      For full results: #{CHECK_CURL}"
  puts
end

unless File.file?('/etc/asterisk/rpt.conf')
  fail 'Not an ASL3 node (/etc/asterisk/rpt.conf missing)'
  exit 1
end

unless File.file?(GPS_CONF)
  fail "#{GPS_CONF} missing — run: #{SETUP_CURL}"
  issues += 1
else
  ok "#{GPS_CONF} present"
end

if File.file?(MODULES_CONF)
  modules = File.read(MODULES_CONF)
  if modules.match?(/^\s*load\s*[=:>]+\s*app_gps\.so\b/im)
    ok 'app_gps.so enabled in modules.conf'
  elsif modules.match?(/^\s*noload\s*[=:>]+\s*app_gps\.so\b/im)
    fail 'app_gps.so is noload in modules.conf'
    issues += 1
  else
    warn 'app_gps.so not found in modules.conf'
    warns += 1
  end
else
  fail "#{MODULES_CONF} missing"
  issues += 1
end

conf = read_gps_conf
gpsd_host = conf['gpsd_host'].to_s
gpsd_port = conf['gpsd_port'].to_s
comport = conf['comport'].to_s
legacy_bridge = File.file?("/etc/systemd/system/#{LEGACY_BRIDGE_UNIT}") ||
                File.executable?(LEGACY_BRIDGE_SCRIPT) ||
                File.exist?(RPT_GPS_PTY)
mobile = !gpsd_host.empty? || !comport.empty? || legacy_bridge

if conf.empty?
  warn 'Could not parse gps.conf settings'
  warns += 1
else
  puts
  puts 'gps.conf:'
  puts "  call:      #{conf['call'] || '(unset)'}"
  puts "  server:    #{conf['server'] || '(unset)'}"
  puts "  interval:  #{conf['interval'] || '(unset)'}"
  if gpsd_host.empty?
    puts '  gpsd_host: (none — fixed mode or legacy serial)'
  else
    puts "  gpsd_host: #{gpsd_host}"
    puts "  gpsd_port: #{gpsd_port.empty? ? '2947 (default)' : gpsd_port}"
  end
  puts "  comport:   #{comport}" unless comport.empty?
  puts "  baudrate:  #{conf['baudrate']}" if conf['baudrate']

  if !gpsd_host.empty? && !comport.empty?
    warn 'both gpsd_host and comport are set; Asterisk ignores comport when gpsd_host is present'
    warns += 1
  end

  if gpsd_host.empty? && !comport.empty?
    warn "comport=#{comport} is the legacy serial path; mobile setup now uses native gpsd_host"
    puts "      Re-run mobile setup: #{SETUP_CURL}"
    warns += 1
  end
end

puts
if root
  if asterisk_binary.nil?
    fail 'asterisk binary not found (expected /usr/sbin/asterisk)'
    issues += 1
  else
    gps_status, ok_cmd = asterisk_command("'gps show status'")
    if !ok_cmd || gps_status.empty?
      fail "Could not run Asterisk GPS status#{gps_status.empty? ? '' : ": #{gps_status}"}"
      issues += 1
    else
      puts 'Asterisk gps show status:'
      gps_status.each_line { |line| puts "  #{line.chomp}" }

      if gps_status.include?('Locked')
        ok 'GPS locked in Asterisk'
      elsif gps_status.include?('Unlocked')
        warn 'GPS connected but no fix (check sky view / antenna / gpsd)'
        warns += 1
      elsif gps_status.include?('default')
        ok 'Using fixed default position (expected for fixed-mode nodes)'
      end
    end
  end
else
  puts 'Asterisk gps show status: (skipped — requires root/sudo)'
end

if mobile
  puts
  puts 'Mobile / gpsd path:'

  if service_active?('gpsd.service')
    ok 'gpsd.service active'
  else
    fail 'gpsd.service not active'
    issues += 1
  end

  if gpsd_host.empty?
    fail 'gpsd_host missing from gps.conf (required for native gpsd mobile mode)'
    puts "      Re-run mobile setup: #{SETUP_CURL}"
    issues += 1
  elsif gpsd_host != '127.0.0.1' && gpsd_host != 'localhost'
    warn "gpsd_host is #{gpsd_host} (setup defaults to 127.0.0.1)"
    warns += 1
  else
    ok "gpsd_host=#{gpsd_host}"
  end

  if File.file?(ASTERISK_GPSD_DROPIN)
    dropin = File.read(ASTERISK_GPSD_DROPIN)
    if dropin.include?('gpsd.service')
      ok 'Asterisk gpsd drop-in present'
    else
      warn "#{ASTERISK_GPSD_DROPIN} is present but does not reference gpsd.service"
      warns += 1
    end
  else
    warn "#{ASTERISK_GPSD_DROPIN} missing (Asterisk may start before gpsd)"
    puts "      Re-run mobile setup: #{SETUP_CURL}"
    warns += 1
  end

  if legacy_bridge || File.file?(LEGACY_GPS_BRIDGE_DROPIN)
    warn 'Legacy NMEA bridge pieces still present (/dev/rptgps path)'
    puts "      Re-run mobile setup to remove them: #{SETUP_CURL}"
    warns += 1
  end

  if File.executable?('/usr/bin/cgps') || File.executable?('/usr/bin/gpspipe')
    puts
    puts 'Quick gpsd check (gpspipe -w, one TPV sample):'
    system('timeout', '3', 'gpspipe', '-w', '-n', '5')
  end
end

puts
puts "Summary: #{issues} issue(s), #{warns} warning(s)"
exit(issues.positive? ? 1 : 0)
