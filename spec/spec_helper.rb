# frozen_string_literal: true

require 'fileutils'

# Set up test environment
ENV['DATABASE_PATH'] = 'tmp/test_conversations.db'
ENV['LOG_FILE'] = 'tmp/test.log'
ENV['LOG_LEVEL'] = 'ERROR'

# Ensure tmp and logs directories exist for tests
FileUtils.mkdir_p('tmp')
FileUtils.mkdir_p('logs')

# Load lib files
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'tmp/rspec_status.txt'
  config.disable_monkey_patching!
  config.warnings = true

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed

  # Clean up test database after each test
  config.after(:each) do
    db_path = ENV['DATABASE_PATH']
    File.delete(db_path) if db_path && File.exist?(db_path)
  end
end
