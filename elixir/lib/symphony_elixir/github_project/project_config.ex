defmodule SymphonyElixir.GitHubProject.ProjectConfig do
  @moduledoc """
  Fetch and normalize GitHub ProjectV2 configuration (fields and status options).

  This is intended to be the single place that understands the GitHub Projects
  GraphQL response shape, so the rest of the app can depend on `t()` and
  `SymphonyElixir.GitHubProject.Field`.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHubProject.{Client, Field, ProjectLocator}

  @fields_page_size 100

  @org_fields_query """
  query SymphonyGitHubProjectFields($login: String!, $number: Int!, $first: Int!, $after: String) {
    organization(login: $login) {
      projectV2(number: $number) {
        id
        title
        fields(first: $first, after: $after) {
          nodes {
            __typename
            ... on ProjectV2FieldCommon {
              id
              name
              dataType
            }
            ... on ProjectV2SingleSelectField {
              options {
                id
                name
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
  """

  @user_fields_query """
  query SymphonyGitHubProjectFields($login: String!, $number: Int!, $first: Int!, $after: String) {
    user(login: $login) {
      projectV2(number: $number) {
        id
        title
        fields(first: $first, after: $after) {
          nodes {
            __typename
            ... on ProjectV2FieldCommon {
              id
              name
              dataType
            }
            ... on ProjectV2SingleSelectField {
              options {
                id
                name
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
  """

  defstruct [:project_id, :project_title, :project_number, fields: [], status_field: nil]

  @type t :: %__MODULE__{
          project_id: String.t(),
          project_title: String.t() | nil,
          project_number: pos_integer(),
          fields: [Field.t()],
          status_field: Field.t() | nil
        }

  @spec fetch(ProjectLocator.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def fetch(%ProjectLocator{} = locator, opts \\ []) do
    with {:ok, meta, fields} <- fetch_all_fields(locator, opts) do
      status_field = find_field_by_name(fields, locator.status_field_name)

      {:ok,
       %__MODULE__{
         project_id: meta.id,
         project_title: meta.title,
         project_number: locator.project_number,
         fields: fields,
         status_field: status_field
       }}
    end
  end

  @spec fetch_from_workflow(keyword()) :: {:ok, t()} | {:error, term()}
  def fetch_from_workflow(opts \\ []) do
    with {:ok, locator} <- Config.github_project_locator() do
      fetch(locator, opts)
    end
  end

  defp fetch_all_fields(locator, opts) do
    query = fields_query(locator.owner_type)
    fetch_fields_page(locator, query, nil, nil, [], opts)
  end

  defp fetch_fields_page(locator, query, after_cursor, meta, acc_fields, opts) do
    variables = %{
      login: locator.owner,
      number: locator.project_number,
      first: @fields_page_size,
      after: after_cursor
    }

    graphql_opts = Keyword.put_new(opts, :operation_name, "SymphonyGitHubProjectFields")

    with {:ok, body} <- Client.graphql(locator, query, variables, graphql_opts),
         {:ok, page_meta, page_fields, page_info} <- decode_fields_response(body, locator.owner_type) do
      meta = meta || page_meta
      acc_fields = Enum.reverse(page_fields, acc_fields)

      case next_page_cursor(page_info) do
        {:ok, cursor} ->
          fetch_fields_page(locator, query, cursor, meta, acc_fields, opts)

        :done ->
          {:ok, meta, Enum.reverse(acc_fields)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fields_query(:organization), do: @org_fields_query
  defp fields_query(:user), do: @user_fields_query

  defp decode_fields_response(%{"errors" => errors}, _owner_type) do
    {:error, {:github_graphql_errors, errors}}
  end

  defp decode_fields_response(%{"data" => _} = body, owner_type) do
    project =
      case owner_type do
        :organization -> get_in(body, ["data", "organization", "projectV2"])
        :user -> get_in(body, ["data", "user", "projectV2"])
      end

    case project do
      %{} = project ->
        fields = Map.get(project, "fields", %{})

        nodes =
          fields
          |> Map.get("nodes", [])
          |> Enum.map(&normalize_field/1)
          |> Enum.reject(&is_nil/1)

        page_info = Map.get(fields, "pageInfo", %{})

        {:ok, %{id: project["id"], title: project["title"]}, nodes, normalize_page_info(page_info)}

      _ ->
        {:error, :github_project_not_found}
    end
  end

  defp decode_fields_response(_body, _owner_type), do: {:error, :github_unknown_payload}

  defp normalize_page_info(%{"hasNextPage" => has_next_page, "endCursor" => end_cursor}) do
    %{
      has_next_page: has_next_page == true,
      end_cursor: end_cursor
    }
  end

  defp normalize_page_info(_page_info) do
    %{has_next_page: false, end_cursor: nil}
  end

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :github_missing_end_cursor}
  defp next_page_cursor(_page_info), do: :done

  defp normalize_field(%{"id" => id, "name" => name} = raw) when is_binary(id) and is_binary(name) do
    %Field{
      id: id,
      name: name,
      data_type: raw["dataType"],
      options: normalize_options(raw["options"])
    }
  end

  defp normalize_field(_raw), do: nil

  defp normalize_options(options) when is_list(options) do
    options
    |> Enum.map(fn
      %{"id" => id, "name" => name} when is_binary(id) and is_binary(name) -> %{id: id, name: name}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_options(_options), do: []

  defp find_field_by_name(fields, target_name) when is_list(fields) and is_binary(target_name) do
    normalized_target = normalize_field_name(target_name)

    Enum.find(fields, fn %Field{name: name} ->
      normalize_field_name(name) == normalized_target
    end)
  end

  defp find_field_by_name(_fields, _target_name), do: nil

  defp normalize_field_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end
end
