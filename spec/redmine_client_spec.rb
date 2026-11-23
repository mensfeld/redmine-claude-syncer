# frozen_string_literal: true

require 'spec_helper'
require 'redmine_client'

RSpec.describe RedmineClient do
  describe '#initialize' do
    it 'creates a new client instance with required parameters' do
      client = described_class.new(
        'https://redmine.example.com',
        'human-api-key',
        'claude-api-key',
        'project-1',
        1,
        2
      )
      expect(client).to be_a(RedmineClient)
    end

    it 'creates a new client instance with all parameters' do
      client = described_class.new(
        'https://redmine.example.com',
        'human-api-key',
        'claude-api-key',
        'project-1',
        1,
        2,
        3,
        4,
        5
      )
      expect(client).to be_a(RedmineClient)
    end
  end

  describe '#create_issue' do
    let(:response) { instance_double(Net::HTTPResponse, body: '{"issue":{"id":7}}') }

    def sent_issue(client)
      sent = nil
      allow(client).to receive(:make_request) do |_method, _path, data, _key|
        sent = data[:issue]
        response
      end
      client.create_issue('Subject', 'Description')
      sent
    end

    it 'uses tracker 1, status 1 and priority 2 when the IDs are nil' do
      client = described_class.new('https://redmine.example.com', 'h', 'c', 'p', 1, 2, nil, nil, nil)

      expect(sent_issue(client)).to include(tracker_id: 1, status_id: 1, priority_id: 2)
    end

    it 'sends the given IDs as integers' do
      client = described_class.new('https://redmine.example.com', 'h', 'c', 'p', 1, 2, '3', '4', '5')

      expect(sent_issue(client)).to include(tracker_id: 3, status_id: 4, priority_id: 5)
    end
  end

  describe '#format_message_with_code' do
    let(:client) do
      described_class.new(
        'https://redmine.example.com',
        'human-api-key',
        'claude-api-key',
        'project-1',
        1,
        2
      )
    end

    it 'formats a simple message' do
      msg = {
        content: 'Hello world',
        created_at: Time.new(2024, 1, 1, 12, 0, 0)
      }

      result = client.format_message_with_code(msg)
      expect(result).to include('Hello world')
      expect(result).to include('2024-01-01')
    end

    it 'formats a message with code items' do
      msg = {
        content: 'Here is some code',
        created_at: Time.new(2024, 1, 1, 12, 0, 0),
        code_items: [
          {
            type: 'markdown_block',
            language: 'ruby',
            content: 'puts "hello"',
            title: 'Code Block #1'
          }
        ]
      }

      result = client.format_message_with_code(msg)
      expect(result).to include('Code Snippets Found')
      expect(result).to include('```ruby')
      expect(result).to include('puts "hello"')
    end
  end
end
