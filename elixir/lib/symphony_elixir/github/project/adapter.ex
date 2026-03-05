defmodule SymphonyElixir.GitHub.Project.Adapter do
  @moduledoc """
  GitHub Projects (ProjectV2)-backed tracker adapter.

  The adapter treats a ProjectV2 item as the tracker "issue id" so that we can
  update project fields (status) without extra lookups. Comments are created on
  the underlying GitHub Issue content referenced by the project item.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Tracker.Issue

  @item_page_size 50
  @field_values_first 50
  @labels_first 50
  @assignees_first 10

  @viewer_query """
  query SymphonyGitHubViewer {
    viewer {
      login
    }
  }
  """

  @project_items_query """
  query SymphonyGitHubProjectItems(
    $owner: String!
    $number: Int!
    $first: Int!
    $after: String
    $fieldValuesFirst: Int!
    $labelsFirst: Int!
    $assigneesFirst: Int!
  ) {
    repositoryOwner(login: $owner) {
      __typename
      ... on Organization {
        projectV2(number: $number) {
          id
          items(first: $first, after: $after) {
            nodes {
              id
              fieldValues(first: $fieldValuesFirst) {
                nodes {
                  __typename
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    optionId
                    field {
                      __typename
                      ... on ProjectV2SingleSelectField {
                        id
                        name
                      }
                    }
                  }
                }
              }
              content {
                __typename
                ... on Issue {
                  id
                  number
                  title
                  body
                  url
                  createdAt
                  updatedAt
                  repository {
                    nameWithOwner
                  }
                  labels(first: $labelsFirst) {
                    nodes {
                      name
                    }
                  }
                  assignees(first: $assigneesFirst) {
                    nodes {
                      login
                    }
                  }
                }
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
      ... on User {
        projectV2(number: $number) {
          id
          items(first: $first, after: $after) {
            nodes {
              id
              fieldValues(first: $fieldValuesFirst) {
                nodes {
                  __typename
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    optionId
                    field {
                      __typename
                      ... on ProjectV2SingleSelectField {
                        id
                        name
                      }
                    }
                  }
                }
              }
              content {
                __typename
                ... on Issue {
                  id
                  number
                  title
                  body
                  url
                  createdAt
                  updatedAt
                  repository {
                    nameWithOwner
                  }
                  labels(first: $labelsFirst) {
                    nodes {
                      name
                    }
                  }
                  assignees(first: $assigneesFirst) {
                    nodes {
                      login
                    }
                  }
                }
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
    }
  }
  """

  @items_by_id_query """
  query SymphonyGitHubProjectItemsById(
    $ids: [ID!]!
    $fieldValuesFirst: Int!
    $labelsFirst: Int!
    $assigneesFirst: Int!
  ) {
    nodes(ids: $ids) {
      __typename
      ... on ProjectV2Item {
        id
        fieldValues(first: $fieldValuesFirst) {
          nodes {
            __typename
            ... on ProjectV2ItemFieldSingleSelectValue {
              name
              optionId
              field {
                __typename
                ... on ProjectV2SingleSelectField {
                  id
                  name
                }
              }
            }
          }
        }
        content {
          __typename
          ... on Issue {
            id
            number
            title
            body
            url
            createdAt
            updatedAt
            repository {
              nameWithOwner
            }
            labels(first: $labelsFirst) {
              nodes {
                name
              }
            }
            assignees(first: $assigneesFirst) {
              nodes {
                login
              }
            }
          }
        }
      }
    }
  }
  """

  @project_fields_query """
  query SymphonyGitHubProjectFields($owner: String!, $number: Int!, $first: Int!) {
    repositoryOwner(login: $owner) {
      __typename
      ... on Organization {
        projectV2(number: $number) {
          id
          fields(first: $first) {
            nodes {
              __typename
              ... on ProjectV2SingleSelectField {
                id
                name
                options {
                  id
                  name
                }
              }
            }
          }
        }
      }
      ... on User {
        projectV2(number: $number) {
          id
          fields(first: $first) {
            nodes {
              __typename
              ... on ProjectV2SingleSelectField {
                id
                name
                options {
                  id
                  name
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @add_comment_mutation """
  mutation SymphonyGitHubAddComment($subjectId: ID!, $body: String!) {
    addComment(input: {subjectId: $subjectId, body: $body}) {
      commentEdge {
        node {
          id
          url
        }
      }
    }
  }
  """

  @update_status_mutation """
  mutation SymphonyGitHubUpdateStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: ID!) {
    updateProjectV2ItemFieldValue(
      input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: {singleSelectOptionId: $optionId}
      }
    ) {
      projectV2Item {
        id
      }
    }
  }
  """

  @impl true
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, assignee_filter} <- routing_assignee_filter() do
      do_fetch_by_states(Config.tracker_active_states(), assignee_filter)
    end
  end

  @impl true
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, assignee_filter} <- routing_assignee_filter() do
      do_fetch_by_states(state_names, assignee_filter)
    end
  end

  @impl true
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, body} <-
               client_module().graphql(@items_by_id_query, %{
                 ids: ids,
                 fieldValuesFirst: @field_values_first,
                 labelsFirst: @labels_first,
                 assigneesFirst: @assignees_first
               }),
             :ok <- ensure_no_graphql_errors(body) do
          items = get_in(body, ["data", "nodes"]) || []
          status_field = Config.github_project_status_field()

          issues =
            items
            |> Enum.map(&normalize_item_node(&1, status_field, assignee_filter))
            |> Enum.reject(&is_nil/1)

          {:ok, issues}
        else
          {:error, reason} -> {:error, reason}
          {:graphql_errors, errors} -> {:error, {:github_graphql_errors, errors}}
          _ -> {:error, :github_unknown_payload}
        end
    end
  end

  @impl true
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, subject_id} <- resolve_issue_subject_id(issue_id),
         {:ok, response} <- client_module().graphql(@add_comment_mutation, %{subjectId: subject_id, body: body}),
         :ok <- ensure_no_graphql_errors(response),
         comment_id when is_binary(comment_id) <-
           get_in(response, ["data", "addComment", "commentEdge", "node", "id"]) do
      :ok
    else
      nil -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      {:graphql_errors, errors} -> {:error, {:github_graphql_errors, errors}}
      _ -> {:error, :comment_create_failed}
    end
  end

  @impl true
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, %{owner: owner, number: number}} <- project_ref(),
         {:ok, project_id, field_id, option_id} <- resolve_status_option(owner, number, state_name),
         {:ok, response} <-
           client_module().graphql(@update_status_mutation, %{
             projectId: project_id,
             itemId: issue_id,
             fieldId: field_id,
             optionId: option_id
           }),
         :ok <- ensure_no_graphql_errors(response),
         updated_id when is_binary(updated_id) <-
           get_in(response, ["data", "updateProjectV2ItemFieldValue", "projectV2Item", "id"]),
         true <- updated_id == issue_id do
      :ok
    else
      false -> {:error, :issue_update_failed}
      nil -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      {:graphql_errors, errors} -> {:error, {:github_graphql_errors, errors}}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp do_fetch_by_states(state_names, assignee_filter) when is_list(state_names) do
    wanted_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if Enum.empty?(wanted_states) do
      {:ok, []}
    else
      with {:ok, %{owner: owner, number: number}} <- project_ref() do
        do_fetch_project_items_page(owner, number, wanted_states, assignee_filter, nil, [])
      end
    end
  end

  defp do_fetch_project_items_page(
         owner,
         number,
         %MapSet{} = wanted_states,
         assignee_filter,
         after_cursor,
         acc
       )
       when is_binary(owner) and is_integer(number) and is_list(acc) do
    with {:ok, body} <-
           client_module().graphql(@project_items_query, %{
             owner: owner,
             number: number,
             first: @item_page_size,
             after: after_cursor,
             fieldValuesFirst: @field_values_first,
             labelsFirst: @labels_first,
             assigneesFirst: @assignees_first
           }),
         :ok <- ensure_no_graphql_errors(body),
         %{"nodes" => nodes, "pageInfo" => page_info} when is_list(nodes) and is_map(page_info) <-
           get_in(body, ["data", "repositoryOwner", "projectV2", "items"]) do
      status_field = Config.github_project_status_field()

      page_issues =
        nodes
        |> Enum.map(&normalize_project_item(&1, status_field, assignee_filter))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn %Issue{state: state} ->
          MapSet.member?(wanted_states, normalize_state(state))
        end)

      updated_acc = Enum.reverse(page_issues, acc)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_project_items_page(owner, number, wanted_states, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, Enum.reverse(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:graphql_errors, errors} -> {:error, {:github_graphql_errors, errors}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp next_page_cursor(%{"hasNextPage" => true, "endCursor" => cursor})
       when is_binary(cursor) and byte_size(cursor) > 0 do
    {:ok, cursor}
  end

  defp next_page_cursor(%{"hasNextPage" => true}), do: {:error, :github_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp project_ref do
    with true <- is_binary(Config.github_api_token()) || {:error, :missing_github_api_token},
         owner when is_binary(owner) <- Config.github_project_owner() || {:error, :missing_github_project_owner},
         trimmed_owner <- String.trim(owner),
         true <- trimmed_owner != "" || {:error, :missing_github_project_owner},
         number when is_integer(number) <- Config.github_project_number() || {:error, :missing_github_project_number} do
      {:ok, %{owner: trimmed_owner, number: number}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_project_config_invalid}
    end
  end

  defp ensure_no_graphql_errors(%{"errors" => errors}) when is_list(errors) and errors != [] do
    {:graphql_errors, errors}
  end

  defp ensure_no_graphql_errors(_), do: :ok

  defp normalize_project_item(item, status_field, assignee_filter) when is_map(item) do
    item_id = Map.get(item, "id")
    content = Map.get(item, "content") || %{}

    with true <- is_binary(item_id) and item_id != "",
         "Issue" <- Map.get(content, "__typename") do
      issue_number = Map.get(content, "number")
      repo = get_in(content, ["repository", "nameWithOwner"])

      identifier =
        cond do
          is_binary(repo) and is_integer(issue_number) -> "#{repo}##{issue_number}"
          is_integer(issue_number) -> "##{issue_number}"
          true -> item_id
        end

      assignees = get_in(content, ["assignees", "nodes"]) || []

      %Issue{
        id: item_id,
        identifier: identifier,
        title: Map.get(content, "title"),
        description: Map.get(content, "body"),
        priority: nil,
        state: resolve_status_value(item, status_field),
        branch_name: nil,
        url: Map.get(content, "url"),
        assignee_id: first_assignee_login(assignees),
        blocked_by: [],
        labels: extract_labels(content),
        assigned_to_worker: assigned_to_worker?(assignees, assignee_filter),
        created_at: parse_datetime(Map.get(content, "createdAt")),
        updated_at: parse_datetime(Map.get(content, "updatedAt"))
      }
    else
      _ -> nil
    end
  end

  defp normalize_project_item(_item, _status_field, _assignee_filter), do: nil

  defp normalize_item_node(%{"__typename" => "ProjectV2Item"} = item, status_field, assignee_filter) do
    normalize_project_item(item, status_field, assignee_filter)
  end

  defp normalize_item_node(_node, _status_field, _assignee_filter), do: nil

  defp resolve_status_value(item, status_field) when is_map(item) and is_binary(status_field) do
    values = get_in(item, ["fieldValues", "nodes"]) || []
    normalized_field = normalize_state(status_field)

    Enum.find_value(values, fn
      %{
        "__typename" => "ProjectV2ItemFieldSingleSelectValue",
        "name" => name,
        "field" => %{"name" => field_name}
      }
      when is_binary(name) and is_binary(field_name) ->
        if normalize_state(field_name) == normalized_field, do: name, else: nil

      _ ->
        nil
    end)
  end

  defp resolve_status_value(_item, _status_field), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_label/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_labels(_content), do: []

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(_value), do: ""

  defp first_assignee_login(assignees) when is_list(assignees) do
    assignees
    |> Enum.find_value(fn
      %{"login" => login} when is_binary(login) and login != "" -> login
      _ -> nil
    end)
  end

  defp first_assignee_login(_assignees), do: nil

  defp routing_assignee_filter do
    case Config.tracker_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    assignee
    |> normalize_assignee_match_value()
    |> case do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new(split_assignee_values(normalized))}}
    end
  end

  defp build_assignee_filter(_assignee), do: {:ok, nil}

  defp split_assignee_values(values) when is_binary(values) do
    values
    |> String.split(",", trim: true)
    |> Enum.map(&normalize_assignee_match_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_viewer_assignee_filter do
    case client_module().graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => %{"login" => login}}}} when is_binary(login) ->
        case normalize_assignee_match_value(login) do
          nil ->
            {:error, :missing_github_viewer_identity}

          viewer_login ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_login])}}
        end

      {:ok, _body} ->
        {:error, :missing_github_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, %{match_values: match_values})
       when is_list(assignees) and is_struct(match_values, MapSet) do
    Enum.any?(assignees, fn
      %{"login" => login} when is_binary(login) ->
        case normalize_assignee_match_value(login) do
          nil -> false
          normalized -> MapSet.member?(match_values, normalized)
        end

      _ ->
        false
    end)
  end

  defp assigned_to_worker?(_assignees, _assignee_filter), do: false

  defp resolve_issue_subject_id(project_item_id) when is_binary(project_item_id) do
    with {:ok, body} <-
           client_module().graphql(@items_by_id_query, %{
             ids: [project_item_id],
             fieldValuesFirst: 1,
             labelsFirst: 1,
             assigneesFirst: 1
           }),
         :ok <- ensure_no_graphql_errors(body),
         [%{"__typename" => "ProjectV2Item"} = node] <- get_in(body, ["data", "nodes"]),
         %{"__typename" => "Issue", "id" => subject_id} when is_binary(subject_id) <-
           Map.get(node, "content") do
      {:ok, subject_id}
    else
      {:graphql_errors, errors} -> {:error, {:github_graphql_errors, errors}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_github_issue_content}
    end
  end

  defp resolve_status_option(owner, number, desired_state) when is_binary(desired_state) do
    status_field_name = Config.github_project_status_field()

    with {:ok, body} <- client_module().graphql(@project_fields_query, %{owner: owner, number: number, first: 50}),
         :ok <- ensure_no_graphql_errors(body),
         %{"id" => project_id, "fields" => %{"nodes" => fields}} when is_list(fields) and is_binary(project_id) <-
           get_in(body, ["data", "repositoryOwner", "projectV2"]),
         %{"id" => field_id, "options" => options} when is_list(options) and is_binary(field_id) <-
           find_single_select_field(fields, status_field_name),
         option_id when is_binary(option_id) <- find_option_id(options, desired_state) do
      {:ok, project_id, field_id, option_id}
    else
      {:graphql_errors, errors} -> {:error, {:github_graphql_errors, errors}}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :github_status_option_not_found}
      _ -> {:error, :github_status_field_not_found}
    end
  end

  defp resolve_status_option(_owner, _number, _desired_state), do: {:error, :github_status_option_not_found}

  defp find_single_select_field(fields, desired_name) when is_list(fields) and is_binary(desired_name) do
    desired = normalize_state(desired_name)

    Enum.find(fields, fn
      %{"__typename" => "ProjectV2SingleSelectField", "name" => name} when is_binary(name) ->
        normalize_state(name) == desired

      _ ->
        false
    end)
  end

  defp find_single_select_field(_fields, _desired_name), do: nil

  defp find_option_id(options, desired_state) when is_list(options) and is_binary(desired_state) do
    desired = normalize_state(desired_state)

    Enum.find_value(options, fn
      %{"id" => id, "name" => name} when is_binary(id) and is_binary(name) ->
        if normalize_state(name) == desired, do: id, else: nil

      _ ->
        nil
    end)
  end

  defp find_option_id(_options, _desired_state), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_value), do: ""

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
