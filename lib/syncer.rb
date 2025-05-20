require_relative 'database'
require_relative 'claude_export_processor'
require_relative 'redmine_client'
require 'logger'
require 'fileutils'
require 'date'

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

    # Add new messages as notes from respective users
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

    # Add all messages as notes from respective users
    @redmine.process_messages(issue['id'], conversation[:messages])

    # Store in database
    @db.create_conversation(
      conversation[:id],
      issue['id'],
      conversation[:messages].last[:id]
    )
  end

  def process_artifacts(conversation_id, issue_id, messages)
    messages.each do |msg|
      # Extract artifacts from message content
      artifacts = extract_artifacts(msg)
      
      artifacts.each do |artifact|
        # Skip if artifact already processed
        next if @db.artifact_exists?(conversation_id, artifact[:id])

        # Save artifact
        file_path = save_artifact(conversation_id, artifact)
        
        # Attach to Redmine issue
        attachment = @redmine.attach_file(
          issue_id,
          file_path,
          "Claude artifact: #{artifact[:type]}"
        )

        # Store in database
        @db.create_artifact(
          conversation_id,
          artifact[:type],
          file_path,
          attachment.id
        )
      end
    end
  end

  def extract_artifacts(message)
    artifacts = []
    
    # Extract code blocks
    message[:content].scan(/```(\w+)?\n(.*?)```/m).each do |lang, code|
      artifacts << {
        id: SecureRandom.uuid,
        type: lang || 'code',
        content: code.strip
      }
    end

    # Extract other types of artifacts (you can add more patterns here)
    # For example, Mermaid diagrams:
    message[:content].scan(/```mermaid\n(.*?)```/m).each do |diagram|
      artifacts << {
        id: SecureRandom.uuid,
        type: 'mermaid',
        content: diagram.first.strip
      }
    end

    artifacts
  end

  def save_artifact(conversation_id, artifact)
    # Create artifacts directory if it doesn't exist
    artifacts_dir = File.join('artifacts', conversation_id)
    FileUtils.mkdir_p(artifacts_dir)

    # Generate file path
    file_path = File.join(
      artifacts_dir,
      "#{artifact[:id]}.#{artifact[:type]}"
    )

    # Save artifact
    File.write(file_path, artifact[:content])
    
    file_path
  end
end 