# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'log_file'
require 'syncer'
require 'claude_code_processor'

RSpec.describe LogFile do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  describe '.logger' do
    it 'creates missing parent directories of the log file' do
      logger = described_class.logger('nested/dir/app.log')

      expect(logger).to be_a(Logger)
      expect(File.exist?('nested/dir/app.log')).to be(true)
    end
  end

  context 'when logs/ does not exist' do
    before { expect(Dir.exist?('logs')).to be(false) }

    it 'creates it for every component logger' do
      Database.new(File.join(Dir.pwd, 'db/test.db'))
      RedmineClient.new('https://redmine.example.com', 'h', 'c', 'p', 1, 2)
      ClaudeExportProcessor.new([])
      ClaudeCodeProcessor.new([])

      %w[database redmine claude_export claude_code].each do |name|
        expect(File.exist?("logs/#{name}.log")).to be(true)
      end
    end

    it 'creates the directory of the Syncer log_file' do
      Syncer.new(
        database_path: File.join(Dir.pwd, 'db/test.db'),
        log_file: 'custom/sync.log',
        redmine_url: 'https://redmine.example.com'
      )

      expect(File.exist?('custom/sync.log')).to be(true)
    end
  end
end
