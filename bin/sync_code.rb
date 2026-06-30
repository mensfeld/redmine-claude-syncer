#!/usr/bin/env ruby

require 'dotenv'
require_relative '../lib/syncer'
require_relative '../lib/claude_code_processor'

# Load environment variables
Dotenv.load

# Resolve the session directories. Precedence:
#   1. command-line args (one or more paths)
#   2. CLAUDE_PROJECTS_DIR (one path, or several colon-separated)
#   3. default ~/.claude/projects
session_dirs =
  if ARGV.any?
    ARGV
  elsif ENV['CLAUDE_PROJECTS_DIR'] && !ENV['CLAUDE_PROJECTS_DIR'].empty?
    ENV['CLAUDE_PROJECTS_DIR'].split(':')
  else
    ['~/.claude/projects']
  end

session_dirs = session_dirs.map { |dir| File.expand_path(dir.strip) }.uniq
missing = session_dirs.reject { |dir| Dir.exist?(dir) }
missing.each { |dir| puts "Warning: skipping missing session directory '#{dir}'" }

session_dirs -= missing
if session_dirs.empty?
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
syncer.import(ClaudeCodeProcessor.new(session_dirs))
