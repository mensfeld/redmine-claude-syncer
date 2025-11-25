# frozen_string_literal: true

require 'spec_helper'
require 'database'

RSpec.describe Database do
  let(:db_path) { 'tmp/test_conversations.db' }

  describe '#initialize' do
    it 'creates a new database instance' do
      db = described_class.new(db_path)
      expect(db).to be_a(Database)
    end

    it 'creates the database file' do
      described_class.new(db_path)
      expect(File.exist?(db_path)).to be true
    end
  end

  describe '#get_conversation' do
    let(:db) { described_class.new(db_path) }

    it 'returns nil for non-existent conversation' do
      result = db.get_conversation('non-existent-id')
      expect(result).to be_nil
    end
  end

  describe '#create_conversation' do
    let(:db) { described_class.new(db_path) }

    it 'creates a conversation record' do
      db.create_conversation('test-uuid', 123, 'last-msg-id')
      result = db.get_conversation('test-uuid')

      expect(result).not_to be_nil
      expect(result[:claude_conversation_id]).to eq('test-uuid')
      expect(result[:redmine_issue_id]).to eq(123)
      expect(result[:last_exported_message_id]).to eq('last-msg-id')
    end
  end

  describe '#update_last_message_id' do
    let(:db) { described_class.new(db_path) }

    it 'updates the last message id' do
      db.create_conversation('test-uuid', 123, 'old-msg-id')
      db.update_last_message_id('test-uuid', 'new-msg-id')

      result = db.get_conversation('test-uuid')
      expect(result[:last_exported_message_id]).to eq('new-msg-id')
    end
  end
end
