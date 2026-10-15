#!/usr/bin/env ruby

require 'dotenv'
require_relative '../lib/syncer'

# Load environment variables
Dotenv.load

# Check if an export path is provided
if ARGV.empty?
  puts "Usage: #{$0} <claude_export.zip | dir with export *.zip parts>"
  exit 1
end

export_path = ARGV[0]

unless File.exist?(export_path)
  puts "Error: '#{export_path}' does not exist"
  exit 1
end

# Newer exports are split into several ZIPs (conversations-000.zip, projects-000.zip, ...);
# a directory imports all of them together
zip_paths = File.directory?(export_path) ? Dir.glob(File.join(export_path, '*.zip')).sort : [export_path]

if zip_paths.empty?
  puts "Error: No .zip files found in '#{export_path}'"
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
  redmine_closed_status_id: ENV['REDMINE_CLOSED_STATUS_ID'],
  database_path: ENV['DATABASE_PATH'],
  log_file: ENV['LOG_FILE'],
  log_level: ENV['LOG_LEVEL']&.upcase
}

# Create and run the syncer
syncer = Syncer.new(config)
syncer.sync(zip_paths) 