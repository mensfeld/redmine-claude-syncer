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

  # Filenames that are JSONL but not session transcripts (skip them)
  NON_TRANSCRIPT_FILES = %w[history.jsonl].freeze

  # Creates a new processor for one or more Claude Code session directories
  #
  # Each directory can carry extra tags applied to every session found under it
  # (e.g. tag everything from a COI session store with `coi`). Accepts:
  #   - a String path
  #   - an Array of String paths
  #   - a Hash of `path => [extra_tags]`
  #   - an Array of `[path, [extra_tags]]` pairs
  #
  # @param dir_configs [String, Array, Hash] session directory configuration
  def initialize(dir_configs)
    @dir_configs = normalize_dir_configs(dir_configs)
    @logger = Logger.new('logs/claude_code.log')
  end

  # Processes all session transcripts across every configured directory
  #
  # Per-directory extra tags are appended to each session's tags. Transcripts are
  # deduplicated by session id (keeping the most complete copy and unioning tags),
  # so the same session in more than one location isn't imported twice. Non-transcript
  # JSONL files (e.g. history.jsonl) are ignored.
  #
  # @return [Array<Hash>] array of conversation hashes with :id, :title, :messages keys
  def process
    @logger.info "Processing Claude Code sessions from #{@dir_configs.map(&:first).join(', ')}"

    sessions = @dir_configs.flat_map { |dir, extra_tags| process_dir(dir, extra_tags) }

    deduped = sessions.group_by { |session| session[:id] }.map do |_id, group|
      best = group.max_by { |session| session[:messages].size }
      best.merge(tags: group.flat_map { |session| session[:tags] }.uniq)
    end

    @logger.info "Successfully processed #{deduped.size} sessions"
    deduped
  end

  # Claude Code transcripts have no separate projects to import
  #
  # @return [Array] always an empty array
  def process_projects
    []
  end

  private

  # Normalizes the directory configuration into [path, extra_tags] pairs
  #
  # @param dir_configs [String, Array, Hash] the raw configuration
  # @return [Array<Array(String, Array<String>)>] normalized pairs
  def normalize_dir_configs(dir_configs)
    case dir_configs
    when Hash
      dir_configs.map { |dir, tags| [dir, Array(tags)] }
    when String
      [[dir_configs, []]]
    when Array
      dir_configs.map { |entry| entry.is_a?(Array) ? [entry[0], Array(entry[1])] : [entry, []] }
    else
      []
    end
  end

  # Processes every transcript in a single directory, applying its extra tags
  #
  # @param dir [String] the directory to scan
  # @param extra_tags [Array<String>] tags to append to each session found
  # @return [Array<Hash>] processed session hashes
  def process_dir(dir, extra_tags)
    paths = Dir.glob(File.join(dir, '**', '*.jsonl'))
               .reject { |path| NON_TRANSCRIPT_FILES.include?(File.basename(path)) }
               .uniq.sort

    paths.filter_map do |path|
      session = process_session_file(path)
      next nil unless session

      session[:tags] = (session[:tags] + extra_tags).uniq unless extra_tags.empty?
      session
    rescue StandardError => e
      @logger.error "Failed to process session #{path}: #{e.message}"
      nil
    end
  end

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
    # Strip square brackets — some aiTitles are wrapped like "[SUGGESTION MODE: ...]"
    title = (ai_title || first_user_prompt(records) || '').to_s.gsub(/[\[\]]/, '').gsub(/\s+/, ' ').strip
    title = "session #{session_id}" if title.empty?
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
