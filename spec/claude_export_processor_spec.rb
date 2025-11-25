# frozen_string_literal: true

require 'spec_helper'
require 'claude_export_processor'

RSpec.describe ClaudeExportProcessor do
  describe '#initialize' do
    it 'creates a new processor instance' do
      processor = described_class.new('test.zip')
      expect(processor).to be_a(ClaudeExportProcessor)
    end
  end

  describe '#process' do
    context 'with non-existent file' do
      it 'raises an error for missing zip file' do
        processor = described_class.new('non_existent.zip')
        expect { processor.process }.to raise_error(Zip::Error)
      end
    end

    context 'with valid zip file' do
      let(:zip_path) { 'tmp/test_export.zip' }

      before do
        # Create a minimal valid zip file with conversations.json
        require 'zip'
        Zip::File.open(zip_path, create: true) do |zipfile|
          zipfile.get_output_stream('conversations.json') do |f|
            f.write([
              {
                'uuid' => 'test-conversation-uuid',
                'name' => 'Test Conversation',
                'chat_messages' => [
                  {
                    'uuid' => 'msg-1',
                    'sender' => 'human',
                    'content' => [{ 'text' => 'Hello' }],
                    'created_at' => '2024-01-01T00:00:00Z'
                  }
                ],
                'created_at' => '2024-01-01T00:00:00Z',
                'updated_at' => '2024-01-01T00:00:00Z'
              }
            ].to_json)
          end
        end
      end

      after do
        File.delete(zip_path) if File.exist?(zip_path)
      end

      it 'processes the zip file and returns conversations' do
        processor = described_class.new(zip_path)
        conversations = processor.process

        expect(conversations).to be_an(Array)
        expect(conversations.length).to eq(1)
        expect(conversations.first[:id]).to eq('test-conversation-uuid')
        expect(conversations.first[:title]).to eq('Test Conversation')
      end
    end
  end
end
