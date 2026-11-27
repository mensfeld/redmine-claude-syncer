# frozen_string_literal: true

require 'spec_helper'
require 'zip'
require 'source_archive'

RSpec.describe SourceArchive do
  let(:conversation) do
    {
      id: 'cc-sess-1', title: 'My Session', created_at: Time.utc(2026, 1, 1), tags: %w[claude-code],
      source_files: { 'sess-1.jsonl' => "{\"a\":1}\n", 'sess-1/tool-results/r1.txt' => 'out' },
      source_paths: ['/home/me/.claude/projects/-w/sess-1.jsonl'],
      messages: [
        { id: 'm1', attachments: [
          { filename: 'code-block-1.rb', content: 'puts 1', available: true },
          { filename: 'code-block-1.rb', content: 'puts 2', available: true },
          { filename: 'photo.png', content: nil, available: false }
        ] },
        { id: 'm2', attachments: [] }
      ]
    }
  end

  def read_zip(binary)
    entries = {}
    Zip::InputStream.open(StringIO.new(binary)) do |io|
      while (entry = io.get_next_entry)
        entries[entry.name] = io.read
      end
    end
    entries
  end

  describe '.key' do
    it 'is stable for the same source and changes when the source changes' do
      grown = conversation.merge(source_files: conversation[:source_files].merge('sess-1.jsonl' => "{\"a\":1}\n{}\n"))

      expect(described_class.key(conversation)).to eq(described_class.key(conversation.dup))
      expect(described_class.key(conversation)).to start_with('cc-sess-1:source:')
      expect(described_class.key(grown)).not_to eq(described_class.key(conversation))
    end
  end

  describe '.build' do
    let(:archive) do
      described_class.build(conversation, issue_id: 7, content_version: 3, archived_at: Time.utc(2026, 11, 27, 12))
    end
    let(:entries) { read_zip(archive[:content]) }

    it 'returns an uploadable zip attachment keyed by source digest' do
      expect(archive).to include(kind: 'source', content_type: 'application/zip', available: true,
                                 key: described_class.key(conversation))
      expect(archive[:filename]).to match(/\Asource-20261127-120000-\h{8}\.zip\z/)
    end

    it 'contains the raw source files verbatim' do
      expect(entries['sess-1.jsonl']).to eq("{\"a\":1}\n")
      expect(entries['sess-1/tool-results/r1.txt']).to eq('out')
    end

    it 'contains every available attachment under a unique per-message path' do
      expect(entries['attachments/0001-m1/code-block-1.rb']).to eq('puts 1')
      expect(entries['attachments/0001-m1/2-code-block-1.rb']).to eq('puts 2')
      expect(entries.keys.grep(/photo/)).to be_empty
    end

    it 'contains import metadata' do
      metadata = JSON.parse(entries['metadata.json'])
      expect(metadata).to include('conversation_id' => 'cc-sess-1', 'redmine_issue_id' => 7,
                                  'content_version' => 3, 'message_count' => 2, 'last_message_id' => 'm2',
                                  'sources' => conversation[:source_paths])
    end
  end
end
