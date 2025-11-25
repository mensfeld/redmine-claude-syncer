require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'fileutils'

# HTTP client for interacting with the Redmine REST API
class RedmineClient
  # Creates a new Redmine API client
  #
  # @param url [String] base URL of the Redmine instance
  # @param human_api_key [String] API key for the human user
  # @param claude_api_key [String] API key for the Claude user
  # @param project_id [String] target project identifier
  # @param human_user_id [Integer] Redmine user ID for human
  # @param claude_user_id [Integer] Redmine user ID for Claude
  # @param tracker_id [Integer] issue tracker ID
  # @param status_id [Integer] issue status ID
  # @param priority_id [Integer] issue priority ID
  def initialize(url, human_api_key, claude_api_key, project_id, human_user_id, claude_user_id, tracker_id = 1, status_id = 1, priority_id = 2)
    @base_url = url.chomp('/')
    @human_api_key = human_api_key
    @claude_api_key = claude_api_key
    @project_id = project_id
    @human_user_id = human_user_id
    @claude_user_id = claude_user_id
    @tracker_id = tracker_id
    @status_id = status_id
    @priority_id = priority_id
    @logger = Logger.new('logs/redmine.log')
  end

  # Creates a new issue in Redmine
  #
  # @param subject [String] issue subject/title
  # @param description [String] issue description
  # @return [Hash] created issue data from Redmine API
  def create_issue(subject, description)
    begin
      issue_data = {
        project_id: @project_id,
        subject: subject,
        description: description,
        tracker_id: @tracker_id,
        status_id: @status_id,
        priority_id: @priority_id
      }

      # Only add assigned_to_id if it's a valid user
      if @human_user_id && @human_user_id.to_i > 0
        issue_data[:assigned_to_id] = @human_user_id
      end

      response = make_request(
        'POST',
        '/issues.json',
        {
          issue: issue_data
        },
        @claude_api_key  # Use Claude's API key for issue creation
      )

      if response.body.nil? || response.body.empty?
        @logger.error "Empty response body when creating issue"
        raise "Empty response from Redmine API"
      end

      begin
        issue = JSON.parse(response.body)['issue']
        if issue.nil?
          @logger.error "No issue data in response when creating issue"
          raise "Invalid response format from Redmine API"
        end
        @logger.info "Successfully created issue ##{issue['id']}"
        issue
      rescue JSON::ParserError => e
        @logger.error "Failed to parse response when creating issue: #{e.message}"
        @logger.error "Response body: #{response.body}"
        raise
      end
    rescue StandardError => e
      @logger.error "Failed to create issue: #{e.message}"
      raise
    end
  end

  # Updates an existing issue's description
  #
  # @param issue_id [Integer] Redmine issue ID
  # @param description [String] new description content
  # @return [Hash] updated issue data from Redmine API
  def update_issue(issue_id, description)
    begin
      response = make_request(
        'PUT',
        "/issues/#{issue_id}.json",
        {
          issue: {
            description: description
          }
        },
        @human_api_key  # Use human API key for issue updates
      )

      issue = JSON.parse(response.body)['issue']
      @logger.info "Successfully updated issue ##{issue_id}"
      issue
    rescue StandardError => e
      @logger.error "Failed to update issue ##{issue_id}: #{e.message}"
      raise
    end
  end

  # Adds a note to an existing issue using the appropriate user's API key
  #
  # @param issue_id [Integer] Redmine issue ID
  # @param content [String] note content
  # @param user_id [Integer] user ID to attribute the note to
  # @return [Hash, Boolean] issue data or true on success
  def add_note(issue_id, content, user_id)
    begin
      # Use the appropriate API key based on the user
      api_key = user_id == @human_user_id ? @human_api_key : @claude_api_key
      
      # Sanitize content to remove problematic characters
      sanitized_content = content.encode('UTF-8', 'UTF-8', invalid: :replace, undef: :replace, replace: '')
      
      response = make_request(
        'PUT',
        "/issues/#{issue_id}.json",
        {
          issue: {
            notes: sanitized_content
          }
        },
        api_key
      )

      # If we get an empty response but the request was successful (200-299),
      # we'll assume the note was added successfully
      if response.code.to_i.between?(200, 299)
        @logger.info "Successfully added note to issue ##{issue_id} as user ##{user_id}"
        return true
      end

      # Only try to parse the response if we have a body
      if response.body && !response.body.empty?
        begin
          issue = JSON.parse(response.body)['issue']
          if issue
            @logger.info "Successfully added note to issue ##{issue_id} as user ##{user_id}"
            return issue
          end
        rescue JSON::ParserError => e
          @logger.warn "Failed to parse response when adding note to issue ##{issue_id}: #{e.message}"
          # Continue anyway since the note was likely added
          return true
        end
      end

      # If we get here, something went wrong
      @logger.error "Failed to add note to issue ##{issue_id}"
      raise "Failed to add note to issue ##{issue_id}"
    rescue StandardError => e
      @logger.error "Failed to add note to issue ##{issue_id}: #{e.message}"
      raise
    end
  end

  # Attaches a file to an existing issue
  #
  # @param issue_id [Integer] Redmine issue ID
  # @param file_path [String] path to the file to attach
  # @param description [String, nil] optional description for the attachment
  # @return [Hash] attachment data from Redmine API
  def attach_file(issue_id, file_path, description = nil)
    begin
      # First, upload the file to get a token
      upload_response = upload_file(file_path, @human_api_key)  # Use human API key for file uploads
      token = JSON.parse(upload_response.body)['upload']['token']

      # Then, attach the file to the issue
      response = make_request(
        'POST',
        "/issues/#{issue_id}/attachments.json",
        {
          attachment: {
            token: token,
            description: description
          }
        },
        @human_api_key  # Use human API key for attachments
      )

      attachment = JSON.parse(response.body)['attachment']
      @logger.info "Successfully attached file to issue ##{issue_id}"
      attachment
    rescue StandardError => e
      @logger.error "Failed to attach file to issue ##{issue_id}: #{e.message}"
      raise
    end
  end

  # Formats an array of messages into a readable conversation string
  #
  # @param messages [Array<Hash>] array of message objects with role, content, created_at
  # @return [String] formatted conversation text
  def format_conversation(messages)
    formatted = messages.map do |msg|
      role = msg.role.capitalize
      timestamp = msg.created_at.strftime("%Y-%m-%d %H:%M:%S")
      "**#{role}** (#{timestamp}):\n#{msg.content}\n\n"
    end.join

    formatted
  end

  # Processes messages and adds them as notes to the issue
  #
  # @param issue_id [Integer] Redmine issue ID
  # @param messages [Array<Hash>] array of message hashes
  def process_messages(issue_id, messages)
    messages.each do |msg|
      user_id = msg[:role] == 'human' ? @human_user_id : @claude_user_id
      content = format_message_with_code(msg)
      add_note(issue_id, content, user_id)
    end
  end

  # Formats a message including any code snippets
  #
  # @param msg [Hash] message hash with :content, :code_items, :created_at keys
  # @return [String] formatted message content
  def format_message_with_code(msg)
    content = msg[:content] || ""
    
    # Add code snippets inline if they exist
    if msg[:code_items] && !msg[:code_items].empty?
      content += "\n\n" + format_code_snippets(msg[:code_items])
    end
    
    content += "\n\n*Posted at: #{msg[:created_at].strftime("%Y-%m-%d %H:%M:%S")}*"
    content
  end

  # Formats code snippets for display in Redmine
  #
  # @param code_items [Array<Hash>] array of code item hashes
  # @return [String] formatted code snippets as markdown
  def format_code_snippets(code_items)
    formatted = "**📄 Code Snippets Found:**\n\n"
    
    code_items.each_with_index do |item, index|
      emoji = item[:type] == 'artifact' ? '🔧' : '🔹'
      formatted += "#{emoji} **#{item[:title]}** (#{item[:language]} - #{item[:type]})\n"
      formatted += "Lines: #{item[:content].lines.count} | Characters: #{item[:content].length}\n\n"
      
      # Format code with proper markdown code blocks
      formatted += "```#{item[:language]}\n"
      formatted += item[:content]
      formatted += "\n```\n\n"
      
      # Add separator between multiple code items
      formatted += "---\n\n" if index < code_items.length - 1
    end
    
    formatted
  end

  private

  # Makes an HTTP request to the Redmine API with retry logic
  #
  # @param method [String] HTTP method (GET, POST, PUT, DELETE)
  # @param path [String] API endpoint path
  # @param data [Hash, nil] request body data
  # @param api_key [String] API key for authentication
  # @return [Net::HTTPResponse] successful response
  def make_request(method, path, data = nil, api_key)
    max_retries = 5  # Increased from 3 to 5
    base_delay = 2   # Increased from 1 to 2 seconds
    max_delay = 30   # Maximum delay of 30 seconds
    
    retries = 0
    begin
      uri = URI.parse("#{@base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 30  # Add read timeout
      http.open_timeout = 30  # Add open timeout

      request = case method
      when 'GET'
        Net::HTTP::Get.new(uri)
      when 'POST'
        Net::HTTP::Post.new(uri)
      when 'PUT'
        Net::HTTP::Put.new(uri)
      when 'DELETE'
        Net::HTTP::Delete.new(uri)
      end

      request['X-Redmine-API-Key'] = api_key
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request.body = data.to_json if data

      @logger.info "Making #{method} request to #{uri}"
      @logger.debug "Request headers: #{request.to_hash}"
      @logger.debug "Request body: #{data.to_json}" if data

      response = http.request(request)
      @logger.debug "Response code: #{response.code}"
      @logger.debug "Response headers: #{response.to_hash}"
      @logger.debug "Response body: #{response.body}"

      case response
      when Net::HTTPSuccess
        response
      else
        error_message = "Redmine API error: #{response.code}"
        error_message += " - #{response.body}" if response.body
        @logger.error error_message
        raise error_message
      end
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT => e
      retries += 1
      if retries <= max_retries
        # Calculate delay with exponential backoff, but cap it at max_delay
        delay = [base_delay * (2 ** (retries - 1)), max_delay].min
        @logger.warn "Connection error: #{e.message}. Retrying in #{delay} seconds... (Attempt #{retries}/#{max_retries})"
        sleep delay
        retry
      else
        @logger.error "Failed after #{max_retries} retries: #{e.message}"
        raise
      end
    end
  end

  # Uploads a file to Redmine and returns the upload token
  #
  # @param file_path [String] path to the file to upload
  # @param api_key [String] API key for authentication
  # @return [Net::HTTPResponse] response containing upload token
  def upload_file(file_path, api_key)
    uri = URI.parse("#{@base_url}/uploads.json")
    boundary = "----WebKitFormBoundary#{rand(1000000)}"

    request = Net::HTTP::Post.new(uri)
    request['X-Redmine-API-Key'] = api_key
    request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"

    body = []
    body << "--#{boundary}\r\n"
    body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{File.basename(file_path)}\"\r\n"
    body << "Content-Type: application/octet-stream\r\n\r\n"
    body << File.read(file_path)
    body << "\r\n--#{boundary}--\r\n"

    request.body = body.join

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    response = http.request(request)

    case response
    when Net::HTTPSuccess
      response
    else
      raise "Failed to upload file: #{response.code} - #{response.body}"
    end
  end
end 