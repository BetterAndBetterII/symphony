defmodule SymphonyElixir.Tracker.StateCount do
  @moduledoc """
  Ordered workflow-state summary entry returned by tracker adapters.
  """

  @enforce_keys [:name, :count]
  defstruct [:name, :count]

  @type t :: %__MODULE__{
          name: String.t(),
          count: non_neg_integer()
        }
end
