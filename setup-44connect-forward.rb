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
# setup-44connect-forward.rb - Port forward 44Net Connect (AMPR) to LAN hosts
#
# EXPERIMENTAL / UNTESTED — not yet validated end-to-end on a 44Net Connect node.
#
# Configures firewalld forward-port rules on a WireGuard/44Connect interface so
# traffic to your AMPR address:port reaches an internal device. Supports Debian
# 12 (Bookworm) and 13 (Trixie) with firewalld (ASL3 / ASL appliance default).
#
# Non-interactive example:
#   FWD_ACTION=add FWD_WG_IF=44net-pop FWD_LAN_IF=eth0 FWD_44_IP=44.33.1.32 \
#   FWD_EXT_PORT=8080 FWD_INT_IP=192.168.1.50 FWD_INT_PORT=80 FWD_PROTO=tcp \
#   curl -sSL .../setup-44connect-forward.rb | sudo ruby

require 'fileutils'
require 'json'
require 'ipaddr'
require 'securerandom'

CONFIG_PATH = '/etc/44connect-forwards.json'
APPLY_BIN = '/usr/local/sbin/44connect-forward-apply'
INSTALLED_SCRIPT = '/usr/local/sbin/setup-44connect-forward.rb'
SYSCTL_DROPIN = '/etc/sysctl.d/99-44connect-forward.conf'
DEFAULT_FIREWALL_ZONE = 'allstarlink'
SUPPORTED_DEBIAN_VERSIONS = [12, 13].freeze
VALID_PROTOS = %w[tcp udp].freeze

def interactive_input
  return $stdin if $stdin.tty?

  File.open('/dev/tty', 'r')
rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM
  abort <<~MSG.strip
    ERROR: Interactive terminal required.
    Run from a TTY: curl -sSL .../setup-44connect-forward.rb | sudo ruby
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

def run!(*args)
  return if system(*args)

  abort "ERROR: Command failed: #{args.join(' ')}"
end

def require_root!
  abort 'ERROR: This script must be run as root (sudo).' if Process.uid != 0
end

def require_debian!
  abort 'ERROR: /etc/os-release not found.' unless File.file?('/etc/os-release')

  os_release = File.read('/etc/os-release')
  abort 'ERROR: Debian 12 or 13 required (ASL3 appliance support).' unless os_release.include?('ID=debian')

  major = os_release[/^VERSION_ID="?(\d+)/, 1]&.to_i
  return if SUPPORTED_DEBIAN_VERSIONS.include?(major)

  abort "ERROR: Unsupported Debian version #{major}. Supported: #{SUPPORTED_DEBIAN_VERSIONS.join(', ')}."
end

def firewalld_active?
  system('command', '-v', 'firewall-cmd', out: File::NULL, err: File::NULL) &&
    system('firewall-cmd', '--state', out: File::NULL, err: File::NULL)
end

def require_firewalld!
  return if firewalld_active?

  abort 'ERROR: firewalld is not running. Install and enable: apt-get install firewalld && systemctl enable --now firewalld'
end

def ampr_addr?(ip)
  IPAddr.new(ip).ipv4? && ip.start_with?('44.')
rescue IPAddr::InvalidAddressError
  false
end

def parse_ip_json
  JSON.parse(`ip -j -4 addr show 2>/dev/null`)
rescue JSON::ParserError
  []
end

def wireguard_interfaces
  Dir.glob('/sys/class/net/*').filter_map do |path|
    name = File.basename(path)
    next if name == 'lo'

    File.directory?(File.join(path, 'wireguard')) ? name : nil
  end
end

def interface_ipv4_addrs(ifname)
  parse_ip_json.filter_map do |iface|
    next unless iface['ifname'] == ifname

    iface.fetch('addr_info', []).filter_map do |info|
      info['local'] if info['family'] == 'inet'
    end
  end.flatten
end

def ampr_ips_on_interface(ifname)
  interface_ipv4_addrs(ifname).select { |ip| ampr_addr?(ip) }
end

def guess_lan_interface(wg_if)
  routes = `ip -j -4 route show default 2>/dev/null`
  default = JSON.parse(routes).find { |r| r['dst'] == 'default' }
  dev = default&.dig('dev')
  return dev if dev && dev != wg_if

  parse_ip_json.filter_map do |iface|
    name = iface['ifname']
    next if name == 'lo' || name == wg_if
    next if wireguard_interfaces.include?(name)

    addrs = iface.fetch('addr_info', []).filter_map { |i| i['local'] if i['family'] == 'inet' }
    name if addrs.any? { |ip| !ampr_addr?(ip) }
  end.first
end

def default_config
  {
    'version' => 2,
    'wg_interface' => nil,
    'lan_interface' => nil,
    'ampr_ip' => nil,
    'firewall_zone' => nil,
    'applied_forward_specs' => [],
    'forwards' => []
  }
end

def load_config
  return default_config unless File.file?(CONFIG_PATH)

  config = JSON.parse(File.read(CONFIG_PATH))
  config['applied_forward_specs'] ||= []
  config
rescue JSON::ParserError
  abort "ERROR: Invalid JSON in #{CONFIG_PATH}"
end

def save_config!(config)
  FileUtils.mkdir_p(File.dirname(CONFIG_PATH))
  File.write(CONFIG_PATH, JSON.pretty_generate(config))
  File.chmod(0o600, CONFIG_PATH)
end

def validate_ipv4!(label, ip)
  IPAddr.new(ip)
  abort "ERROR: #{label} must be IPv4: #{ip}" unless IPAddr.new(ip).ipv4?
rescue IPAddr::InvalidAddressError
  abort "ERROR: Invalid #{label}: #{ip}"
end

def validate_port!(label, port)
  abort "ERROR: #{label} must be 1-65535" unless port.to_s.match?(/\A\d+\z/) && port.to_i.between?(1, 65_535)
end

def validate_proto!(proto)
  p = proto.to_s.downcase
  abort 'ERROR: protocol must be tcp or udp' unless VALID_PROTOS.include?(p)

  p
end

def ensure_ip_forward!
  if File.read('/proc/sys/net/ipv4/ip_forward').strip != '1'
    File.write('/proc/sys/net/ipv4/ip_forward', '1')
    puts '[OK] Enabled IPv4 forwarding (runtime).'
  end

  return if File.file?(SYSCTL_DROPIN)

  File.write(SYSCTL_DROPIN, "net.ipv4.ip_forward=1\n")
  puts "[OK] Wrote #{SYSCTL_DROPIN} (persistent across reboot)."
end

def forward_port_spec(fwd)
  "port=#{fwd['external_port']}:proto=#{fwd['protocol']}:toport=#{fwd['internal_port']}:toaddr=#{fwd['internal_host']}"
end

def default_firewall_zone
  zones = `firewall-cmd --get-zones 2>/dev/null`.split
  return DEFAULT_FIREWALL_ZONE if zones.include?(DEFAULT_FIREWALL_ZONE)

  zone = `firewall-cmd --get-default-zone 2>/dev/null`.strip
  zone.empty? ? 'public' : zone
end

def zone_for_interface(ifname)
  zone = `firewall-cmd --get-zone-of-interface=#{ifname} 2>/dev/null`.strip
  return zone unless zone.empty? || zone.include?('no zone')

  nil
end

def resolve_firewall_zone!(config)
  wg = config['wg_interface']
  abort 'ERROR: wg_interface not set in config.' if wg.nil? || wg.empty?

  zone = zone_for_interface(wg) || config['firewall_zone']
  if zone.nil? || zone.empty?
    zone = default_firewall_zone
    run!('firewall-cmd', '--permanent', "--zone=#{zone}", "--add-interface=#{wg}")
    puts "[OK] Assigned #{wg} to firewalld zone #{zone}."
  end

  config['firewall_zone'] = zone
  zone
end

def remove_forward_port!(zone, spec)
  system('firewall-cmd', '--permanent', "--zone=#{zone}", "--remove-forward-port=#{spec}",
         out: File::NULL, err: File::NULL)
end

def add_forward_port!(zone, spec)
  run!('firewall-cmd', '--permanent', "--zone=#{zone}", "--add-forward-port=#{spec}")
end

def ensure_zone_masquerade!(zone)
  return if system('firewall-cmd', '--permanent', "--zone=#{zone}", '--query-masquerade',
                   out: File::NULL, err: File::NULL)

  run!('firewall-cmd', '--permanent', "--zone=#{zone}", '--add-masquerade')
end

def apply_forwards!(config)
  wg = config['wg_interface']
  lan = config['lan_interface']
  ampr = config['ampr_ip']
  forwards = config['forwards'] || []

  abort 'ERROR: wg_interface not set in config.' if wg.nil? || wg.empty?
  abort 'ERROR: lan_interface not set in config.' if lan.nil? || lan.empty?
  abort 'ERROR: ampr_ip not set in config.' if ampr.nil? || ampr.empty?

  zone = resolve_firewall_zone!(config)
  ensure_ip_forward!
  ensure_zone_masquerade!(zone)

  (config['applied_forward_specs'] || []).each do |spec|
    remove_forward_port!(zone, spec)
  end

  forwards.each do |fwd|
    add_forward_port!(zone, forward_port_spec(fwd))
  end

  config['applied_forward_specs'] = forwards.map { |f| forward_port_spec(f) }
  save_config!(config)
  run!('firewall-cmd', '--reload')

  install_apply_helper!
  puts "[OK] Applied #{forwards.length} port forward(s) in firewalld zone #{zone}."
end

def install_apply_helper!
  if File.file?(__FILE__) && !__FILE__.start_with?('-')
    FileUtils.cp(__FILE__, INSTALLED_SCRIPT)
    File.chmod(0o755, INSTALLED_SCRIPT)
  end

  File.write(APPLY_BIN, <<~SH)
    #!/bin/sh
    if [ -x #{INSTALLED_SCRIPT} ]; then
      exec /usr/bin/env ruby #{INSTALLED_SCRIPT} --apply-only
    fi
    echo "44connect-forward-apply: install #{INSTALLED_SCRIPT} first (run setup from a saved copy)." >&2
    exit 1
  SH
  File.chmod(0o755, APPLY_BIN)
end

def flush_forwards!(config = load_config)
  zone = config['firewall_zone']
  unless zone && firewalld_active?
    puts '[WARN] firewalld not active or zone unknown; nothing to flush.'
    return
  end

  (config['applied_forward_specs'] || []).each do |spec|
    remove_forward_port!(zone, spec)
  end
  run!('firewall-cmd', '--reload')
  puts '[OK] Removed 44Connect forward-port rules from firewalld.'
end

def list_forwards(config)
  puts "\nConfig: #{CONFIG_PATH}"
  puts "WireGuard: #{config['wg_interface']}"
  puts "LAN:       #{config['lan_interface']}"
  puts "AMPR IP:   #{config['ampr_ip']}"
  puts "Zone:      #{config['firewall_zone'] || '(auto)'}"
  puts ''

  forwards = config['forwards'] || []
  if forwards.empty?
    puts 'No port forwards configured.'
    return
  end

  forwards.each do |fwd|
    puts "#{fwd['id']}: #{config['ampr_ip']}:#{fwd['external_port']}/#{fwd['protocol']}" \
         " -> #{fwd['internal_host']}:#{fwd['internal_port']}" \
         "#{fwd['description'] ? " (#{fwd['description']})" : ''}"
  end
end

def pick_interface(input, label, candidates, default: nil)
  if candidates.length == 1
    puts "#{label}: using #{candidates.first}"
    return candidates.first
  end

  puts "\n#{label}:"
  candidates.each_with_index { |c, i| puts "  #{i + 1}) #{c}" }
  answer = ask(input, 'Choose number', default: '1')
  idx = answer.to_i
  return candidates[idx - 1] if idx.between?(1, candidates.length)

  default || candidates.first
end

def configure_interfaces!(input, config)
  wg_candidates = wireguard_interfaces
  abort 'ERROR: No WireGuard interface found. Is 44Connect/wg-quick up?' if wg_candidates.empty?

  config['wg_interface'] ||= pick_interface(input, 'WireGuard / 44Connect interface', wg_candidates,
                                            default: wg_candidates.first)

  ampr_candidates = ampr_ips_on_interface(config['wg_interface'])
  if ampr_candidates.empty?
    config['ampr_ip'] ||= ask(input, 'AMPR IPv4 on WireGuard (44.x.x.x)')
  elsif ampr_candidates.length == 1
    config['ampr_ip'] ||= ampr_candidates.first
    puts "AMPR IP: using #{config['ampr_ip']}"
  else
    config['ampr_ip'] ||= pick_interface(input, 'AMPR IPv4', ampr_candidates, default: ampr_candidates.first)
  end

  validate_ipv4!('AMPR IP', config['ampr_ip'])
  abort "ERROR: #{config['ampr_ip']} is not in 44.0.0.0/8" unless ampr_addr?(config['ampr_ip'])

  lan_default = guess_lan_interface(config['wg_interface'])
  config['lan_interface'] ||= ask(input, 'LAN interface toward internal devices', default: lan_default || 'eth0')
end

def add_forward_interactive!(input, config)
  configure_interfaces!(input, config)

  proto = validate_proto!(ask(input, 'Protocol (tcp/udp)', default: 'tcp'))
  ext_port = ask(input, 'External port on AMPR IP', default: nil)
  int_ip = ask(input, 'Internal device IPv4', default: nil)
  int_port = ask(input, 'Internal port', default: ext_port)
  desc = ask(input, 'Short description (optional)', default: '')

  validate_port!('external port', ext_port)
  validate_port!('internal port', int_port)
  validate_ipv4!('internal host', int_ip)

  config['forwards'] ||= []
  if config['forwards'].any? { |f| f['protocol'] == proto && f['external_port'].to_i == ext_port.to_i }
    abort "ERROR: Forward already exists for #{proto}/#{ext_port}"
  end

  config['forwards'] << {
    'id' => SecureRandom.hex(4),
    'protocol' => proto,
    'external_port' => ext_port.to_i,
    'internal_host' => int_ip,
    'internal_port' => int_port.to_i,
    'description' => desc.empty? ? nil : desc
  }.compact

  apply_forwards!(config)
  list_forwards(config)
end

def remove_forward_interactive!(input, config)
  list_forwards(config)
  forwards = config['forwards'] || []
  return if forwards.empty?

  id = ask(input, 'Enter forward id to remove', default: nil)
  before = forwards.length
  config['forwards'] = forwards.reject { |f| f['id'] == id }
  abort "ERROR: No forward with id #{id}" if config['forwards'].length == before

  apply_forwards!(config)
  puts '[OK] Forward removed.'
end

def add_forward_from_env!(config)
  config['wg_interface'] = ENV.fetch('FWD_WG_IF')
  config['lan_interface'] = ENV.fetch('FWD_LAN_IF')
  config['ampr_ip'] = ENV.fetch('FWD_44_IP')
  proto = validate_proto!(ENV.fetch('FWD_PROTO', 'tcp'))
  ext_port = ENV.fetch('FWD_EXT_PORT')
  int_ip = ENV.fetch('FWD_INT_IP')
  int_port = ENV.fetch('FWD_INT_PORT', ext_port)

  validate_port!('external port', ext_port)
  validate_port!('internal port', int_port)
  validate_ipv4!('AMPR IP', config['ampr_ip'])
  validate_ipv4!('internal host', int_ip)

  config['forwards'] ||= []
  config['forwards'] << {
    'id' => SecureRandom.hex(4),
    'protocol' => proto,
    'external_port' => ext_port.to_i,
    'internal_host' => int_ip,
    'internal_port' => int_port.to_i,
    'description' => ENV['FWD_DESC']
  }.compact

  apply_forwards!(config)
  list_forwards(config)
end

def show_status(config)
  list_forwards(config)
  puts ''
  puts "IPv4 forwarding: #{File.read('/proc/sys/net/ipv4/ip_forward').strip}"
  puts "firewalld:         #{firewalld_active? ? 'active' : 'inactive'}"
  puts "Apply helper:      #{APPLY_BIN}#{File.executable?(APPLY_BIN) ? '' : ' (missing)'}"

  zone = config['firewall_zone']
  if zone && firewalld_active?
    puts ''
    puts "firewalld zone #{zone} forward-ports:"
    system('firewall-cmd', '--permanent', "--zone=#{zone}", '--list-forward-ports')
  end

  puts ''
  puts 'Persist after WireGuard restarts — add to your 44Connect wg config [Interface] section:'
  puts "  PostUp = #{APPLY_BIN}"
  puts "  PostDown = /usr/bin/env ruby #{INSTALLED_SCRIPT} --flush-only"
end

def run_menu!(input)
  loop do
    config = load_config
    puts "\n=== 44Connect port forward ==="
    puts '1) Add port forward'
    puts '2) List forwards'
    puts '3) Remove port forward'
    puts '4) Re-apply firewalld rules'
    puts '5) Set WireGuard/LAN interfaces'
    puts '6) Status'
    puts '7) Exit'

    choice = ask(input, 'Choice', default: '7')
    case choice
    when '1' then add_forward_interactive!(input, config)
    when '2' then list_forwards(config)
    when '3' then remove_forward_interactive!(input, config)
    when '4' then apply_forwards!(config)
    when '5'
      config = default_config.merge(
        'forwards' => config['forwards'] || [],
        'applied_forward_specs' => config['applied_forward_specs'] || []
      )
      configure_interfaces!(input, config)
      save_config!(config)
      puts '[OK] Interface settings saved.'
    when '6' then show_status(config)
    when '7' then break
    else puts 'Invalid choice.'
    end
  end
end

require_root!
require_debian!
require_firewalld!

if ARGV.include?('--apply-only')
  apply_forwards!(load_config)
  exit 0
end

if ARGV.include?('--flush-only')
  flush_forwards!
  exit 0
end

action = ENV.fetch('FWD_ACTION', 'menu').downcase
config = load_config

case action
when 'menu'
  input = interactive_input
  puts '44Connect / AMPRNet port forwarding (WireGuard -> LAN)'
  puts 'Traffic to your 44.x address:port is forwarded to an internal host via firewalld.'
  puts "Supported: Debian #{SUPPORTED_DEBIAN_VERSIONS.join(' and ')} with firewalld."
  puts ''
  run_menu!(input)
when 'add'
  add_forward_from_env!(config)
when 'apply'
  apply_forwards!(config)
when 'list'
  list_forwards(config)
when 'status'
  show_status(config)
else
  abort "ERROR: Unknown FWD_ACTION=#{action} (use menu, add, apply, list, status)"
end
