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
RPT_GPS_PTY = '/dev/rptgps'
BRIDGE_UNIT = 'gpsd-nmea-bridge.service'
BRIDGE_SCRIPT = '/usr/local/sbin/gpsd-nmea-bridge'
ASTERISK_GPS_BRIDGE_DROPIN = '/etc/systemd/system/asterisk.service.d/gps-bridge.conf'
APP_GPS_BAUD = '4800'
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
comport = conf['comport'].to_s
bridge_configured = File.file?("/etc/systemd/system/#{BRIDGE_UNIT}")
mobile = !comport.empty? || bridge_configured
using_bridge_pty = comport == RPT_GPS_PTY || comport.empty? && bridge_configured

if conf.empty?
  warn 'Could not parse gps.conf settings'
  warns += 1
else
  puts
  puts 'gps.conf:'
  puts "  call:     #{conf['call'] || '(unset)'}"
  puts "  server:   #{conf['server'] || '(unset)'}"
  puts "  interval: #{conf['interval'] || '(unset)'}"
  puts "  comport:  #{comport.empty? ? '(none — fixed mode)' : comport}"
  puts "  baudrate: #{conf['baudrate'] || '(unset)'}" if conf['baudrate']

  if !comport.empty? && comport != RPT_GPS_PTY
    warn "comport is #{comport}; mobile setup uses #{RPT_GPS_PTY} (gpsd NMEA bridge)"
    puts "      Re-run mobile setup: #{SETUP_CURL}"
    warns += 1
  end

  if using_bridge_pty && conf['baudrate'] && conf['baudrate'] != APP_GPS_BAUD
    warn "baudrate is #{conf['baudrate']}; app_gps needs #{APP_GPS_BAUD} on the NMEA bridge (#{RPT_GPS_PTY})"
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
        warn 'GPS serial open but no fix (check sky view / antenna)'
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

  if File.file?("/etc/systemd/system/#{BRIDGE_UNIT}")
    if service_active?(BRIDGE_UNIT)
      ok "#{BRIDGE_UNIT} active"
    else
      fail "#{BRIDGE_UNIT} not active (check: systemctl status #{BRIDGE_UNIT})"
      issues += 1
    end

    unit = File.read("/etc/systemd/system/#{BRIDGE_UNIT}")
    if unit.include?('gpspipe -r |') || unit.include?('ExecStartPre=-/bin/rm -f /dev/rptgps')
      warn "#{BRIDGE_UNIT} uses the legacy inline gpspipe|socat unit; upgrade with mobile setup"
      puts "      #{SETUP_CURL}"
      warns += 1
    elsif !unit.include?(BRIDGE_SCRIPT)
      warn "#{BRIDGE_UNIT} does not reference #{BRIDGE_SCRIPT}"
      warns += 1
    end
  else
    fail "#{BRIDGE_UNIT} unit file missing"
    puts "      Re-run mobile setup: #{SETUP_CURL}"
    issues += 1
  end

  if File.executable?(BRIDGE_SCRIPT)
    ok "#{BRIDGE_SCRIPT} installed"
  else
    fail "#{BRIDGE_SCRIPT} missing or not executable"
    puts "      Re-run mobile setup: #{SETUP_CURL}"
    issues += 1
  end

  if File.file?(ASTERISK_GPS_BRIDGE_DROPIN)
    dropin = File.read(ASTERISK_GPS_BRIDGE_DROPIN)
    if dropin.include?('Requires=gpsd-nmea-bridge.service') && dropin.include?(RPT_GPS_PTY)
      ok 'Asterisk gps-bridge drop-in waits for /dev/rptgps'
    else
      warn "#{ASTERISK_GPS_BRIDGE_DROPIN} is present but looks outdated"
      puts "      Re-run mobile setup: #{SETUP_CURL}"
      warns += 1
    end
  else
    warn "#{ASTERISK_GPS_BRIDGE_DROPIN} missing (Asterisk may start before /dev/rptgps exists)"
    puts "      Re-run mobile setup: #{SETUP_CURL}"
    warns += 1
  end

  if File.exist?(RPT_GPS_PTY)
    ok "#{RPT_GPS_PTY} exists"
  else
    fail "#{RPT_GPS_PTY} missing"
    issues += 1
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
