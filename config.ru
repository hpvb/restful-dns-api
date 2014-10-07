require 'rubygems'
require 'sinatra'
require File.expand_path('../config/environment', __FILE__)

set :show_exceptions, false
set :raise_errors, false

run Sinatra::Application

