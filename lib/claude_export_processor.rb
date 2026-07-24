require 'zip'
require 'json'
require 'logger'
require 'fileutils'
require 'date'
require 'time'
require 'digest'

# Processes Claude AI export ZIP files and extracts conversation data
class ClaudeExportProcessor
  # Maps file extensions to MIME content types for uploads
  MIME_BY_EXTENSION = {
    'md' => 'text/markdown', 'markdown' => 'text/markdown', 'txt' => 'text/plain',
    'text' => 'text/plain', 'log' => 'text/plain', 'py' => 'text/x-python',
    'rb' => 'text/x-ruby', 'js' => 'text/javascript', 'mjs' => 'text/javascript',
    'ts' => 'text/x-typescript', 'jsx' => 'text/javascript', 'tsx' => 'text/x-typescript',
    'json' => 'application/json', 'html' => 'text/html', 'htm' => 'text/html',
    'css' => 'text/css', 'svg' => 'image/svg+xml', 'xml' => 'application/xml',
    'csv' => 'text/csv', 'yaml' => 'text/yaml', 'yml' => 'text/yaml',
    'toml' => 'text/plain', 'ini' => 'text/plain', 'sh' => 'text/x-shellscript',
    'bash' => 'text/x-shellscript', 'sql' => 'application/sql', 'scad' => 'text/plain',
    'stl' => 'application/sla', 'go' => 'text/x-go', 'rs' => 'text/x-rust',
    'java' => 'text/x-java', 'c' => 'text/x-c', 'cpp' => 'text/x-c', 'h' => 'text/x-c',
    'php' => 'text/x-php', 'pdf' => 'application/pdf', 'jpg' => 'image/jpeg',
    'jpeg' => 'image/jpeg', 'png' => 'image/png', 'gif' => 'image/gif',
    'webp' => 'image/webp', 'heic' => 'image/heic', 'conf' => 'text/plain'
  }.freeze

  # Maps MIME content types to file extensions (inverse of {MIME_BY_EXTENSION})
  EXTENSION_BY_MIME = {
    'text/markdown' => 'md', 'text/plain' => 'txt', 'text/x-python' => 'py',
    'application/x-python' => 'py', 'text/x-ruby' => 'rb', 'application/x-ruby' => 'rb',
    'text/javascript' => 'js', 'application/javascript' => 'js',
    'text/x-typescript' => 'ts', 'application/json' => 'json', 'text/html' => 'html',
    'text/css' => 'css', 'image/svg+xml' => 'svg', 'application/xml' => 'xml',
    'text/csv' => 'csv', 'text/yaml' => 'yml', 'application/yaml' => 'yml',
    'application/x-yaml' => 'yml', 'text/x-shellscript' => 'sh',
    'application/x-shellscript' => 'sh', 'application/sql' => 'sql',
    'application/pdf' => 'pdf'
  }.freeze

  # Maps code language hints to file extensions
  LANGUAGE_EXTENSIONS = {
    'python' => 'py', 'ruby' => 'rb', 'javascript' => 'js', 'typescript' => 'ts',
    'html' => 'html', 'css' => 'css', 'json' => 'json', 'bash' => 'sh',
    'sh' => 'sh', 'shell' => 'sh', 'zsh' => 'sh', 'sql' => 'sql', 'go' => 'go',
    'rust' => 'rs', 'java' => 'java', 'c' => 'c', 'cpp' => 'cpp', 'yaml' => 'yml',
    'yml' => 'yml', 'xml' => 'xml', 'markdown' => 'md', 'md' => 'md',
    'apache' => 'conf', 'nginx' => 'conf', 'diff' => 'diff', 'text' => 'txt'
  }.freeze

  # Maximum size (characters) of an inline block before it is attached as a file
  LARGE_BLOCK_THRESHOLD = 10_000

  # Creates a new processor for the given ZIP export file
  #
  # @param zip_path [String] path to the Claude export ZIP file
  def initialize(zip_path)
    @zip_path = zip_path
    @logger = Logger.new('logs/claude_export.log')
  end

  # Processes the ZIP file and extracts all conversations
  #
  # @return [Array<Hash>] array of conversation hashes with :id, :title, :messages keys
  def process
    @logger.info "Processing Claude export from #{@zip_path}"

    conversations = []

    Zip::File.open(@zip_path) do |zip_file|
      # Look for the conversations.json file
      entry = zip_file.find { |e| e.name == 'conversations.json' }

      if entry.nil?
        @logger.error "No conversations.json file found in the ZIP"
        return []
      end

      begin
        conversations_data = JSON.parse(entry.get_input_stream.read)

        if conversations_data.is_a?(Array)
          conversations_data.each do |conversation_data|
            conversation = process_conversation(conversation_data)
            conversations << conversation if conversation
          end
        else
          @logger.error "Expected an array of conversations in conversations.json"
        end
      rescue JSON::ParserError => e
        @logger.error "Failed to parse conversations.json: #{e.message}"
      rescue StandardError => e
        @logger.error "Error processing conversations.json: #{e.message}"
      end
    end

    @logger.info "Successfully processed #{conversations.size} conversations"
    conversations
  end

  # Processes the ZIP file and extracts all Claude Projects
  #
  # @return [Array<Hash>] array of project hashes with :id, :name, :docs keys
  def process_projects
    projects = []

    Zip::File.open(@zip_path) do |zip_file|
      zip_file.each do |entry|
        next unless entry.name.start_with?('projects/') && entry.name.end_with?('.json')

        begin
          data = JSON.parse(entry.get_input_stream.read)
          project = process_project(data)
          projects << project if project
        rescue JSON::ParserError => e
          @logger.error "Failed to parse #{entry.name}: #{e.message}"
        end
      end
    end

    @logger.info "Successfully processed #{projects.size} projects"
    projects
  end

  private

  # Processes a single conversation from the export data
  #
  # @param data [Hash] raw conversation data from JSON
  # @return [Hash, nil] processed conversation hash or nil if invalid
  def process_conversation(data)
    return nil unless data.is_a?(Hash) && data['chat_messages'].is_a?(Array)

    raw_messages = data['chat_messages']
    messages = raw_messages.map { |msg| process_message(msg) }
    attach_created_files(messages, raw_messages)

    {
      id: data['uuid'],
      title: data['name'],
      messages: messages,
      created_at: parse_timestamp(data['created_at']),
      updated_at: parse_timestamp(data['updated_at']),
      tags: %w[claude web]
    }
  end

  # Processes a single message into a full note body and its attachments
  #
  # @param msg [Hash] raw message data from JSON
  # @return [Hash] processed message hash with :id, :role, :content, :created_at, :files, :attachments
  def process_message(msg)
    message_id = msg['uuid']
    content_items = msg['content'] || []

    rendered = render_message_content(message_id, content_items)
    text = rendered[:text]
    text = msg['text'].to_s if text.strip.empty? && !msg['text'].to_s.strip.empty?

    # Original prose (text items only) used to detect inline code blocks
    original_text = content_items.select { |c| c['type'] == 'text' }
                                 .map { |c| c['text'].to_s }.join("\n\n")

    attachments = []
    attachments.concat(rendered[:attachments])
    attachments.concat(extract_user_attachments(message_id, msg))
    attachments.concat(extract_user_files(message_id, msg))
    attachments.concat(extract_artifacts(message_id, msg))
    attachments.concat(extract_code_block_attachments(original_text, message_id))

    {
      id: message_id,
      role: msg['sender'],
      content: text,
      created_at: parse_timestamp(msg['created_at']),
      files: msg['files']&.map { |f| f['file_name'] } || [],
      attachments: attachments
    }
  end

  # Renders all content items of a message in order into note text + attachments
  #
  # @param message_id [String] the message UUID
  # @param content_items [Array<Hash>] the raw content array of the message
  # @return [Hash] hash with :text (String) and :attachments (Array<Hash>)
  def render_message_content(message_id, content_items)
    segments = []
    attachments = []
    index = 0

    content_items.each do |item|
      index += 1
      case item['type']
      when 'text'
        text = item['text'].to_s
        segments << text unless text.strip.empty?
      when 'thinking'
        seg, att = render_thinking(message_id, item, index)
        segments << seg if seg
        attachments << att if att
      when 'tool_use'
        seg, atts = render_tool_use(message_id, item, index)
        segments << seg if seg
        attachments.concat(atts)
      when 'tool_result'
        seg, atts = render_tool_result(message_id, item, index)
        segments << seg if seg
        attachments.concat(atts)
      end
    end

    { text: segments.join("\n\n"), attachments: attachments }
  end

  # Renders a thinking block as a blockquote, attaching it as a file if large
  #
  # @param message_id [String] the message UUID
  # @param item [Hash] the thinking content item
  # @param index [Integer] position of the item within the message
  # @return [Array(String, Hash), Array(String, nil)] inline text and optional attachment
  def render_thinking(message_id, item, index)
    thinking = item['thinking'].to_s
    return [nil, nil] if thinking.strip.empty?

    if thinking.length > LARGE_BLOCK_THRESHOLD
      filename = "thinking-#{index}.md"
      att = build_attachment(
        kind: 'thinking', filename: filename, content: thinking,
        message_id: message_id, key_suffix: "thinking:#{index}", description: 'Claude thinking'
      )
      ["**🧠 Thinking** _(large — attached as `#{filename}`)_", att]
    else
      quoted = thinking.split("\n").map { |line| "> #{line}" }.join("\n")
      ["**🧠 Thinking:**\n#{quoted}", nil]
    end
  end

  # Renders a tool call, attaching its input as a file if large
  #
  # @param message_id [String] the message UUID
  # @param item [Hash] the tool_use content item
  # @param index [Integer] position of the item within the message
  # @return [Array(String, Array<Hash>)] inline text and any attachments
  def render_tool_use(message_id, item, index)
    name = item['name'].to_s
    input = item['input'] || {}

    case name
    when 'artifacts'
      ["**📎 Claude artifact:** `#{input['title']}` _(attached as a file)_", []]
    when 'create_file'
      ["**📎 File created by Claude:** `#{File.basename(input['path'].to_s)}` _(attached)_", []]
    when 'str_replace'
      render_str_replace(message_id, input, index)
    else
      pretty = pretty_json(input)
      if pretty.length > LARGE_BLOCK_THRESHOLD
        filename = "toolcall-#{index}.json"
        att = build_attachment(
          kind: 'toolcall', filename: filename, content: pretty,
          message_id: message_id, key_suffix: "toolcall:#{index}", description: "Tool call: #{name}"
        )
        ["**🔧 Tool call — `#{name}`** _(large input — attached as `#{filename}`)_", [att]]
      else
        ["**🔧 Tool call — `#{name}`:**\n\n#{fenced(pretty, 'json')}", []]
      end
    end
  end

  # Renders a str_replace edit, showing the before/after content
  #
  # @param message_id [String] the message UUID
  # @param input [Hash] the str_replace tool input
  # @param index [Integer] position of the item within the message
  # @return [Array(String, Array<Hash>)] inline text and any attachments
  def render_str_replace(message_id, input, index)
    base = File.basename(input['path'].to_s)
    body = "--- before\n#{input['old_str']}\n\n+++ after\n#{input['new_str']}"

    if body.length > LARGE_BLOCK_THRESHOLD
      filename = "edit-#{index}.diff"
      att = build_attachment(
        kind: 'edit', filename: filename, content: body,
        message_id: message_id, key_suffix: "edit:#{index}", description: "Edit to #{base}"
      )
      ["**✏️ Claude edited `#{base}`** _(large diff — attached as `#{filename}`)_", [att]]
    else
      ["**✏️ Claude edited `#{base}`:**\n\n_Replaced:_\n\n#{fenced(input['old_str'])}\n\n_With:_\n\n#{fenced(input['new_str'])}", []]
    end
  end

  # Renders a tool result, attaching it as a file if large
  #
  # @param message_id [String] the message UUID
  # @param item [Hash] the tool_result content item
  # @param index [Integer] position of the item within the message
  # @return [Array(String, Array<Hash>)] inline text and any attachments
  def render_tool_result(message_id, item, index)
    body = render_result_items(item['content'])
    return [nil, []] if body.strip.empty?

    name = item['name'].to_s
    label = "📥 Result#{name.empty? ? '' : " — `#{name}`"}#{item['is_error'] ? ' (error)' : ''}"

    if body.length > LARGE_BLOCK_THRESHOLD
      filename = "toolresult-#{index}.md"
      att = build_attachment(
        kind: 'toolresult', filename: filename, content: body,
        message_id: message_id, key_suffix: "toolresult:#{index}", description: 'Tool result'
      )
      ["**#{label}** _(large — attached as `#{filename}`)_", [att]]
    else
      ["**#{label}:**\n\n#{body}", []]
    end
  end

  # Renders the content items of a tool result into readable markdown
  #
  # Plain output (command output, file contents) is wrapped in a code fence so it
  # renders as preformatted text; web-search results stay as markdown links.
  #
  # @param content [Object] the tool result content (string or array of items)
  # @return [String] readable representation of the result
  def render_result_items(content)
    unless content.is_a?(Array)
      text = content.to_s
      return text.strip.empty? ? '' : fenced(text)
    end

    content.filter_map { |item| render_result_item(item) }.join("\n\n")
  end

  # Renders a single tool-result content item
  #
  # @param item [Hash] a single tool-result content item
  # @return [String, nil] readable markdown or nil when empty
  def render_result_item(item)
    case item['type']
    when 'text'
      text = item['text'].to_s
      text.strip.empty? ? nil : fenced(text)
    when 'knowledge'
      head = item['title'].to_s.empty? ? item['url'].to_s : item['title'].to_s
      link = item['url'].to_s.empty? ? "- #{head}" : "- [#{head}](#{item['url']})"
      snippet = item['text'].to_s.strip
      snippet.empty? ? link : "#{link}\n  #{snippet}"
    when 'local_resource'
      "- #{item['name']} (#{item['mime_type']})"
    when 'image'
      "- [image #{item['file_uuid']}]"
    when 'image_gallery'
      '- [image gallery]'
    else
      "- (#{item['type']})"
    end
  end

  # Wraps text in a Markdown code fence sized to survive any backticks inside it
  #
  # @param text [String] the text to wrap
  # @param language [String] optional code fence language hint
  # @return [String] the fenced code block
  def fenced(text, language = '')
    body = text.to_s
    longest_run = body.scan(/`+/).map(&:length).max || 0
    fence = '`' * [longest_run + 1, 3].max
    "#{fence}#{language}\n#{body}\n#{fence}"
  end

  # Parses a timestamp string into a Time object
  #
  # @param timestamp [String, nil] ISO 8601 timestamp string
  # @return [Time] parsed time or current time if parsing fails
  def parse_timestamp(timestamp)
    return Time.now unless timestamp

    begin
      Time.parse(timestamp)
    rescue ArgumentError
      Time.now
    end
  end

  # Extracts user-uploaded document attachments that carry extracted text
  #
  # @param message_id [String] the message UUID the attachment belongs to
  # @param original_msg [Hash] original raw message from JSON
  # @return [Array<Hash>] array of document attachment hashes
  def extract_user_attachments(message_id, original_msg)
    return [] unless original_msg['attachments'].is_a?(Array)

    original_msg['attachments'].each_with_index.filter_map do |attachment, index|
      content = attachment['extracted_content']
      next if content.nil? || content.to_s.strip.empty?

      raw_name = attachment['file_name'].to_s
      extension = extension_for_file_type(attachment['file_type'])
      filename = raw_name.empty? ? "attachment-#{message_id[0..7]}-#{index + 1}.#{extension}" : sanitize_filename(raw_name)

      build_attachment(
        kind: 'document',
        filename: filename,
        content: content.to_s,
        message_id: message_id,
        key_suffix: "attachment:#{index}",
        description: 'User-provided document'
      )
    end
  end

  # Extracts user-uploaded files (images) which have no binary in the export
  #
  # @param message_id [String] the message UUID the file belongs to
  # @param original_msg [Hash] original raw message from JSON
  # @return [Array<Hash>] array of image attachment hashes without content
  def extract_user_files(message_id, original_msg)
    return [] unless original_msg['files'].is_a?(Array)

    original_msg['files'].each_with_index.map do |file, index|
      raw_name = file['file_name'].to_s
      filename = raw_name.empty? ? "file-#{message_id[0..7]}-#{index + 1}" : sanitize_filename(raw_name)
      file_uuid = file['file_uuid'].to_s

      {
        kind: 'image',
        filename: filename,
        content: nil,
        content_type: guess_content_type(filename),
        available: false,
        description: 'User-uploaded file; binary not included in the Claude export',
        key: "#{message_id}:file:#{file_uuid.empty? ? index : file_uuid}"
      }
    end
  end

  # Extracts Claude artifacts (tool_use named "artifacts") as file attachments
  #
  # @param message_id [String] the message UUID the artifact belongs to
  # @param original_msg [Hash] original raw message from JSON
  # @return [Array<Hash>] array of artifact attachment hashes
  def extract_artifacts(message_id, original_msg)
    return [] unless original_msg['content'].is_a?(Array)

    original_msg['content'].each_with_index.filter_map do |content_item, index|
      next unless content_item['type'] == 'tool_use' && content_item['name'] == 'artifacts'

      build_artifact_attachment(message_id, content_item, index)
    end
  end

  # Extracts inline fenced code blocks from text as downloadable file attachments
  #
  # @param text [String] the message prose to scan for fenced code blocks
  # @param message_id [String] the message UUID the code blocks belong to
  # @return [Array<Hash>] array of code attachment hashes
  def extract_code_block_attachments(text, message_id)
    return [] if text.to_s.strip.empty?

    text.scan(/```([a-zA-Z0-9+#.\-]*)\n(.*?)```/m).each_with_index.filter_map do |(lang, code), index|
      body = code.to_s.strip
      next if body.empty?

      extension = LANGUAGE_EXTENSIONS[lang.to_s.downcase] || 'txt'
      build_attachment(
        kind: 'code',
        filename: "code-block-#{index + 1}.#{extension}",
        content: body,
        message_id: message_id,
        key_suffix: "codeblock:#{index}",
        description: "Inline #{lang.to_s.empty? ? 'code' : lang} block"
      )
    end
  end

  # Reconstructs files created by Claude and attaches their final versions
  #
  # @param messages [Array<Hash>] processed message hashes
  # @param raw_messages [Array<Hash>] original raw message hashes
  # @return [void]
  def attach_created_files(messages, raw_messages)
    by_id = messages.each_with_object({}) { |m, acc| acc[m[:id]] = m }

    reconstruct_created_files(raw_messages).each do |file|
      target = by_id[file[:create_message_id]]
      next unless target

      basename = sanitize_filename(File.basename(file[:path]))
      digest = Digest::SHA256.hexdigest(file[:content])[0..15]
      target[:attachments] << {
        kind: 'file',
        filename: basename,
        content: file[:content],
        content_type: guess_content_type(basename),
        available: true,
        description: file[:description].to_s.empty? ? 'File created by Claude' : file[:description],
        key: "#{file[:create_message_id]}:create_file:#{file[:create_index]}:#{digest}"
      }
    end
  end

  # Walks tool calls in order to rebuild the final content of created files
  #
  # Applies create_file (set content) and str_replace (apply edits). Because the export sometimes snapshots create_file
  # at a different point than the edits target, reconstruction is all-or-nothing: only when every edit applies cleanly
  # is the reconstructed content used; otherwise the verbatim create_file snapshot is kept so the uploaded file is
  # always a coherent real version (never a mix). The individual edits are always preserved separately in the rendered
  # notes.
  #
  # @param raw_messages [Array<Hash>] original raw message hashes
  # @return [Array<Hash>] file hashes with :path, :content, :create_message_id, :create_index, :description
  def reconstruct_created_files(raw_messages)
    files = {}
    order = []

    raw_messages.each do |msg|
      content = msg['content']
      next unless content.is_a?(Array)

      message_id = msg['uuid']
      content.each_with_index do |item, index|
        next unless item['type'] == 'tool_use'

        input = item['input'] || {}
        case item['name']
        when 'create_file'
          apply_create_file(files, order, input, message_id, index)
        when 'str_replace'
          apply_str_replace(files, input)
        end
      end
    end

    order.map do |path|
      file = files[path]
      file[:content] = file[:original] unless file[:clean]
      file
    end
  end

  # Records a created file in the virtual file map
  #
  # @param files [Hash] map of path to file hash
  # @param order [Array<String>] ordered list of seen paths
  # @param input [Hash] the create_file tool input
  # @param message_id [String] the message UUID of the tool call
  # @param index [Integer] position of the tool call within the message
  # @return [void]
  def apply_create_file(files, order, input, message_id, index)
    path = input['path'].to_s
    return if path.empty?

    text = input['file_text'].to_s
    return if text.strip.empty?

    files[path] = {
      path: path, content: text, original: text, clean: true,
      create_message_id: message_id, create_index: index, description: input['description'].to_s
    }
    order << path unless order.include?(path)
  end

  # Applies a str_replace edit to a previously created file
  #
  # Marks the file as not cleanly reconstructable when the edit does not match,
  # so the verbatim create_file snapshot is used instead of a partial result.
  #
  # @param files [Hash] map of path to file hash
  # @param input [Hash] the str_replace tool input
  # @return [void]
  def apply_str_replace(files, input)
    path = input['path'].to_s
    return unless files.key?(path)

    old_str = input['old_str'].to_s

    if !old_str.empty? && files[path][:content].include?(old_str)
      new_str = input['new_str'].to_s
      files[path][:content] = files[path][:content].sub(old_str) { new_str }
    else
      files[path][:clean] = false
    end
  end

  # Builds an attachment hash for a Claude "artifacts" tool call
  #
  # @param message_id [String] the message UUID the artifact belongs to
  # @param content_item [Hash] the tool_use content item from JSON
  # @param index [Integer] position of the content item within the message
  # @return [Hash, nil] attachment hash or nil when the artifact has no content
  def build_artifact_attachment(message_id, content_item, index)
    input = content_item['input'] || {}
    content = input['content']
    return nil if content.nil? || content.to_s.strip.empty?

    extension = extension_for_artifact(input['type'], input['language'])
    title = input['title'].to_s.strip
    base = title.empty? ? "artifact-#{index + 1}" : sanitize_filename(title)
    filename = base.end_with?(".#{extension}") ? base : "#{base}.#{extension}"

    build_attachment(
      kind: 'artifact',
      filename: filename,
      content: content.to_s,
      message_id: message_id,
      key_suffix: "artifact:#{input['id'] || index}",
      description: 'Claude artifact'
    )
  end

  # Builds a normalized attachment hash with a stable idempotency key
  #
  # @param kind [String] attachment kind (document, artifact, file, code, etc.)
  # @param filename [String] sanitized file name to use in Redmine
  # @param content [String] textual content of the attachment
  # @param message_id [String] the message UUID the attachment belongs to
  # @param key_suffix [String] discriminator appended to the idempotency key
  # @param description [String] human-readable description of the attachment
  # @return [Hash] normalized attachment hash
  def build_attachment(kind:, filename:, content:, message_id:, key_suffix:, description:)
    digest = Digest::SHA256.hexdigest(content)[0..15]

    {
      kind: kind,
      filename: filename,
      content: content,
      content_type: guess_content_type(filename),
      available: true,
      description: description,
      key: "#{message_id}:#{key_suffix}:#{digest}"
    }
  end

  # Processes a single Claude Project into a normalized hash
  #
  # @param data [Hash] raw project data from JSON
  # @return [Hash, nil] processed project hash or nil if invalid
  def process_project(data)
    return nil unless data.is_a?(Hash) && data['uuid']

    docs = (data['docs'] || []).each_with_index.map do |doc, index|
      build_project_doc(data['uuid'], doc, index)
    end

    {
      id: data['uuid'],
      name: data['name'].to_s,
      description: data['description'].to_s,
      prompt_template: data['prompt_template'].to_s,
      created_at: parse_timestamp(data['created_at']),
      docs: docs
    }
  end

  # Builds an attachment hash for a single project knowledge document
  #
  # @param project_id [String] the project UUID
  # @param doc [Hash] the raw document hash from JSON
  # @param index [Integer] position of the document within the project
  # @return [Hash] document attachment hash
  def build_project_doc(project_id, doc, index)
    raw_name = doc['filename'].to_s
    filename = raw_name.empty? ? "doc-#{index + 1}.md" : sanitize_filename(raw_name)
    filename = "#{filename}.md" unless filename.include?('.')
    content = doc['content'].to_s
    digest = Digest::SHA256.hexdigest(content)[0..15]

    {
      kind: 'project_doc',
      filename: filename,
      content: content,
      content_type: guess_content_type(filename),
      available: !content.strip.empty?,
      description: 'Project knowledge document',
      key: "#{project_id}:doc:#{index}:#{digest}"
    }
  end

  # Sanitizes a string into a safe, single-segment file name
  #
  # @param name [String] raw file name or title
  # @return [String] sanitized file name limited in length
  def sanitize_filename(name)
    cleaned = name.to_s.strip.gsub(%r{[/\\]}, '-').gsub(/[^\w.\- ]/, '').gsub(/\s+/, ' ').strip
    cleaned = 'attachment' if cleaned.empty?
    cleaned.length > 120 ? cleaned[0, 120] : cleaned
  end

  # Pretty-prints a value as JSON, falling back to its string form
  #
  # @param value [Object] the value to serialize
  # @return [String] pretty JSON or the value's string form
  def pretty_json(value)
    JSON.pretty_generate(value)
  rescue StandardError
    value.to_s
  end

  # Maps a Claude attachment file_type to a file extension
  #
  # @param file_type [String, nil] the file_type value from the export
  # @return [String] a file extension without the leading dot
  def extension_for_file_type(file_type)
    type = file_type.to_s
    return 'txt' if type.empty? || type == 'txt'

    extension_for_mime(type) || type
  end

  # Maps a Claude artifact type/language to a file extension
  #
  # @param artifact_type [String, nil] artifact MIME type
  # @param language [String, nil] artifact language hint
  # @return [String] a file extension without the leading dot
  def extension_for_artifact(artifact_type, language)
    case artifact_type
    when 'text/markdown' then 'md'
    when 'text/html' then 'html'
    when 'image/svg+xml' then 'svg'
    when 'application/vnd.ant.code' then LANGUAGE_EXTENSIONS[language.to_s] || 'txt'
    else
      extension_for_mime(artifact_type.to_s) || LANGUAGE_EXTENSIONS[language.to_s] || 'md'
    end
  end

  # Guesses a MIME content type from a file name extension
  #
  # @param filename [String] the file name to inspect
  # @return [String] a MIME content type, defaulting to text/plain
  def guess_content_type(filename)
    extension = File.extname(filename.to_s).delete('.').downcase
    return 'application/octet-stream' if extension.empty?

    MIME_BY_EXTENSION.fetch(extension, 'text/plain')
  end

  # Maps a MIME type to a file extension using the known extension table
  #
  # @param mime [String] the MIME type to look up
  # @return [String, nil] the matching extension or nil when unknown
  def extension_for_mime(mime)
    EXTENSION_BY_MIME[mime.to_s]
  end
end
