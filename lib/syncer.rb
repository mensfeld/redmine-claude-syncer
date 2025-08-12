require_relative 'database'
require_relative 'claude_export_processor'
require_relative 'redmine_client'
require 'logger'
require 'fileutils'
require 'date'
require 'securerandom'

class Syncer
  def initialize(config)
    @config = config
    @logger = Logger.new(config[:log_file] || 'logs/sync.log')
    @logger.level = config[:log_level] ? Logger.const_get(config[:log_level]) : Logger::INFO

    @db = Database.new(config[:database_path] || 'db/conversations.db')
    @redmine = RedmineClient.new(
      config[:redmine_url],
      config[:redmine_human_api_key],
      config[:redmine_claude_api_key],
      config[:redmine_project_id],
      config[:redmine_human_user_id],
      config[:redmine_claude_user_id],
      config[:redmine_tracker_id],
      config[:redmine_status_id],
      config[:redmine_priority_id]
    )
  end

  def sync(zip_path)
    @logger.info "Starting synchronization process for export: #{zip_path}"
    
    begin
      processor = ClaudeExportProcessor.new(zip_path)
      conversations = processor.process
      
      conversations.each do |conversation|
        process_conversation(conversation)
      end

      @logger.info "Synchronization completed successfully"
    rescue StandardError => e
      @logger.error "Synchronization failed: #{e.message}"
      raise
    end
  end

  private

  def process_conversation(conversation)
    @logger.info "Processing conversation #{conversation[:id]}"

    # Check if conversation exists in database
    existing = @db.get_conversation(conversation[:id])
    
    if existing
      update_existing_conversation(existing, conversation)
    else
      create_new_conversation(conversation)
    end
  end

  def update_existing_conversation(existing, conversation)
    # Get messages that haven't been processed yet
    new_messages = conversation[:messages].select do |msg|
      msg[:id] > existing[:last_exported_message_id]
    end

    return if new_messages.empty?

    # Add new messages as notes from respective users (including code snippets inline)
    @redmine.process_messages(existing[:redmine_issue_id], new_messages)

    # Update database with new last message ID
    @db.update_last_message_id(
      conversation[:id],
      new_messages.last[:id]
    )
  end

  def create_new_conversation(conversation)
    # Skip empty conversations
    if conversation[:messages].nil? || conversation[:messages].empty?
      @logger.warn "Skipping empty conversation #{conversation[:id]}"
      return
    end

    # Create new Redmine issue with initial description
    title = conversation[:title].to_s.strip
    title = "Claude Conversation #{conversation[:id]}" if title.empty?
    
    initial_description = "#{title}\n\n" \
                        "This issue tracks a conversation between a human user and Claude AI.\n" \
                        "Each message will be added as a note from the respective user."
    
    issue = @redmine.create_issue(
      title,
      initial_description
    )

    # Add all messages as notes from respective users (including code snippets inline)
    @redmine.process_messages(issue['id'], conversation[:messages])

    # Store in database
    @db.create_conversation(
      conversation[:id],
      issue['id'],
      conversation[:messages].last[:id]
    )
  end

end 