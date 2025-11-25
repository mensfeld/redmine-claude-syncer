require 'sqlite3'
require 'logger'
require 'fileutils'

class Database
  def initialize(db_path)
    @db_path = db_path
    @logger = Logger.new('logs/database.log')
    setup_database
  end

  def get_conversation(conversation_id)
    row = @db.get_first_row(
      "SELECT claude_conversation_id, redmine_issue_id, last_exported_message_id, created_at, updated_at 
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
      updated_at: row[4]
    }
  end

  def create_conversation(conversation_id, redmine_issue_id, last_message_id)
    @db.execute(
      "INSERT INTO conversations
       (claude_conversation_id, redmine_issue_id, last_exported_message_id, created_at, updated_at)
       VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
      [conversation_id, redmine_issue_id, last_message_id]
    )
    @logger.info "Created conversation record for #{conversation_id}"
  end

  def update_last_message_id(conversation_id, last_message_id)
    @db.execute(
      "UPDATE conversations
       SET last_exported_message_id = ?, updated_at = CURRENT_TIMESTAMP
       WHERE claude_conversation_id = ?",
      [last_message_id, conversation_id]
    )
    @logger.info "Updated last message ID for conversation #{conversation_id}"
  end

  def save_artifact(conversation_id, artifact_type, file_path, redmine_attachment_id)
    @db.execute(
      "INSERT INTO artifacts
       (conversation_id, artifact_type, file_path, redmine_attachment_id)
       VALUES (?, ?, ?, ?)",
      [conversation_id, artifact_type, file_path, redmine_attachment_id]
    )
  end

  private

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
      CREATE TABLE IF NOT EXISTS artifacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT,
        artifact_type TEXT,
        file_path TEXT,
        redmine_attachment_id INTEGER,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (conversation_id) REFERENCES conversations(claude_conversation_id)
      )
    SQL

    @logger.info "Database initialized at #{@db_path}"
  rescue SQLite3::Exception => e
    @logger.error "Database initialization failed: #{e.message}"
    raise
  end
end 