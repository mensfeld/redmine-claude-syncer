# Redmine Claude Syncer

A Ruby application that archives your Claude history in Redmine as a complete, browsable
backup. It imports two things into the same Redmine project:

- **Claude.ai conversations** — from your account export ZIP (chats and Projects)
- **Claude Code sessions** — your local agentic coding sessions (the `~/.claude/projects` transcripts)

Each conversation/session becomes a Redmine issue with every message as a note, so even
after Claude Code compacts its context the full history lives safely in Redmine. Built to
be run repeatedly (e.g. weekly): it's incremental and only adds what's new.

## Features

- Imports both Claude.ai conversations and Claude Code coding sessions as a complete backup
- Renders the full message content as notes: text, thinking, tool calls and tool results
- Uploads all attachments and artifacts: user documents, Claude artifacts, created files
  (final version after edits), inline code blocks, and oversized blocks as files
- Imports Claude Projects (description, custom instructions and knowledge docs); coding
  sessions also attach the raw `.jsonl` transcript for full fidelity
- Tags issues by source for easy filtering: `claude`/`web`, `coding-session`/`claude-code`/`<project>`, `claude`/`project`
- Sets issue `start_date` and leads each note with its original timestamp (Redmine can't backdate `created_on`)
- Creates issues oldest-first so issue IDs follow the conversation timeline
- Supersedes partial older imports: creates a complete new issue and closes (never deletes) the old one
- Idempotent: tracks conversations by content version and attachments by key, so re-runs don't duplicate
- Tracks conversation, attachment and project state in SQLite
- Handles retries and error recovery, skipping (and logging) any item that fails

## Requirements

- Ruby 4.0 or later
- Redmine instance with API access, plus:
  - the [redmine_tags](https://github.com/ixti/redmine_tags) plugin (for source tags)
  - the **Start date** standard field enabled on the tracker you import into (Administration →
    Trackers → your tracker → Standard fields) so `start_date` can be set
- Two Redmine users (a human and a "Claude" user), each with an API key, for correct note authorship
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

# Optional
REDMINE_CLOSED_STATUS_ID=5            # status used when closing a superseded issue
CLAUDE_PROJECTS_DIR=~/.claude/projects # where bin/sync_code.rb looks for sessions
DATABASE_PATH=db/conversations.db      # tracking DB (reuse the same one across runs)
LOG_FILE=logs/sync.log
LOG_LEVEL=info
```

4. Make the sync scripts executable:
```bash
chmod +x bin/sync.rb bin/sync_code.rb
```

## Usage

There are two importers. Both are **incremental and idempotent** — run them as often
as you like (e.g. weekly); they only add what's new and never duplicate.

**Claude.ai conversations** — from an export ZIP:
```bash
./bin/sync.rb path/to/export.zip
```

**Claude Code coding sessions** — from your local transcripts under `~/.claude/projects/`:
```bash
./bin/sync_code.rb
```
(Override the location with `CLAUDE_PROJECTS_DIR` if it isn't `~/.claude/projects`.)

Both write to the same Redmine project and the same SQLite database (keep using the
same `db/conversations.db` so re-runs know what's already imported). On each run:

- New conversations/sessions become issues (created oldest-first so issue IDs follow the timeline).
- Existing ones get only their new messages appended.
- Each issue is tagged by source — `claude` + `web`, `coding-session` + `claude-code` + `<project>`,
  or `claude` + `project` — so you can filter by type/agent/project.
- `start_date` is set to the conversation's original date; each note also leads with its timestamp.
- The full message content is rendered (text, thinking, tool calls/results); attachments,
  artifacts, created files and code blocks are uploaded; coding sessions also attach the raw `.jsonl`.

## Directory Structure

- `bin/` - Executable scripts
- `lib/` - Ruby source code
- `db/` - SQLite database files
- `logs/` - Application logs
- `artifacts/` - Exported artifacts (if any)

## License

This project is licensed under the GNU Affero General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

The GNU AGPL is a free, copyleft license that ensures the software remains free and open source, with the additional requirement that any modifications made available over a network must also be made available under the same license terms. 