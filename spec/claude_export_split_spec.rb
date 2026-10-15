# frozen_string_literal: true

require 'spec_helper'
require 'zip'
require 'claude_export_processor'

RSpec.describe ClaudeExportProcessor do
  let(:dir) { 'tmp/split_export_spec' }

  def write_zip(path, entries)
    FileUtils.mkdir_p(File.dirname(path))
    Zip::File.open(path, create: true) do |zip|
      entries.each { |name, body| zip.get_output_stream(name) { |f| f.write(body) } }
    end
  end

  before { FileUtils.rm_rf(dir) }
  after { FileUtils.rm_rf(dir) }

  describe 'processing split exports' do
    it 'finds conversations and projects across several ZIPs and layouts' do
      conv = lambda do |id|
        { 'uuid' => id, 'name' => id, 'created_at' => '2026-01-01T00:00:00Z',
          'chat_messages' => [{ 'uuid' => "#{id}-m", 'sender' => 'human',
                                'content' => [{ 'type' => 'text', 'text' => 'hi' }],
                                'created_at' => '2026-01-01T00:00:00Z' }] }
      end
      write_zip(File.join(dir, 'conversations-000.zip'),
                'conversations.json' => [conv.call('c1'), conv.call('c2')].to_json,
                'conversations/c3.json' => conv.call('c3').to_json,
                'more.jsonl' => "#{conv.call('c4').to_json}\n#{conv.call('c1').to_json}\n")
      write_zip(File.join(dir, 'projects-000.zip'),
                'projects.json' => [{ 'uuid' => 'p1', 'name' => 'P', 'docs' => [] }].to_json,
                'users.json' => [{ 'uuid' => 'u1', 'full_name' => 'Me' }].to_json)

      processor = described_class.new(Dir.glob(File.join(dir, '*.zip')).sort)

      expect(processor.process.map { |c| c[:id] }).to contain_exactly('c1', 'c2', 'c3', 'c4')
      expect(processor.process_projects.map { |p| p[:id] }).to eq(['p1'])
    end
  end
end
