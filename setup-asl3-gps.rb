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
# setup-asl3-gps.rb - Interactive ASL3 APRS setup (fixed or mobile)
#
# Configures app_gps for APRS-IS beacons on AllStarLink v3.
# Fixed:  lat/lon/elev only (no gpsd; repeaters, hubs, radioless nodes)
# Mobile: gpsd + NMEA bridge to /dev/rptgps (shared with saytime, SkywarnPlus, etc.)

require 'fileutils'

GPSD_NMEA_BRIDGE_UNIT = '/etc/systemd/system/gpsd-nmea-bridge.service'
GPSD_NMEA_BRIDGE_SCRIPT = '/usr/local/sbin/gpsd-nmea-bridge'
ASTERISK_GPS_BRIDGE_DROPIN = '/etc/systemd/system/asterisk.service.d/gps-bridge.conf'
RPT_GPS_PTY = '/dev/rptgps'
GPSD_USB_BAUD = 115_200
APP_GPS_BAUD = 4800

MASKED_SECRET = '*****'

APRS_SERVERS = {
  'rotate' => 'rotate.aprs2.net',
  'noam' => 'noam.aprs2.net',
  'soam' => 'soam.aprs2.net',
  'euro' => 'euro.aprs2.net',
  'asia' => 'asia.aprs2.net',
  'aunz' => 'aunz.aprs2.net'
}.freeze

# APRS PHG digit tables (single digit 0-9 in gps.conf).
# See http://www.aprs.org/aprsdos-pix/phg.txt
PHG_POWER_WATTS = [0, 1, 4, 9, 16, 25, 36, 49, 64, 81].freeze
PHG_HEIGHT_FEET = [10, 20, 40, 80, 160, 320, 640, 1280, 2560, 5120].freeze
PHG_GAIN_DBI    = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].freeze
PHG_DIR_DEGREES = ['omni', 45, 90, 135, 180, 225, 270, 315, 360, 'n/a'].freeze

# Decimal places written to gps.conf (matches app_gps template conventions).
LAT_LON_DECIMALS = 4   # ~11 m position precision
ELEV_DECIMALS = 1        # meters above sea level
FREQ_DECIMALS = 3        # MHz (e.g. 443.075)
TONE_DECIMALS = 1        # Hz (e.g. 103.5)

PRESETS = {
  'fixed' => {
    interval: 1800,
    icon: '-',
    icontable: '/',
    power: 3,
    height: 5,
    gain: 3,
    dir: 0,
    comment: 'ASL3 Node'
  },
  'mobile' => {
    interval: 180,
    icon: '>',
    icontable: '/',
    power: 2,
    height: 1,
    gain: 1,
    dir: 0,
    comment: 'ASL3 Mobile Node'
  }
}.freeze

def interactive_input
  return $stdin if $stdin.tty?

  File.open('/dev/tty', 'r')
rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM
  abort <<~MSG.strip
    ERROR: Interactive terminal required.
    Run from a TTY: sudo ruby #{File.basename($PROGRAM_NAME)}
  MSG
end

def ask(input, prompt, default: nil)
  suffix = default.nil? ? '' : " [default: #{default}]"
  print "#{prompt}#{suffix}: "
  line = input.gets
  abort 'ERROR: Input interrupted.' if line.nil?

  value = line.chomp.strip
  value.empty? && !default.nil? ? default.to_s : value
end

def ask_yes_no(input, prompt, default: true)
  default_label = default ? 'Y/n' : 'y/N'
  answer = ask(input, "#{prompt} (#{default_label})", default: nil)
  return default if answer.empty?

  answer.match?(/\A[Yy]/)
end

def ask_choice(input, prompt, choices, default:)
  puts prompt
  choices.each_with_index do |choice, idx|
    marker = choice == default ? ' (default)' : ''
    puts "  #{idx + 1}) #{choice}#{marker}"
  end
  answer = ask(input, 'Choose', default: '1')
  idx = answer.to_i
  return choices[idx - 1] if idx.between?(1, choices.length)

  default
end

def calculate_aprs_passcode(callsign)
  call = callsign.split('-', 2).first.upcase
  code = 0x73e2
  call.each_char.with_index { |ch, i| code ^= ch.ord << (i.even? ? 8 : 0) }
  (code & 0x7fff).to_s
end

def format_decimal(value, places)
  format("%.#{places}f", value.to_f)
end

def ask_decimal(input, prompt, places:, example:, default: nil, required: false)
  puts "  Use #{places} decimal place#{'s' unless places == 1} (e.g. #{example})"
  raw = ask(input, prompt, default: default)
  abort "ERROR: #{prompt} is required." if required && raw.empty?

  value = raw.to_f
  abort "ERROR: #{prompt} must be a number." unless value.finite?

  formatted = format_decimal(value, places)
  puts "  => stored as #{formatted}" unless raw == formatted
  formatted
end

def nearest_digit(values, target)
  target = target.to_f
  best = 0
  best_diff = Float::INFINITY
  values.each_with_index do |value, idx|
    diff = (value.to_f - target).abs
    next unless diff < best_diff

    best = idx
    best_diff = diff
  end
  best
end

def phg_power_label(digit)
  watts = PHG_POWER_WATTS.fetch(digit)
  watts.zero? ? 'comment-only (power=0 sends comment without PHG)' : "#{watts} W"
end

def phg_height_label(digit)
  "#{PHG_HEIGHT_FEET.fetch(digit)} ft HAAT"
end

def phg_gain_label(digit)
  "#{PHG_GAIN_DBI.fetch(digit)} dBi"
end

def phg_dir_label(digit)
  PHG_DIR_DEGREES.fetch(digit).to_s
end

def print_phg_table(name, values, unit)
  puts "  #{name} digit => APRS value"
  values.each_with_index do |value, digit|
    puts format('    %d => %s %s', digit, value, unit)
  end
end

def ask_phg_digit(input, name, values, unit, default_digit, real_prompt: nil)
  puts
  puts "--- #{name} (gps.conf: single digit 0-9) ---"
  print_phg_table(name, values, unit)
  puts
  puts "Default for this setup: #{default_digit} => #{values.fetch(default_digit)} #{unit}"
  raw = ask(input, "Enter #{name.downcase} digit (0-9), or a real #{real_prompt || unit} value", default: default_digit.to_s)

  if raw.match?(/\A\d\z/)
    digit = raw.to_i
  else
    digit = nearest_digit(values, raw)
    puts "  => nearest digit #{digit} (#{values.fetch(digit)} #{unit})"
  end

  unless digit.between?(0, 9)
    abort "ERROR: #{name} must be a digit 0-9 or a numeric #{unit} value."
  end

  digit
end

def ask_elevation_meters(input, default:)
  puts
  puts '--- Antenna elevation (gps.conf: elev) ---'
  puts '  This is height above sea level in METERS — NOT HAAT.'
  puts '  HAAT is configured separately via the height PHG digit above.'
  ask_decimal(
    input,
    'Enter antenna elevation in meters',
    places: ELEV_DECIMALS,
    example: '123.4',
    default: default
  ).to_f
end

def ask_coordinates(input, mobile:)
  puts
  if mobile
    puts '--- GPS fallback position (used when receiver has no satellite lock) ---'
  else
    puts '--- Fixed position ---'
  end
  puts "  gps.conf stores lat/lon with #{LAT_LON_DECIMALS} decimal places (~11 m precision)."
  lat = ask_decimal(
    input,
    'Latitude in decimal degrees (+N)',
    places: LAT_LON_DECIMALS,
    example: '32.9143',
    required: true
  ).to_f
  lon = ask_decimal(
    input,
    'Longitude in decimal degrees (-W for US)',
    places: LAT_LON_DECIMALS,
    example: '-97.1169',
    required: true
  ).to_f
  abort 'ERROR: Latitude must be between -90 and 90.' unless lat.between?(-90, 90)
  abort 'ERROR: Longitude must be between -180 and 180.' unless lon.between?(-180, 180)

  [lat, lon]
end

def beacon_comment(user_comment, rf_freq, rf_tone)
  return user_comment if rf_freq.empty?

  parts = ["#{rf_freq}MHz"]
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

def require_asl3!
  abort 'ERROR: Not an ASL3 node: /etc/asterisk/rpt.conf missing.' unless File.file?('/etc/asterisk/rpt.conf')
  abort 'ERROR: Not an ASL3 node: /etc/asterisk/modules.conf missing.' unless File.file?('/etc/asterisk/modules.conf')
  abort 'ERROR: asterisk not found in PATH.' unless system('command', '-v', 'asterisk', out: File::NULL, err: File::NULL)
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
    FileUtils.cp(modules_conf, "#{modules_conf}.bak") if File.exist?(modules_conf)
    File.open(modules_conf, 'a') do |f|
      f.puts
      f.puts '; Added by setup-asl3-gps.rb'
      f.puts 'load = app_gps.so                     ; GPS Interface'
    end
    puts "[OK] Appended load app_gps.so to #{modules_conf}"
    return
  end

  FileUtils.cp(modules_conf, "#{modules_conf}.bak")
  File.write(modules_conf, updated)
  puts "[OK] Enabled app_gps.so in #{modules_conf}"
end

def gpsd_nmea_bridge_script_body
  # curl | ruby has no sibling files; use the __END__ payload bundled in this script.
  repo_script = File.expand_path('gpsd-nmea-bridge', File.dirname($PROGRAM_NAME))
  return File.read(repo_script) if $PROGRAM_NAME != '-' && File.file?(repo_script)

  body = DATA.read
  abort 'ERROR: gpsd-nmea-bridge payload missing from setup-asl3-gps.rb' if body.strip.empty?

  body
end

def install_gpsd_nmea_bridge!
  FileUtils.mkdir_p(File.dirname(GPSD_NMEA_BRIDGE_SCRIPT))
  File.write(GPSD_NMEA_BRIDGE_SCRIPT, gpsd_nmea_bridge_script_body)
  File.chmod(0o755, GPSD_NMEA_BRIDGE_SCRIPT)

  unit = <<~UNIT
    [Unit]
    Description=Replay gpsd NMEA to #{RPT_GPS_PTY} for app_gps
    Documentation=man:gpspipe(1) man:socat(1)
    After=gpsd.service
    Requires=gpsd.service
    PartOf=gpsd.service

    [Service]
    Type=simple
    RuntimeDirectory=gpsd-nmea-bridge
    RuntimeDirectoryMode=0755
    Restart=always
    RestartSec=1
    ExecStart=#{GPSD_NMEA_BRIDGE_SCRIPT}
    ExecStartPost=/bin/bash -c 'for i in $(seq 1 50); do [ -e #{RPT_GPS_PTY} ] && exit 0; sleep 0.1; done; echo "timed out waiting for #{RPT_GPS_PTY}"; exit 1'

    [Install]
    WantedBy=multi-user.target
  UNIT

  File.write(GPSD_NMEA_BRIDGE_UNIT, unit)
  run!('systemctl', 'daemon-reload')
  run!('systemctl', 'enable', 'gpsd-nmea-bridge.service')
  run!('systemctl', 'restart', 'gpsd-nmea-bridge.service')
  puts "[OK] Installed gpsd NMEA bridge -> #{RPT_GPS_PTY} via #{GPSD_NMEA_BRIDGE_SCRIPT}"
end

def install_asterisk_after_gps_bridge!
  FileUtils.mkdir_p(File.dirname(ASTERISK_GPS_BRIDGE_DROPIN))
  File.write(ASTERISK_GPS_BRIDGE_DROPIN, <<~DROPIN)
    [Unit]
    After=gpsd-nmea-bridge.service
    Requires=gpsd-nmea-bridge.service

    [Service]
    ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do [ -e #{RPT_GPS_PTY} ] && exit 0; sleep 1; done; echo "asterisk: #{RPT_GPS_PTY} not ready"; exit 1'
  DROPIN
  run!('systemctl', 'daemon-reload')
  puts '[OK] Asterisk will wait for gpsd NMEA bridge before starting.'
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

  system('usermod', '-aG', 'dialout', 'asterisk')
  puts '[OK] Added user asterisk to group dialout (for APRS GPS PTY)'
end

def setup_mobile_gps!(gps_device)
  puts "\n--- System update & package installation ---"
  unless system('env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'update') &&
         system('env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', 'gpsd', 'gpsd-clients', 'socat')
    abort 'ERROR: Package installation failed.'
  end

  puts "\n--- Writing /etc/default/gpsd ---"
  File.write('/etc/default/gpsd', <<~GPSD)
    # /etc/default/gpsd - written by #{File.basename($PROGRAM_NAME)}
    START_DAEMON="true"
    USBAUTO="false"
    DEVICES="#{gps_device}"
    GPSD_OPTIONS="-n -s #{GPSD_USB_BAUD}"
    OPTIONS=""
  GPSD

  unless system('systemctl', 'enable', 'gpsd.socket', 'gpsd.service')
    run!('systemctl', 'enable', 'gpsd.service')
  end
  run!('systemctl', 'restart', 'gpsd.service')
  puts '[OK] gpsd enabled (shared GPS on 127.0.0.1:2947).'

  puts "\n--- APRS NMEA bridge (gpsd -> app_gps) ---"
  ensure_asterisk_dialout!
  install_gpsd_nmea_bridge!
  install_asterisk_after_gps_bridge!
  wait_for_rptgps!
end

def build_gps_conf(config)
  lines = []
  lines << "; /etc/asterisk/gps.conf - written by #{File.basename($PROGRAM_NAME)}"
  lines << "; Mode: #{config[:mode]}"
  if config[:mobile]
    if config[:radioless]
      lines << "; Mobile radioless: live GPS via #{RPT_GPS_PTY} (gpsd-nmea-bridge.service)"
    else
      lines << "; Mobile: NMEA from gpsd via #{RPT_GPS_PTY} (gpsd-nmea-bridge.service)"
    end
  elsif config[:radioless]
    lines << '; Fixed radioless: no GPS device; position from lat/lon below'
  else
    lines << '; Fixed: no GPS device; position from lat/lon below'
  end
  lines << ''
  lines << '[general]'
  lines << ''
  lines << '; APRS-IS login'
  lines << "call = #{config[:call]}"
  lines << "password = #{config[:password]}"
  lines << "server = #{config[:server]}"
  lines << 'port = 14580'
  lines << "interval = #{config[:interval]}"
  lines << ''
  lines << '; Map appearance'
  lines << "comment = #{config[:comment]}"
  lines << "icontable = #{config[:icontable]}"
  lines << "icon = #{config[:icon]}"
  if config[:radioless]
    lines << '; Radioless node — no RF transmitter'
    lines << 'freq = 0.0'
    lines << 'tone = 0.0'
  else
    lines << "freq = #{config[:freq]}"
    lines << "tone = #{config[:tone]}"
  end
  lines << ''
  lines << '; PHG (encoded single digits — see script summary for decoded values)'
  lines << "; power=#{config[:power]} => #{phg_power_label(config[:power])}"
  lines << "; height=#{config[:height]} => #{phg_height_label(config[:height])}"
  lines << "; gain=#{config[:gain]} => #{phg_gain_label(config[:gain])}"
  lines << "; dir=#{config[:dir]} => #{phg_dir_label(config[:dir])}"
  lines << "power = #{config[:power]}"
  lines << "height = #{config[:height]}"
  lines << "gain = #{config[:gain]}"
  lines << "dir = #{config[:dir]}"
  lines << ''
  lines << '; Position'
  lines << "lat = #{format_decimal(config[:lat], LAT_LON_DECIMALS)}"
  lines << "lon = #{format_decimal(config[:lon], LAT_LON_DECIMALS)}"
  lines << "elev = #{format_decimal(config[:elev], ELEV_DECIMALS)} ; meters above sea level (NOT HAAT)"
  lines << ''

  if config[:mobile]
    lines << '; GPS serial (NMEA bridge from gpsd)'
    lines << "comport = #{RPT_GPS_PTY}"
    lines << "baudrate = #{APP_GPS_BAUD}"
  end

  lines << ''
  lines << '#tryinclude "custom/gps.conf"'
  lines.join("\n") + "\n"
end

def print_config_summary(config)
  puts
  puts '===================================================='
  puts '              CONFIGURATION SUMMARY'
  puts '===================================================='
  puts "Mode:           #{config[:mode]}"
  puts "APRS-IS call:   #{config[:call]}"
  puts "APRS-IS pass:   #{MASKED_SECRET} (stored in gps.conf)"
  puts "Server:         #{config[:server]}:14580"
  puts "Beacon every:   #{config[:interval]} seconds"
  puts "Map comment:    #{config[:comment]}"
  if config[:radioless]
    puts 'RF:             none (radioless node)'
  else
    puts "RF display:     #{config[:freq]} MHz, tone #{config[:tone]}"
  end
  puts "Map symbol:     icontable=#{config[:icontable].inspect} icon=#{config[:icon].inspect}"
  puts
  if config[:mobile]
    puts 'Position:       live GPS when locked (fallback lat/lon if no fix):'
  else
    puts 'Position:       fixed lat/lon:'
  end
  puts "  lat = #{format_decimal(config[:lat], LAT_LON_DECIMALS)}  (#{LAT_LON_DECIMALS} decimal places)"
  puts "  lon = #{format_decimal(config[:lon], LAT_LON_DECIMALS)}  (#{LAT_LON_DECIMALS} decimal places)"
  puts "  elev = #{format_decimal(config[:elev], ELEV_DECIMALS)} m MSL  (#{ELEV_DECIMALS} decimal place, NOT HAAT)"
  puts
  puts 'PHG fields (what APRS maps will show from the encoded digits):'
  puts "  power  = #{config[:power]}  =>  #{phg_power_label(config[:power])}"
  puts "  height = #{config[:height]}  =>  #{phg_height_label(config[:height])}"
  puts "  gain   = #{config[:gain]}  =>  #{phg_gain_label(config[:gain])}"
  puts "  dir    = #{config[:dir]}  =>  #{phg_dir_label(config[:dir])}"
  puts
  if config[:mobile]
    puts "GPS:            gpsd on 127.0.0.1:2947, NMEA bridge -> #{RPT_GPS_PTY}"
  else
    puts 'GPS:            none (fixed position only)'
  end
  puts '===================================================='
end

def hint_saytime_gpsd!
  weather_ini = '/etc/asterisk/local/weather.ini'
  return unless File.exist?(weather_ini)

  content = File.read(weather_ini)
  return if content.include?('location_source')

  puts "\nNote: saytime_weather_rb — add to #{weather_ini} under [weather] for GPS location:"
  puts '    location_source = gps'
  puts '    gpsd_host = 127.0.0.1'
  puts '    gpsd_port = 2947'
end

def verify_installation!(mobile:)
  notes = []
  if mobile
    notes << 'gpsd-nmea-bridge.service is not active' unless system('systemctl', 'is-active', '--quiet', 'gpsd-nmea-bridge.service')
    notes << 'gpsd.service is not active' unless system('systemctl', 'is-active', '--quiet', 'gpsd.service')
    notes << "#{RPT_GPS_PTY} is missing" unless File.exist?(RPT_GPS_PTY)
  end

  gps_status = `asterisk -rx 'gps show status' 2>/dev/null`
  if gps_status.include?('Locked')
    puts '[OK] Post-install: GPS locked in Asterisk.'
  elsif mobile && gps_status.include?('Unlocked')
    notes << 'GPS serial open but no fix yet (allow time for satellite lock and clear sky)'
  elsif !mobile && gps_status.include?('default')
    puts '[OK] Post-install: using fixed default position (no GPS device).'
  end

  return if notes.empty?

  puts "\nPost-install notes:"
  notes.each { |note| puts "  - #{note}" }
end

abort 'ERROR: This script must be run as root (sudo).' if Process.uid != 0

require_asl3!

input = interactive_input

puts '===================================================='
puts '     ASL3 INTERACTIVE APRS CONFIGURATION TOOL'
puts '===================================================='
puts ''
puts 'Configures app_gps for APRS-IS position beacons.'
puts 'Choose fixed (repeater/base) or mobile (GPS-tracked) setup.'
puts ''

mode_key = ask_choice(
  input,
  'Station type:',
  %w[fixed mobile],
  default: 'fixed'
)
mobile = mode_key == 'mobile'
preset = PRESETS.fetch(mode_key)

puts
puts "Selected: #{mode_key} (#{mobile ? 'live GPS via gpsd' : 'fixed lat/lon, no GPS hardware'})"

base_callsign = ask(input, 'Enter your FCC callsign (e.g., W5GLE)').upcase
abort 'ERROR: Callsign cannot be blank.' if base_callsign.empty?

aprs_passcode = calculate_aprs_passcode(base_callsign)
puts "APRS-IS passcode for #{base_callsign}: #{MASKED_SECRET} (computed from callsign; stored in gps.conf)"

default_ssid = mobile ? '10' : '1'
ssid = ask(input, 'Enter APRS SSID suffix (-1 through -15)', default: default_ssid)
full_callsign = "#{base_callsign}-#{ssid}"

radioless = ask_yes_no(
  input,
  'Radioless node (no RF frequency or tone; hub, link, or GPS-only tracker)?',
  default: false
)

if radioless
  puts '  RF frequency and tone skipped; map comment will not include MHz/T fields.'
  rf_freq = ''
  rf_tone = '0.0'
  default_comment = mobile ? 'ASL3 Mobile Hub' : 'ASL3 Hub Node'
  user_comment = ask(input, 'Enter short map beacon comment', default: default_comment)
  map_comment = user_comment
else
  puts
  puts '--- RF frequency and tone (gps.conf: freq, tone) ---'
  rf_freq = ask_decimal(
    input,
    'Enter node RF frequency in MHz',
    places: FREQ_DECIMALS,
    example: '443.075',
    required: true
  )

  rf_tone = ask_decimal(
    input,
    'Enter CTCSS tone in Hz (0.0 for none)',
    places: TONE_DECIMALS,
    example: '103.5',
    default: '0.0'
  )
  user_comment = ask(input, 'Enter short map beacon comment', default: preset[:comment])
  map_comment = beacon_comment(user_comment, rf_freq, rf_tone)
end

server_key = ask_choice(
  input,
  'APRS-IS server region:',
  APRS_SERVERS.keys,
  default: 'rotate'
)
server = APRS_SERVERS.fetch(server_key)

interval_str = ask(
  input,
  'Beacon interval in seconds (mobile 60-120, infrastructure ~1200, fixed ~1800)',
  default: preset[:interval].to_s
)
interval = interval_str.to_i
abort 'ERROR: Beacon interval must be at least 30 seconds.' if interval < 30

icontable = ask(input, 'Icon table (/ = primary, \\ = alternate)', default: preset[:icontable])
icon = ask(input, 'Map icon character (see aprs.org/symbols.html)', default: preset[:icon])

power = ask_phg_digit(input, 'Power', PHG_POWER_WATTS, 'W', preset[:power], real_prompt: 'watts')
height = ask_phg_digit(input, 'Height', PHG_HEIGHT_FEET, 'ft HAAT', preset[:height], real_prompt: 'feet HAAT')
gain = ask_phg_digit(input, 'Gain', PHG_GAIN_DBI, 'dBi', preset[:gain], real_prompt: 'dBi')
dir = ask_phg_digit(input, 'Direction', PHG_DIR_DEGREES, 'bearing', preset[:dir], real_prompt: 'degrees (0=omni)')

default_elev = mobile ? '100' : '200'
elev = ask_elevation_meters(input, default: default_elev)

lat, lon = ask_coordinates(input, mobile: mobile)

gps_device = nil
if mobile
  gps_device = ask(input, 'USB GPS serial device for gpsd', default: '/dev/ttyACM0')
  warn_unless_gps_device!(gps_device)
end

config = {
  mode: mode_key,
  mobile: mobile,
  radioless: radioless,
  call: full_callsign,
  password: aprs_passcode,
  server: server,
  interval: interval,
  comment: map_comment,
  icontable: icontable,
  icon: icon,
  freq: radioless ? '0.0' : rf_freq,
  tone: radioless ? '0.0' : rf_tone,
  power: power,
  height: height,
  gain: gain,
  dir: dir,
  lat: lat,
  lon: lon,
  elev: elev
}

print_config_summary(config)

unless ask_yes_no(input, 'Write configuration and restart services?', default: true)
  puts 'Aborted — no changes written.'
  input.close unless input.equal?($stdin)
  exit 0
end

input.close unless input.equal?($stdin)

setup_mobile_gps!(gps_device) if mobile

gps_conf = '/etc/asterisk/gps.conf'
if File.exist?(gps_conf)
  FileUtils.cp(gps_conf, "#{gps_conf}.bak")
  puts "Note: Existing gps.conf backed up to gps.conf.bak"
end
File.write(gps_conf, build_gps_conf(config))
puts '[OK] /etc/asterisk/gps.conf written.'

enable_app_gps!('/etc/asterisk/modules.conf')

puts "\n--- Restarting Asterisk ---"
run!('systemctl', 'restart', 'asterisk')

hint_saytime_gpsd! if mobile
verify_installation!(mobile: mobile)

puts "\n===================================================="
puts 'Configuration complete!'
puts '===================================================='
if mobile
  puts 'Shared GPS: gpsd on 127.0.0.1:2947 (saytime_weather_rb, SkywarnPlus-NG, cgps)'
  puts "APRS: app_gps reads NMEA from #{RPT_GPS_PTY}"
  puts ''
  puts '1. Check gpsd:     cgps -s'
  puts "2. Check bridge:   ls -l #{RPT_GPS_PTY}"
  puts '3. Asterisk CLI:   gps show status'
else
  puts 'Fixed APRS: position from lat/lon in gps.conf (no GPS hardware)'
  puts '3. Asterisk CLI:   gps show status  (shows default position)'
end
puts "4. Map: https://aprs.fi/#!call=#{full_callsign}"
puts '   (Allow a few minutes for the first beacon.)'
puts '===================================================='

__END__
#!/bin/bash
# Replay gpsd NMEA to /dev/rptgps for app_gps.
#
# Copyright (C) 2026 Jory A. Pratt, W5GLE <geekypenguin@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# Decouple gpspipe from socat so a dropped PTY reader does not tear down the
# whole bridge, and recreate /dev/rptgps quickly when socat must restart.
set -euo pipefail

RUNDIR=/run/gpsd-nmea-bridge
FIFO="${RUNDIR}/nmea.pipe"
PTYLINK=/dev/rptgps

install -d -m 0755 "$RUNDIR"
rm -f "$FIFO"
mkfifo -m 0660 "$FIFO"
chgrp dialout "$FIFO" 2>/dev/null || true

cleanup() {
	local pids

	pids=$(jobs -p 2>/dev/null || true)
	if [ -n "${pids}" ]; then
		kill ${pids} 2>/dev/null || true
	fi
	wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Keep feeding NMEA even if the PTY bridge restarts.
(
	while true; do
		gpspipe -r 2>/dev/null >"${FIFO}" || true
		sleep 1
	done
) &

while true; do
	rm -f "${PTYLINK}"
	socat \
		"OPEN:${FIFO},ignoreeof" \
		"PTY,link=${PTYLINK},raw,echo=0,group=dialout,mode=660,waitslave" \
		|| true
	sleep 0.2
done
