defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Tracker.{Issue, StateCount}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec fetch_state_counts() :: {:ok, [StateCount.t()]} | {:error, term()}
  def fetch_state_counts do
    issues = issue_entries()

    counts_by_state =
      Enum.reduce(issues, %{}, fn %Issue{state: state}, counts ->
        increment_state_count(counts, state)
      end)

    ordered_states = ordered_state_names(issues)

    {:ok,
     Enum.map(ordered_states, fn state_name ->
       normalized = normalize_state(state_name)

       %StateCount{
         name: state_name,
         count: counts_by_state |> Map.get(normalized, %{count: 0}) |> Map.get(:count, 0)
       }
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp ordered_state_names(issues) when is_list(issues) do
    configured_order =
      SymphonyElixir.Config.tracker_active_states() ++ SymphonyElixir.Config.tracker_terminal_states()

    encountered_order =
      issues
      |> Enum.map(& &1.state)
      |> Enum.filter(&is_binary/1)

    (configured_order ++ encountered_order)
    |> Enum.reduce([], fn state_name, acc ->
      normalized = normalize_state(state_name)

      cond do
        normalized == "" ->
          acc

        Enum.any?(acc, &(normalize_state(&1) == normalized)) ->
          acc

        true ->
          acc ++ [String.trim(state_name)]
      end
    end)
  end

  defp increment_state_count(counts, state_name) when is_map(counts) do
    case normalize_state(state_name) do
      "" ->
        counts

      normalized ->
        Map.update(counts, normalized, %StateCount{name: String.trim(state_name), count: 1}, fn %StateCount{} = state_count ->
          %StateCount{state_count | count: state_count.count + 1}
        end)
    end
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
