require 'logger'
require 'fileutils'

# Builds file loggers and creates the log directory when it does not exist yet
module LogFile
  class << self
    # Creates a logger for the given file, creating its parent directory first
    #
    # @param path [String] path to the log file
    # @return [Logger] logger that writes to the file
    def logger(path)
      FileUtils.mkdir_p(File.dirname(path))
      Logger.new(path)
    end
  end
end
