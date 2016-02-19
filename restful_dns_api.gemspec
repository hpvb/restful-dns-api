# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'restful_dns_api/version'

Gem::Specification.new do |spec|
  spec.name          = "restful_dns_api"
  spec.version       = RestfulDnsApi::VERSION
  spec.authors       = ["Hein-Pieter van Braam"]
  spec.email         = ["hp@tmm.cx"]
  spec.summary       = 'Simple RESTful DNS management API'
  spec.license       = "GPLv2+"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.7"
  spec.add_development_dependency "rake", "~> 10.0"

  spec.add_dependency "rack"
  spec.add_dependency "sinatra"
  #spec.add_dependency "ruby-ldap"
  spec.add_dependency "ipaddress"
  spec.add_dependency "json"
end
