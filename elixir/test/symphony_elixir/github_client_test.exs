defmodule SymphonyElixir.GitHub.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client

  test "graphql returns :missing_github_api_token when token is unset" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_gh_token = System.get_env("GH_TOKEN")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_env("GH_TOKEN", previous_gh_token)
    end)

    System.delete_env("GITHUB_TOKEN")
    System.delete_env("GH_TOKEN")

    assert {:error, :missing_github_api_token} =
             Client.graphql("query Viewer { viewer { login } }", %{},
               request_fun: fn _payload, _headers ->
                 flunk("request_fun should not be called when auth is missing")
               end
             )
  end

  test "graphql forwards payload and returns body on 200" do
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)
    System.put_env("GITHUB_TOKEN", "token-123")

    request_fun = fn payload, headers ->
      send(self(), {:request_sent, payload, headers})
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "me"}}}}}
    end

    assert {:ok, %{"data" => %{"viewer" => %{"login" => "me"}}}} =
             Client.graphql(
               "query Viewer { viewer { login } }",
               %{"includeTeams" => false},
               operation_name: "Viewer",
               request_fun: request_fun
             )

    assert_received {:request_sent,
                     %{
                       "operationName" => "Viewer",
                       "query" => "query Viewer { viewer { login } }",
                       "variables" => %{"includeTeams" => false}
                     }, headers}

    assert Enum.any?(headers, fn
             {"Authorization", "Bearer token-123"} -> true
             _ -> false
           end)
  end

  test "graphql maps non-200 responses to {:github_api_status, status}" do
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)
    System.put_env("GITHUB_TOKEN", "token-123")

    assert {:error, {:github_api_status, 503}} =
             Client.graphql("query Viewer { viewer { login } }", %{},
               request_fun: fn _payload, _headers -> {:ok, %{status: 503, body: "nope"}} end
             )
  end

  test "graphql maps transport errors to {:github_api_request, reason}" do
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)
    System.put_env("GITHUB_TOKEN", "token-123")

    assert {:error, {:github_api_request, :timeout}} =
             Client.graphql("query Viewer { viewer { login } }", %{},
               request_fun: fn _payload, _headers -> {:error, :timeout} end
             )
  end

  test "graphql omits operationName when operation_name is blank or non-binary" do
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)
    System.put_env("GITHUB_TOKEN", "token-123")

    request_fun = fn payload, _headers ->
      send(self(), {:payload_sent, payload})
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "me"}}}}}
    end

    assert {:ok, _body} =
             Client.graphql("query Viewer { viewer { login } }", %{},
               operation_name: "   ",
               request_fun: request_fun
             )

    assert_received {:payload_sent, payload}
    refute Map.has_key?(payload, "operationName")

    assert {:ok, _body} =
             Client.graphql("query Viewer { viewer { login } }", %{},
               operation_name: :viewer,
               request_fun: request_fun
             )

    assert_received {:payload_sent, payload}
    refute Map.has_key?(payload, "operationName")
  end

  test "graphql logs operation name and truncates long error bodies" do
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)
    System.put_env("GITHUB_TOKEN", "token-123")

    long_body = String.duplicate("x", 1_100)

    log =
      capture_log(fn ->
        assert {:error, {:github_api_status, 500}} =
                 Client.graphql("query Viewer { viewer { login } }", %{},
                   operation_name: "Viewer",
                   request_fun: fn _payload, _headers -> {:ok, %{status: 500, body: long_body}} end
                 )
      end)

    assert log =~ "operation=Viewer"
    assert log =~ "<truncated>"
  end

  test "graphql summarizes non-binary error bodies" do
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)
    System.put_env("GITHUB_TOKEN", "token-123")

    log =
      capture_log(fn ->
        assert {:error, {:github_api_status, 400}} =
                 Client.graphql("query Viewer { viewer { login } }", %{},
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 400, body: %{"errors" => [%{"message" => "boom"}]}}}
                   end
                 )
      end)

    assert log =~ "body=%{"
    assert log =~ "errors"
  end
end
