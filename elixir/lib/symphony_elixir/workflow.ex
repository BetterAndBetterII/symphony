defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"

  @default_workflow_template """
  ---
  # Minimal Symphony WORKFLOW.md template.
  #
  # Expected env vars:
  # - LINEAR_API_KEY
  # - LINEAR_PROJECT_SLUG
  # - SOURCE_REPO_URL (optional, used by hooks.after_create below)
  # - SYMPHONY_WORKSPACE_ROOT (optional)
  tracker:
    kind: linear
    api_key: $LINEAR_API_KEY
    project_slug: $LINEAR_PROJECT_SLUG
  polling:
    interval_ms: 5000
  workspace:
    root: $SYMPHONY_WORKSPACE_ROOT
  hooks:
    after_create: |
      # TODO: set SOURCE_REPO_URL to the repository Symphony should work on.
      # Example:
      #   export SOURCE_REPO_URL=git@github.com:your-org/your-repo.git
      git clone --depth 1 "$SOURCE_REPO_URL" .
  agent:
    max_concurrent_agents: 10
    max_turns: 20
  codex:
    command: codex app-server
    approval_policy: never
    thread_sandbox: workspace-write
    turn_sandbox_policy:
      type: workspaceWrite
  ---

  You are working on a Linear ticket `{{ issue.identifier }}`

  Issue context:
  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Description:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @spec default_workflow_file_path() :: Path.t()
  def default_workflow_file_path do
    Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      env_workflow_file_path() ||
      default_workflow_file_path()
  end

  defp env_workflow_file_path do
    case System.get_env("SYMPHONY_WORKFLOW_FILE_PATH") do
      path when is_binary(path) ->
        case String.trim(path) do
          "" -> nil
          trimmed -> Path.expand(trimmed)
        end

      _ ->
        nil
    end
  end

  @spec init_default_workflow_file(Path.t()) :: :ok | {:error, term()}
  def init_default_workflow_file(path) when is_binary(path) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, @default_workflow_template, [:exclusive]) do
      :ok
    else
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp parse(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end
