# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'yaml'

RSpec.describe 'bin scripts' do
  let(:bin_dir) { File.expand_path('../bin', __dir__) }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def run_script(name, *args, env: {})
    base_env = {
      'REDMINE_URL' => 'https://redmine.example.com',
      'REDMINE_TRACKER_ID' => 'abc',
      'DATABASE_PATH' => File.join(@dir, 'db.sqlite'),
      'LOG_FILE' => File.join(@dir, 'sync.log')
    }
    Open3.capture2e(base_env.merge(env), RbConfig.ruby, File.join(bin_dir, name), *args, chdir: @dir)
  end

  shared_examples 'an invalid ID' do
    it 'prints a one-line error and exits 1' do
      output, status = result

      expect(status.exitstatus).to eq(1)
      expect(output).to include('Error: REDMINE_TRACKER_ID must be an integer, got "abc"')
      expect(output).not_to match(/\.rb:\d+:in /)
    end
  end

  describe 'sync.rb' do
    let(:result) do
      File.write(File.join(@dir, 'export.zip'), '')
      run_script('sync.rb', 'export.zip')
    end

    it_behaves_like 'an invalid ID'
  end

  describe 'sync_code.rb' do
    let(:result) do
      config = File.join(@dir, 'sync_code.yml')
      File.write(config, { 'directories' => { @dir => [] } }.to_yaml)
      run_script('sync_code.rb', env: { 'SYNC_CODE_CONFIG' => config })
    end

    it_behaves_like 'an invalid ID'
  end
end
