This small ruby program runs a simple DNS management API. Currently it requires an LDAP backend to work.

# Usecase

The primary purpose for this API is to allow groups with access to an (internal) cloud to manage a separate namespace for their systems. The API and access management trivially allows automation of DNS records for private systems while remaining safe for others. 

Initially only an LDAP backend was developed because it is easy to set up an LDAP server in a higly-availble active-active setup over multiple availability zones. In the future different backends may be added.

# Runtime environment

Care was taken to ensure the software can function on a RHEL6/CentOS6 system with only EPEL sources. No non-packaged rubygems should be necessary.

# Features

* Add / remove A records
* (optional) Automatic management of PTR records
* IP based authentication for zone updates
* Limit PTR record management for subnets per zone

# Configuration file
An example configuration file is included in the 'examples' directory. 
```
---
ldap:
  server: localhost
  basedn: ou=dns,dc=example,dc=com
  binddn: cn=root,dc=example,dc=com
  bindpw: secret
reverse_zones:
  20.10.in-addr.arpa:
    - 10.20.30.0/24
    - 10.20.40.0/24
managed_zones:
  test.example.com:
    sourceip:
      - 172.16.32.0/24
    managedip:
      - 10.20.30.128/25
  test2.example.com:
    sourceip:
      - 10.20.100.0/24
      - 192.168.0.0/24
    managedip:
      - 10.20.30.128/25
```
## LDAP section
This section controls the LDAP connection the software will use

server: Servername or ip address
basedn: Basedn of your DNS root
binddn: User to bind to the directory with
bindpw: Password of the user 

Note that currently the software defaults to using ldaps. This is hardcoded at the moment.

## reverse zone section
This section controls the reverse zones that the server will be willing to control. Each zone has a set of subnets that it will be willing to create reverse records for. See the example for the syntax. 

In the example above the server will refuse to create reverse records for 10.20.50.1, for instance.

## managed zones section
This section controls the regular zones that the server will be willing to control. Each zone has two sets of subnets:
* Source ips
* Managed ips

The list of source IPs is a list of subnets from which that zone can be managed. A client originating from a different IP address will not be able to modifiy (or see) the zone.

The list of managed IPs is a list of subnets for which this zone can create reverse records. This can be a subset of the available reverse records. This allows an administrator to separate zones by VPC (If using amazon). Different cloud providers have similar systems. Cloudstack has 'networks' for instance.

# Access control
When a user tries to create a record in a zone that they are not allowed to modify based on their source IP address the following will happen:
```
curl -X PUT -H 'Content-Type: application/json' -d '{ "reverse": true }' http://dns-server/test2.example.com/server10/ipaddress/10.20.30.203 
{
   "error" : "IP 10.20.30.50 is not allowed to manage this zone"
}
```
When a user tries to create a reverse address for an address that their zone has no access to the following will happen:
```
curl -X PUT -H 'Content-Type: application/json' -d '{ "reverse": true }' http://dns-server/test.example.com/server10/ipaddress/10.20.30.1
{
   "error" : "Reverse records for 10.20.30.1 are not allowed for this zone"
}

```
Note that it is still possible to create arbitrary A records in any zone that a user can manage:
```
curl -X POST -H 'Content-Type: application/json' -d '{ "reverse": false }' http://dns-server/test.example.com/google/ipaddress/173.194.65.139
```

# The API
## Listing resources
### Managed zones
```
curl -s http://dns-server
[
   "example.com",
   "test.example.com",
   "test3.example.com"
]
```
### Host in a zone
```
curl -s http://dns-server/test.example.com
[
   "server",
   "test",
]
```
### Details of a host
```
curl -s http://dns-server/test.example.com/server
{
   "cname" : [],
   "ipaddress" : [
      "127.0.0.1"
   ]
}
```
### Details of an IP
```
curl -s http://dns-server/test.example.com/server/ipaddress/127.0.0.1
{
   "reverse" : false
}
```
Note that the 'reverse' attribute of an IP address refers to whether or not the IP has a reverse record for the host it was requested on.
```
curl -s http://dns-server/test.example.com/server10/ipaddress/10.20.30.244 
{
   "reverse" : true
}
curl -s http://dns-server/test.example.com/server11/ipaddress/10.20.30.244 
{
   "reverse" : false
}

```
## Creating resources
### Host
```
curl -X POST -H 'Content-Type: application/json' -d '{}' http://dns-server/test.example.com/server2
```
### IP address
Without a reverse address:
```
curl -X POST -H 'Content-Type: application/json' -d '{}' http://dns-server/test.example.com/server2/ipaddress/10.20.30.7
```
Or with:
```
curl -X POST -H 'Content-Type: application/json' -d '{ "reverse" => true }' http://dns-server/test.example.com/server2/ipaddress/10.20.30.7
```
Note: If a host does not exist for an IP it will also be created. This facilitates running the script automatically during system boot.
### CNAME
```
curl -X POST -H 'Content-Type: application/json' -d '{}' http://dns-server/test.example.com/server4/cname/blah.example.com
```
Note: As with IP addresses a host will be created if it does not exist.
## Deleting resources
### Host
```
curl -X DELETE http://dns-server/test.example.com/server2/
```
Note: A host deletion will also remove all reverse names that are associated with it.
### IP address
```
curl -X DELETE http://dns-server/test.example.com/server3/ipaddress/10.20.30.8
```
Note: Reverse addresses belonging to the host will also be removed
### CNAME
```
curl -X DELETE http://dns-server/test.example.com/server3/cname/blah.example.com
```
## Modifying resouces
Only IP addresses can be modified at this time, and only whether or not a reverse record for it should exist.
### IP address
Creating the reverse record
```
curl -X PUT -H 'Content-Type: application/json' -d '{ "reverse": true }' http://dns-server/test.example.com/server10/ipaddress/10.20.30.203
```
Removing the reverse record
```
curl -X PUT -H 'Content-Type: application/json' -d '{ "reverse": false }' http://dns-server/test.example.com/server10/ipaddress/10.20.30.203
```
Note: An IP address can only have ONE reverse record. The software will not allow an IP address to have multiple.
```
curl -X PUT -H 'Content-Type: application/json' -d '{ "reverse": true }' http://dns-server/test.example.com/server11/ipaddress/10.20.30.244
{
   "error" : "Address 10.20.30.244 already has a reverse record (server10.test.example.com.)"
}
```
# TODO
* Create RHEL/CentOS RPM packages
* Example single-master configuration with openldap, bind, and apache.
* Normalize error messages
* Create proper rubygem
* Split the code more logically
