defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub GraphQL client used by tracker adapters.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.GitHubAuth

  @max_error_body_log_bytes 1_000

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    endpoint = Keyword.get(opts, :endpoint, Config.github_endpoint())

    request_fun =
      Keyword.get(opts, :request_fun, fn request_payload, headers ->
        post_graphql_request(endpoint, request_payload, headers)
      end)

    with {:ok, headers} <- graphql_headers(opts),
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
        if Config.github_auth_error?(reason) do
          {:error, reason}
        else
          Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
          {:error, {:github_api_request, reason}}
        end
    end
  end

  defp graphql_headers(opts) do
    case auth_from_opts(opts) do
      {:ok, %GitHubAuth{token: token}} ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Content-Type", "application/json"},
           {"Accept", "application/vnd.github+json"},
           {"User-Agent", "symphony"}
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_from_opts(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, %GitHubAuth{host: github_host(opts), source: :explicit_config, token: token}}

      _ ->
        Config.github_auth()
    end
  end

  defp github_host(opts) do
    endpoint = Keyword.get(opts, :endpoint, Config.github_endpoint())

    case URI.parse(endpoint) do
      %URI{host: "api.github.com"} -> "github.com"
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "github.com"
    end
  end

  defp post_graphql_request(endpoint, payload, headers) do
    Req.post(endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp github_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

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
