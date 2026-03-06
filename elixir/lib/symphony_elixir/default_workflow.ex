defmodule SymphonyElixir.DefaultWorkflow do
  @moduledoc """
  Provides the default `WORKFLOW.md` template used for first-run bootstrap.
  """

  @template_path Path.expand("../../priv/default_workflow.md", __DIR__)
  @external_resource @template_path
  @template_contents File.read!(@template_path)

  @spec contents() :: String.t()
  def contents do
    @template_contents
  end

  @spec write(Path.t()) :: :ok | {:error, term()}
  def write(path) when is_binary(path) do
    expanded_path = Path.expand(path)

    with :ok <- File.mkdir_p(Path.dirname(expanded_path)) do
      File.write(expanded_path, contents())
    end
  end
end
