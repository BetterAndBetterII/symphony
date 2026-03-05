defmodule SymphonyElixirWeb.GitHubProjectApiController do
  @moduledoc """
  JSON API for fetching GitHub ProjectV2 configuration.

  This endpoint is intended to surface the current ProjectV2 field metadata
  (including single-select options such as the default `Status` field) so that
  Symphony can later switch trackers without needing Linear.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.GitHubProject.{Field, ProjectConfig}
  alias SymphonyElixirWeb.Endpoint

  @spec config(Conn.t(), map()) :: Conn.t()
  def config(conn, _params) do
    case ProjectConfig.fetch_from_workflow(project_config_opts()) do
      {:ok, %ProjectConfig{} = config} ->
        json(conn, project_config_payload(config))

      {:error, reason} ->
        {status, code, message} = map_error(reason)
        error_response(conn, status, code, message)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  defp project_config_opts do
    case Endpoint.config(:github_project_request_fun) do
      request_fun when is_function(request_fun, 2) ->
        [request_fun: request_fun]

      _ ->
        []
    end
  end

  defp project_config_payload(%ProjectConfig{} = config) do
    %{
      project_id: config.project_id,
      project_title: config.project_title,
      project_number: config.project_number,
      status_field: config.status_field && field_payload(config.status_field),
      fields: Enum.map(config.fields, &field_payload/1)
    }
  end

  defp field_payload(%Field{} = field) do
    %{
      id: field.id,
      name: field.name,
      data_type: field.data_type,
      options: field.options
    }
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp map_error(:missing_github_project_endpoint) do
    {400, "missing_github_project_endpoint", "Missing github_project.endpoint in WORKFLOW.md"}
  end

  defp map_error(:missing_github_project_api_token) do
    {400, "missing_github_project_api_token", "Missing GitHub token (set github_project.api_key or GITHUB_TOKEN)"}
  end

  defp map_error(:missing_github_project_owner) do
    {400, "missing_github_project_owner", "Missing github_project.owner in WORKFLOW.md"}
  end

  defp map_error(:missing_github_project_owner_type) do
    {400, "missing_github_project_owner_type", "Missing github_project.owner_type in WORKFLOW.md (organization|user)"}
  end

  defp map_error(:missing_github_project_number) do
    {400, "missing_github_project_number", "Missing github_project.project_number in WORKFLOW.md"}
  end

  defp map_error({:invalid_github_project_owner_type, owner_type}) do
    {400, "invalid_github_project_owner_type", "Invalid github_project.owner_type: #{inspect(owner_type)}"}
  end

  defp map_error({:invalid_github_project_number, project_number}) do
    {400, "invalid_github_project_number", "Invalid github_project.project_number: #{inspect(project_number)}"}
  end

  defp map_error(:github_project_not_found) do
    {404, "github_project_not_found", "GitHub Project not found"}
  end

  defp map_error({:github_api_status, status}) do
    {502, "github_api_status", "GitHub API request failed with status #{status}"}
  end

  defp map_error({:github_api_request, reason}) do
    {502, "github_api_request", "GitHub API request failed: #{inspect(reason)}"}
  end

  defp map_error({:github_graphql_errors, errors}) when is_list(errors) do
    message = "GitHub GraphQL errors returned: " <> summarize_graphql_errors(errors)
    {502, "github_graphql_errors", message}
  end

  defp map_error(:github_unknown_payload) do
    {502, "github_unknown_payload", "Unexpected GitHub response payload"}
  end

  defp map_error(:github_missing_end_cursor) do
    {502, "github_missing_end_cursor", "GitHub response pagination cursor was missing"}
  end

  defp map_error(other) do
    {500, "internal_error", "Unexpected error: #{inspect(other)}"}
  end

  defp summarize_graphql_errors(errors) do
    errors
    |> Enum.take(1)
    |> Enum.map_join("; ", fn
      %{"message" => message} when is_binary(message) -> message
      %{message: message} -> to_string(message)
      other -> inspect(other)
    end)
  end
end
