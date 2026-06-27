require_relative 'database'
require_relative 'claude_export_processor'
require_relative 'redmine_client'
require 'logger'
require 'fileutils'
require 'date'
require 'securerandom'

# Main orchestrator that synchronizes Claude conversations to Redmine issues
class Syncer
  # Content schema version of the importer. Conversations imported with an older
  # version are superseded by a fresh, complete issue on the next run.
  # v3: tool results and outputs are rendered inside code fences.
  CONTENT_VERSION = 3

  # Creates a new syncer with the given configuration
  #
  # @param config [Hash] configuration hash with Redmine and database settings
  def initialize(config)
    @config = config
    @logger = Logger.new(config[:log_file] || 'logs/sync.log')
    @logger.level = config[:log_level] ? Logger.const_get(config[:log_level]) : Logger::INFO

    @human_user_id = config[:redmine_human_user_id]
    @claude_user_id = config[:redmine_claude_user_id]
    @closed_status_id = config[:redmine_closed_status_id] || 5

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

  # Synchronizes conversations and projects from a Claude export ZIP to Redmine
  #
  # @param zip_path [String] path to the Claude export ZIP file
  # @return [void]
  def sync(zip_path)
    import(ClaudeExportProcessor.new(zip_path))
  end

  # Synchronizes conversations (and projects) from any export processor
  #
  # @param processor [#process] an export processor responding to #process
  # @return [void]
  def import(processor)
    @logger.info "Starting synchronization process"

    begin
      sync_conversations(processor)
      sync_projects(processor) if processor.respond_to?(:process_projects)

      @logger.info "Synchronization completed"
    rescue StandardError => e
      @logger.error "Synchronization failed: #{e.message}"
      raise
    end
  end

  private

  # Orders items oldest-first by their original creation time
  #
  # Ensures issues are created chronologically so newer conversations get higher
  # issue IDs (so the natural card order matches the conversation timeline).
  #
  # @param items [Array<Hash>] items with a :created_at key
  # @return [Array<Hash>] the items sorted by :created_at ascending
  def ordered_by_creation(items)
    items.sort_by { |item| item[:created_at] || Time.at(0) }
  end

  # Synchronizes all conversations from the export
  #
  # @param processor [ClaudeExportProcessor] the export processor
  # @return [void]
  def sync_conversations(processor)
    # Create oldest-first so newer conversations get higher issue IDs (natural order)
    conversations = ordered_by_creation(processor.process)

    succeeded = 0
    failed = 0
    conversations.each do |conversation|
      process_conversation(conversation)
      succeeded += 1
    rescue StandardError => e
      failed += 1
      @logger.error "Failed to process conversation #{conversation[:id]}: #{e.message}"
    end

    @logger.info "Conversations completed: #{succeeded} succeeded, #{failed} failed"
  end

  # Synchronizes all Claude Projects from the export
  #
  # @param processor [ClaudeExportProcessor] the export processor
  # @return [void]
  def sync_projects(processor)
    projects = ordered_by_creation(processor.process_projects)

    projects.each do |project|
      sync_project(project)
    rescue StandardError => e
      @logger.error "Failed to process project #{project[:id]}: #{e.message}"
    end

    @logger.info "Projects completed: #{projects.size} processed"
  end

  # Processes a single conversation, routing to create/supersede/update
  #
  # @param conversation [Hash] conversation data with :id, :messages keys
  # @return [void]
  def process_conversation(conversation)
    @logger.info "Processing conversation #{conversation[:id]}"

    existing = @db.get_conversation(conversation[:id])

    if existing.nil?
      create_new_conversation(conversation)
    elsif existing[:content_version].to_i < CONTENT_VERSION
      supersede_conversation(existing, conversation)
    else
      update_existing_conversation(existing, conversation)
    end
  end

  # Creates a new Redmine issue with the full conversation content
  #
  # @param conversation [Hash] conversation data with :id, :title, :messages keys
  # @return [void]
  def create_new_conversation(conversation)
    issue_id = import_conversation(conversation)
    return unless issue_id

    @db.create_conversation(
      conversation[:id],
      issue_id,
      conversation[:messages].last[:id],
      CONTENT_VERSION
    )
    apply_tags(issue_id, conversation, fresh: true)
  end

  # Replaces a partially-imported conversation with a fresh, complete issue
  #
  # The old issue is closed (not deleted) with a note pointing to the new one.
  #
  # @param existing [Hash] existing conversation record from database
  # @param conversation [Hash] conversation data with :id, :title, :messages keys
  # @return [void]
  def supersede_conversation(existing, conversation)
    old_issue_id = existing[:redmine_issue_id]

    # Clear attachment tracking so everything re-uploads to the new issue
    @db.reset_conversation_attachments(conversation[:id])

    new_issue_id = import_conversation(conversation)
    return unless new_issue_id

    @redmine.close_issue(
      old_issue_id,
      "Superseded by ##{new_issue_id} — re-imported with complete content " \
      "(thinking, tool calls & results, and all attachments).",
      @closed_status_id
    )

    @db.repoint_conversation(
      conversation[:id],
      new_issue_id,
      conversation[:messages].last[:id],
      CONTENT_VERSION
    )
    apply_tags(new_issue_id, conversation, fresh: true)
  end

  # Updates an existing Redmine issue with new messages and backfills attachments
  #
  # @param existing [Hash] existing conversation record from database
  # @param conversation [Hash] conversation data with new messages
  # @return [void]
  def update_existing_conversation(existing, conversation)
    issue_id = existing[:redmine_issue_id]

    new_messages = messages_after(conversation[:messages], existing[:last_exported_message_id])

    unless new_messages.empty?
      @redmine.process_messages(issue_id, new_messages)
      @db.update_last_message_id(conversation[:id], new_messages.last[:id])
    end

    # Always reconcile attachments so anything missing gets backfilled
    sync_attachments(issue_id, conversation)

    # Ensure tags on existing issues too (backfills issues imported before tagging)
    apply_tags(issue_id, conversation, fresh: false)
  end

  # Applies the conversation's tags to its issue, tracked to stay cheap
  #
  # Fresh issues get their tags set directly; existing issues get an additive
  # merge (preserving manual tags). Already-applied tags are skipped via the
  # database so re-runs don't re-read journals or re-write tags.
  #
  # @param issue_id [Integer] the Redmine issue ID
  # @param conversation [Hash] conversation data with :id and :tags keys
  # @param fresh [Boolean] whether the issue was just created
  # @return [void]
  def apply_tags(issue_id, conversation, fresh:)
    desired = conversation[:tags] || []
    return if desired.empty?

    applied = @db.get_applied_tags(conversation[:id])
    return if (desired - applied).empty?

    result = fresh ? @redmine.set_tags(issue_id, desired) : @redmine.add_tags(issue_id, desired)
    @db.set_applied_tags(conversation[:id], (applied | result))
  end

  # Returns the messages that come after the last-processed message, by position
  #
  # Position-based (not id comparison) so it works for both time-ordered Claude.ai
  # message UUIDs and the random UUIDs used by Claude Code transcripts.
  #
  # @param messages [Array<Hash>] all messages of the conversation in order
  # @param last_id [String, nil] UUID of the last processed message
  # @return [Array<Hash>] messages after last_id (empty if none or not found)
  def messages_after(messages, last_id)
    return messages if last_id.nil? || last_id.to_s.empty?

    index = messages.index { |msg| msg[:id] == last_id }
    if index.nil?
      @logger.warn "Last processed message #{last_id} not found; skipping to avoid duplicates" unless messages.empty?
      return []
    end

    messages[(index + 1)..] || []
  end

  # Creates an issue and imports the full conversation (messages + attachments)
  #
  # @param conversation [Hash] conversation data with :id, :title, :messages keys
  # @return [Integer, nil] the new Redmine issue ID, or nil if the conversation is empty
  def import_conversation(conversation)
    if conversation[:messages].nil? || conversation[:messages].empty?
      @logger.warn "Skipping empty conversation #{conversation[:id]}"
      return nil
    end

    title = conversation[:title].to_s.strip
    title = "Claude Conversation #{conversation[:id]}" if title.empty?

    start_date = conversation[:created_at]&.strftime('%Y-%m-%d')
    issue = @redmine.create_issue(title, conversation_description(title, conversation), start_date)
    @redmine.process_messages(issue['id'], conversation[:messages])
    sync_attachments(issue['id'], conversation)

    issue['id']
  end

  # Builds the initial description for a conversation issue
  #
  # @param title [String] the conversation title
  # @param conversation [Hash] conversation data with :id and :created_at keys
  # @return [String] the issue description
  def conversation_description(title, conversation)
    lines = [
      title,
      '',
      'Backup of a conversation between a human user and Claude AI.',
      "Claude conversation ID: #{conversation[:id]}",
      "Started: #{conversation[:created_at]&.strftime('%Y-%m-%d %H:%M:%S')}"
    ]
    lines << "Working directory: #{conversation[:cwd]}" if conversation[:cwd]
    lines << "Git branch: #{conversation[:git_branch]}" if conversation[:git_branch]
    lines << ''
    lines << 'Each message is added as a note from the respective user, including thinking, ' \
             'tool calls and results. Attachments and artifacts are attached to the relevant notes.'
    lines.join("\n")
  end

  # Synchronizes a single Claude Project into a Redmine issue
  #
  # @param project [Hash] project data with :id, :name, :docs keys
  # @return [void]
  def sync_project(project)
    existing = @db.get_project(project[:id])

    issue_id = existing ? existing[:redmine_issue_id] : create_project_issue(project)

    # Tag projects (additive + idempotent — no-op once present)
    @redmine.add_tags(issue_id, %w[claude project])

    pending = project[:docs].reject { |doc| @db.attachment_synced?(doc[:key]) }
    return if pending.empty?

    @redmine.add_attachments(issue_id, pending, @human_user_id, "Project knowledge documents")
    pending.each do |doc|
      @db.record_attachment(project[:id], project[:id], doc[:key], doc[:kind], doc[:filename], nil)
    end
  end

  # Creates the Redmine issue for a project and records it
  #
  # @param project [Hash] project data with :id, :name, :description keys
  # @return [Integer] the new Redmine issue ID
  def create_project_issue(project)
    name = project[:name].to_s.strip
    name = "Claude Project #{project[:id]}" if name.empty?

    issue = @redmine.create_issue("Project: #{name}", project_description(project))
    @db.create_project(project[:id], issue['id'])
    issue['id']
  end

  # Builds the description for a project issue
  #
  # @param project [Hash] project data with :name, :description, :prompt_template keys
  # @return [String] the issue description
  def project_description(project)
    parts = ["Claude Project backup: #{project[:name]}", '']
    parts << project[:description] unless project[:description].to_s.strip.empty?

    unless project[:prompt_template].to_s.strip.empty?
      parts << "\n**Custom instructions:**\n\n#{project[:prompt_template]}"
    end

    parts << "\nClaude project ID: #{project[:id]}"
    parts.join("\n")
  end

  # Uploads any not-yet-synced attachments for each message in the conversation
  #
  # This is idempotent: attachments already recorded in the database are skipped.
  #
  # @param issue_id [Integer] the Redmine issue ID
  # @param conversation [Hash] conversation data with :id and :messages keys
  # @return [void]
  def sync_attachments(issue_id, conversation)
    conversation[:messages].each do |msg|
      pending = (msg[:attachments] || []).reject { |a| @db.attachment_synced?(a[:key]) }
      next if pending.empty?

      user_id = msg[:role] == 'human' ? @human_user_id : @claude_user_id
      header = "Attachments from #{msg[:role]} message (#{msg[:created_at].strftime('%Y-%m-%d %H:%M:%S')})"

      @redmine.add_attachments(issue_id, pending, user_id, header)

      pending.each do |attachment|
        @db.record_attachment(
          conversation[:id],
          msg[:id],
          attachment[:key],
          attachment[:kind],
          attachment[:filename],
          nil
        )
      end
    end
  end
end
