defmodule SymphonyElixir.GitHubProject.Client do
  @moduledoc """
  Thin GitHub GraphQL client used for GitHub Projects v2 configuration reads.

  This client is intentionally small and takes a `request_fun` option so it can
  be unit-tested without network access.
  """

  require Logger

  alias SymphonyElixir.GitHubProject.ProjectLocator

  @max_error_body_log_bytes 1_000

  @spec graphql(ProjectLocator.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(%ProjectLocator{} = locator, query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))

    request_fun =
      Keyword.get(opts, :request_fun, fn payload, headers ->
        post_graphql_request(locator.endpoint, payload, headers)
      end)

    with {:ok, headers} <- graphql_headers(locator),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "GitHub GraphQL request failed status=#{response.status}" <>
            github_error_context(payload, response)
        )

        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp build_graphql_payload(query, variables, operation_name) do
    base = %{query: query, variables: variables}

    case operation_name do
      name when is_binary(name) and String.trim(name) != "" ->
        Map.put(base, :operationName, String.trim(name))

      _ ->
        base
    end
  end

  defp graphql_headers(%ProjectLocator{token: token}) when is_binary(token) do
    case String.trim(token) do
      "" ->
        {:error, :missing_github_project_api_token}

      trimmed ->
        {:ok,
         [
           {"Authorization", "Bearer " <> trimmed},
           {"Accept", "application/vnd.github+json"},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp graphql_headers(_locator), do: {:error, :missing_github_project_api_token}

  defp post_graphql_request(endpoint, payload, headers) do
    Req.post(endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp github_error_context(payload, %{body: body}) do
    operation_name = operation_label(payload)

    operation_name <>
      " body=" <>
      body
      |> summarize_error_body()
  end

  defp github_error_context(payload, _response) do
    operation_label(payload) <> " body=:unknown"
  end

  defp operation_label(%{operationName: name}) when is_binary(name) and name != "" do
    " operation=#{name}"
  end

  defp operation_label(_payload), do: ""

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end

