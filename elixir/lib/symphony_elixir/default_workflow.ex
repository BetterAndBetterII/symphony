defmodule SymphonyElixir.DefaultWorkflow do
  @moduledoc """
  Provides the default `WORKFLOW.md` template used for first-run bootstrap.
  """

  alias SymphonyElixir.DefaultWorkflow.Bootstrap

  @template_path Path.expand("../../priv/default_workflow.md", __DIR__)
  @external_resource @template_path
  @template_contents File.read!(@template_path)

  @type write_option ::
          {:interactive, boolean()}
          | {:gets, (String.t() -> String.t() | nil)}
          | {:puts, (String.t() -> term())}
          | {:env_getter, (String.t() -> String.t() | nil)}
          | {:github_cli_runner, (String.t(), [String.t()], keyword() -> term())}
          | {:github_query_fun, (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})}
          | {:github_endpoint, String.t()}

  @type write_options :: [write_option()]

  @spec contents() :: String.t()
  def contents do
    @template_contents
  end

  @spec bootstrap_contents(write_options()) :: {:ok, String.t()} | {:error, term()}
  def bootstrap_contents(opts \\ []) do
    if Keyword.get(opts, :interactive, false) do
      Bootstrap.run(opts)
    else
      {:ok, contents()}
    end
  end

  @spec write(Path.t(), write_options()) :: :ok | {:error, term()}
  def write(path, opts \\ []) when is_binary(path) and is_list(opts) do
    expanded_path = Path.expand(path)

    with {:ok, workflow_contents} <- bootstrap_contents(opts),
         :ok <- File.mkdir_p(Path.dirname(expanded_path)) do
      File.write(expanded_path, workflow_contents)
    end
  end
end
