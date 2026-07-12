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

def ok(msg) = puts "[OK] #{msg}"
def warn(msg) = puts "[WARN] #{msg}"
def fail(msg) = puts "[FAIL] #{msg}"

def service_active?(unit)
  system('systemctl', 'is-active', '--quiet', unit)
end

def read_gps_conf
  return {} unless File.file?(GPS_CONF)

  conf = {}
  File.foreach(GPS_CONF) do |line|
    next if line.strip.empty? || line.strip.start_with?(';', '#')

    key, value = line.split('=', 2)
    next unless key && value

    conf[key.strip.downcase] = value.strip.delete(';')
  end
  conf
end

issues = 0
warns = 0

puts '=== ASL3 APRS / GPS diagnostic ==='
puts

unless File.file?('/etc/asterisk/rpt.conf')
  fail 'Not an ASL3 node (/etc/asterisk/rpt.conf missing)'
  exit 1
end

unless File.file?(GPS_CONF)
  fail "#{GPS_CONF} missing — run setup-asl3-gps.rb"
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
mobile = !conf['comport'].to_s.empty?
mobile = true if File.file?("/etc/systemd/system/#{BRIDGE_UNIT}")

if conf.empty?
  warn 'Could not parse gps.conf settings'
  warns += 1
else
  puts
  puts 'gps.conf:'
  puts "  call:     #{conf['call'] || '(unset)'}"
  puts "  server:   #{conf['server'] || '(unset)'}"
  puts "  interval: #{conf['interval'] || '(unset)'}"
  puts "  comport:  #{conf['comport'] || '(none — fixed mode)'}"
  puts "  baudrate: #{conf['baudrate'] || '(unset)'}" if conf['baudrate']

  if conf['baudrate'] && conf['baudrate'] != '4800'
    warn "baudrate is #{conf['baudrate']}; app_gps typically needs 4800 on the NMEA bridge"
    warns += 1
  end
end

puts
gps_status = `asterisk -rx 'gps show status' 2>/dev/null`.strip
if gps_status.empty?
  fail 'Could not run: asterisk -rx \'gps show status\''
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

if mobile || File.file?("/etc/systemd/system/#{BRIDGE_UNIT}")
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
      fail "#{BRIDGE_UNIT} not active (common cause: gpspipe broken pipe)"
      issues += 1
    end
  else
    warn "#{BRIDGE_UNIT} unit file missing"
    warns += 1
  end

  if File.exist?(RPT_GPS_PTY)
    ok "#{RPT_GPS_PTY} exists"
  else
    fail "#{RPT_GPS_PTY} missing"
    issues += 1
  end

  if system('command', '-v', 'cgps', out: File::NULL, err: File::NULL)
    puts
    puts 'cgps -s (one sample):'
    system('timeout', '3', 'cgps', '-s')
  end
end

puts
puts "Summary: #{issues} issue(s), #{warns} warning(s)"
exit(issues.positive? ? 1 : 0)
