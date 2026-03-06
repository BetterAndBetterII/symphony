defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.{DefaultWorkflow, LogFile}

  @switches [logs_root: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          write_default_workflow: (String.t() -> :ok | {:error, term()}),
          notify: (String.t() -> term()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps, bootstrap?: true)
        end

      {opts, [workflow_path], []} ->
        with :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps, bootstrap?: false)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps(), keyword()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps, opts \\ []) do
    expanded_path = Path.expand(workflow_path)
    bootstrap? = Keyword.get(opts, :bootstrap?, false)

    with :ok <- ensure_workflow_file(expanded_path, bootstrap?, deps),
         :ok <- deps.set_workflow_file_path.(expanded_path) do
      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      write_default_workflow: &DefaultWorkflow.write/1,
      notify: &IO.puts/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp ensure_workflow_file(path, true, deps) do
    if deps.file_regular?.(path) do
      :ok
    else
      case deps.write_default_workflow.(path) do
        :ok ->
          deps.notify.(bootstrap_message(path))
          :ok

        {:error, reason} ->
          {:error, "Failed to initialize workflow file #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp ensure_workflow_file(path, false, deps) do
    if deps.file_regular?.(path) do
      :ok
    else
      {:error, "Workflow file not found: #{path}"}
    end
  end

  defp bootstrap_message(path) do
    "Created default WORKFLOW.md at #{path}. Update GITHUB_TOKEN, GITHUB_PROJECT_OWNER, GITHUB_PROJECT_NUMBER, SOURCE_REPO_URL, and SYMPHONY_WORKSPACE_ROOT for your repo."
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
