defmodule SymphonyElixir.GitHubAuthTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.GitHubAuth

  test "resolve_cli_token strips inherited GitHub token env vars before invoking gh" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_gh_token = System.get_env("GH_TOKEN")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_env("GH_TOKEN", previous_gh_token)
    end)

    System.put_env("GITHUB_TOKEN", "ambient-github-token")
    System.put_env("GH_TOKEN", "ambient-gh-token")

    runner = fn "gh", args, opts ->
      send(self(), {:gh_call, args, Keyword.fetch!(opts, :env)})

      case args do
        ["auth", "status", "--hostname", "github.com", "--json", "hosts"] ->
          {:ok, ~s({"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo","scopes":"repo, project, read:org"}]}})}

        ["auth", "token", "--hostname", "github.com"] ->
          {:ok, "gh-token-123\n"}
      end
    end

    assert {:ok, %GitHubAuth{host: "github.com", source: :gh_cli, token: "gh-token-123"}} =
             GitHubAuth.resolve_cli_token("github.com", runner: runner)

    assert_received {:gh_call, ["auth", "status", "--hostname", "github.com", "--json", "hosts"], env}
    assert {"GITHUB_TOKEN", nil} in env
    assert {"GH_TOKEN", nil} in env

    assert_received {:gh_call, ["auth", "token", "--hostname", "github.com"], env}
    assert {"GITHUB_TOKEN", nil} in env
    assert {"GH_TOKEN", nil} in env
  end

  test "resolve_cli_token reports gh login guidance when no active account exists" do
    runner = fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
      {:ok, "You are not logged into any GitHub hosts. To log in, run: gh auth login\n{\"hosts\":{}}"}
    end

    assert {:error, {:github_cli_not_logged_in, "github.com"}} =
             GitHubAuth.resolve_cli_token("github.com", runner: runner)
  end

  test "resolve_cli_token fails fast when the gh session is missing project scope" do
    runner = fn "gh", args, _opts ->
      case args do
        ["auth", "status", "--hostname", "github.com", "--json", "hosts"] ->
          {:ok, ~s({"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo","scopes":"repo, read:org"}]}})}

        ["auth", "token", "--hostname", "github.com"] ->
          flunk("gh auth token should not run when scope validation already failed")
      end
    end

    assert {:error, {:github_insufficient_scopes, "github.com", ["project"], ["read:org", "repo"]}} =
             GitHubAuth.resolve_cli_token("github.com", runner: runner)
  end
end
