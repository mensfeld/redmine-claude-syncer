# Redmine Claude Syncer

A Ruby application that synchronizes Claude AI conversations to Redmine issues.

## Features

- Imports conversations from Claude export ZIP files as a complete backup
- Renders the full message content as notes: text, thinking, tool calls and tool results
- Uploads all attachments and artifacts: user documents, Claude artifacts, created files
  (final version after edits), inline code blocks, and oversized blocks as files
- Imports Claude Projects (description, custom instructions and knowledge docs)
- Tags issues by source (`coding-session`/`claude-code`, `claude`/`web`, `claude`/`project`) for easy filtering
- Sets issue `start_date` and leads each note with its original timestamp (Redmine can't backdate `created_on`)
- Supersedes partial older imports: creates a complete new issue and closes (never deletes) the old one
- Idempotent: tracks conversations by content version and attachments by key, so re-runs don't duplicate
- Tracks conversation, attachment and project state in SQLite
- Handles retries and error recovery, skipping (and logging) any item that fails

## Requirements

- Ruby 4.0 or later
- Redmine instance with API access
- SQLite3

## Setup

1. Clone the repository:
```bash
git clone <repository-url>
cd redmine-claude-syncer
```

2. Install dependencies:
```bash
bundle install
```

3. Create a `.env` file with your configuration:
```bash
REDMINE_URL=https://your-redmine-instance
REDMINE_HUMAN_API_KEY=your-human-api-key
REDMINE_CLAUDE_API_KEY=your-claude-api-key
REDMINE_PROJECT_ID=your-project-id
REDMINE_HUMAN_USER_ID=your-human-user-id
REDMINE_CLAUDE_USER_ID=your-claude-user-id
REDMINE_TRACKER_ID=1
REDMINE_STATUS_ID=1
REDMINE_PRIORITY_ID=2
```

4. Make the sync script executable:
```bash
chmod +x bin/sync.rb
```

## Usage

Run the sync script with a Claude export ZIP file:
```bash
./bin/sync.rb path/to/export.zip
```

### Importing Claude Code sessions

You can also archive your local Claude Code coding sessions (the JSONL transcripts
under `~/.claude/projects/`) into the same Redmine project:
```bash
./bin/sync_code.rb
```
Each session becomes an issue whose subject is prefixed with `[Claude Code]` (so it
can be filtered/tagged), rendered the same way as conversations (text, thinking, tool
calls and results, code blocks as files) with the raw `.jsonl` transcript attached for
full fidelity. Override the location with `CLAUDE_PROJECTS_DIR` if it isn't `~/.claude/projects`.

## Directory Structure

- `bin/` - Executable scripts
- `lib/` - Ruby source code
- `db/` - SQLite database files
- `logs/` - Application logs
- `artifacts/` - Exported artifacts (if any)

## License

This project is licensed under the GNU Affero General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

The GNU AGPL is a free, copyleft license that ensures the software remains free and open source, with the additional requirement that any modifications made available over a network must also be made available under the same license terms. 