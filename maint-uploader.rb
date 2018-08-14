#!/usr/bin/env ruby
####
# Copyright 2016-2017 John Messenger
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

require 'rubygems'
require 'slop'
require 'open-uri'
require 'date'
require 'json'
require 'rest-client'
require 'yaml'
require 'nokogiri'
require 'logger'

####
# Log in to the Maintenance Database API
####
def login(api, username, password)
  login_request = {}
  login_request['user'] = {}
  login_request['user']['email'] = username
  login_request['user']['password'] = password

  begin
    # {ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE}
    res = api['users/sign_in'].post login_request.to_json, { content_type: :json, accept: :json }
  rescue RestClient::ExceptionWithResponse => e
    abort "Could not log in: #{e.response.to_s}"
  end
  res
end

####
# Search the Maintenance Database for an item with the specified number and return the parsed item
####
def find_item(api, number)
  search_result = api['items'].get accept: :json, params: { search: number }
  items = JSON.parse(search_result.body)
  return nil if items.empty?
  thisid = items[0]['id']
  JSON.parse(api["items/#{thisid}"].get accept: :json)
end

####
# Given a parsed item, return the corresponding request (if there is one)
####
def find_request(api, item)
  itemid = item['id']
  JSON.parse((api["items/#{itemid}/requests"].get accept: :json).body)
end

####
# Create a new request on an existing item
####
def add_request_to_item(api, cookie, item, newreq)
  itemid = item['id']
  option_hash = { content_type: :json, accept: :json, cookies: cookie }
  begin
    res = api["items/#{itemid}/requests"].post newreq.to_json, option_hash
  rescue => e
    $logger.error "add_request_to_item => exception #{e.class.name} : #{e.message}"
    if (ej = JSON.parse(e.response)) && (eje = ej['errors'])
      eje.each do |k, v|
        $logger.error "#{k}: #{v.first}"
      end
      exit(1)
    end
  end
end

####
# Delete a request which is attached to an item
####
def delete_request(api, cookie, item, request)
  option_hash = { accept: :json, cookies: cookie }
  begin
    res = api["items/#{item['id']}/requests/#{request['id']}"].delete option_hash
  rescue => e
    $logger.error "delete_request => exception #{e.class.name} : #{e.message}"
    if (ej = JSON.parse(e.response)) && (eje = ej['errors'])
      eje.each do |k, v|
        $logger.error "#{k}: #{v.first}"
      end
      exit(1)
    end
  end
end

####
# Create a new item and add a request to it
####
def add_new_item(api, cookie, number, subject, newreq)
  item = nil
  option_hash = {content_type: :json, accept: :json, cookies: cookie}
  newitem = {number: number, clause: newreq['clauseno'], date: newreq['date'], standard: newreq['standard'],
             subject: subject}
  begin
    res = api["items"].post newitem.to_json, option_hash
  rescue => e
    $logger.error "add_new_item => exception #{e.class.name} : #{e.message}"
    if (ej = JSON.parse(e.response)) && (eje = ej['errors'])
      eje.each do |k, v|
        $logger.error "#{k}: #{v.first}"
      end
      exit(1)
    end
  end
  if res.code == 201
    item = JSON.parse(res.body)
    reqres = add_request_to_item(api, cookie, item, newreq)
  end
  item
end

####
# Given the URL of a Maintenance Reflector Archive entry, parse the text and return a hash containing the fields
####
def parse_request(url, creds)
  rqstream = open(url, http_basic_authentication: creds)
  rqdoc = Nokogiri::HTML(rqstream)
  text = rqdoc.xpath('//body//text()').to_s     # this is a really cool line
  return nil unless /^\+------------------------/.match(text)
  return nil unless /^| IEEE 802.+ REVISION REQUEST/.match(text)
  fields = {}
  # Get the date from the "Head-of-Message" because that's the date it was *really* posted.
  rqdoc.at('ul').search('li').each do |li|
    em = li.at('em')
    if /Date/.match(em.children.to_s)
      fields['date'] = Date.parse(li.children[1].to_s[2..-1])
      break
    end
  end

  # Get the remaining fields from the stylised form
  # NAME
  matches = /^NAME:\s*(?<name>.+)\n/.match(text)
  unless matches
    $logger.warn "Parse error (name) in Request #{url}"
    return nil
  end
  fields.merge!(Hash[ matches.names.zip(matches.captures)])

  # COMPANY/AFFILIATION
  matches = /^COMPANY\/AFFILIATION:\s*(?<company>.+)\n/.match(text)
  unless matches
    $logger.warn "Parse error (company) in Request #{url}"
    return nil
  end
  fields.merge!(Hash[ matches.names.zip(matches.captures)])

  # E-MAIL
  matches = /^E-MAIL:\s*(?<email>.+)\n/.match(text)
  unless matches
    $logger.warn "Parse error (email) in Request #{url}"
    return nil
  end
  fields.merge!(Hash[ matches.names.zip(matches.captures)])

  # STANDARD
  matches = /^\s*STANDARD:\s*(?<standard>.+)\n/.match(text)
  unless matches
    $logger.warn "Parse error (standard) in Request #{url}"
    return nil
  end
  fields.merge!(Hash[ matches.names.zip(matches.captures)])

  # CLAUSE NUMBER
  matches = /^\s*CLAUSE NUMBER:\s*(?<clauseno>.*)\n/.match(text)
  unless matches
    $logger.warn "Parse error (clauseno) in Request #{url}"
    return nil
  end
  fields.merge!(Hash[ matches.names.zip(matches.captures)])

  # CLAUSE TITLE
  matches = /^\s*CLAUSE TITLE:\s*(?<clausetitle>.*)\n/.match(text)
  unless matches
    $logger.warn "Parse error (clausetitle) in Request #{url}"
    return nil
  end
  fields.merge!(Hash[ matches.names.zip(matches.captures)])

  # The "Rationale", "Proposed Revision" and "Impact" sections are parsed using a line-based scheme.  This isn't very
  # good.  What's more, it turns out that there can be embedded HTML in the message body.
  bin = :bin
  collection = {}
  textcollection = ''
  text.each_line do |line|
    if /^RATIONALE/.match(line)
      collection[bin] = textcollection.strip
      textcollection = ''
      bin = :rationale
      next
    elsif /^PROPOSED REVISION/.match(line)
      collection[bin] = textcollection.strip
      textcollection = ''
      bin = :proposal
      next
    elsif /^IMPACT ON EXISTING/.match(line)
      collection[bin] = textcollection.strip
      textcollection = ''
      bin = :impact
      next
    end
    break if /\+------------------------/.match(line) and bin != :bin
    textcollection << line
  end
  collection[bin] = textcollection.strip
  fields['rationale'] = collection[:rationale]
  fields['proposal'] = collection[:proposal]
  fields['impact'] = collection[:impact]
  twit = 10
  fields
end

begin
  opts = Slop.parse do |o|
    o.string '-s', '--secrets', 'secrets YAML file name', default: 'secrets.yml'
    o.bool   '-d', '--debug', 'debug mode'
    o.bool   '-a', '--all', 'don\'t stop at first already-existing item'
    o.on '--help' do
      STDERR.puts o
      exit
    end
  end
  config = YAML.load(File.read(opts[:secrets]))

  # Set up logging
  $DEBUG = opts.debug?
  $logger = Logger.new(STDERR)
  $logger.level = Logger::INFO
  $logger.level = Logger::DEBUG if $DEBUG
#
# Log in to the 802.1 Maintenance Database
#
  if $DEBUG
    RestClient.proxy = "http://localhost:8888"
    $logger.debug("Using HTTP proxy #{RestClient.proxy}")
    maint = RestClient::Resource.new(config['api_uri'], verify_ssl: OpenSSL::SSL::VERIFY_NONE)
  else
    maint = RestClient::Resource.new(config['api_uri'])
  end

  res = login(maint, config['email'], config['password'])
# Save the session cookie
  maint_cookie = {}
  res.cookies.each { |ck| maint_cookie[ck[0]] = ck[1] if /_session/.match(ck[0]) }

#
# Parse each index page of the 802.1 Maintenance Reflector Archive
# and find the maintenance items
#
  em_arch_url = config['email_archive'] + '/' + config['email_start']
  mtarch_creds = [config['archive_user'], config['archive_password']]
  num_requests = 0
  num_responses = 0
  num_malformed_title = 0
  num_unfound_items = 0
  num_requests_deleted = 0
  num_requests_parsed_ok = 0
  num_items_added = 0
  num_requests_added_to_existing_items = 0

  catch :done do
    while em_arch_url do
      page = open(em_arch_url, http_basic_authentication: mtarch_creds) { |f| f.read }
      pagedoc = Nokogiri::HTML(page)
      pagedoc.at('ul').search('li').each do |el|
        next unless el.children[0].name =~ /strong/
        # For each message...
        num_requests += 1
        href = el.children[0].children[0].attributes['href'].to_s
        url = config['email_archive'] + '/' + href
        titlestr = el.children[0].children[0].children[0].to_s
        if titlestr =~ /^[Rr][Ee]/ # discard responses to other maintenance items
          num_responses += 1
          next
        end
        mtchdata = /^\[802.1_maint_req - (?<number>\d+)\] (?<title>.+)/.match(titlestr)
        unless mtchdata
          num_malformed_title += 1
          next
        end
        number = "%04d" % mtchdata['number']
        title = mtchdata['title']
        $logger.debug "#{number}: #{title}: #{url}"
        if config['blacklist'].include? number
          $logger.info "Ignoring blacklisted item #{number}"
          next
        end

        #
        # Find the item in the database, and its corresponding request
        #
        item = find_item(maint, number)
        request = {}
        if item
          unless opts[:all]
            $logger.info "Stopping at first already-existing item (#{number})"
            throw :done
          end
          request = find_request(maint, item)
          if $DELETE_ALL_REQUESTS && !request.empty?
            delete_request(maint, maint_cookie, item, request)
            $logger.warn "Deleting item #{number}"
            num_requests_deleted += 1
            request = {}
          end
        else
          $logger.info "Item #{number} not found"
          num_unfound_items += 1
        end

        #
        # If there's no request, parse the corresponding archive entry to get the fields.
        # If we can parse the request, then create the item and/or the request in the database
        #
        if request.empty?
          newreq = parse_request(url, mtarch_creds)
          if newreq
            num_requests_parsed_ok += 1
            if item.nil?
              add_new_item(maint, maint_cookie, number, title, newreq)
              num_items_added += 1
              $logger.info "Added new item #{number}"
            else
              add_request_to_item(maint, maint_cookie, item, newreq)
              num_requests_added_to_existing_items += 1
            end
          else
            $logger.warn "Could not parse request for item #{number} at #{url}"
          end
        end
      end
      nextpage = pagedoc.search('tr')[1].children.search('td').children[4].attributes['href']
      em_arch_url = nextpage ? config['email_archive'] + '/' + nextpage.value : nil
    end
  end


  puts("num_requests: #{num_requests}\n")
  puts("num_responses: #{num_responses}\n")
  puts("num_malformed_title: #{num_malformed_title}\n")
  puts("num_unfound_items: #{num_unfound_items}\n")
  puts("num_requests_deleted: #{num_requests_deleted}\n")
  puts("num_requests_parsed_ok: #{num_requests_parsed_ok}\n")
  puts("num_items_added: #{num_items_added}\n")
  puts("num_requests_added_to_existing_items: #{num_requests_added_to_existing_items}\n")

rescue StopIteration

end
