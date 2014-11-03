require 'yaml'
require 'ipaddr'

settings = YAML.load_file("#{File.dirname(__FILE__)}/../config/settings.yaml")

LDAPHOST = settings['ldap']['server']
BINDDN = settings['ldap']['binddn']
BINDPW = settings['ldap']['bindpw']
BASEDN = settings['ldap']['basedn']

ReverseZones = {}
settings['reverse_zones'].each do |reverse_zone, networks|
  ReverseZones[reverse_zone] = []
  networks.each do |network|
    ReverseZones[reverse_zone].push IPAddr.new(network)
  end
end

Zones = {}
settings['managed_zones'].each do |managed_zone, networks|
  Zones[managed_zone] = {}
  Zones[managed_zone]['sourceip'] = []
  Zones[managed_zone]['managedip'] = []

  networks['sourceip'].each do |network|
    Zones[managed_zone]['sourceip'].push IPAddr.new(network)
  end

  networks['managedip'].each do |network|
    Zones[managed_zone]['managedip'].push IPAddr.new(network)
  end
end

ZoneDefaults = {}
ZoneDefaults['soa'] = {}
ZoneDefaults['soa']['mname'] = settings['zone_defaults']['soa']['mname']
ZoneDefaults['soa']['rname'] = settings['zone_defaults']['soa']['rname']
ZoneDefaults['soa']['refresh'] = settings['zone_defaults']['soa']['refresh'].to_s
ZoneDefaults['soa']['retry'] = settings['zone_defaults']['soa']['retry'].to_s
ZoneDefaults['soa']['expire'] = settings['zone_defaults']['soa']['expire'].to_s
ZoneDefaults['soa']['minimum'] = settings['zone_defaults']['soa']['minimum'].to_s
ZoneDefaults['nameservers'] = settings['zone_defaults']['nameservers']

require 'restful_dns_api'
