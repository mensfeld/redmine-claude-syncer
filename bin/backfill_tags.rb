#!/usr/bin/env ruby
# One-off backfill: set tags + start_date (+ strip "[Claude Code] " prefix) on
# existing Redmine issues, driven by the local DB. Idempotent (replace tags).
#   ruby backfill_tags.rb canary   -> a few issues only
#   ruby backfill_tags.rb coding   -> coding sessions only
#   ruby backfill_tags.rb          -> everything
require 'dotenv'; Dotenv.load
require 'net/http'; require 'json'; require 'uri'; require 'sqlite3'

$stdout.sync = true
BASE = ENV['REDMINE_URL'].chomp('/')
HKEY = ENV['REDMINE_HUMAN_API_KEY']
DBP  = ENV['DATABASE_PATH'] || 'db/conversations.db'
MODE = ARGV[0] # nil (all), 'canary' (a few), 'coding' (coding sessions only)
CANARY = MODE == 'canary'

# Derives a downcased project tag from a working directory path (its basename)
def project_tag(cwd)
  return nil if cwd.to_s.strip.empty?

  name = File.basename(cwd.to_s.strip).downcase.gsub(/\s+/, '-').gsub(/[^a-z0-9._-]/, '')
  name.empty? ? nil : name
end

db = SQLite3::Database.new(DBP)

uri = URI(BASE)
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = uri.scheme == 'https'
http.read_timeout = 60; http.open_timeout = 30
http.start

def request(http, klass, path, body = nil)
  r = klass.new(path)
  r['X-Redmine-API-Key'] = HKEY
  r['Content-Type'] = 'application/json'
  r['Accept'] = 'application/json'
  r.body = body.to_json if body
  tries = 0
  begin
    http.request(r)
  rescue StandardError
    tries += 1
    if tries < 4
      sleep 2
      http.start unless http.started?
      retry
    end
    raise
  end
end

# Build work list from the DB: [issue_id, conv_id|nil, base_tags, coding?]
work = []
db.execute('SELECT claude_conversation_id, redmine_issue_id FROM conversations').each do |cid, iid|
  next unless iid
  coding = cid.start_with?('cc-')
  work << [iid, cid, coding ? %w[coding-session claude-code] : %w[claude web], coding]
end
db.execute('SELECT redmine_issue_id FROM projects').each do |iid,|
  work << [iid, nil, %w[claude project], false] if iid
end

work.select! { |w| w[3] } if MODE == 'coding'
if CANARY
  work = [work.find { |w| w[3] }, work.find { |w| !w[3] && w[1] }, work.find { |w| w[1].nil? }].compact
end

puts "issues to process: #{work.size} (mode: #{MODE || 'all'})"

done = failed = renamed = dated = estimated = projected = 0
work.each do |iid, cid, base_tags, coding|
  begin
    g = request(http, Net::HTTP::Get, "/issues/#{iid}.json")
    if g.code.to_i == 404
      failed += 1
      next
    end
    issue = JSON.parse(g.body)['issue']
    desc = issue['description'].to_s

    tags = base_tags.dup
    if coding && (wd = desc.match(/Working directory:\s*(.+)/))
      pt = project_tag(wd[1])
      if pt
        tags << pt
        projected += 1
      end
    end

    payload = { tag_list: tags }
    if (m = desc.match(/Started:\s*(\d{4}-\d{2}-\d{2})/))
      payload[:start_date] = m[1]; dated += 1
    elsif issue['created_on'].to_s.length >= 10
      # No recoverable original date -> use the issue's creation date as the closest estimate
      payload[:start_date] = issue['created_on'][0, 10]; estimated += 1
    end
    subj = issue['subject'].to_s
    if coding
      clean = subj.sub(/^\[Claude Code\]\s*/, '').gsub(/[\[\]]/, '').gsub(/\s+/, ' ').strip
      if !clean.empty? && clean != subj
        payload[:subject] = clean; renamed += 1
      end
    end

    p = request(http, Net::HTTP::Put, "/issues/#{iid}.json", { issue: payload })
    unless p.code.to_i.between?(200, 299)
      warn "PUT #{iid} -> #{p.code}"
      failed += 1
      next
    end
    db.execute('UPDATE conversations SET tags_applied=? WHERE claude_conversation_id=?', [tags.join(','), cid]) if cid
    done += 1
    puts "##{iid} tags=#{tags.join(',')} start=#{payload[:start_date] || '-'} subj=#{payload[:subject] || issue['subject']}" if CANARY
  rescue StandardError => e
    warn "issue #{iid}: #{e.message}"
    failed += 1
  end
  puts "progress: #{done} done, #{failed} failed, #{renamed} renamed, #{dated} dated, #{estimated} estimated, #{projected} project-tagged" if !CANARY && (done + failed) % 250 == 0
end

puts "FINAL: #{done} done, #{failed} failed, #{renamed} renamed, #{dated} dated, #{estimated} estimated, #{projected} project-tagged of #{work.size}"
