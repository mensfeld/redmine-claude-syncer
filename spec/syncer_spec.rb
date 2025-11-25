# frozen_string_literal: true

require 'spec_helper'
require 'syncer'

RSpec.describe Syncer do
  describe '#initialize' do
    it 'creates a new syncer instance with valid config' do
      config = {
        database_path: 'tmp/test_conversations.db',
        log_file: 'tmp/test.log',
        log_level: 'ERROR',
        redmine_url: 'https://redmine.example.com',
        redmine_human_api_key: 'human-key',
        redmine_claude_api_key: 'claude-key',
        redmine_project_id: 'test-project',
        redmine_human_user_id: 1,
        redmine_claude_user_id: 2,
        redmine_tracker_id: 1,
        redmine_status_id: 1,
        redmine_priority_id: 2
      }

      syncer = described_class.new(config)
      expect(syncer).to be_a(Syncer)
    end
  end
end
