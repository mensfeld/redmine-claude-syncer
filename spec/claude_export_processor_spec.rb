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

    context 'with attachments and artifacts' do
      let(:zip_path) { 'tmp/test_attachments_export.zip' }

      let(:conversation_json) do
        [
          {
            'uuid' => 'conv-attachments',
            'name' => 'Attachments Conversation',
            'created_at' => '2024-01-01T00:00:00Z',
            'updated_at' => '2024-01-01T00:00:00Z',
            'chat_messages' => [
              {
                'uuid' => 'msg-human',
                'sender' => 'human',
                'created_at' => '2024-01-01T00:00:00Z',
                'content' => [{ 'type' => 'text', 'text' => 'Please review' }],
                'attachments' => [
                  {
                    'file_name' => 'notes.txt',
                    'file_size' => 12,
                    'file_type' => 'txt',
                    'extracted_content' => 'some extracted text'
                  },
                  {
                    'file_name' => '',
                    'file_size' => 0,
                    'file_type' => 'txt',
                    'extracted_content' => ''
                  }
                ],
                'files' => [
                  { 'file_uuid' => 'img-uuid-1', 'file_name' => 'photo.jpg' }
                ]
              },
              {
                'uuid' => 'msg-claude',
                'sender' => 'assistant',
                'created_at' => '2024-01-01T00:01:00Z',
                'content' => [
                  { 'type' => 'text', 'text' => 'Here you go' },
                  {
                    'type' => 'tool_use',
                    'name' => 'artifacts',
                    'input' => {
                      'command' => 'create',
                      'id' => 'artifact-1',
                      'type' => 'text/markdown',
                      'title' => 'Research Report',
                      'content' => '# Title'
                    }
                  },
                  {
                    'type' => 'tool_use',
                    'name' => 'create_file',
                    'input' => {
                      'path' => '/mnt/user-data/outputs/script.py',
                      'description' => 'A script',
                      'file_text' => "print('hi')"
                    }
                  }
                ],
                'attachments' => [],
                'files' => []
              }
            ]
          }
        ]
      end

      before do
        require 'zip'
        Zip::File.open(zip_path, create: true) do |zipfile|
          zipfile.get_output_stream('conversations.json') { |f| f.write(conversation_json.to_json) }
        end
      end

      after do
        File.delete(zip_path) if File.exist?(zip_path)
      end

      let(:messages) { described_class.new(zip_path).process.first[:messages] }
      let(:human_attachments) { messages.first[:attachments] }
      let(:claude_attachments) { messages.last[:attachments] }

      it 'extracts user document attachments that have content' do
        document = human_attachments.find { |a| a[:kind] == 'document' }
        expect(document[:filename]).to eq('notes.txt')
        expect(document[:content]).to eq('some extracted text')
        expect(document[:available]).to be true
        expect(document[:content_type]).to eq('text/plain')
      end

      it 'skips empty document attachments' do
        documents = human_attachments.select { |a| a[:kind] == 'document' }
        expect(documents.length).to eq(1)
      end

      it 'extracts user image files without content' do
        image = human_attachments.find { |a| a[:kind] == 'image' }
        expect(image[:filename]).to eq('photo.jpg')
        expect(image[:available]).to be false
        expect(image[:content]).to be_nil
        expect(image[:key]).to include('img-uuid-1')
      end

      it 'extracts Claude artifacts as markdown files' do
        artifact = claude_attachments.find { |a| a[:kind] == 'artifact' }
        expect(artifact[:filename]).to eq('Research Report.md')
        expect(artifact[:content]).to eq('# Title')
        expect(artifact[:available]).to be true
      end

      it 'extracts files created by Claude' do
        file = claude_attachments.find { |a| a[:kind] == 'file' }
        expect(file[:filename]).to eq('script.py')
        expect(file[:content]).to eq("print('hi')")
        expect(file[:content_type]).to eq('text/x-python')
      end

      it 'builds stable idempotency keys scoped to the message' do
        keys = (human_attachments + claude_attachments).map { |a| a[:key] }
        expect(keys.uniq.length).to eq(keys.length)
        expect(claude_attachments.map { |a| a[:key] }).to all(start_with('msg-claude'))
      end
    end

    context 'with thinking, tool calls and results' do
      let(:zip_path) { 'tmp/test_render_export.zip' }

      let(:conversation_json) do
        [
          {
            'uuid' => 'conv-render',
            'name' => 'Render Conversation',
            'created_at' => '2024-01-01T00:00:00Z',
            'updated_at' => '2024-01-01T00:00:00Z',
            'chat_messages' => [
              {
                'uuid' => 'msg-1',
                'sender' => 'assistant',
                'created_at' => '2024-01-01T00:00:00Z',
                'content' => [
                  { 'type' => 'thinking', 'thinking' => 'Let me think about this.' },
                  { 'type' => 'text', 'text' => "Here is a snippet:\n\n```ruby\nputs 1\n```" },
                  { 'type' => 'tool_use', 'name' => 'web_search', 'input' => { 'query' => 'ruby' } },
                  {
                    'type' => 'tool_result',
                    'name' => 'web_search',
                    'content' => [
                      { 'type' => 'knowledge', 'title' => 'Ruby site', 'url' => 'https://ruby-lang.org', 'text' => 'about ruby' }
                    ]
                  }
                ],
                'attachments' => [],
                'files' => []
              }
            ]
          }
        ]
      end

      before do
        require 'zip'
        Zip::File.open(zip_path, create: true) do |zipfile|
          zipfile.get_output_stream('conversations.json') { |f| f.write(conversation_json.to_json) }
        end
      end

      after { File.delete(zip_path) if File.exist?(zip_path) }

      let(:message) { described_class.new(zip_path).process.first[:messages].first }

      it 'renders thinking, tool calls and results in the note body' do
        expect(message[:content]).to include('🧠 Thinking')
        expect(message[:content]).to include('Let me think about this.')
        expect(message[:content]).to include('Tool call — `web_search`')
        expect(message[:content]).to include('📥 Result')
        expect(message[:content]).to include('[Ruby site](https://ruby-lang.org)')
      end

      it 'still uploads inline code blocks as files' do
        code = message[:attachments].find { |a| a[:kind] == 'code' }
        expect(code[:filename]).to eq('code-block-1.rb')
        expect(code[:content]).to eq('puts 1')
      end
    end

    context 'with files created and edited by Claude' do
      let(:zip_path) { 'tmp/test_created_files_export.zip' }

      let(:conversation_json) do
        [
          {
            'uuid' => 'conv-files',
            'name' => 'Created Files',
            'created_at' => '2024-01-01T00:00:00Z',
            'updated_at' => '2024-01-01T00:00:00Z',
            'chat_messages' => [
              {
                'uuid' => 'msg-a',
                'sender' => 'assistant',
                'created_at' => '2024-01-01T00:00:00Z',
                'content' => [
                  { 'type' => 'tool_use', 'name' => 'create_file', 'input' => { 'path' => '/home/claude/app.rb', 'file_text' => "puts 'v1'" } }
                ],
                'attachments' => [], 'files' => []
              },
              {
                'uuid' => 'msg-b',
                'sender' => 'assistant',
                'created_at' => '2024-01-01T00:01:00Z',
                'content' => [
                  { 'type' => 'tool_use', 'name' => 'str_replace', 'input' => { 'path' => '/home/claude/app.rb', 'old_str' => "puts 'v1'", 'new_str' => "puts 'v2'" } }
                ],
                'attachments' => [], 'files' => []
              }
            ]
          }
        ]
      end

      before do
        require 'zip'
        Zip::File.open(zip_path, create: true) do |zipfile|
          zipfile.get_output_stream('conversations.json') { |f| f.write(conversation_json.to_json) }
        end
      end

      after { File.delete(zip_path) if File.exist?(zip_path) }

      it 'uploads the final version after str_replace edits' do
        messages = described_class.new(zip_path).process.first[:messages]
        file = messages.flat_map { |m| m[:attachments] }.find { |a| a[:kind] == 'file' }
        expect(file[:filename]).to eq('app.rb')
        expect(file[:content]).to eq("puts 'v2'")
      end

      it 'renders the edit before/after in the note body' do
        messages = described_class.new(zip_path).process.first[:messages]
        edit_note = messages.map { |m| m[:content] }.find { |c| c.include?('Claude edited') }
        expect(edit_note).to include("puts 'v1'")
        expect(edit_note).to include("puts 'v2'")
      end
    end

    context 'when a str_replace edit does not match the created file' do
      let(:zip_path) { 'tmp/test_nomatch_export.zip' }

      let(:conversation_json) do
        [
          {
            'uuid' => 'conv-nomatch',
            'name' => 'No Match',
            'created_at' => '2024-01-01T00:00:00Z',
            'updated_at' => '2024-01-01T00:00:00Z',
            'chat_messages' => [
              {
                'uuid' => 'msg-a',
                'sender' => 'assistant',
                'created_at' => '2024-01-01T00:00:00Z',
                'content' => [
                  { 'type' => 'tool_use', 'name' => 'create_file', 'input' => { 'path' => '/home/claude/a.py', 'file_text' => 'final content' } },
                  { 'type' => 'tool_use', 'name' => 'str_replace', 'input' => { 'path' => '/home/claude/a.py', 'old_str' => 'does not exist', 'new_str' => 'X' } }
                ],
                'attachments' => [], 'files' => []
              }
            ]
          }
        ]
      end

      before do
        require 'zip'
        Zip::File.open(zip_path, create: true) do |zipfile|
          zipfile.get_output_stream('conversations.json') { |f| f.write(conversation_json.to_json) }
        end
      end

      after { File.delete(zip_path) if File.exist?(zip_path) }

      it 'keeps the verbatim create_file snapshot instead of a partial result' do
        messages = described_class.new(zip_path).process.first[:messages]
        file = messages.flat_map { |m| m[:attachments] }.find { |a| a[:kind] == 'file' }
        expect(file[:content]).to eq('final content')
      end
    end
  end

  describe '#process_projects' do
    let(:zip_path) { 'tmp/test_projects_export.zip' }

    before do
      require 'zip'
      Zip::File.open(zip_path, create: true) do |zipfile|
        zipfile.get_output_stream('conversations.json') { |f| f.write('[]') }
        zipfile.get_output_stream('projects/p1.json') do |f|
          f.write({
            'uuid' => 'project-1',
            'name' => 'My Project',
            'description' => 'A project',
            'prompt_template' => 'Be concise',
            'created_at' => '2024-01-01T00:00:00Z',
            'docs' => [{ 'uuid' => 'd1', 'filename' => 'guide', 'content' => 'doc content' }]
          }.to_json)
        end
      end
    end

    after { File.delete(zip_path) if File.exist?(zip_path) }

    it 'extracts projects and their knowledge documents' do
      projects = described_class.new(zip_path).process_projects
      expect(projects.length).to eq(1)
      expect(projects.first[:name]).to eq('My Project')
      expect(projects.first[:prompt_template]).to eq('Be concise')

      doc = projects.first[:docs].first
      expect(doc[:filename]).to eq('guide.md')
      expect(doc[:content]).to eq('doc content')
      expect(doc[:available]).to be true
    end
  end
end
