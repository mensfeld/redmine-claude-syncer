require_relative 'claude_export_processor'
require 'json'
require 'logger'
require 'digest'

# Processes Claude Code session transcripts (~/.claude/projects/*/*.jsonl)
#
# Reuses the rendering and attachment logic of {ClaudeExportProcessor} but reads
# the JSONL transcript format produced by Claude Code instead of a Claude.ai
# export ZIP. Each session becomes a conversation with the same shape the
# {Syncer} already understands, so coding sessions are archived in Redmine the
# same way as Claude.ai conversations.
class ClaudeCodeProcessor < ClaudeExportProcessor
  # Base tags applied to every coding-session issue (project tag is appended)
  SESSION_TAGS = %w[coding-session claude-code].freeze

  # Record types that carry conversational messages
  MESSAGE_TYPES = %w[user assistant].freeze

  # Creates a new processor for a Claude Code projects directory
  #
  # @param projects_dir [String] path to the ~/.claude/projects directory
  def initialize(projects_dir)
    @projects_dir = projects_dir
    @logger = Logger.new('logs/claude_code.log')
  end

  # Processes all session transcripts into conversation hashes
  #
  # @return [Array<Hash>] array of conversation hashes with :id, :title, :messages keys
  def process
    @logger.info "Processing Claude Code sessions from #{@projects_dir}"

    sessions = Dir.glob(File.join(@projects_dir, '**', '*.jsonl')).sort.filter_map do |path|
      process_session_file(path)
    rescue StandardError => e
      @logger.error "Failed to process session #{path}: #{e.message}"
      nil
    end

    @logger.info "Successfully processed #{sessions.size} sessions"
    sessions
  end

  # Claude Code transcripts have no separate projects to import
  #
  # @return [Array] always an empty array
  def process_projects
    []
  end

  private

  # Processes a single session transcript file into a conversation hash
  #
  # @param path [String] path to the .jsonl transcript
  # @return [Hash, nil] conversation hash, or nil if there are no messages
  def process_session_file(path)
    records = read_jsonl(path)
    return nil if records.empty?

    session_id = records.filter_map { |r| r['sessionId'] }.first || File.basename(path, '.jsonl')

    messages = records.select { |r| message_record?(r) }.filter_map { |r| process_record(r) }
    return nil if messages.empty?

    attach_raw_transcript(messages.first, session_id, path)

    timestamps = records.filter_map { |r| r['timestamp'] }.sort
    cwd = records.filter_map { |r| r['cwd'] }.first
    {
      id: "cc-#{session_id}",
      title: session_title(records, session_id),
      messages: messages,
      created_at: parse_timestamp(timestamps.first),
      updated_at: parse_timestamp(timestamps.last),
      cwd: cwd,
      git_branch: records.filter_map { |r| r['gitBranch'] }.first,
      tags: session_tags(cwd)
    }
  end

  # Builds the tag list for a coding session, appending the project name from cwd
  #
  # @param cwd [String, nil] the working directory of the session
  # @return [Array<String>] tags for the session issue
  def session_tags(cwd)
    project = project_name(cwd)
    project.empty? ? SESSION_TAGS.dup : SESSION_TAGS + [project]
  end

  # Derives a downcased project tag from a working directory (its basename)
  #
  # @param cwd [String, nil] the working directory of the session
  # @return [String] the sanitized project name (empty if unknown)
  def project_name(cwd)
    return '' if cwd.to_s.empty?

    File.basename(cwd.to_s).downcase.gsub(/\s+/, '-').gsub(/[^a-z0-9._-]/, '')
  end

  # Determines whether a record is a conversational message worth rendering
  #
  # @param record [Hash] a parsed JSONL record
  # @return [Boolean] true if the record is a non-meta user/assistant message
  def message_record?(record)
    MESSAGE_TYPES.include?(record['type']) && record['isMeta'] != true && !record['message'].nil?
  end

  # Converts a single transcript record into a processed message hash
  #
  # @param record [Hash] a parsed user/assistant JSONL record
  # @return [Hash, nil] processed message hash, or nil if it has no content
  def process_record(record)
    message = record['message'] || {}
    raw_content = message['content']
    content_items = raw_content.is_a?(Array) ? raw_content : [{ 'type' => 'text', 'text' => raw_content.to_s }]
    message_id = record['uuid'].to_s

    rendered = render_message_content(message_id, content_items)
    text = rendered[:text]
    return nil if text.strip.empty? && rendered[:attachments].empty?

    original_text = content_items.select { |c| c['type'] == 'text' }
                                 .map { |c| c['text'].to_s }.join("\n\n")

    attachments = rendered[:attachments] + extract_code_block_attachments(original_text, message_id)

    {
      id: message_id,
      role: message['role'] == 'user' ? 'human' : 'assistant',
      content: text,
      created_at: parse_timestamp(record['timestamp']),
      files: [],
      attachments: attachments
    }
  end

  # Attaches the raw transcript file to the first message of a session
  #
  # @param first_message [Hash] the first processed message of the session
  # @param session_id [String] the Claude Code session UUID
  # @param path [String] path to the .jsonl transcript
  # @return [void]
  def attach_raw_transcript(first_message, session_id, path)
    content = File.read(path)
    digest = Digest::SHA256.hexdigest(content)[0..15]

    first_message[:attachments].unshift(
      kind: 'transcript',
      filename: "#{session_id}.jsonl",
      content: content,
      content_type: 'application/x-ndjson',
      available: true,
      description: 'Raw Claude Code session transcript',
      key: "cc-#{session_id}:transcript:#{digest}"
    )
  end

  # Determines a human-readable title for the session
  #
  # @param records [Array<Hash>] all parsed records of the session
  # @param session_id [String] the Claude Code session UUID
  # @return [String] the session title
  def session_title(records, session_id)
    ai_title = records.select { |r| r['type'] == 'ai-title' }.filter_map { |r| r['aiTitle'] }.last
    title = ai_title || first_user_prompt(records) || session_id
    title.length > 200 ? title[0, 200] : title
  end

  # Extracts the first meaningful user prompt to use as a fallback title
  #
  # @param records [Array<Hash>] all parsed records of the session
  # @return [String, nil] the first clean user prompt, or nil if none
  def first_user_prompt(records)
    records.each do |record|
      next unless record['type'] == 'user' && record['isMeta'] != true

      content = record.dig('message', 'content')
      text = content.is_a?(String) ? content : nil
      next if text.nil? || text.strip.empty?
      next if text.include?('command-name') || text.include?('local-command') ||
              text.include?('system-reminder') || text.include?('caveat')

      return text.strip.lines.first.to_s.strip
    end
    nil
  end

  # Reads and parses a JSONL file into an array of records
  #
  # @param path [String] path to the .jsonl file
  # @return [Array<Hash>] parsed records (invalid lines are skipped)
  def read_jsonl(path)
    records = []
    File.foreach(path) do |line|
      line = line.strip
      next if line.empty?

      begin
        records << JSON.parse(line)
      rescue JSON::ParserError => e
        @logger.warn "Skipping invalid JSONL line in #{path}: #{e.message}"
      end
    end
    records
  end
end
