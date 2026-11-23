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

    {
      'database' => -> { Database.new(File.join(Dir.pwd, 'db/test.db')) },
      'redmine' => -> { RedmineClient.new('https://redmine.example.com', 'h', 'c', 'p', 1, 2) },
      'claude_export' => -> { ClaudeExportProcessor.new([]) },
      'claude_code' => -> { ClaudeCodeProcessor.new([]) }
    }.each do |name, build|
      it "creates it for the #{name} logger" do
        build.call

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
