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
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# setup_asl3_gps.rb - Interactive ASL3 GPSD, shared GPS, and APRS setup
#
# gpsd owns the USB receiver (saytime_weather_rb, SkywarnPlus-NG, cgps, etc.).
# app_gps cannot talk to gpsd directly; a systemd bridge replays NMEA to /dev/rptgps.

require 'fileutils'

GPSD_NMEA_BRIDGE_UNIT = '/etc/systemd/system/gpsd-nmea-bridge.service'
RPT_GPS_PTY = '/dev/rptgps'
GPSD_USB_BAUD = 115_200
APP_GPS_BAUD = 4800 # app_gps iospeed; PTY bridge NMEA (not the USB receiver rate)

# APRS defaults for Shari PiHat-class nodes (~5W HT, rubber duck, mobile/low HAAT).
# PHG digits map to APRS tables: power=sqrt(W), height=log2(HAAT/10 ft), gain=dBi.
DEFAULT_APRS_INTERVAL = 180 # seconds; easier on Pi CPU and APRS-IS than 60s
DEFAULT_APRS_ICON = '>'       # primary table: small car (typical mobile GPS node)
DEFAULT_APRS_POWER = 2        # 4W (closest PHG step for ~3-5W radios)
DEFAULT_APRS_HEIGHT = 1       # ~20 ft HAAT
DEFAULT_APRS_GAIN = 1         # 1 dBi (rubber duck / short antenna)
DEFAULT_APRS_DIR = 0          # omni

def interactive_input
  return $stdin if $stdin.tty?

  File.open('/dev/tty', 'r')
rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM
  abort <<~MSG.strip
    ERROR: Interactive terminal required.
    Run from a TTY: curl -sSL https://raw.githubusercontent.com/hardenedpenguin/asl-misc-scripts/refs/heads/main/setup-asl3-gps.rb | sudo ruby
  MSG
end

def ask(input, prompt, default: nil)
  if default
    print "#{prompt} [default: #{default}]: "
  else
    print "#{prompt}: "
  end
  line = input.gets
  abort 'ERROR: Input interrupted.' if line.nil?

  value = line.chomp.strip
  value.empty? && !default.nil? ? default : value
end

def calculate_aprs_passcode(callsign)
  call = callsign.split('-', 2).first.upcase
  code = 0x73e2
  call.each_char.with_index { |ch, i| code ^= ch.ord << (i.even? ? 8 : 0) }
  (code & 0x7fff).to_s
end

def beacon_comment(user_comment, rf_freq, rf_tone)
  return user_comment if rf_freq.empty?

  parts = ["#{rf_freq} MHz"]
  unless rf_tone.empty? || rf_tone == '0' || rf_tone == '0.0'
    parts << "T#{rf_tone}"
  end
  parts << user_comment unless user_comment.empty?
  parts.join(' ')
end

def run!(*args)
  return if system(*args)

  abort "ERROR: Command failed: #{args.join(' ')}"
end

def warn_unless_gps_device!(device)
  return if File.exist?(device)

  puts "[WARN] GPS device #{device} not found. Plug in the receiver; gpsd will start when it appears."
end

def enable_app_gps!(modules_conf)
  return unless File.exist?(modules_conf)

  content = File.read(modules_conf)
  return if content.match?(/^\s*load\s*[=:>]+\s*app_gps\.so\b/im)

  updated = content
         .gsub(/^\s*;+\s*noload\s*[=:>]+\s*app_gps\.so.*$/i, 'load = app_gps.so                     ; GPS Interface')
         .gsub(/^\s*noload\s*[=:>]+\s*app_gps\.so.*$/i, 'load = app_gps.so                     ; GPS Interface')

  if updated == content
    puts '[WARN] Could not enable app_gps.so automatically; set load = app_gps.so in modules.conf'
    return
  end

  FileUtils.cp(modules_conf, "#{modules_conf}.bak")
  File.write(modules_conf, updated)
  puts "[OK] Enabled app_gps.so in #{modules_conf}"
end

def install_gpsd_nmea_bridge!
  unit = <<~UNIT
    [Unit]
    Description=Replay gpsd NMEA to #{RPT_GPS_PTY} for app_gps
    Documentation=man:gpspipe(1) man:socat(1)
    After=gpsd.service
    Requires=gpsd.service
    PartOf=gpsd.service

    [Service]
    Type=simple
    Restart=always
    RestartSec=5
    ExecStartPre=-/bin/rm -f #{RPT_GPS_PTY}
    ExecStart=/bin/sh -c 'exec /usr/bin/gpspipe -r | /usr/bin/socat - PTY,link=#{RPT_GPS_PTY},raw,echo=0,group=dialout,mode=660,waitslave'

    [Install]
    WantedBy=multi-user.target
  UNIT

  File.write(GPSD_NMEA_BRIDGE_UNIT, unit)
  run!('systemctl', 'daemon-reload')
  run!('systemctl', 'enable', 'gpsd-nmea-bridge.service')
  run!('systemctl', 'restart', 'gpsd-nmea-bridge.service')
  puts "[OK] Installed gpsd NMEA bridge -> #{RPT_GPS_PTY}"
end

def install_asterisk_after_gps_bridge!
  dir = '/etc/systemd/system/asterisk.service.d'
  dropin = File.join(dir, 'gps-bridge.conf')
  FileUtils.mkdir_p(dir)
  File.write(dropin, <<~DROPIN)
    [Unit]
    After=gpsd-nmea-bridge.service
    Wants=gpsd-nmea-bridge.service
  DROPIN
  run!('systemctl', 'daemon-reload')
  puts '[OK] Asterisk will start after gpsd NMEA bridge on boot.'
end

def wait_for_rptgps!(timeout_sec: 15)
  timeout_sec.times do
    return if File.exist?(RPT_GPS_PTY)

    sleep 1
  end
  abort "ERROR: #{RPT_GPS_PTY} did not appear; check: systemctl status gpsd-nmea-bridge.service"
end

def ensure_asterisk_dialout!
  return unless File.exist?('/etc/passwd')

  dialout = File.read('/etc/group').lines.find { |l| l.start_with?('dialout:') }
  return unless dialout

  members = dialout.split(':').fetch(3, '').split(',')
  return if members.include?('asterisk')

  system('usermod -aG dialout asterisk')
  puts '[OK] Added user asterisk to group dialout (for APRS GPS PTY)'
end

def hint_saytime_gpsd!
  weather_ini = '/etc/asterisk/local/weather.ini'
  return unless File.exist?(weather_ini)

  content = File.read(weather_ini)
  return if content.include?('location_source')

  puts "\nNote: saytime_weather_rb: add to #{weather_ini} under [weather] for GPS location:"
  puts '    location_source = gps'
  puts '    gpsd_host = 127.0.0.1'
  puts '    gpsd_port = 2947'
end

def verify_installation!
  notes = []
  notes << 'gpsd-nmea-bridge.service is not active' unless system('systemctl', 'is-active', '--quiet', 'gpsd-nmea-bridge.service')
  notes << "#{RPT_GPS_PTY} is missing" unless File.exist?(RPT_GPS_PTY)

  gps_status = `asterisk -rx 'gps show status' 2>/dev/null`
  if gps_status.include?('Locked')
    puts '[OK] Post-install: GPS locked in Asterisk.'
  elsif gps_status.include?('Unlocked')
    notes << 'GPS serial open but no fix yet (allow time for satellite lock and clear sky)'
  else
    notes << 'could not read gps show status from Asterisk'
  end

  return if notes.empty?

  puts "\nPost-install notes:"
  notes.each { |note| puts "  - #{note}" }
end

abort 'ERROR: This script must be run as root (sudo).' if Process.uid != 0

input = interactive_input

puts '===================================================='
puts '   ASL3 INTERACTIVE GPSD & APRS CONFIGURATION TOOL  '
puts '===================================================='
puts ''

base_callsign = ask(input, 'Enter your FCC Callsign (e.g., W5GLE)').upcase
abort 'ERROR: Callsign cannot be blank.' if base_callsign.empty?

aprs_passcode = calculate_aprs_passcode(base_callsign)
puts "APRS passcode for #{base_callsign}: #{aprs_passcode}"

ssid = ask(input, 'Enter APRS SSID suffix', default: '10')
full_callsign = "#{base_callsign}-#{ssid}"

gps_device = ask(input, 'Enter USB GPS serial device for gpsd', default: '/dev/ttyACM0')
warn_unless_gps_device!(gps_device)

rf_freq = ask(input, 'Enter node RF frequency in MHz (e.g., 443.075)')
abort 'ERROR: RF frequency is required for the beacon comment.' if rf_freq.empty?

rf_tone = ask(input, 'Enter CTCSS tone in Hz (e.g., 103.5, or 0.0 for none)', default: '0.0')

comment = ask(input, 'Enter short map beacon comment', default: 'ASL3 Node')
map_comment = beacon_comment(comment, rf_freq, rf_tone)

interval_str = ask(input, 'APRS beacon interval in seconds', default: DEFAULT_APRS_INTERVAL.to_s)
interval = interval_str.to_i
abort 'ERROR: APRS beacon interval must be at least 30 seconds.' if interval < 30

input.close unless input.equal?($stdin)

puts "\n--- System update & package installation ---"
unless system('env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'update') &&
       system('env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', 'gpsd', 'gpsd-clients', 'socat')
  abort 'ERROR: Package installation failed.'
end

puts "\n--- Writing /etc/default/gpsd ---"
gpsd_config = <<~GPSD
  # /etc/default/gpsd - written by setup_asl3_gps.rb
  START_DAEMON="true"
  USBAUTO="false"
  DEVICES="#{gps_device}"
  # No -b: allow gpsd to use native u-blox binary (readonly blocks satellite config).
  GPSD_OPTIONS="-n -s #{GPSD_USB_BAUD}"
  OPTIONS=""
GPSD

File.write('/etc/default/gpsd', gpsd_config)
unless system('systemctl', 'enable', 'gpsd.socket', 'gpsd.service')
  run!('systemctl', 'enable', 'gpsd.service')
end
run!('systemctl', 'restart', 'gpsd.service')
puts '[OK] gpsd enabled (shared GPS on localhost:2947).'

puts "\n--- APRS NMEA bridge (gpsd -> app_gps) ---"
ensure_asterisk_dialout!
install_gpsd_nmea_bridge!
install_asterisk_after_gps_bridge!
wait_for_rptgps!

puts "\n--- Writing /etc/asterisk/gps.conf ---"
asterisk_gps_config = <<~ASTERISK
  ; /etc/asterisk/gps.conf - written by setup_asl3_gps.rb
  ; Position NMEA comes from gpsd via #{RPT_GPS_PTY} (gpsd-nmea-bridge.service).

  [general]
  call = #{full_callsign}
  password = #{aprs_passcode}
  server = rotate.aprs2.net
  port = 14580
  interval = #{interval}
  icon = #{DEFAULT_APRS_ICON}

  comport = #{RPT_GPS_PTY}
  baudrate = #{APP_GPS_BAUD}

  ; PHG tuned for Shari PiHat-class nodes (~5W HT, rubber duck, omni, low HAAT)
  power = #{DEFAULT_APRS_POWER}
  height = #{DEFAULT_APRS_HEIGHT}
  gain = #{DEFAULT_APRS_GAIN}
  dir = #{DEFAULT_APRS_DIR}
  comment = #{map_comment}
ASTERISK

gps_conf = '/etc/asterisk/gps.conf'
if File.exist?(gps_conf)
  FileUtils.cp(gps_conf, "#{gps_conf}.bak")
  puts 'Note: Existing gps.conf backed up to gps.conf.bak'
end
File.write(gps_conf, asterisk_gps_config)
puts '[OK] /etc/asterisk/gps.conf written.'

enable_app_gps!('/etc/asterisk/modules.conf')

puts "\n--- Restarting Asterisk ---"
run!('systemctl', 'restart', 'asterisk')

hint_saytime_gpsd!
verify_installation!

puts "\n===================================================="
puts 'Configuration complete!'
puts '===================================================='
puts 'Shared GPS: gpsd on 127.0.0.1:2947 (saytime_weather_rb, SkywarnPlus-NG, cgps)'
puts "APRS: app_gps reads NMEA from #{RPT_GPS_PTY} (gpsd-nmea-bridge.service)"
puts ''
puts '1. Check gpsd: cgps -s   (or gpsmon)'
puts "2. Check bridge: ls -l #{RPT_GPS_PTY}"
puts '3. Asterisk CLI: gps show status'
puts "4. Map: https://aprs.fi/#!call=#{full_callsign}"
puts '   (Allow a few minutes after satellite lock.)'
puts '===================================================='
