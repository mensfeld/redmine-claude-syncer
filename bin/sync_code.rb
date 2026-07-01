#!/usr/bin/env ruby

require 'dotenv'
require 'yaml'
require_relative '../lib/syncer'
require_relative '../lib/claude_code_processor'

# Load environment variables
Dotenv.load

# Built-in defaults, used when no config file is present. Each directory maps to a
# list of extra tags applied to every session found under it.
DEFAULT_SESSION_DIRS = {
  '~/.claude/projects' => [],
  '~/.coi/sessions-claude' => ['coi']
}.freeze

# Session directories come from config/sync_code.yml (override its path with
# SYNC_CODE_CONFIG). Its `directories:` map is `path => [extra tags]`. If the file
# is absent or empty, the built-in defaults above are used — so a plain
# `bin/sync_code.rb` with no arguments Just Works.
config_path = ENV['SYNC_CODE_CONFIG'] || File.expand_path('../config/sync_code.yml', __dir__)
configured = (YAML.safe_load(File.read(config_path)) || {})['directories'] if File.exist?(config_path)
dir_map = configured && !configured.empty? ? configured : DEFAULT_SESSION_DIRS

dir_configs = dir_map.filter_map do |path, tags|
  dir = File.expand_path(path.to_s)
  unless Dir.exist?(dir)
    puts "Warning: skipping missing session directory '#{dir}'"
    next nil
  end
  [dir, Array(tags)]
end

if dir_configs.empty?
  puts 'Error: no existing Claude Code session directories to scan'
  exit 1
end

# Configure the syncer (same Redmine settings as the conversation importer)
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

# Create and run the syncer over Claude Code sessions
syncer = Syncer.new(config)
syncer.import(ClaudeCodeProcessor.new(dir_configs))
