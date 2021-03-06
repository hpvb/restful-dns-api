#!/usr/bin/env ruby

# Copyright (C) 2014 Hein-Pieter van Braam <hp@tmm.cx>
#
# This file is part of Simple RESTful DNS api.
#
# Simple RESTful DNS api is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# Simple RESTful DNS api is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Simple RESTful DNS api. If not, see <http://www.gnu.org/licenses/>.

require 'rubygems'
require 'sinatra'
require 'json'
require 'ipaddr'
require 'ipaddress'
require 'ldap'
require 'restful_dns_api/version'

module RestfulDnsApi
  class App < Sinatra::Base
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
          ldapquery(BASEDN, LDAP::LDAP_SCOPE_SUBTREE, '(objectClass=idnsZone)', ['idnsName']) do |entry|
            zones.push entry['idnsName'][0] unless entry['idnsName'][0].end_with?('.in-addr.arpa')
          end
        rescue NotFoundError
          raise NotFoundError, 'No zones found'
        end

        zones
      end

      def zone_exists?(zone)
        begin
          ldapconnection.search("idnsName=#{zone},#{BASEDN}", LDAP::LDAP_SCOPE_BASE, '(objectClass=*)', %w(aRecord cNAMERecord)) do |_entry|
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
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAmName', [ZoneDefaults['soa']['mname']]),
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOArName', [ZoneDefaults['soa']['rname']]),
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAserial', ['1']),
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOArefresh', [ZoneDefaults['soa']['refresh']]),
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAretry', [ZoneDefaults['soa']['retry']]),
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAexpire', [ZoneDefaults['soa']['expire']]),
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsSOAminimum', [ZoneDefaults['soa']['minimum']]),
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'NSRecord', ZoneDefaults['nameservers'])
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
          ldapquery("idnsName=#{zone},#{BASEDN}", LDAP::LDAP_SCOPE_ONELEVEL, '(objectClass=idnsRecord)', %w(idnsName)) do |entry|
            hosts.push entry['idnsName'][0]
          end
        rescue NotFoundError
          raise NotFoundError, "No hosts found in zone #{zone}"
        end

        hosts
      end

      def gethost(zone, host)
        hostdata = {}

        begin
          ldapquery("idnsName=#{host},idnsName=#{zone},#{BASEDN}", LDAP::LDAP_SCOPE_BASE, '(objectClass=*)', %w(aRecord cNAMERecord dNSTTL)) do |entry|
            hostdata['ipaddress'] = entry['aRecord'] || []
            hostdata['cname'] = entry['cNAMERecord'] || []
            if entry['dNSTTL']
              hostdata['ttl'] = entry['dNSTTL'][0]
            else
              hostdata['ttl'] = nil
            end
          end
        rescue NotFoundError
          raise NotFoundError, "Host #{host} not found in zone #{zone}"
        end

        hostdata
      end

      def host_exists?(zone, host)
        begin
          ldapconnection.search("idnsName=#{host},idnsName=#{zone},#{BASEDN}", LDAP::LDAP_SCOPE_BASE, '(objectClass=*)', %w(aRecord cNAMERecord)) do |_entry|
          end
        rescue LDAP::ResultError
          return false
        rescue RuntimeError
          return false
        end

        true
      end

      def createhost(zone, host, ttl)
        createzone(zone) unless zone_exists?(zone)
        fail(InvalidInputError, "#{host} is not a valid RFC1123 hostname") unless host =~ /#{ValidHostRegex}/

        createrecord(zone, host, ttl)
      end

      def createptr(zone, ptr, ttl)
        createzone(zone) unless zone_exists?(zone)
        createrecord(zone, ptr, ttl)
      end

      def createrecord(zone, name, ttl)
        entry = [
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'objectClass', %w(top idnsRecord)),
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'idnsName', [name])
        ]

        entry.push(LDAP.mod(LDAP::LDAP_MOD_ADD, 'dNSTTL', [ttl.to_s])) if ttl

        begin
          ldapconnection.add("idnsName=#{name},idnsName=#{zone},#{BASEDN}", entry)
         rescue LDAP::ResultError => msg
           raise DatabaseError, msg
        end
      end

      def addiptohost(zone, host, ipaddress)
        fail(InvalidInputError, "#{ipaddress} is not a valid ip address") unless IPAddress.valid? ipaddress

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

        reverse = getreverse(ipaddress)

        return unless reverse['record']
        deletereverse(zone, ipaddress) if reverse['record'][0] == "#{host}.#{zone}."
      end

      def addptrtohost(zone, host, ptraddress, ttl)
        createptr(zone, host, ttl) unless host_exists?(zone, host)

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

        operation = [
          LDAP.mod(LDAP::LDAP_MOD_ADD, 'cNAMERecord', [cname])
        ]

        begin
          modifyhost(zone, host, operation)
        rescue AlreadyExistsError
          raise AlreadyExistsError, "Host #{host} in zone #{zone} already has cname #{cname}"
        end
      end

      def removecnamefromhost(zone, host, cname)
        operation = [
          LDAP.mod(LDAP::LDAP_MOD_DELETE, 'cNAMERecord', [cname])
        ]

        begin
          modifyhost(zone, host, operation)
        rescue NotFoundError
          raise NotFoundError, "Host #{host} in zone #{zone} does not have cname #{cname}"
        end
      end

      def changettlforhost(zone, host, ttl)
        hostdata = gethost(zone, host);
        if hostdata['ttl']
          operation = [
            LDAP.mod(LDAP::LDAP_MOD_REPLACE, 'dNSTTL', [ttl.to_s])
          ]
        else
          operation = [
            LDAP.mod(LDAP::LDAP_MOD_ADD, 'dNSTTL', [ttl.to_s])
          ]
        end

        begin
          modifyhost(zone, host, operation)
        rescue NotFoundError
          raise NotFoundError, "Host #{host} in zone #{zone} does not have a TTL"
        end

        hostdata['ipaddress'].each do |ipaddress|
          reverse = getreverse(ipaddress)
          return unless reverse['record']

          if reverse['record'][0] == "#{host}.#{zone}."
            reversezone = getzoneforip(ipaddress)
            ptrname = reverseip(ipaddress).sub(".#{reversezone}", '')
            if reverse['ttl'] 
              operation = [
                LDAP.mod(LDAP::LDAP_MOD_REPLACE, 'dNSTTL', [ttl.to_s])
              ]
            else
              operation = [
                LDAP.mod(LDAP::LDAP_MOD_ADD, 'dNSTTL', [ttl.to_s])
              ]
            end

            modifyhost(reversezone, ptrname, operation)
          end
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

        reversedata = {}
        begin
          ldapconnection.search("idnsName=#{ptrname},idnsName=#{reversezone},#{BASEDN}", LDAP::LDAP_SCOPE_BASE, '(objectClass=*)', %w(pTRRecord dNSTTL)) do |entry|
            reversedata['record'] = entry['pTRRecord']
            if entry['dNSTTL']
              reversedata['ttl'] = entry['dNSTTL'][0]
            else
              reversedata['ttl'] = nil
            end
          end
        rescue LDAP::ResultError
        end

        reversedata
      end

      def reverseip(ipaddress)
        reverseip = IPAddr.new ipaddress
        reverseip.reverse
      end

      def createreverse(ip, zone, host, replace = false)
        reversezone = getzoneforip(ip)
        ptrname = reverseip(ip).sub(".#{reversezone}", '')
        fail(NotAllowedError, "Reverse zones for #{ip} are not managed by this host") unless reversezone
        fail(NotAllowedError, "Reverse records for #{ip} are not allowed for this zone") unless reverse_allowed_in_zone?(zone, ip)

        existing = getreverse(ip)
        if getreverse(ip)['record']
          unless replace
            fail AlreadyExistsError, "Address #{ip} already has a reverse record (#{existing['record'][0]})"
          end

          deletereverse(zone, ip)
        end

        hostdata = gethost(zone, host)
        addptrtohost(reversezone, ptrname, "#{host}.#{zone}.", hostdata['ttl'])
      end

      def deletereverse(zone, ip)
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

      def is_boolean?(val)
        return true if val.is_a?(TrueClass)
        return true if val.is_a?(FalseClass)

        false
      end

      def is_numeric?(val)
        return true if val.is_a? Integer
        !!(val =~ /\A[0-9]+\z/)
      end

      def parse_postdata(data)
        begin
          postdata = JSON.parse(data)
        rescue JSON::ParserError => msg
          raise InvalidInputError, "JSON parser error : #{msg}"
        end

        if postdata['reverse']
          unless is_boolean? postdata['reverse']
            fail InvalidInputError, 'Reverse must be a boolean value'
          end
        else
          postdata['reverse'] = false
        end

        if postdata['ttl']
          unless is_numeric? postdata['ttl']
            fail InvalidInputError, 'TTL must be a number'
          end
        end

        postdata
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
      content_type 'application/json'

      pathmatches = request.path_info.match(/^\/([0-9a-zA-Z\.-]+)\/*.*/)
      if pathmatches
        zone = pathmatches.captures[0]

        fail(NotAllowedError, "Zone #{zone} is not managed by this host") unless allowed_zone?(zone)
        fail(NotAllowedError, "IP #{request.ip} is not allowed to manage this zone") unless allowed_ip?(zone, request.ip)
      end
    end

    get '/' do
      getzones.to_json
    end

    get '/:zone/?' do
      gethosts(params[:zone]).to_json
    end

    post '/:zone/?' do
      halt 405, { 'error' => 'POST is not supported by zone resources' }.to_json
    end

    put '/:zone/?' do
      halt 405, { 'error' => 'PUT is not supported by zone resources' }.to_json
    end

    delete '/:zone/?' do
      halt 405, { 'error' => 'DELETE is not supported by zone resources' }.to_json
    end

    get '/:zone/:host/?' do
      gethost(params[:zone], params[:host]).to_json
    end

    post '/:zone/:host/?' do
      postdata = parse_postdata(request.body.read)
      createhost(params[:zone], params[:host], postdata['ttl'])

      status 206
    end

    put '/:zone/:host/?' do
      postdata = parse_postdata(request.body.read)
      unless postdata['ttl']
        halt 400, { 'error' => "TTL value is mandatory" }.to_json
      end

      changettlforhost(params[:zone], params[:host], postdata['ttl'])
      gethost(params[:zone], params[:host]).to_json
    end

    delete '/:zone/:host/?' do
      deletehost(params[:zone], params[:host])

      status 204
    end

    get '/:zone/:host/ipaddress/?' do
      gethost(params[:zone], params[:host])['ipaddress'].to_json
    end

    get '/:zone/:host/ipaddress/:ipaddress/?' do
      unless host_has_ip?(params[:zone], params[:host], params[:ipaddress])
        fail(NotFoundError, "Host #{params[:host]} does not have ip #{params[:ipaddress]}")
      end

      if getreverse(params[:ipaddress])['record'][0] == "#{params[:host]}.#{params[:zone]}."
        return { 'reverse' => true }.to_json
      end

      return { 'reverse' => false }.to_json
    end

    post '/:zone/:host/ipaddress/:ipaddress/?' do
      postdata = parse_postdata(request.body.read)
      replace = request['replace'] == 'true'

      createhost(params[:zone], params[:host], postdata['ttl']) unless host_exists?(params[:zone], params[:host])
      addiptohost(params[:zone], params[:host], params[:ipaddress])
      if postdata['reverse'] == true
        createreverse(params[:ipaddress], params[:zone], params[:host], replace)
      end

      status 206
    end

    put '/:zone/:host/ipaddress/:ipaddress/?' do
      postdata = parse_postdata(request.body.read)
      replace = request['replace'] == 'true'

      unless host_has_ip?(params[:zone], params[:host], params[:ipaddress])
        fail(NotFoundError, "Host #{params[:host]} does not have ip #{params[:ipaddress]}")
      end

      myreverse = false
      reverse = getreverse(params[:ipaddress])
      if reverse['record']
        myreverse = true if reverse['record'][0] == "#{params[:host]}.#{params[:zone]}."
      end

      if postdata['reverse'] == true
        return if myreverse
        createreverse(params[:ipaddress], params[:zone], params[:host], replace)
      else
        deletereverse(params[:zone], params[:ipaddress]) if myreverse
      end

      status 204
    end

    delete '/:zone/:host/ipaddress/:ipaddress/?' do
      unless host_has_ip?(params[:zone], params[:host], params[:ipaddress])
        fail(NotFoundError, "Host #{params[:host]} does not have ip #{params[:ipaddress]}")
      end

      removeipfromhost(params[:zone], params[:host], params[:ipaddress])

      status 204
    end

    get '/:zone/:host/cname/?' do
      gethost(params[:zone], params[:host])['cname'].to_json
    end

    get '/:zone/:host/cname/:cname/?' do
      unless host_has_cname?(params[:zone], params[:host], params[:cname])
        fail(NotFoundError, "Host #{params[:host]} does not have cname #{params[:cname]}")
      end

      {}.to_json
    end

    post '/:zone/:host/cname/:cname/?' do
      postdata = parse_postdata(request.body.read)

      createhost(params[:zone], params[:host], postdata['ttl']) unless host_exists?(params[:zone], params[:host])
      addcnametohost(params[:zone], params[:host], params[:cname])

      status 206
    end

    put '/:zone/:host/cname/:cname/?' do
      halt 405, { 'error' => 'PUT is not supported by cname resources' }.to_json
    end

    delete '/:zone/:host/cname/:cname/?' do
      unless host_has_cname?(params[:zone], params[:host], params[:cname])
        fail(NotFoundError, "Host #{params[:host]} does not have cname #{params[:cname]}")
      end

      removecnamefromhost(params[:zone], params[:host], params[:cname])

      status 204
    end
  end
end
