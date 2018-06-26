require "test_helper"

class Autoproj::SyncTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Autoproj::Sync::VERSION
  end

  def test_it_does_something_useful
    assert false
  end
end
