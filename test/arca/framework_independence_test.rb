require "test_helper"

class Arca::FrameworkIndependenceTest < Minitest::Test
  def test_loads_without_active_support
    refute defined?(ActiveSupport), "arca_rb or one of its dependencies loaded ActiveSupport"
  end

  def test_does_not_rely_on_rails_or_active_support
    source = Dir[File.expand_path("../../lib/**/*.rb", __dir__)].map { |path| File.read(path, encoding: "UTF-8") }.join("\n")

    refute_match(/\bRails\b|ActiveSupport|ActiveRecord|\.blank\?|\.present\?|\.presence\b|\.sole\b|Time\.zone|Date\.current|\.deep_symbolize_keys/, source)
  end
end
