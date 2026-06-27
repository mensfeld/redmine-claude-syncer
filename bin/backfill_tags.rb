#!/usr/bin/env ruby
# One-off backfill: set tags + start_date (+ strip "[Claude Code] " prefix) on
# existing Redmine issues, driven by the local DB. Idempotent (replace tags).
#   ruby backfill_tags.rb canary   -> a few issues only
#   ruby backfill_tags.rb          -> everything
require 'dotenv'; Dotenv.load
require 'net/http'; require 'json'; require 'uri'; require 'sqlite3'

BASE = ENV['REDMINE_URL'].chomp('/')
HKEY = ENV['REDMINE_HUMAN_API_KEY']
DBP  = ENV['DATABASE_PATH'] || 'db/conversations.db'
CANARY = ARGV[0] == 'canary'

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

# Build work list from the DB: [issue_id, conv_id|nil, tags, coding?]
work = []
db.execute('SELECT claude_conversation_id, redmine_issue_id FROM conversations').each do |cid, iid|
  next unless iid
  coding = cid.start_with?('cc-')
  work << [iid, cid, coding ? %w[coding-session claude-code] : %w[claude web], coding]
end
db.execute('SELECT redmine_issue_id FROM projects').each do |iid,|
  work << [iid, nil, %w[claude project], false] if iid
end

if CANARY
  coding = work.find { |w| w[3] }
  web    = work.find { |w| !w[3] && w[1] }
  proj   = work.find { |w| w[1].nil? }
  work = [coding, web, proj].compact
end

puts "issues to process: #{work.size}#{CANARY ? ' (canary)' : ''}"

done = failed = renamed = dated = 0
work.each do |iid, cid, tags, coding|
  begin
    g = request(http, Net::HTTP::Get, "/issues/#{iid}.json")
    if g.code.to_i == 404
      failed += 1
      next
    end
    issue = JSON.parse(g.body)['issue']
    payload = { tag_list: tags }
    if (m = issue['description'].to_s.match(/Started:\s*(\d{4}-\d{2}-\d{2})/))
      payload[:start_date] = m[1]; dated += 1
    end
    subj = issue['subject'].to_s
    if coding && subj.start_with?('[Claude Code] ')
      payload[:subject] = subj.sub(/^\[Claude Code\]\s*/, ''); renamed += 1
    end
    p = request(http, Net::HTTP::Put, "/issues/#{iid}.json", { issue: payload })
    unless p.code.to_i.between?(200, 299)
      warn "PUT #{iid} -> #{p.code}"
      failed += 1
      next
    end
    db.execute('UPDATE conversations SET tags_applied=? WHERE claude_conversation_id=?', [tags.join(','), cid]) if cid
    done += 1
    if CANARY
      puts "##{iid} coding=#{coding} tags=#{tags.join(',')} start=#{payload[:start_date] || '-'} subj=#{payload[:subject] || issue['subject']}"
    end
  rescue StandardError => e
    warn "issue #{iid}: #{e.message}"
    failed += 1
  end
  puts "progress: #{done} done, #{failed} failed, #{renamed} renamed, #{dated} dated" if !CANARY && (done + failed) % 250 == 0
end

puts "FINAL: #{done} done, #{failed} failed, #{renamed} renamed, #{dated} dated of #{work.size}"
