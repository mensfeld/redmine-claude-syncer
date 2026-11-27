require 'zip'
require 'json'
require 'digest'
require 'stringio'
require 'time'

# Builds a compressed ZIP snapshot of the raw data a conversation was imported from
#
# Each import uploads one of these to the issue, so Redmine keeps not just the rendered notes but the original
# source (raw export record / session transcript, sibling files, metadata and every extracted attachment) for
# later metadata lookups or full reconstruction. A snapshot is identified by a digest of its source files, so an
# unchanged source is never uploaded twice, while a changed one is uploaded again alongside the older snapshots.
module SourceArchive
  # Attachment kind used for source snapshots in the attachments table
  KIND = 'source'.freeze

  module_function

  # Computes a stable digest of a conversation's raw source files
  #
  # @param source_files [Hash{String => String}] archive path => raw content
  # @return [String] a short hex digest identifying this exact source
  def digest(source_files)
    sha = Digest::SHA256.new
    source_files.sort_by(&:first).each do |path, content|
      sha << path << "\0" << content.to_s.b << "\0"
    end
    sha.hexdigest[0, 16]
  end

  # Builds the idempotency key of a conversation's source snapshot
  #
  # @param conversation [Hash] conversation data with :id and :source_files keys
  # @return [String] attachment key (conversation + source digest)
  def key(conversation)
    "#{conversation[:id]}:#{KIND}:#{digest(conversation[:source_files])}"
  end

  # Builds the snapshot attachment for a conversation
  #
  # The archive holds the raw source files as-is, a `metadata.json` describing the import and every attachment
  # extracted from the messages under `attachments/<message-index>-<message-id>/`.
  #
  # @param conversation [Hash] conversation data with :id, :source_files and :messages keys
  # @param issue_id [Integer] the Redmine issue the snapshot is attached to
  # @param content_version [Integer] the importer content version
  # @param archived_at [Time] when the snapshot is taken
  # @return [Hash] an attachment hash accepted by {RedmineClient#add_attachments}
  def build(conversation, issue_id:, content_version:, archived_at: Time.now)
    entries = conversation[:source_files].dup
    entries['metadata.json'] = JSON.pretty_generate(metadata(conversation, issue_id, content_version, archived_at))
    entries.merge!(attachment_entries(conversation[:messages] || []))

    {
      kind: KIND,
      filename: "source-#{archived_at.strftime('%Y%m%d-%H%M%S')}-#{digest(conversation[:source_files])[0, 8]}.zip",
      content: zip(entries),
      content_type: 'application/zip',
      available: true,
      description: "Compressed source snapshot (#{conversation[:source_files].keys.join(', ')}, metadata and attachments)",
      key: key(conversation)
    }
  end

  # Describes the import so the snapshot is self-explanatory on its own
  #
  # @param conversation [Hash] conversation data
  # @param issue_id [Integer] the Redmine issue ID
  # @param content_version [Integer] the importer content version
  # @param archived_at [Time] when the snapshot is taken
  # @return [Hash] metadata for metadata.json
  def metadata(conversation, issue_id, content_version, archived_at)
    {
      conversation_id: conversation[:id],
      title: conversation[:title],
      redmine_issue_id: issue_id,
      created_at: conversation[:created_at]&.iso8601,
      updated_at: conversation[:updated_at]&.iso8601,
      cwd: conversation[:cwd],
      git_branch: conversation[:git_branch],
      tags: conversation[:tags],
      sources: conversation[:source_paths],
      message_count: (conversation[:messages] || []).size,
      last_message_id: conversation[:messages]&.last&.dig(:id),
      source_digest: digest(conversation[:source_files]),
      content_version: content_version,
      archived_at: archived_at.iso8601
    }.compact
  end

  # Maps every uploadable message attachment to a unique path inside the archive
  #
  # @param messages [Array<Hash>] processed messages with :id and :attachments keys
  # @return [Hash{String => String}] archive path => content
  def attachment_entries(messages)
    messages.each_with_index.each_with_object({}) do |(msg, index), entries|
      (msg[:attachments] || []).each_with_index do |attachment, att_index|
        next unless attachment[:available] && attachment[:content]

        dir = format('attachments/%<index>04d-%<id>s', index: index + 1, id: msg[:id])
        path = "#{dir}/#{attachment[:filename]}"
        path = "#{dir}/#{att_index + 1}-#{attachment[:filename]}" if entries.key?(path)
        entries[path] = attachment[:content]
      end
    end
  end

  # Packs entries into an in-memory, deflate-compressed ZIP
  #
  # @param entries [Hash{String => String}] archive path => content
  # @return [String] the binary ZIP data
  def zip(entries)
    Zip::OutputStream.write_buffer(StringIO.new) do |out|
      entries.each do |path, content|
        out.put_next_entry(path)
        out.write(content.to_s)
      end
    end.string
  end
end
