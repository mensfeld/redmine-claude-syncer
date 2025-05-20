require 'zip'
require 'json'
require 'logger'
require 'fileutils'
require 'date'
require 'digest'

class ClaudeExportProcessor
  def initialize(zip_path)
    @zip_path = zip_path
    @logger = Logger.new('logs/claude_export.log')
  end

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

    {
      id: msg['uuid'],
      role: msg['sender'],
      content: text_content,
      created_at: parse_timestamp(msg['created_at']),
      files: msg['files']&.map { |f| f['file_name'] } || []
    }
  end

  def parse_timestamp(timestamp)
    return Time.now unless timestamp
    
    begin
      Time.parse(timestamp)
    rescue ArgumentError
      Time.now
    end
  end
end 