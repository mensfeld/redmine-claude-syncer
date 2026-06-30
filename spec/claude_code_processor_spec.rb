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

  it 'reads one session with a clean title and metadata' do
    expect(sessions.length).to eq(1)
    expect(session[:id]).to eq('cc-sess-1')
    expect(session[:title]).to eq('My Session')
    expect(session[:cwd]).to eq('/workspace')
    expect(session[:git_branch]).to eq('main')
  end

  it 'tags the session as coding-session + claude-code + project name from cwd' do
    expect(session[:tags]).to eq(%w[coding-session claude-code workspace])
  end

  it 'strips square brackets from the title' do
    bracketed = records.map do |r|
      r['type'] == 'ai-title' ? r.merge('aiTitle' => '[SUGGESTION MODE: do a thing]') : r
    end
    File.write(session_path, bracketed.map(&:to_json).join("\n"))
    title = described_class.new(projects_dir).process.first[:title]
    expect(title).to eq('SUGGESTION MODE: do a thing')
  end

  it 'maps roles and skips meta records' do
    expect(session[:messages].map { |m| m[:role] }).to eq(%w[human assistant human])
  end

  it 'renders thinking and tool calls in the assistant note' do
    assistant = session[:messages][1]
    expect(assistant[:content]).to include('🧠 Thinking')
    expect(assistant[:content]).to include('Tool call — `Bash`')
  end

  it 'renders tool results from user records inside a code fence' do
    last = session[:messages].last[:content]
    expect(last).to include('📥 Result')
    expect(last).to include('total 0')
    expect(last).to match(/```\s*\ntotal 0\n```/)
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

  describe 'multiple session directories' do
    let(:dir_a) { 'tmp/cc_a' }
    let(:dir_b) { 'tmp/cc_b' }

    def write_session(dir, sid, message_count)
      require 'fileutils'
      FileUtils.mkdir_p(dir)
      recs = [{ 'type' => 'ai-title', 'aiTitle' => sid, 'sessionId' => sid }]
      message_count.times do |i|
        recs << {
          'type' => 'assistant', 'uuid' => "#{sid}-#{i}", 'sessionId' => sid,
          'timestamp' => '2026-01-01T00:00:0%dZ' % i,
          'message' => { 'role' => 'assistant', 'content' => [{ 'type' => 'text', 'text' => "msg #{i}" }] }
        }
      end
      File.write(File.join(dir, "#{sid}.jsonl"), recs.map(&:to_json).join("\n"))
    end

    after { require 'fileutils'; FileUtils.rm_rf(dir_a); FileUtils.rm_rf(dir_b) }

    it 'imports sessions from every directory' do
      write_session(dir_a, 'sess-a', 1)
      write_session(dir_b, 'sess-b', 1)
      ids = described_class.new([dir_a, dir_b]).process.map { |s| s[:id] }
      expect(ids).to contain_exactly('cc-sess-a', 'cc-sess-b')
    end

    it 'deduplicates a session present in two dirs, keeping the most complete' do
      write_session(dir_a, 'dup', 1)
      write_session(dir_b, 'dup', 3)
      sessions = described_class.new([dir_a, dir_b]).process
      expect(sessions.length).to eq(1)
      expect(sessions.first[:messages].length).to eq(3)
    end

    it 'ignores non-transcript JSONL like history.jsonl' do
      write_session(dir_a, 'real', 1)
      require 'fileutils'
      FileUtils.mkdir_p(File.join(dir_a, '.claude'))
      File.write(File.join(dir_a, '.claude', 'history.jsonl'), { 'display' => 'a prompt' }.to_json)
      ids = described_class.new(dir_a).process.map { |s| s[:id] }
      expect(ids).to eq(['cc-real'])
    end

    it 'applies per-directory extra tags' do
      write_session(dir_a, 'plain', 1)
      write_session(dir_b, 'coi-sess', 1)
      sessions = described_class.new([dir_a, [dir_b, ['coi']]]).process
      plain = sessions.find { |s| s[:id] == 'cc-plain' }
      coi = sessions.find { |s| s[:id] == 'cc-coi-sess' }
      expect(plain[:tags]).not_to include('coi')
      expect(coi[:tags]).to include('coi')
      expect(coi[:tags]).to include('coding-session', 'claude-code')
    end

    it 'accepts a hash of dir => extra tags' do
      write_session(dir_b, 'h', 1)
      session = described_class.new(dir_b => ['coi']).process.first
      expect(session[:tags]).to include('coi')
    end
  end
end
