# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Redmine Claude Syncer is a Ruby application that synchronizes Claude AI conversations from exported ZIP files to Redmine issues. It processes Claude export files, creates corresponding Redmine issues, and adds conversation messages as notes from the respective users (human/Claude).

## Commands

### Setup and Installation
```bash
bundle install                    # Install dependencies
chmod +x bin/sync.rb              # Make sync script executable
```

### Running the Syncer
```bash
./bin/sync.rb path/to/export.zip  # Sync a Claude.ai export ZIP to Redmine
./bin/sync_code.rb                # Sync local Claude Code sessions (~/.claude/projects)
```

### Environment Configuration
Create a `.env` file with these required variables:
- `REDMINE_URL` - Your Redmine instance URL
- `REDMINE_HUMAN_API_KEY` - API key for human user
- `REDMINE_CLAUDE_API_KEY` - API key for Claude user
- `REDMINE_PROJECT_ID` - Target project ID
- `REDMINE_HUMAN_USER_ID` - Human user ID in Redmine
- `REDMINE_CLAUDE_USER_ID` - Claude user ID in Redmine
- `REDMINE_TRACKER_ID` - Issue tracker ID (default: 1)
- `REDMINE_STATUS_ID` - Issue status ID (default: 1)
- `REDMINE_PRIORITY_ID` - Issue priority ID (default: 2)

Optional configuration:
- `REDMINE_CLOSED_STATUS_ID` - Status ID used when closing superseded issues (default: 5)
- `CLAUDE_PROJECTS_DIR` - Claude Code transcripts dir for `bin/sync_code.rb` (default: ~/.claude/projects)
- `DATABASE_PATH` - SQLite database path (default: db/conversations.db)
- `LOG_FILE` - Log file path (default: logs/sync.log)
- `LOG_LEVEL` - Logging level (DEBUG, INFO, WARN, ERROR)

## Architecture

### Core Components

**Syncer** (`lib/syncer.rb`) - Main orchestrator that:
- Coordinates the entire synchronization process
- Manages conversation processing and Redmine issue creation/updates
- Handles artifact extraction and file attachments
- Tracks processed conversations in SQLite database

**ClaudeExportProcessor** (`lib/claude_export_processor.rb`) - Handles Claude export parsing:
- Extracts conversations from Claude ZIP exports
- Parses `conversations.json` files
- Converts Claude message format to internal representation

**ClaudeCodeProcessor** (`lib/claude_code_processor.rb`) - Claude Code session reader:
- Subclass of ClaudeExportProcessor that reads `~/.claude/projects/*/*.jsonl` transcripts
- Reuses the same renderer so coding sessions are archived like conversations
- Attaches the raw transcript and prefixes issue subjects with `[Claude Code]`

**RedmineClient** (`lib/redmine_client.rb`) - Redmine API interface:
- Creates and updates Redmine issues
- Adds conversation messages as notes using appropriate user contexts
- Handles file attachments and uploads
- Implements retry logic with exponential backoff for API reliability

**Database** (`lib/database.rb`) - SQLite persistence layer:
- Tracks conversation sync state and last processed message IDs
- Stores artifact metadata and Redmine attachment references
- Prevents duplicate processing of conversations

### Data Flow

1. **Export Processing**: ZIP file → JSON parsing → conversation + project objects
2. **State Check**: Database lookup to determine the conversation's content version
3. **Issue Management**: Create / supersede / incrementally update the Redmine issue
4. **Message Processing**: Render each message fully and add it as a note from the right user
5. **Attachment Processing**: Upload artifacts, files, code blocks and oversized blocks as Redmine attachments
6. **Project Processing**: Create an issue per Claude Project and attach its knowledge docs
7. **State Persistence**: Update database with message IDs, content version and synced attachments

### Full message rendering

The goal is for Redmine to be a complete backup. Each message's `content` array is
rendered **in order** into the note body, not just the visible text:

- **text** → rendered as-is (Markdown)
- **thinking** → rendered as a blockquote (`🧠 Thinking`)
- **tool_use** → rendered as `🔧 Tool call — <name>` with its input
- **tool_result** → rendered as `📥 Result` (web search hits as links, command output, etc.)

Any single block larger than `LARGE_BLOCK_THRESHOLD` (10k chars) is attached as a file
instead of bloating the note (e.g. a fetched web page becomes `toolresult-N.md`).

### Attachments & Artifacts

Each message is scanned for uploadable content, attached to the issue as a note
(attributed to the message sender) with the files attached:

- **User documents** (`message.attachments[]` with `extracted_content`) - uploaded as text files
- **User files** (`message.files[]`) - images referenced by name only; the Claude export
  does not include their binary content, so they are listed but cannot be uploaded
- **Claude artifacts** (`tool_use` named `artifacts`) - uploaded as files (e.g. markdown)
- **Claude-created files** (`create_file` + `str_replace`) - the **final** version is rebuilt and uploaded
- **Inline code blocks** - every fenced code block is uploaded as a file (and kept inline too)
- **Oversized thinking / tool blocks** - externalized to files (see above)

Attachment uploads are idempotent: each is tracked by a stable key (message + source +
content hash) in the `attachments` table, so re-runs never create duplicates.

### Claude Projects

`projects/*.json` are imported too: each Project becomes a Redmine issue (`Project: <name>`)
with its description and `prompt_template`, and each knowledge doc is attached. Tracked in
the `projects` table for idempotency.

### Claude Code sessions

`bin/sync_code.rb` archives local Claude Code coding sessions the same way as
Claude.ai conversations. `ClaudeCodeProcessor` (`lib/claude_code_processor.rb`)
reads the JSONL transcripts under `~/.claude/projects/*/*.jsonl`, and — being a
subclass of `ClaudeExportProcessor` — reuses the exact same renderer (text,
thinking, tool calls, tool results, code blocks as files). Per session:

- The issue subject is prefixed `[Claude Code]` so sessions can be filtered/tagged.
- The title comes from the transcript's `aiTitle` (falling back to the first prompt).
- `cwd` and git branch are recorded in the description.
- The raw `.jsonl` transcript is attached for full fidelity.
- Conversation id is `cc-<sessionId>` so it never collides with Claude.ai conversations.

Both entry points share the same `Syncer`, database and Redmine project. Because
Claude Code uses random (non-time-ordered) message UUIDs, incremental detection is
**position-based** (`Syncer#messages_after`), not id comparison.

### Re-import / superseding

The importer stamps each conversation with `content_version` (see `Syncer::CONTENT_VERSION`).
When a conversation was imported by an older version, the next run **supersedes** it: it
creates a fresh, complete issue, **closes** (does not delete) the old issue with a note
pointing to the new one, and repoints the database. This is how partial older imports are
upgraded to full content. Once at the current version, runs are incremental.

### Key Design Decisions

- **Dual API Keys**: Separate Redmine API keys for human and Claude users to maintain proper authorship
- **Complete backup**: Full message content (text + thinking + tools), attachments, code, and projects
- **Superseding, not deleting**: Old partial issues are closed and linked, never deleted
- **Idempotent**: Attachments tracked by key; conversations tracked by content version
- **Resilient Runs**: A failure on one conversation/project is logged and skipped so the rest continues

### Database Schema

**conversations** table:
- `claude_conversation_id` (PRIMARY KEY) - Claude conversation UUID
- `redmine_issue_id` - Corresponding Redmine issue ID
- `last_exported_message_id` - Last processed message UUID for incremental sync
- `content_version` - Importer content version used (drives superseding)

**attachments** table:
- `conversation_id` - Conversation (or project) the attachment belongs to
- `message_id` - Claude message UUID the attachment belongs to
- `attachment_key` (UNIQUE) - Stable idempotency key (message + source + content hash)
- `kind` - Attachment kind (`document`, `image`, `artifact`, `file`, `code`, `thinking`, `toolcall`, `toolresult`, `project_doc`)
- `filename` - File name used in Redmine
- `redmine_attachment_id` - Redmine attachment ID if known

**projects** table:
- `claude_project_id` (PRIMARY KEY) - Claude project UUID
- `redmine_issue_id` - Corresponding Redmine issue ID

## File Structure

- `bin/sync.rb` - Entry point for Claude.ai export ZIPs
- `bin/sync_code.rb` - Entry point for Claude Code sessions (~/.claude/projects)
- `lib/` - Core Ruby classes and business logic
- `db/` - SQLite database files
- `logs/` - Application log files (separate logs per component)
- `artifacts/` - Extracted artifacts from conversations (if any)