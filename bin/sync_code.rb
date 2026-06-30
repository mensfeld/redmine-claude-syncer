#!/usr/bin/env ruby

require 'dotenv'
require_relative '../lib/syncer'
require_relative '../lib/claude_code_processor'

# Load environment variables
Dotenv.load

# Resolve the session directories. Precedence:
#   1. command-line args (one or more specs)
#   2. CLAUDE_PROJECTS_DIR (one spec, or several colon-separated)
#   3. default ~/.claude/projects
# Each spec is a path, optionally with extra tags: "dir" or "dir=tag1,tag2".
# Those tags are applied to every session found under that directory, e.g.
#   bin/sync_code.rb ~/.claude/projects "~/.coi/sessions-claude=coi"
raw_specs =
  if ARGV.any?
    ARGV
  elsif ENV['CLAUDE_PROJECTS_DIR'] && !ENV['CLAUDE_PROJECTS_DIR'].empty?
    ENV['CLAUDE_PROJECTS_DIR'].split(':')
  else
    ['~/.claude/projects']
  end

dir_configs = raw_specs.filter_map do |spec|
  path, tags = spec.strip.split('=', 2)
  dir = File.expand_path(path)
  extra_tags = (tags || '').split(',').map(&:strip).reject(&:empty?)

  unless Dir.exist?(dir)
    puts "Warning: skipping missing session directory '#{dir}'"
    next nil
  end
  [dir, extra_tags]
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
