defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the github_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "github_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "GitHub"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["github_graphql"]
             }
           }
  end

  test "github_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        github_client: fn query, variables, opts ->
          send(test_pid, {:github_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:github_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "github_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_graphql",
        "  query Viewer { viewer { id } }  ",
        github_client: fn query, variables, opts ->
          send(test_pid, {:github_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:github_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "github_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        github_client: fn query, variables, opts ->
          send(test_pid, {:github_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:github_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "github_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => query},
        github_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:github_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:github_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "github_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("github_graphql", "   ")

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`github_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "github_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        github_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "github_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        github_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "github_graphql validates required arguments before calling GitHub" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`github_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "   "},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "github_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "github_graphql",
        [:not, :valid],
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`github_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "github_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`github_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "github_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        github_client: fn _query, _variables, _opts -> {:error, :missing_github_api_token} end
      )

    assert missing_token["success"] == false

    assert [
             %{
               "text" => missing_token_text
             }
           ] = missing_token["contentItems"]

    assert Jason.decode!(missing_token_text) == %{
             "error" => %{
               "message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN` / `GH_TOKEN`."
             }
           }

    status_error =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        github_client: fn _query, _variables, _opts -> {:error, {:github_api_status, 503}} end
      )

    assert [
             %{
               "text" => status_error_text
             }
           ] = status_error["contentItems"]

    assert Jason.decode!(status_error_text) == %{
             "error" => %{
               "message" => "GitHub GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        github_client: fn _query, _variables, _opts -> {:error, {:github_api_request, :timeout}} end
      )

    assert [
             %{
               "text" => request_error_text
             }
           ] = request_error["contentItems"]

    assert Jason.decode!(request_error_text) == %{
             "error" => %{
               "message" => "GitHub GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "github_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        github_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "GitHub GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "github_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        github_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true

    assert [
             %{
               "text" => ":ok"
             }
           ] = response["contentItems"]
  end
end
