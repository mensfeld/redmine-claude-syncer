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

  describe '#messages_after' do
    let(:syncer) do
      described_class.new(
        database_path: 'tmp/test_conversations.db',
        log_file: 'tmp/test.log',
        log_level: 'ERROR',
        redmine_url: 'https://redmine.example.com',
        redmine_human_api_key: 'h', redmine_claude_api_key: 'c',
        redmine_project_id: 'p', redmine_human_user_id: 1, redmine_claude_user_id: 2
      )
    end

    let(:messages) { [{ id: 'a' }, { id: 'b' }, { id: 'c' }] }

    it 'returns messages after the last processed one by position' do
      expect(syncer.send(:messages_after, messages, 'a')).to eq([{ id: 'b' }, { id: 'c' }])
    end

    it 'returns an empty array when the last message is the most recent' do
      expect(syncer.send(:messages_after, messages, 'c')).to eq([])
    end

    it 'returns all messages when there is no last processed id' do
      expect(syncer.send(:messages_after, messages, nil)).to eq(messages)
    end

    it 'returns empty (no duplicates) when the last id is not found' do
      expect(syncer.send(:messages_after, messages, 'missing')).to eq([])
    end

    it 'works regardless of id ordering (random UUIDs)' do
      shuffled = [{ id: 'zzz' }, { id: 'aaa' }, { id: 'mmm' }]
      expect(syncer.send(:messages_after, shuffled, 'zzz')).to eq([{ id: 'aaa' }, { id: 'mmm' }])
    end
  end

  describe '#ordered_by_creation' do
    let(:syncer) do
      described_class.new(
        database_path: 'tmp/test_conversations.db', log_file: 'tmp/test.log', log_level: 'ERROR',
        redmine_url: 'https://redmine.example.com', redmine_human_api_key: 'h',
        redmine_claude_api_key: 'c', redmine_project_id: 'p',
        redmine_human_user_id: 1, redmine_claude_user_id: 2
      )
    end

    it 'sorts items oldest-first by created_at' do
      items = [
        { id: 'new', created_at: Time.new(2026, 3, 1) },
        { id: 'old', created_at: Time.new(2024, 1, 1) },
        { id: 'mid', created_at: Time.new(2025, 6, 1) }
      ]
      expect(syncer.send(:ordered_by_creation, items).map { |i| i[:id] }).to eq(%w[old mid new])
    end
  end
end
