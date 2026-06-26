require 'sqlite3'
require 'logger'
require 'fileutils'

# SQLite database layer for tracking synced conversations and artifacts
class Database
  # Creates a new database connection and initializes schema
  #
  # @param db_path [String] path to the SQLite database file
  def initialize(db_path)
    @db_path = db_path
    @logger = Logger.new('logs/database.log')
    setup_database
  end

  # Retrieves a conversation record by its Claude conversation ID
  #
  # @param conversation_id [String] the Claude conversation UUID
  # @return [Hash, nil] conversation data or nil if not found
  def get_conversation(conversation_id)
    row = @db.get_first_row(
      "SELECT claude_conversation_id, redmine_issue_id, last_exported_message_id, created_at, updated_at, content_version
       FROM conversations
       WHERE claude_conversation_id = ?",
      conversation_id
    )

    return nil unless row

    {
      claude_conversation_id: row[0],
      redmine_issue_id: row[1],
      last_exported_message_id: row[2],
      created_at: row[3],
      updated_at: row[4],
      content_version: row[5].to_i
    }
  end

  # Creates a new conversation record in the database
  #
  # @param conversation_id [String] the Claude conversation UUID
  # @param redmine_issue_id [Integer] the corresponding Redmine issue ID
  # @param last_message_id [String] the UUID of the last processed message
  # @param content_version [Integer] the content schema version of the import
  # @return [void]
  def create_conversation(conversation_id, redmine_issue_id, last_message_id, content_version = 0)
    @db.execute(
      "INSERT INTO conversations
       (claude_conversation_id, redmine_issue_id, last_exported_message_id, content_version, created_at, updated_at)
       VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
      [conversation_id, redmine_issue_id, last_message_id, content_version]
    )
    @logger.info "Created conversation record for #{conversation_id}"
  end

  # Repoints a conversation to a new Redmine issue and bumps its content version
  #
  # @param conversation_id [String] the Claude conversation UUID
  # @param redmine_issue_id [Integer] the new Redmine issue ID
  # @param last_message_id [String] the UUID of the last processed message
  # @param content_version [Integer] the content schema version of the import
  # @return [void]
  def repoint_conversation(conversation_id, redmine_issue_id, last_message_id, content_version)
    @db.execute(
      "UPDATE conversations
       SET redmine_issue_id = ?, last_exported_message_id = ?, content_version = ?, updated_at = CURRENT_TIMESTAMP
       WHERE claude_conversation_id = ?",
      [redmine_issue_id, last_message_id, content_version, conversation_id]
    )
    @logger.info "Repointed conversation #{conversation_id} to issue ##{redmine_issue_id}"
  end

  # Removes all recorded attachments for a conversation so they re-upload
  #
  # @param conversation_id [String] the Claude conversation UUID
  # @return [void]
  def reset_conversation_attachments(conversation_id)
    @db.execute("DELETE FROM attachments WHERE conversation_id = ?", conversation_id)
    @logger.info "Reset attachment tracking for conversation #{conversation_id}"
  end

  # Updates the last processed message ID for a conversation
  #
  # @param conversation_id [String] the Claude conversation UUID
  # @param last_message_id [String] the UUID of the last processed message
  def update_last_message_id(conversation_id, last_message_id)
    @db.execute(
      "UPDATE conversations
       SET last_exported_message_id = ?, updated_at = CURRENT_TIMESTAMP
       WHERE claude_conversation_id = ?",
      [last_message_id, conversation_id]
    )
    @logger.info "Updated last message ID for conversation #{conversation_id}"
  end

  # Checks whether an attachment has already been uploaded to Redmine
  #
  # @param attachment_key [String] stable idempotency key for the attachment
  # @return [Boolean] true if the attachment was already synced, false otherwise
  def attachment_synced?(attachment_key)
    row = @db.get_first_row(
      "SELECT 1 FROM attachments WHERE attachment_key = ? LIMIT 1",
      attachment_key
    )
    !row.nil?
  end

  # Records an attachment that has been uploaded to a Redmine issue
  #
  # @param conversation_id [String] the Claude conversation UUID
  # @param message_id [String] the Claude message UUID the attachment belongs to
  # @param attachment_key [String] stable idempotency key for the attachment
  # @param kind [String] attachment kind (document, image, artifact, file)
  # @param filename [String] the file name used in Redmine
  # @param redmine_attachment_id [Integer, nil] Redmine attachment ID if known
  # @return [void]
  def record_attachment(conversation_id, message_id, attachment_key, kind, filename, redmine_attachment_id)
    @db.execute(
      "INSERT OR IGNORE INTO attachments
       (conversation_id, message_id, attachment_key, kind, filename, redmine_attachment_id)
       VALUES (?, ?, ?, ?, ?, ?)",
      [conversation_id, message_id, attachment_key, kind, filename, redmine_attachment_id]
    )
    @logger.info "Recorded #{kind} attachment '#{filename}' for conversation #{conversation_id}"
  end

  # Retrieves a project record by its Claude project ID
  #
  # @param project_id [String] the Claude project UUID
  # @return [Hash, nil] project data or nil if not found
  def get_project(project_id)
    row = @db.get_first_row(
      "SELECT claude_project_id, redmine_issue_id FROM projects WHERE claude_project_id = ?",
      project_id
    )

    return nil unless row

    { claude_project_id: row[0], redmine_issue_id: row[1] }
  end

  # Creates a new project record in the database
  #
  # @param project_id [String] the Claude project UUID
  # @param redmine_issue_id [Integer] the corresponding Redmine issue ID
  # @return [void]
  def create_project(project_id, redmine_issue_id)
    @db.execute(
      "INSERT OR REPLACE INTO projects (claude_project_id, redmine_issue_id, created_at)
       VALUES (?, ?, CURRENT_TIMESTAMP)",
      [project_id, redmine_issue_id]
    )
    @logger.info "Created project record for #{project_id}"
  end

  private

  # Initializes the database connection and creates tables if needed
  def setup_database
    FileUtils.mkdir_p(File.dirname(@db_path))
    
    @db = SQLite3::Database.new(@db_path)
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS conversations (
        claude_conversation_id TEXT PRIMARY KEY,
        redmine_issue_id INTEGER,
        last_exported_message_id TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT,
        message_id TEXT,
        attachment_key TEXT UNIQUE,
        kind TEXT,
        filename TEXT,
        redmine_attachment_id INTEGER,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (conversation_id) REFERENCES conversations(claude_conversation_id)
      )
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS projects (
        claude_project_id TEXT PRIMARY KEY,
        redmine_issue_id INTEGER,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    SQL

    ensure_column('conversations', 'content_version', 'INTEGER DEFAULT 0')

    @logger.info "Database initialized at #{@db_path}"
  rescue SQLite3::Exception => e
    @logger.error "Database initialization failed: #{e.message}"
    raise
  end

  # Adds a column to a table if it does not already exist
  #
  # @param table [String] the table name
  # @param column [String] the column name
  # @param definition [String] the SQL column definition
  # @return [void]
  def ensure_column(table, column, definition)
    existing = @db.table_info(table).map { |col| col['name'] }
    return if existing.include?(column)

    @db.execute("ALTER TABLE #{table} ADD COLUMN #{column} #{definition}")
    @logger.info "Added column #{column} to #{table}"
  end
end 