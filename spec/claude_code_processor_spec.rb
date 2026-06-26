# frozen_string_literal: true

require 'spec_helper'
require 'claude_code_processor'

RSpec.describe ClaudeCodeProcessor do
  let(:projects_dir) { 'tmp/cc_projects' }
  let(:session_dir) { File.join(projects_dir, '-workspace') }
  let(:session_path) { File.join(session_dir, 'sess-1.jsonl') }

  let(:records) do
    [
      { 'type' => 'ai-title', 'aiTitle' => 'My Session', 'sessionId' => 'sess-1' },
      { 'type' => 'mode', 'mode' => 'default', 'sessionId' => 'sess-1' },
      {
        'type' => 'user', 'uuid' => 'u1', 'sessionId' => 'sess-1',
        'timestamp' => '2026-01-01T00:00:00Z', 'cwd' => '/workspace', 'gitBranch' => 'main',
        'message' => { 'role' => 'user', 'content' => 'hello, write code' }
      },
      {
        'type' => 'user', 'uuid' => 'umeta', 'isMeta' => true,
        'timestamp' => '2026-01-01T00:00:01Z',
        'message' => { 'role' => 'user', 'content' => '<system-reminder>noise</system-reminder>' }
      },
      {
        'type' => 'assistant', 'uuid' => 'a1', 'timestamp' => '2026-01-01T00:00:02Z',
        'message' => {
          'role' => 'assistant',
          'content' => [
            { 'type' => 'thinking', 'thinking' => 'let me think' },
            { 'type' => 'text', 'text' => "Here you go:\n\n```ruby\nputs 1\n```" },
            { 'type' => 'tool_use', 'name' => 'Bash', 'input' => { 'command' => 'ls' } }
          ]
        }
      },
      {
        'type' => 'user', 'uuid' => 'u2', 'timestamp' => '2026-01-01T00:00:03Z',
        'message' => { 'role' => 'user', 'content' => [{ 'type' => 'tool_result', 'tool_use_id' => 'x', 'content' => 'total 0' }] }
      }
    ]
  end

  before do
    require 'fileutils'
    FileUtils.mkdir_p(session_dir)
    File.write(session_path, records.map(&:to_json).join("\n"))
  end

  after { FileUtils.rm_rf(projects_dir) }

  let(:sessions) { described_class.new(projects_dir).process }
  let(:session) { sessions.first }

  it 'reads one session with a prefixed title and metadata' do
    expect(sessions.length).to eq(1)
    expect(session[:id]).to eq('cc-sess-1')
    expect(session[:title]).to eq('[Claude Code] My Session')
    expect(session[:cwd]).to eq('/workspace')
    expect(session[:git_branch]).to eq('main')
  end

  it 'maps roles and skips meta records' do
    expect(session[:messages].map { |m| m[:role] }).to eq(%w[human assistant human])
  end

  it 'renders thinking and tool calls in the assistant note' do
    assistant = session[:messages][1]
    expect(assistant[:content]).to include('🧠 Thinking')
    expect(assistant[:content]).to include('Tool call — `Bash`')
  end

  it 'renders tool results from user records' do
    expect(session[:messages].last[:content]).to include('📥 Result')
    expect(session[:messages].last[:content]).to include('total 0')
  end

  it 'extracts inline code blocks as files' do
    code = session[:messages][1][:attachments].find { |a| a[:kind] == 'code' }
    expect(code[:filename]).to eq('code-block-1.rb')
    expect(code[:content]).to eq('puts 1')
  end

  it 'attaches the raw transcript to the first message' do
    transcript = session[:messages].first[:attachments].find { |a| a[:kind] == 'transcript' }
    expect(transcript[:filename]).to eq('sess-1.jsonl')
    expect(transcript[:available]).to be true
    expect(transcript[:content]).to include('"sessionId":"sess-1"')
  end

  describe '#process_projects' do
    it 'returns an empty array' do
      expect(described_class.new(projects_dir).process_projects).to eq([])
    end
  end
end
