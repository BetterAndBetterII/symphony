defmodule SymphonyElixir.Version do
  @moduledoc """
  Runtime access to the Symphony application version.
  """

  @spec current() :: String.t()
  def current do
    :symphony_elixir
    |> Application.spec(:vsn)
    |> normalize()
  end

  @doc false
  @spec normalize(term()) :: String.t()
  def normalize(version) do
    case version do
      value when is_binary(value) -> value
      value when is_list(value) -> List.to_string(value)
      _ -> "dev"
    end
  end
end
