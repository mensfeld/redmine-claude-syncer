#!/usr/bin/env ruby

require 'dotenv'
require_relative '../lib/syncer'

# Load environment variables
Dotenv.load

# Check if ZIP file path is provided
if ARGV.empty?
  puts "Usage: #{$0} <claude_export.zip>"
  exit 1
end

zip_path = ARGV[0]

unless File.exist?(zip_path)
  puts "Error: File '#{zip_path}' does not exist"
  exit 1
end

# Configure the syncer
config = {
  redmine_url: ENV['REDMINE_URL'],
  redmine_human_api_key: ENV['REDMINE_HUMAN_API_KEY'],
  redmine_claude_api_key: ENV['REDMINE_CLAUDE_API_KEY'],
  redmine_project_id: ENV['REDMINE_PROJECT_ID'],
  redmine_human_user_id: ENV['REDMINE_HUMAN_USER_ID'],
  redmine_claude_user_id: ENV['REDMINE_CLAUDE_USER_ID'],
  redmine_tracker_id: ENV['REDMINE_TRACKER_ID'],
  redmine_status_id: ENV['REDMINE_STATUS_ID'],
  redmine_priority_id: ENV['REDMINE_PRIORITY_ID'],
  database_path: ENV['DATABASE_PATH'],
  log_file: ENV['LOG_FILE'],
  log_level: ENV['LOG_LEVEL']&.upcase
}

# Create and run the syncer
syncer = Syncer.new(config)
syncer.sync(zip_path) 