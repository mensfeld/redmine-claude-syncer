#!/usr/bin/env ruby

require 'dotenv'
require_relative '../lib/syncer'
require_relative '../lib/claude_code_processor'

# Load environment variables
Dotenv.load

# Resolve the Claude Code projects directory (override with CLAUDE_PROJECTS_DIR)
claude_projects_dir = ENV['CLAUDE_PROJECTS_DIR'] || File.expand_path('~/.claude/projects')

unless Dir.exist?(claude_projects_dir)
  puts "Error: Claude Code projects directory '#{claude_projects_dir}' does not exist"
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
syncer.import(ClaudeCodeProcessor.new(claude_projects_dir))
