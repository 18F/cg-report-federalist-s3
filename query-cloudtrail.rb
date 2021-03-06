#!/usr/bin/env ruby
# frozen_string_literal: true

require 'aws-sdk-cloudtrail'
require 'aws-sdk-s3'
require 'yaml'

REPORT_DATE = Time.now.strftime('%F')

def main
  raise ArgumentError, "Usage: #{$0} tf_state.yml output_file_path" unless ARGV.length == 2
  tf_state = ARGV.fetch(0)
  output_file_path = ARGV.fetch(1)

  cg_cloudtrail = Aws::CloudTrail::Client.new(cg_client_creds(tf_state))
  fed_cloudtrail = Aws::CloudTrail::Client.new(fed_client_creds)

  events = []

  puts "Gathering events for old buckets:"
  add_bucket_events(events, old_buckets, cg_cloudtrail)

  puts "Gathering events for new buckets:"
  add_bucket_events(events, new_buckets, fed_cloudtrail)

  puts "Writing json file to #{output_file_path}"
  File.open(output_file_path, 'w') do |f|
    f.puts(JSON.pretty_generate(events,
                                object_nl: "\n",
                                arrary_nl: "\n",
                                indent: "  "))
  end
end

def add_bucket_events(event_list, bucket_list, cloudtrail_client)
  bucket_list.each do |bucket|
    print "  #{bucket}"
    events = events_for_bucket(cloudtrail_client, bucket)
    puts " - #{events.length} events"
    event_list.push(*events)
  end
end

def cg_client_creds(tf_state)
  { access_key_id:     tf_output(tf_state, 'federalist_auditor_access_key_id_curr'),
    secret_access_key: tf_output(tf_state, 'federalist_auditor_secret_access_key_curr') }
end

def tf_output(tf_state, key)
  yaml = YAML.load_file(tf_state)
  yaml.fetch('terraform_outputs').fetch(key)
end

def fed_client_creds
  return {
    access_key_id: ENV.fetch('FED_AWS_ACCESS_KEY_ID'),
    secret_access_key: ENV.fetch('FED_AWS_SECRET_ACCESS_KEY')
  }
end

def old_buckets
  ENV.fetch("OLD_BUCKETS", "").split(" ")
end

def new_buckets
  fed_s3 = Aws::S3::Client.new(fed_client_creds)
  return fed_s3.list_buckets.buckets.map(&:name).grep(%r{federalist})
end

def events_for_bucket(cloudtrail_client, name)
  # We sleep here to avoid rate limiting (2 req/second)
  sleep(0.6)
  events = []
  lookup_attributes = [{attribute_key: "ResourceName", attribute_value: name}]
  response = cloudtrail_client.lookup_events(lookup_attributes: lookup_attributes)
  response.events.each do |event|
    events.append({
      report_date: REPORT_DATE,
      bucket_name: name,
      username: event.username,
      event_id: event.event_id,
      event_name: event.event_name,
      event_time: event.event_time.utc,
    })
  end
  return events
end

main unless defined?(::RSpec)
