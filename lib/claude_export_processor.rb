require 'zip'
require 'json'
require 'logger'
require 'fileutils'
require 'date'
require 'time'
require 'digest'

# Processes Claude AI export ZIP files and extracts conversation data
class ClaudeExportProcessor
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

  private

  def process_conversation(data)
    return nil unless data.is_a?(Hash) && data['chat_messages'].is_a?(Array)

    {
      id: data['uuid'],
      title: data['name'],
      messages: data['chat_messages'].map { |msg| process_message(msg) },
      created_at: parse_timestamp(data['created_at']),
      updated_at: parse_timestamp(data['updated_at'])
    }
  end

  def process_message(msg)
    # Extract the actual text content from the content array
    text_content = msg['content'].map { |c| c['text'] }.join("\n")
    
    # Use the full text content from the message if the content array is empty or contains only empty text
    if text_content.strip.empty? && msg['text'] && !msg['text'].strip.empty?
      text_content = msg['text']
    end

    message_data = {
      id: msg['uuid'],
      role: msg['sender'],
      content: text_content,
      created_at: parse_timestamp(msg['created_at']),
      files: msg['files']&.map { |f| f['file_name'] } || []
    }
    
    # Extract code snippets from this message and add them to the message data
    code_items = extract_code_items(message_data, msg)
    message_data[:code_items] = code_items
    
    # Print found code snippets if any
    print_code_snippets(message_data, code_items) unless code_items.empty?
    
    message_data
  end

  def parse_timestamp(timestamp)
    return Time.now unless timestamp
    
    begin
      Time.parse(timestamp)
    rescue ArgumentError
      Time.now
    end
  end
  
  def extract_code_items(message_data, original_msg)
    all_code_items = []
    
    # 1. Extract markdown code blocks from text content
    if message_data[:content] && !message_data[:content].strip.empty?
      message_data[:content].scan(/```(\w+)?\n(.*?)```/m).each_with_index do |(lang, code), index|
        all_code_items << {
          type: 'markdown_block',
          language: lang || 'text',
          content: code.strip,
          index: index + 1,
          title: "Code Block ##{index + 1}",
          id: "#{message_data[:id]}_markdown_#{index + 1}"
        }
      end
    end
    
    # 2. Extract artifacts from content array (tool_use with name "artifacts")
    if original_msg['content'].is_a?(Array)
      original_msg['content'].each_with_index do |content_item, index|
        if content_item['type'] == 'tool_use' && 
           content_item['name'] == 'artifacts' && 
           content_item['input'] && 
           content_item['input']['content']
          
          artifact_content = content_item['input']['content']
          artifact_type = content_item['input']['type'] || 'unknown'
          artifact_title = content_item['input']['title'] || "Artifact ##{index + 1}"
          
          all_code_items << {
            type: 'artifact',
            language: extract_language_from_artifact_type(artifact_type),
            content: artifact_content.strip,
            index: index + 1,
            title: artifact_title,
            artifact_id: content_item['input']['id'],
            id: content_item['input']['id'] || "#{message_data[:id]}_artifact_#{index + 1}"
          }
        end
      end
    end
    
    all_code_items
  end
  
  def print_code_snippets(message_data, all_code_items)
    puts "\n" + "="*70
    puts "📄 CODE SNIPPETS & ARTIFACTS FOUND IN MESSAGE #{message_data[:id][0..7]}..."
    puts "   Role: #{message_data[:role].upcase}"
    puts "   Created: #{message_data[:created_at]}"
    puts "="*70
    
    all_code_items.each_with_index do |item, index|
      type_emoji = item[:type] == 'artifact' ? '🔧' : '🔹'
      puts "\n#{type_emoji} #{item[:title]} (#{item[:language]}):"
      
      if item[:type] == 'artifact' && item[:artifact_id]
        puts "   Artifact ID: #{item[:artifact_id]}"
      end
      
      puts "-" * 50
      puts item[:content]
      puts "-" * 50
      puts "   Lines: #{item[:content].lines.count}"
      puts "   Characters: #{item[:content].length}"
      puts "   Type: #{item[:type]}"
    end
    
    puts "\n📊 SUMMARY: Found #{all_code_items.length} code item(s) in this message"
    artifact_count = all_code_items.count { |item| item[:type] == 'artifact' }
    markdown_count = all_code_items.count { |item| item[:type] == 'markdown_block' }
    puts "   - #{artifact_count} artifact(s)"
    puts "   - #{markdown_count} markdown code block(s)"
    puts "📝 These will be included inline in the Redmine note content"
    puts "="*70
  end
  
  def extract_language_from_artifact_type(artifact_type)
    case artifact_type
    when 'application/vnd.ant.code'
      'code'
    when /javascript|js/
      'javascript'
    when /python|py/
      'python'
    when /ruby|rb/
      'ruby'
    when /html/
      'html'
    when /css/
      'css'
    else
      artifact_type || 'text'
    end
  end
end 