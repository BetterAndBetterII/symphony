defmodule SymphonyElixir.VersionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Version

  describe "normalize/1" do
    test "returns binaries unchanged" do
      assert Version.normalize("0.3.0") == "0.3.0"
    end

    test "converts charlists to strings" do
      assert Version.normalize(~c"0.3.0") == "0.3.0"
    end

    test "falls back to dev for unsupported metadata" do
      assert Version.normalize(nil) == "dev"
    end
  end

  test "current/0 returns a normalized string" do
    version = Version.current()

    assert is_binary(version)
    assert version != ""
  end
end
