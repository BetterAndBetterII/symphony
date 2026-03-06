defmodule SymphonyElixir.Config.GitHubAuth do
  @moduledoc false

  @required_scopes ["project", "repo"]

  @enforce_keys [:host, :source, :token]
  defstruct [:host, :source, :token]

  @type source :: :explicit_config | :gh_cli
  @type t :: %__MODULE__{host: String.t(), source: source(), token: String.t()}

  @type error_reason ::
          {:github_cli_not_installed, String.t()}
          | {:github_cli_not_logged_in, String.t()}
          | {:github_insufficient_scopes, String.t(), [String.t()], [String.t()]}
          | {:github_cli_command_failed, String.t(), String.t(), String.t()}

  @type command_result ::
          {:ok, String.t()} | {:error, :command_not_found} | {:error, {:exit_status, non_neg_integer(), String.t()}}

  @type command_runner :: (String.t(), [String.t()], keyword() -> command_result())

  @spec resolve_cli_token(String.t(), keyword()) :: {:ok, t()} | {:error, error_reason()}
  def resolve_cli_token(host, opts \\ []) when is_binary(host) do
    runner = Keyword.get(opts, :runner, &default_command_runner/3)

    with {:ok, account} <- fetch_active_account(host, runner),
         :ok <- ensure_required_scopes(host, account),
         {:ok, token_output} <- run_gh(host, gh_token_args(host), runner),
         {:ok, token} <- parse_token(host, token_output) do
      {:ok, %__MODULE__{host: host, source: :gh_cli, token: token}}
    end
  end

  @spec auth_error?(term()) :: boolean()
  def auth_error?(:missing_github_api_token), do: true
  def auth_error?({:github_cli_not_installed, host}) when is_binary(host), do: true
  def auth_error?({:github_cli_not_logged_in, host}) when is_binary(host), do: true

  def auth_error?({:github_insufficient_scopes, host, missing, available})
      when is_binary(host) and is_list(missing) and is_list(available),
      do: true

  def auth_error?({:github_cli_command_failed, host, command, detail})
      when is_binary(host) and is_binary(command) and is_binary(detail),
      do: true

  def auth_error?(_reason), do: false

  @spec error_message(term(), String.t()) :: String.t() | nil
  def error_message(:missing_github_api_token, host) when is_binary(host) do
    "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` (for example `$GITHUB_TOKEN`), or run `#{gh_login_command(host)}`."
  end

  def error_message({:github_cli_not_installed, host}, _default_host) when is_binary(host) do
    "Symphony could not find GitHub CLI. Install `gh`, then run `#{gh_login_command(host)}`; for headless runs, set `tracker.api_key` in `WORKFLOW.md`."
  end

  def error_message({:github_cli_not_logged_in, host}, _default_host) when is_binary(host) do
    "Symphony could not read GitHub auth from `gh`. Run `#{gh_login_command(host)}`; for headless runs, set `tracker.api_key` in `WORKFLOW.md`."
  end

  def error_message({:github_insufficient_scopes, host, missing, available}, _default_host)
      when is_binary(host) and is_list(missing) and is_list(available) do
    missing_text = missing |> Enum.sort() |> Enum.join(", ")

    available_text =
      case Enum.sort(available) do
        [] -> "(unknown)"
        scopes -> Enum.join(scopes, ", ")
      end

    "Symphony's `gh` session for #{host} is missing required GitHub scopes (missing: #{missing_text}; current: #{available_text}). Run `#{gh_refresh_command(host)}`."
  end

  def error_message({:github_cli_command_failed, host, command, detail}, _default_host)
      when is_binary(host) and is_binary(command) and is_binary(detail) do
    "Symphony failed to read GitHub auth from `gh` for #{host} via `#{command}`: #{detail}. Retry `#{gh_login_command(host)}` or set `tracker.api_key` in `WORKFLOW.md`."
  end

  def error_message(_reason, _default_host), do: nil

  @spec default_command_runner(String.t(), [String.t()], keyword()) :: command_result()
  def default_command_runner(command, args, opts)
      when is_binary(command) and is_list(args) and is_list(opts) do
    case System.find_executable(command) do
      nil ->
        {:error, :command_not_found}

      path ->
        command_opts = [stderr_to_stdout: true] ++ opts

        case System.cmd(path, args, command_opts) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {:exit_status, status, output}}
        end
    end
  end

  defp fetch_active_account(host, runner) do
    case run_gh(host, gh_status_args(host), runner) do
      {:ok, output} ->
        with {:ok, payload} <- parse_status_payload(host, output) do
          active_account(payload, host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_required_scopes(host, account) do
    available_scopes = parse_scopes(Map.get(account, "scopes"))

    case available_scopes do
      [] ->
        :ok

      scopes ->
        available_set = MapSet.new(scopes)

        missing_scopes =
          @required_scopes
          |> Enum.reject(&MapSet.member?(available_set, &1))
          |> Enum.sort()

        if missing_scopes == [] do
          :ok
        else
          {:error, {:github_insufficient_scopes, host, missing_scopes, Enum.sort(scopes)}}
        end
    end
  end

  defp parse_token(host, output) when is_binary(output) do
    case String.trim(output) do
      "" ->
        {:error, {:github_cli_command_failed, host, gh_token_command(host), "`gh auth token` returned an empty token."}}

      token ->
        {:ok, token}
    end
  end

  defp parse_status_payload(host, output) when is_binary(output) do
    with {:ok, json} <- extract_json_payload(output),
         {:ok, %{"hosts" => hosts}} <- Jason.decode(json) do
      {:ok, hosts}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:github_cli_command_failed, host, gh_status_command(host), Exception.message(reason)}}

      :error ->
        {:error, {:github_cli_command_failed, host, gh_status_command(host), "`gh auth status` did not return JSON output."}}

      _ ->
        {:error, {:github_cli_command_failed, host, gh_status_command(host), "`gh auth status` returned an unexpected payload."}}
    end
  end

  defp active_account(hosts, host) when is_map(hosts) and is_binary(host) do
    case Map.get(hosts, host, []) do
      entries when is_list(entries) ->
        entries
        |> Enum.find(&(Map.get(&1, "active") == true))
        |> case do
          nil -> List.first(entries)
          account -> account
        end
        |> normalize_active_account(host)

      _ ->
        {:error, {:github_cli_not_logged_in, host}}
    end
  end

  defp normalize_active_account(nil, host), do: {:error, {:github_cli_not_logged_in, host}}

  defp normalize_active_account(%{"state" => "success"} = account, _host), do: {:ok, account}

  defp normalize_active_account(%{} = _account, host), do: {:error, {:github_cli_not_logged_in, host}}

  defp extract_json_payload(output) when is_binary(output) do
    case Regex.run(~r/(\{.*\})/s, output, capture: :all_but_first) do
      [json] -> {:ok, json}
      _ -> :error
    end
  end

  defp parse_scopes(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_scopes(_value), do: []

  defp run_gh(host, args, runner) do
    case runner.("gh", args, env: scrubbed_env()) do
      {:ok, output} ->
        {:ok, output}

      {:error, :command_not_found} ->
        {:error, {:github_cli_not_installed, host}}

      {:error, {:exit_status, _status, output}} ->
        map_gh_failure(host, args, output)

      unexpected ->
        {:error, {:github_cli_command_failed, host, gh_command(args), "runner returned unexpected result: #{inspect(unexpected)}"}}
    end
  end

  defp map_gh_failure(host, args, output) when is_binary(host) and is_list(args) and is_binary(output) do
    normalized = String.downcase(String.trim(output))

    cond do
      normalized == "" ->
        {:error, {:github_cli_command_failed, host, gh_command(args), "command exited without output."}}

      String.contains?(normalized, "no oauth token found") or
        String.contains?(normalized, "not logged into any github hosts") or
          String.contains?(normalized, "run: gh auth login") ->
        {:error, {:github_cli_not_logged_in, host}}

      true ->
        {:error, {:github_cli_command_failed, host, gh_command(args), output |> String.trim() |> String.replace(~r/\s+/, " ")}}
    end
  end

  defp scrubbed_env do
    [{"GITHUB_TOKEN", nil}, {"GH_TOKEN", nil}]
  end

  defp gh_status_args(host), do: ["auth", "status", "--hostname", host, "--json", "hosts"]
  defp gh_token_args(host), do: ["auth", "token", "--hostname", host]
  defp gh_status_command(host), do: gh_command(gh_status_args(host))
  defp gh_token_command(host), do: gh_command(gh_token_args(host))
  defp gh_command(args), do: Enum.join(["gh" | args], " ")

  defp gh_login_command(host) do
    "gh auth login --hostname #{host} --scopes repo,project,read:org"
  end

  defp gh_refresh_command(host) do
    "gh auth refresh --hostname #{host} --scopes repo,project,read:org"
  end
end
