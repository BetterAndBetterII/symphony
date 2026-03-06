defmodule SymphonyElixir.Version do
  @moduledoc """
  Runtime access to the Symphony application version.
  """

  @spec current() :: String.t()
  def current do
    case Application.spec(:symphony_elixir, :vsn) do
      version when is_binary(version) -> version
      version when is_list(version) -> List.to_string(version)
      _ -> "dev"
    end
  end
end
