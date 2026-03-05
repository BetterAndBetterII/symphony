defmodule SymphonyElixir.GitHubProject.Field do
  @moduledoc """
  Normalized representation of a GitHub ProjectV2 field.
  """

  @enforce_keys [:id, :name]
  defstruct [:id, :name, :data_type, options: []]

  @type option :: %{id: String.t(), name: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          data_type: String.t() | nil,
          options: [option()]
        }
end

