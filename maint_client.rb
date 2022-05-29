# frozen_string_literal: true

####
# Copyright 2016-2022 John Messenger
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
####
require "rubygems"
require "bundler"
Bundler.setup(:default)

class MaintClient
  attr_accessor :logger

  # Sets up a client instance ready to query the Maintenance Database API.
  # @param [String] email 802.1 Maintenance Database username email address
  # @param [String] password 802.1 Maintenance Database password
  # @param [Boolean] debug Select debug mode
  # @param [Logger] logger A previously-created Logger object
  # @param [Hash] options Use this to pass +verify_ssl: OpenSSL::SSL::VERIFY_NONE+ for debugging with https://www.charlesproxy.com/
  # @param [String] api_uri The URI of the maintenance database API
  # @return [MaintClient] A newly-created MaintClient instance
  def initialize(email, password, debug: false, logger: nil, api_uri: "https://www.802-1.org/", options: {})
    @logger = logger
    if debug
      RestClient.proxy = "http://localhost:8888"
      logger&.debug("Using HTTP proxy #{RestClient.proxy}")
      @api = RestClient::Resource.new(api_uri, options.merge({verify_ssl: OpenSSL::SSL::VERIFY_NONE}))
    else
      @api = RestClient::Resource.new(api_uri, options)
    end

    login_request = {}
    login_request["user"] = {}
    login_request["user"]["email"] = email
    login_request["user"]["password"] = password

    res = @api["users/sign_in"].post login_request.to_json, {content_type: :json, accept: :json}
    # Save the session cookie
    @maint_cookie = {}
    res.cookies.each { |ck| @maint_cookie[ck[0]] = ck[1] if /_session/.match?(ck[0]) }
  end

  ####
  # Search the Maintenance Database for an item with the specified number and return the parsed item
  ####
  def find_item(number)
    search_result = @api["items"].get accept: :json, params: {search: number}
    items = JSON.parse(search_result.body)
    return nil if items.empty?

    this_id = items[0]["id"]
    JSON.parse(@api["items/#{this_id}"].get(accept: :json))
  end

  ####
  # Given a parsed item, return the corresponding request (if there is one)
  ####
  def find_request(item)
    itemid = item["id"]
    JSON.parse((@api["items/#{itemid}/requests"].get accept: :json).body)
  end

  ####
  # Create a new request on an existing item
  ####
  def add_request_to_item(item, new_request)
    itemid = item["id"]
    option_hash = {content_type: :json, accept: :json, cookies: @maint_cookie}
    begin
      res = @api["items/#{itemid}/requests"].post new_request.to_json, option_hash
    rescue => e
      @logger&.error "add_request_to_item => exception #{e.class.name} : #{e.message}"
      if (ej = JSON.parse(e.response)) && (eje = ej["errors"])
        eje.each do |k, v|
          @logger&.error "#{k}: #{v.first}"
        end
      end
      return nil
    end
    res
  end

  ####
  # Delete a request which is attached to an item
  ####
  def delete_request(item, request)
    option_hash = {accept: :json, cookies: @maint_cookie}
    begin
      res = @api["items/#{item["id"]}/requests/#{request["id"]}"].delete option_hash
    rescue => e
      @logger&.error "delete_request => exception #{e.class.name} : #{e.message}"
      if (ej = JSON.parse(e.response)) && (eje = ej["errors"])
        eje.each do |k, v|
          @logger&.error "#{k}: #{v.first}"
        end
      end
      return nil
    end
    res
  end

  ####
  # Create a new item and add a request to it
  ####
  def add_new_item(number, subject, request)
    item = nil
    option_hash = {content_type: :json, accept: :json, cookies: @maint_cookie}
    new_item = {number: number, clause: request["clauseno"], date: request["date"], standard: request["standard"],
                subject: subject}
    begin
      res = @api["items"].post new_item.to_json, option_hash
      location = res.headers[:location]
    rescue => e
      @logger&.error "add_new_item => exception #{e.class.name} : #{e.message}"
      if (ej = JSON.parse(e.response)) && (eje = ej["errors"])
        eje.each do |k, v|
          @logger&.error "#{k}: #{v.first}"
        end
      end
      return [nil, nil]
    end
    if res.code == 201
      item = JSON.parse(res.body)
      add_request_to_item(item, request)
    end
    [item, location]
  end
end
