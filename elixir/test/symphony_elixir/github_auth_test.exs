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

  test "resolve_cli_token without opts uses the default command runner" do
    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)
    System.put_env("PATH", "")

    assert {:error, {:github_cli_not_installed, "github.com"}} =
             GitHubAuth.resolve_cli_token("github.com")
  end

  test "auth_error? and error_message cover typed auth variants" do
    assert GitHubAuth.auth_error?(:missing_github_api_token)
    assert GitHubAuth.auth_error?({:github_cli_not_installed, "github.com"})
    assert GitHubAuth.auth_error?({:github_cli_not_logged_in, "github.com"})

    assert GitHubAuth.auth_error?({:github_insufficient_scopes, "github.com", ["project"], ["repo"]})

    assert GitHubAuth.auth_error?({:github_cli_command_failed, "github.com", "gh auth status", "boom"})

    refute GitHubAuth.auth_error?(:boom)

    assert GitHubAuth.error_message({:github_cli_not_installed, "github.com"}, "github.com") =~
             "Install `gh`"

    assert GitHubAuth.error_message(
             {:github_insufficient_scopes, "github.com", ["project"], []},
             "github.com"
           ) =~ "current: (unknown)"

    assert GitHubAuth.error_message(
             {:github_cli_command_failed, "github.com", "gh auth status", "boom"},
             "github.com"
           ) =~ "Retry `gh auth login --hostname github.com --scopes repo,project,read:org`"

    assert GitHubAuth.error_message(:boom, "github.com") == nil
  end

  test "default_command_runner handles missing commands and non-zero exits" do
    assert {:error, :command_not_found} =
             GitHubAuth.default_command_runner("definitely-missing-gh-helper", [], [])

    assert {:ok, "ok"} = GitHubAuth.default_command_runner("sh", ["-lc", "printf ok"], [])

    assert {:error, {:exit_status, 7, output}} =
             GitHubAuth.default_command_runner("sh", ["-lc", "printf fail >&2; exit 7"], [])

    assert output =~ "fail"
  end

  test "resolve_cli_token reports gh login guidance when no active account exists" do
    runner = fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
      {:ok, "You are not logged into any GitHub hosts. To log in, run: gh auth login\n{\"hosts\":{}}"}
    end

    assert {:error, {:github_cli_not_logged_in, "github.com"}} =
             GitHubAuth.resolve_cli_token("github.com", runner: runner)
  end

  test "resolve_cli_token accepts the first successful account when scopes metadata is absent" do
    runner = fn "gh", args, _opts ->
      case args do
        ["auth", "status", "--hostname", "github.com", "--json", "hosts"] ->
          {:ok, ~s({"hosts":{"github.com":[{"state":"success","active":false,"host":"github.com","login":"octo"}]}})}

        ["auth", "token", "--hostname", "github.com"] ->
          {:ok, "gh-token-234\n"}
      end
    end

    assert {:ok, %GitHubAuth{host: "github.com", source: :gh_cli, token: "gh-token-234"}} =
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

  test "resolve_cli_token surfaces malformed gh status payloads" do
    assert {:error, {:github_cli_command_failed, "github.com", "gh auth status --hostname github.com --json hosts", "`gh auth status` did not return JSON output."}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 {:ok, "plain text without json"}
               end
             )

    assert {:error, {:github_cli_command_failed, "github.com", _, detail}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 {:ok, "{not-json}"}
               end
             )

    assert detail =~ "unexpected byte"

    assert {:error, {:github_cli_command_failed, "github.com", "gh auth status --hostname github.com --json hosts", "`gh auth status` returned an unexpected payload."}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 {:ok, ~s({"not_hosts":{}})}
               end
             )

    assert {:error, {:github_cli_not_logged_in, "github.com"}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 {:ok, ~s({"hosts":{"github.com":"bad"}})}
               end
             )

    assert {:error, {:github_cli_not_logged_in, "github.com"}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 {:ok, ~s({"hosts":{"github.com":[{"state":"expired"}]}})}
               end
             )
  end

  test "resolve_cli_token maps gh command failures and empty token output" do
    success_status_output =
      {:ok, ~s({"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo","scopes":"repo, project, read:org"}]}})}

    assert {:error, {:github_cli_command_failed, "github.com", "gh auth status --hostname github.com --json hosts", "command exited without output."}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 {:error, {:exit_status, 1, ""}}
               end
             )

    assert {:error, {:github_cli_not_logged_in, "github.com"}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 {:error, {:exit_status, 1, "run: gh auth login"}}
               end
             )

    assert {:error, {:github_cli_not_logged_in, "github.com"}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 {:error, {:exit_status, 1, "no oauth token found for github.com"}}
               end
             )

    assert {:error, {:github_cli_command_failed, "github.com", "gh auth status --hostname github.com --json hosts", "boom line one line two"}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 {:error, {:exit_status, 1, "boom  line one\nline two  "}}
               end
             )

    assert {:error, {:github_cli_command_failed, "github.com", "gh auth status --hostname github.com --json hosts", "runner returned unexpected result: :boom"}} =
             GitHubAuth.resolve_cli_token("github.com",
               runner: fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
                 :boom
               end
             )

    runner = fn "gh", args, _opts ->
      case args do
        ["auth", "status", "--hostname", "github.com", "--json", "hosts"] ->
          success_status_output

        ["auth", "token", "--hostname", "github.com"] ->
          {:ok, " \n "}
      end
    end

    assert {:error, {:github_cli_command_failed, "github.com", "gh auth token --hostname github.com", "`gh auth token` returned an empty token."}} =
             GitHubAuth.resolve_cli_token("github.com", runner: runner)
  end
end
