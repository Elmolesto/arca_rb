require "fileutils"
require "json"
require "time"

module Arca
  # Where WSAA access tickets live between processes. ARCA grants one ticket
  # per certificate and service, valid for up to 12 hours, and refuses a new
  # one while it lasts, so every process using a certificate must see the
  # same store and it must survive deploys and restarts.
  #
  # A store only needs `read(key)` returning the stored String (or nil) and
  # `write(key, value, expires_in:)`.
  module TicketStore
    # One file per ticket. Fine for a single server with a persistent
    # directory (a Kamal volume); not for Heroku, whose dynos have ephemeral,
    # unshared disks.
    class File
      def initialize(directory) = @directory = directory.to_s

      def read(key)
        path = path(key)
        ::File.read(path) if ::File.exist?(path)
      end

      def write(key, value, expires_in:)
        FileUtils.mkdir_p(@directory)
        temporary = "#{path(key)}.#{Process.pid}.tmp"
        ::File.write(temporary, value)
        ::File.rename(temporary, path(key))
      end

      private

      def path(key) = ::File.join(@directory, "#{key.tr("/", "-")}.json")
    end

    # Any cache object answering read(key) and write(key, value, expires_in:),
    # such as the app's cache store backed by Solid Cache or Redis. This is what
    # Heroku apps should use.
    class Cache
      def initialize(cache) = @cache = cache
      def read(key) = @cache.read(key)
      def write(key, value, expires_in:) = @cache.write(key, value, expires_in:)
    end

    # Per-process only; for tests and scripts.
    class Memory
      def initialize = @values = {}
      def read(key) = @values[key]
      def write(key, value, expires_in:) = @values[key] = value
    end
  end
end
