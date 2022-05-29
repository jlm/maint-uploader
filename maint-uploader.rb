#!/usr/bin/env ruby
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
require "bundler/setup"
Bundler.require
require "./maint_client"

####
# Given the URL of a Maintenance Reflector Archive entry, parse the text and return a hash containing the fields
####
def parse_request(url, creds, logger: nil)
  begin
    request_stream = URI.parse(url).open(http_basic_authentication: creds, redirect: false)
  rescue => e
    # NOTE: OPENuri won't redirect and then re-use the basic authentication.  This appears to be deliberate, though
    # it results in a misleading error message.  So, we rescue on a redirect and re-state the authentication.
    if e.is_a?(OpenURI::HTTPRedirect)
      request_stream = e.uri.open(http_basic_authentication: creds, redirect: false)
    else
      logger&.error "Opening email archive => exception #{e.class.name} : #{e.message}"
      exit(1)
    end
  end
  parsed_request = Nokogiri::HTML(request_stream)
  text = parsed_request.xpath("//body//text()").to_s # this is a really cool line
  text.gsub!("&nbsp;", " ") # this is for Mick.  It's not a proper job though.
  return nil unless /^\+------------------------/.match?(text)
  return nil unless /^| IEEE 802.+ REVISION REQUEST/.match?(text)

  fields = {}
  # Get the date from the "Head-of-Message" because that's the date it was *really* posted.
  parsed_request.at("ul").search("li").each do |li|
    em = li.at("em")
    if /Date/.match?(em.children.to_s)
      fields["date"] = Date.parse(li.children[1].to_s[2..])
      break
    end
  end

  # Get the remaining fields from the stylised form
  # NAME
  matches = /^NAME:\s*(?<name>.+)\n/.match(text)
  unless matches
    logger&.warn "Parse error (name) in Request #{url}"
    return nil
  end
  fields.merge!(matches.names.zip(matches.captures).to_h)

  # COMPANY/AFFILIATION
  matches = /^COMPANY\/AFFILIATION:\s*(?<company>.+)\n/.match(text)
  unless matches
    logger&.warn "Parse error (company) in Request #{url}"
    return nil
  end
  fields.merge!(matches.names.zip(matches.captures).to_h)

  # E-MAIL
  matches = /^E-MAIL:\s*(?<email>.+)\n/.match(text)
  unless matches
    logger&.warn "Parse error (email) in Request #{url}"
    return nil
  end
  fields.merge!(matches.names.zip(matches.captures).to_h)

  # STANDARD
  matches = /^\s*STANDARD:\s*(?<standard>.+)\n/.match(text)
  unless matches
    logger&.warn "Parse error (standard) in Request #{url}"
    return nil
  end
  fields.merge!(matches.names.zip(matches.captures).to_h)

  # CLAUSE NUMBER
  matches = /^\s*CLAUSE NUMBER:\s*(?<clauseno>.*)\n/.match(text)
  unless matches
    logger&.warn "Parse error (clauseno) in Request #{url}"
    return nil
  end
  fields.merge!(matches.names.zip(matches.captures).to_h)

  # CLAUSE TITLE
  matches = /^\s*CLAUSE TITLE:\s*(?<clausetitle>.*)\n/.match(text)
  unless matches
    logger&.warn "Parse error (clausetitle) in Request #{url}"
    return nil
  end
  fields.merge!(matches.names.zip(matches.captures).to_h)

  # The "Rationale", "Proposed Revision" and "Impact" sections are parsed using a line-based scheme.  This isn't very
  # good.  What's more, it turns out that there can be embedded HTML in the message body.
  bin = :bin
  collection = {}
  text_collection = +""
  text.each_line do |line|
    case line
    when /^RATIONALE/
      collection[bin] = text_collection.strip
      text_collection = +""
      bin = :rationale
      next
    when /^PROPOSED REVISION/
      collection[bin] = text_collection.strip
      text_collection = +""
      bin = :proposal
      next
    when /^IMPACT ON EXISTING/
      collection[bin] = text_collection.strip
      text_collection = +""
      bin = :impact
      next
    else
      # do nothing
      bin
    end
    break if /\+------------------------/.match(line) && (bin != :bin)

    text_collection << line
  end

  collection[bin] = text_collection.strip
  fields["rationale"] = collection[:rationale]
  fields["proposal"] = collection[:proposal]
  fields["impact"] = collection[:impact]
  fields
end

def post_slack_announcement(slack, it, item_url, new_request)
  slack_data = {
    attachments: [
      {
        fallback: "New item #{it["number"]}: #{it["subject"]}",
        color: "good",
        author_name: (new_request["name"]).to_s,
        author_link: "mailto:#{new_request["email"]}",
        pretext: "New Maintenance item",
        title: "Item \##{it["number"]}: #{it["subject"]}",
        title_link: item_url,
        text: new_request["rationale"],
        fields: [
          {
            title: "Standard",
            value: it["standard"],
            short: true
          },
          {
            title: "Clause",
            value: it["clause"],
            short: true
          }
        ],
        footer: "802.1",
        footer_icon: "https://platform.slack-edge.com/img/default_application_icon.png",
        ts: Date.parse(it["date"]).to_time.to_i
      }
    ]
  }
  slack&.post slack_data.to_json, {content_type: :json, accept: :json}
end

def fetch_page(url, creds, logger)
  begin
    page = URI.parse(url).open(http_basic_authentication: creds, redirect: false, &:read)
  rescue => e
    # NOTE: OPENuri won't redirect and then re-use the basic authentication.  This appears to be deliberate, though
    # it results in a misleading error message.  So, we rescue on a redirect and re-state the authentication.
    if e.is_a?(OpenURI::HTTPRedirect)
      page = e.uri.open(http_basic_authentication: creds, redirect: false, &:read)
    else
      logger.error "Opening email archive => exception #{e.class.name} : #{e.message}"
      exit(1)
    end
  end
  page
end

DELETE_ALL_REQUESTS = false
# rubocop:disable Layout/ExtraSpacing

#
# Main program
#
begin
  opts = Slop.parse do |o|
    o.string "-s", "--secrets", "secrets YAML file name", default: "secrets.yml"
    o.bool   "-d", "--debug", "debug mode"
    o.bool   "-p", "--slackpost", "post alerts to Slack for new items"
    o.bool   "-a", "--all", "don't stop at first already-existing item"
    o.on "--help" do
      warn o
      exit
    end
  end
  # noinspection RubyResolve
  config = YAML.safe_load(File.read(opts[:secrets]))
  # rubocop:enable all

  # Set up logging
  debug = opts.debug?
  logger = Logger.new($stderr)
  logger.level = Logger::INFO
  logger.level = Logger::DEBUG if debug

  # Connect to the maintenance database
  begin
    maint = MaintClient.new(config["email"], config["password"], api_uri: config["api_uri"], logger: logger, debug: debug)
  rescue => e
    logger.fatal("Maintenance database: #{e.message}")
    abort(e.message)
  end

  # If we are posting to Slack, open the Slack webhook
  slack = if opts[:slackpost]
    RestClient::Resource.new(config["slack_webhook"])
  end

  #
  # Parse each index page of the 802.1 Maintenance Reflector Archive
  # and find the maintenance items
  #
  em_arch_url = config["email_archive"] + "/" + config["email_start"]
  archive_creds = [config["archive_user"], config["archive_password"]]
  num_requests = 0
  num_responses = 0
  num_malformed_title = 0
  num_unfound_items = 0
  num_requests_deleted = 0
  num_requests_parsed_ok = 0
  num_items_added = 0
  num_reqs_added_to_exist_items = 0

  catch :done do
    while em_arch_url
      parsed_page = Nokogiri::HTML(fetch_page(em_arch_url, archive_creds, logger))
      parsed_page.at("ul").search("li").each do |el|
        next unless /strong/.match?(el.children[0].name)

        # For each message...
        num_requests += 1
        href = el.children[0].children[0].attributes["href"].to_s
        url = config["email_archive"] + "/" + href
        title_string = el.children[0].children[0].children[0].to_s
        if /^[Rr][Ee]/.match?(title_string) # discard responses to other maintenance items
          num_responses += 1
          next
        end
        match_data = /^\[802.1_maint_req - (?<number>\d+)\] (?<title>.+)/.match(title_string)
        unless match_data
          num_malformed_title += 1
          next
        end
        number = "%04d" % match_data["number"]
        title = match_data["title"]
        logger.debug "#{number}: #{title}: #{url}"
        if config["blacklist"].include? number
          logger.info "Ignoring blacklisted item #{number}"
          next
        end

        # Find the item in the database, and its corresponding request
        item = maint.find_item(number)
        request = {}
        if item
          unless opts[:all]
            logger.info "Stopping at first already-existing item (#{number})"
            throw :done
          end
          request = maint.find_request(item)
          if DELETE_ALL_REQUESTS && !request.empty?
            logger.warn "Deleting request from item #{number}"
            num_requests_deleted += 1 if maint.delete_request(item, request)
            request = {}
          end
        else
          logger.info "Item #{number} not found"
          num_unfound_items += 1
        end

        # If there's no request, parse the corresponding archive entry to get the fields.
        next unless request.empty?

        # If we can parse the request, then create the item and/or the request in the database
        new_request = parse_request(url, archive_creds)
        if new_request
          num_requests_parsed_ok += 1
          if item.nil?
            (it, item_url) = maint.add_new_item(number, title, new_request)
            if it
              num_items_added += 1
              logger.info "Added new item #{number} at #{item_url}"
            else
              logger.error "Failed to add new item #{number}"
              next
            end
            post_slack_announcement(slack, it, item_url, new_request) if opts[:slackpost]
          elsif maint.add_request_to_item(item, new_request)
            num_reqs_added_to_exist_items += 1
          else
            logger.error "Adding request to item #{number} failed"
          end
        else
          logger.warn "Could not parse request for item #{number} at #{url}"
        end
      end
      next_page = parsed_page.search("tr")[1].children.search("td").children[4].attributes["href"]
      em_arch_url = next_page ? config["email_archive"] + "/" + next_page.value : nil
    end
  end

  puts("num_requests: #{num_requests}\n")
  puts("num_responses: #{num_responses}\n")
  puts("num_malformed_title: #{num_malformed_title}\n")
  puts("num_unfound_items: #{num_unfound_items}\n")
  puts("num_requests_deleted: #{num_requests_deleted}\n")
  puts("num_requests_parsed_ok: #{num_requests_parsed_ok}\n")
  puts("num_items_added: #{num_items_added}\n")
  puts("num_requests_added_to_existing_items: #{num_reqs_added_to_exist_items}\n")
rescue StopIteration
  # Ignored
end
