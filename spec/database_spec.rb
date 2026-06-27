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

  describe '#attachment_synced? and #record_attachment' do
    let(:db) { described_class.new(db_path) }

    it 'reports unknown attachments as not synced' do
      expect(db.attachment_synced?('missing-key')).to be false
    end

    it 'records an attachment and reports it as synced' do
      db.record_attachment('conv-1', 'msg-1', 'key-1', 'document', 'notes.txt', nil)
      expect(db.attachment_synced?('key-1')).to be true
    end

    it 'is idempotent when recording the same attachment key twice' do
      db.record_attachment('conv-1', 'msg-1', 'key-1', 'document', 'notes.txt', nil)
      expect do
        db.record_attachment('conv-1', 'msg-1', 'key-1', 'document', 'notes.txt', nil)
      end.not_to raise_error
      expect(db.attachment_synced?('key-1')).to be true
    end
  end

  describe 'content version and superseding' do
    let(:db) { described_class.new(db_path) }

    it 'defaults content_version to 0 for legacy creates' do
      db.create_conversation('c', 1, 'm')
      expect(db.get_conversation('c')[:content_version]).to eq(0)
    end

    it 'stores the content_version when provided' do
      db.create_conversation('c', 1, 'm', 2)
      expect(db.get_conversation('c')[:content_version]).to eq(2)
    end

    it 'repoints a conversation to a new issue and bumps the version' do
      db.create_conversation('c', 1, 'm', 0)
      db.repoint_conversation('c', 99, 'm2', 2)

      row = db.get_conversation('c')
      expect(row[:redmine_issue_id]).to eq(99)
      expect(row[:last_exported_message_id]).to eq('m2')
      expect(row[:content_version]).to eq(2)
    end

    it 'resets attachment tracking for a conversation' do
      db.record_attachment('c', 'm', 'k', 'document', 'f.txt', nil)
      db.reset_conversation_attachments('c')
      expect(db.attachment_synced?('k')).to be false
    end
  end

  describe 'applied tags tracking' do
    let(:db) { described_class.new(db_path) }

    it 'returns no applied tags by default' do
      db.create_conversation('c', 1, 'm', 3)
      expect(db.get_applied_tags('c')).to eq([])
    end

    it 'stores and reads back applied tags' do
      db.create_conversation('c', 1, 'm', 3)
      db.set_applied_tags('c', %w[coding-session claude-code])
      expect(db.get_applied_tags('c')).to eq(%w[coding-session claude-code])
    end
  end

  describe '#get_project and #create_project' do
    let(:db) { described_class.new(db_path) }

    it 'returns nil for an unknown project' do
      expect(db.get_project('missing')).to be_nil
    end

    it 'creates and retrieves a project record' do
      db.create_project('proj-1', 555)
      expect(db.get_project('proj-1')).to eq(claude_project_id: 'proj-1', redmine_issue_id: 555)
    end
  end
end
