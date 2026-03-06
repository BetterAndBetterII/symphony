defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client

  @github_graphql_tool "github_graphql"
  @github_graphql_description """
  Execute a raw GraphQL query or mutation against GitHub using Symphony's configured auth.
  """
  @github_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against GitHub."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @github_graphql_tool ->
        execute_github_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @github_graphql_tool,
        "description" => @github_graphql_description,
        "inputSchema" => @github_graphql_input_schema
      }
    ]
  end

  defp execute_github_graphql(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_github_graphql_arguments(arguments),
         {:ok, response} <- github_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_github_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> normalize_single_operation_query(query, %{})
    end
  end

  defp normalize_github_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            normalize_single_operation_query(query, variables)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_github_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_single_operation_query(query, variables)
       when is_binary(query) and is_map(variables) do
    if multiple_graphql_operations?(query) do
      {:error, :multiple_operations_not_supported}
    else
      {:ok, query, variables}
    end
  end

  defp multiple_graphql_operations?(query) when is_binary(query) do
    Regex.scan(~r/^\s*(query|mutation|subscription)\b/m, query)
    |> length()
    |> Kernel.>(1)
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`github_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`github_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`github_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:multiple_operations_not_supported) do
    %{
      "error" => %{
        "message" => "`github_graphql` only supports a single GraphQL operation per tool call (multiple operations require `operationName`, which is intentionally out of scope)."
      }
    }
  end

  defp tool_error_payload({:github_api_status, status}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) when is_atom(reason) or is_tuple(reason) do
    case Config.github_auth_error_message(reason) do
      nil -> generic_tool_error_payload(reason)
      message -> %{"error" => %{"message" => message}}
    end
  end

  defp tool_error_payload(reason) do
    generic_tool_error_payload(reason)
  end

  defp generic_tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
