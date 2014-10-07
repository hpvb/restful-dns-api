#!/usr/bin/env ruby

require 'rubygems'
require 'sinatra'
require 'json'
require 'ipaddr'
require 'ipaddress'
require 'ldap'

HostPartRegex = '[a-z0-9]{1}[a-z0-9-]{0,63}'
ValidHostRegex = "^#{HostPartRegex}$"
ValidFQDNRegex = "^#{HostPartRegex}\.*#{HostPartRegex}*$"

class NotFoundError < RuntimeError
end

class DatabaseError < RuntimeError
end

class InvalidInputError < RuntimeError
end

class AlreadyExistsError < RuntimeError
end

class NotAllowedError < RuntimeError
end

helpers do
  def ldapconnection
    unless @conn
      @conn = LDAP::SSLConn.new(LDAPHOST, LDAP::LDAPS_PORT, false)
      @conn.set_option(LDAP::LDAP_OPT_PROTOCOL_VERSION, 3)
      @conn.bind(BINDDN, BINDPW)
    end
    @conn
  end

  def ldapquery(basedn, scope, filter, attributes, &block)
    entries = []

    begin
      ldapconnection.search(basedn, scope, filter, attributes, &block)
    rescue LDAP::ResultError => msg
      raise NotFoundError if ldapconnection.err == 32
      raise DatabaseError, msg
    end

    entries
  end

  def getzones
    zones = []

    begin
      ldapquery(BASEDN, LDAP::LDAP_SCOPE_SUBTREE, '(objectClass=idnsZone)', ['idnsname']) do |entry|
        zones.push entry['idnsname'][0] unless entry['idnsname'][0].end_with?('.in-addr.arpa')
      end
    rescue NotFoundError
      raise NotFoundError, 'No zones found'
    end

    zones
  end

  def zone_exists?(zone)
    begin
      ldapconnection.search("idnsName=#{zone},#{BASEDN}", LDAP::LDAP_SCOPE_BASE, '(objectClass=*)', %w(arecord cnamerecord)) do |_entry|
      end
    rescue LDAP::ResultError
      return false
    rescue RuntimeError
      return false
    end

    true
  end

  def createzone(zone)
    entry = [
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'objectClass', %w(top idnsRecord idnsZone)),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsName', [zone]),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsZoneActive', ['TRUE']),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAmName', ['server.example.com.']),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOArName', ['root.server.example.com.']),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAserial', ['1']),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOArefresh', ['10800']),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAretry', ['900']),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAexpire', ['604800']),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAminimum', ['86400']),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'ARecord', ['127.0.0.1']),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'NSRecord', ['server.example.com.'])
    ]

    begin
      ldapconnection.add("idnsName=#{zone},#{BASEDN}", entry)
     rescue LDAP::ResultError => msg
       raise DatabaseError, msg
    end
  end

  def gethosts(zone)
    hosts = []

    begin
      ldapquery("idnsName=#{zone},#{BASEDN}", LDAP::LDAP_SCOPE_ONELEVEL, '(objectClass=idnsRecord)', ['idnsname']) do |entry|
        hosts.push entry['idnsname'][0]
      end
    rescue NotFoundError
      raise NotFoundError, "No hosts found in zone #{zone}"
    end

    hosts
  end

  def gethost(zone, host)
    hostdata = {}

    begin
      ldapquery("idnsName=#{host},idnsName=#{zone},#{BASEDN}", LDAP::LDAP_SCOPE_BASE, '(objectClass=*)', %w(arecord cnamerecord)) do |entry|
        hostdata['ipaddress'] = entry['arecord'] || []
        hostdata['cname'] = entry['cnamerecord'] || []
      end
    rescue NotFoundError
      raise NotFoundError, "Host #{host} not found in zone #{zone}"
    end

    hostdata
  end

  def host_exists?(zone, host)
    begin
      ldapconnection.search("idnsName=#{host},idnsName=#{zone},#{BASEDN}", LDAP::LDAP_SCOPE_BASE, '(objectClass=*)', %w(arecord cnamerecord)) do |_entry|
      end
    rescue LDAP::ResultError
      return false
    rescue RuntimeError
      return false
    end

    true
  end

  def createhost(zone, host)
    createzone(zone) unless zone_exists?(zone)
    fail(InvalidInputError, "#{host} is not a valid RFC1123 hostname") unless host =~ /#{ValidHostRegex}/

    createrecord(zone, host)
  end

  def createptr(zone, ptr)
    createzone(zone) unless zone_exists?(zone)
    createrecord(zone, ptr)
  end

  def createrecord(zone, name)
    entry = [
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'objectClass', %w(top idnsRecord)),
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsName', [name])
    ]

    begin
      ldapconnection.add("idnsName=#{name},idnsName=#{zone},#{BASEDN}", entry)
     rescue LDAP::ResultError => msg
       raise DatabaseError, msg
    end
  end

  def addiptohost(zone, host, ipaddress)
    fail(InvalidInputError, "#{ipaddress} is not a valid ip address") unless IPAddress.valid? ipaddress
    createhost(zone, host) unless host_exists?(zone, host)

    operation = [
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'ARecord', [ipaddress])
    ]

    begin
      modifyhost(zone, host, operation)
    rescue AlreadyExistsError
      raise AlreadyExistsError, "Host #{host} in zone #{zone} already has ip #{ipaddress}"
    end
  end

  def removeipfromhost(zone, host, ipaddress)
    operation = [
      LDAP.mod(LDAP::LDAP_MOD_DELETE, 'ARecord', [ipaddress])
    ]

    begin
      modifyhost(zone, host, operation)
    rescue NotFoundError
      raise NotFoundError, "Host #{host} in zone #{zone} does not have ip #{ipaddress}"
    end

    getreverse(ipaddress).each do |reverse|
      deletereverse(ipaddress) if reverse == "#{host}.#{zone}."
    end
  end

  def addptrtohost(zone, host, ptraddress)
    createptr(zone, host) unless host_exists?(zone, host)

    operation = [
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'PTRRecord', [ptraddress])
    ]

    begin
      modifyhost(zone, host, operation)
    rescue AlreadyExistsError
      raise AlreadyExistsError, "PTR record for #{ptraddress} already exists"
    end
  end

  def addcnametohost(zone, host, cname)
    fail(InvalidInputError, "#{host} is not a valid RFC1123 hostname") unless host =~ /#{ValidFQDNRegex}/
    createhost(zone, host) unless host_exists?(zone, host)

    operation = [
      LDAP.mod(LDAP::LDAP_MOD_ADD, 'CNAMERecord', [cname])
    ]

    begin
      modifyhost(zone, host, operation)
    rescue AlreadyExistsError
      raise AlreadyExistsError, "Host #{host} in zone #{zone} already has cname #{cname}"
    end
  end

  def removecnamefromhost(zone, host, cname)
    operation = [
      LDAP.mod(LDAP::LDAP_MOD_DELETE, 'CNAMERecord', [cname])
    ]

    begin
      modifyhost(zone, host, operation)
    rescue NotFoundError
      raise NotFoundError, "Host #{host} in zone #{zone} does not have cname #{cname}"
    end
  end

  def modifyhost(zone, host, operations)
    ldapconnection.modify("idnsName=#{host},idnsName=#{zone},#{BASEDN}", operations)
   rescue LDAP::ResultError => msg
     raise AlreadyExistsError if ldapconnection.err == 20
     raise NotFoundError if ldapconnection.err == 16
     raise DatabaseError, msg
  end

  def deletehost(zone, host)
    hostdata = gethost(zone, host)

    hostdata['ipaddress'].each do |ipaddress|
      removeipfromhost(zone, host, ipaddress)
    end

    begin
      ldapconnection.delete("idnsName=#{host},idnsName=#{zone},#{BASEDN}")
    rescue LDAP::ResultError => msg
      raise DatabaseError, msg
    end
  end

  def getzoneforip(ip)
    ipaddress = IPAddr.new ip

    ReverseZones.each do |zone|
      zone[1].each do |network|
        return zone[0] if network.include?(ipaddress)
      end
    end

    nil
  end

  def getreverse(ip)
    reversezone = getzoneforip(ip)
    ptrname = reverseip(ip).sub(".#{reversezone}", '')

    reversedata = []
    begin
      ldapconnection.search("idnsName=#{ptrname},idnsName=#{reversezone},#{BASEDN}", LDAP::LDAP_SCOPE_BASE, '(objectClass=*)', ['ptrrecord']) do |entry|
        reversedata = entry['ptrrecord']
      end
    rescue LDAP::ResultError
    end

    reversedata
  end

  def reverseip(ipaddress)
    reverseip = IPAddr.new ipaddress
    reverseip.reverse
  end

  def createreverse(ip, zone, host)
    reversezone = getzoneforip(ip)
    ptrname = reverseip(ip).sub(".#{reversezone}", '')
    fail(NotAllowedError, "Reverse zones for #{ip} are not managed by this host") unless reversezone
    fail(NotAllowedError, "Reverse records for #{ip} are not allowed for this zone") unless reverse_allowed_in_zone?(zone, ip)

    existing = getreverse(ip)
    unless existing.empty?
      fail AlreadyExistsError, "Address #{ip} already has a reverse record (#{existing[0]})"
    end

    addptrtohost(reversezone, ptrname, "#{host}.#{zone}.")
  end

  def deletereverse(ip)
    fail(NotAllowedError, "Reverse records for #{ip} are not allowed for this zone") unless reverse_allowed_in_zone?(zone, ip)
    reversezone = getzoneforip(ip)
    ptrname = reverseip(ip).sub(".#{reversezone}", '')

    begin
      ldapconnection.delete("idnsName=#{ptrname},idnsName=#{reversezone},#{BASEDN}")
    rescue LDAP::ResultError
    end
  end

  def allowed_zone?(zone)
    Zones.each do |allowedzone|
      return true if allowedzone[0] == zone
    end

    false
  end

  def allowed_ip?(zone, ip)
    ipaddress = IPAddr.new(ip)
    Zones[zone]['sourceip'].each do |allowed_ip|
      return true if allowed_ip.include? ipaddress
    end

    false
  end

  def reverse_allowed_in_zone?(zone, ip)
    ipaddress = IPAddr.new(ip)
    Zones[zone]['managedip'].each do |managed_ip|
      return true if managed_ip.include? ipaddress
    end

    false
  end

  def host_has_ip?(zone, host, ip)
    hostips = gethost(zone, host)['ipaddress']

    unless hostips.include? ip
      return false
    end

    true
  end

  def host_has_cname?(zone, host, cname)
    hostcnames = gethost(zone, host)['cname']

    unless hostcnames.include? cname
      return false
    end

    true
  end
end

error NotFoundError do
  halt 404, { 'error' => env['sinatra.error'].message }.to_json
end

error DatabaseError do
  halt 500, { 'error' => "Database error: #{env['sinatra.error'].message}" }.to_json
end

error InvalidInputError do
  halt 400, { 'error' => "#{env['sinatra.error'].message}" }.to_json
end

error AlreadyExistsError do
  halt 409, { 'error' => "#{env['sinatra.error'].message}" }.to_json
end

error NotAllowedError do
  halt 403, { 'error' => "#{env['sinatra.error'].message}" }.to_json
end

before do
  pathmatches = request.path_info.match(/^\/([0-9a-zA-Z\.-]+)\/*.*/)
  if pathmatches
    zone = pathmatches.captures[0]

    fail(NotAllowedError, "Zone #{zone} is not managed by this host") unless allowed_zone?(zone)
    fail(NotAllowedError, "IP #{request.ip} is not allowed to manage this zone") unless allowed_ip?(zone, request.ip)
  end
end

get '/' do
  content_type :json

  getzones.to_json
end

get '/:zone/?' do
  content_type :json

  gethosts(params[:zone]).to_json
end

post '/:zone/?' do
  content_type :json

  halt 405, { 'error' => 'POST is not supported by zone resources' }.to_json
end

put '/:zone/?' do
  content_type :json

  halt 405, { 'error' => 'PUT is not supported by zone resources' }.to_json
end

delete '/:zone/?' do
  content_type :json

  halt 405, { 'error' => 'DELETE is not supported by zone resources' }.to_json
end

get '/:zone/:host/?' do
  content_type :json

  gethost(params[:zone], params[:host]).to_json
end

post '/:zone/:host/?' do
  content_type :json

  createhost(params[:zone], params[:host])

  status 206
end

put '/:zone/:host/?' do
  content_type :json

  halt 405, { 'error' => 'PUT is not supported by host resources' }.to_json
end

delete '/:zone/:host/?' do
  content_type :json

  deletehost(params[:zone], params[:host])

  status 204
end

get '/:zone/:host/ipaddress/?' do
  content_type :json

  gethost(params[:zone], params[:host])['ipaddress'].to_json
end

get '/:zone/:host/ipaddress/:ipaddress/?' do
  content_type :json
  fail(NotFoundError, "Host #{params[:host]} does not have ip #{params[:ipaddress]}") unless host_has_ip?(params[:zone], params[:host], params[:ipaddress])

  if getreverse(params[:ipaddress])[0] == "#{params[:host]}.#{params[:zone]}."
    return { 'reverse' => true }.to_json
  end

  return { 'reverse' => false }.to_json
end

post '/:zone/:host/ipaddress/:ipaddress/?' do
  content_type :json
  begin
    request_params = JSON.parse(request.body.read)
  rescue JSON::ParserError => msg
    raise InvalidInputError, "JSON parser error : #{msg}"
  end

  addiptohost(params[:zone], params[:host], params[:ipaddress])
  if request_params['reverse'] == true
    createreverse(params[:ipaddress], params[:zone], params[:host])
  end

  status 206
end

put '/:zone/:host/ipaddress/:ipaddress/?' do
  content_type :json
  begin
    request_params = JSON.parse(request.body.read)
  rescue JSON::ParserError => msg
    raise InvalidInputError, "JSON parser error : #{msg}"
  end

  fail(NotFoundError, "Host #{params[:host]} does not have ip #{params[:ipaddress]}") unless host_has_ip?(params[:zone], params[:host], params[:ipaddress])

  myreverse = false
  getreverse(params[:ipaddress]).each do |reverse|
    myreverse = true if reverse == "#{params[:host]}.#{params[:zone]}."
  end

  if request_params['reverse'] == true
    return if myreverse
    createreverse(params[:ipaddress], params[:zone], params[:host])
  else
    deletereverse(params[:ipaddress]) if myreverse
  end

  status 204
end

delete '/:zone/:host/ipaddress/:ipaddress/?' do
  content_type :json

  fail(NotFoundError, "Host #{params[:host]} does not have ip #{params[:ipaddress]}") unless host_has_ip?(params[:zone], params[:host], params[:ipaddress])

  removeipfromhost(params[:zone], params[:host], params[:ipaddress])

  status 204
end

get '/:zone/:host/cname/?' do
  content_type :json

  gethost(params[:zone], params[:host])['cname'].to_json
end

get '/:zone/:host/cname/:cname/?' do
  content_type :json
  fail(NotFoundError, "Host #{params[:host]} does not have cname #{params[:cname]}") unless host_has_cname?(params[:zone], params[:host], params[:cname])

  {}.to_json
end

post '/:zone/:host/cname/:cname/?' do
  content_type :json

  addcnametohost(params[:zone], params[:host], params[:cname])

  status 206
end

put '/:zone/:host/cname/:cname/?' do
  content_type :json

  halt 405, { 'error' => 'PUT is not supported by cname resources' }.to_json
end

delete '/:zone/:host/cname/:cname/?' do
  content_type :json

  fail(NotFoundError, "Host #{params[:host]} does not have cname #{params[:cname]}") unless host_has_cname?(params[:zone], params[:host], params[:cname])
  removecnamefromhost(params[:zone], params[:host], params[:cname])

  status 204
end
