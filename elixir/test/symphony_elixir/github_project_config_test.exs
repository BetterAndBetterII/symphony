defmodule SymphonyElixir.GitHubProjectConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubProject.{Client, ProjectConfig, ProjectLocator}

  test "github project locator resolves token from GITHUB_TOKEN env var" do
    previous_token = System.get_env("GITHUB_TOKEN")
    env_token = "test-github-token"

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    System.put_env("GITHUB_TOKEN", env_token)

    write_workflow_file!(Workflow.workflow_file_path(),
      github_project_api_token: nil,
      github_project_owner: "octo-org",
      github_project_owner_type: "organization",
      github_project_number: 7
    )

    assert {:ok, locator} = Config.github_project_locator()
    assert locator.endpoint == "https://api.github.com/graphql"
    assert locator.token == env_token
    assert locator.owner == "octo-org"
    assert locator.owner_type == :organization
    assert locator.project_number == 7
    assert locator.status_field_name == "Status"
  end

  test "github project locator parsing enforces required fields" do
    assert {:error, :invalid_github_project_locator} = ProjectLocator.parse(nil)

    assert {:error, :missing_github_project_endpoint} =
             ProjectLocator.parse(%{
               endpoint: " ",
               token: "token",
               owner: "octo-org",
               owner_type: "organization",
               project_number: 1,
               status_field_name: "Status"
             })

    assert {:error, :missing_github_project_owner_type} =
             ProjectLocator.parse(%{
               endpoint: "https://api.github.com/graphql",
               token: "token",
               owner: "octo-org",
               project_number: 1,
               status_field_name: "Status"
             })

    assert {:error, {:invalid_github_project_owner_type, "team"}} =
             ProjectLocator.parse(%{
               endpoint: "https://api.github.com/graphql",
               token: "token",
               owner: "octo-org",
               owner_type: "team",
               project_number: 1,
               status_field_name: "Status"
             })

    assert {:error, {:invalid_github_project_number, "0"}} =
             ProjectLocator.parse(%{
               endpoint: "https://api.github.com/graphql",
               token: "token",
               owner: "octo-org",
               owner_type: "organization",
               project_number: "0",
               status_field_name: "Status"
             })

    assert {:ok, locator} =
             ProjectLocator.parse(%{
               endpoint: "https://api.github.com/graphql",
               token: "token",
               owner: "octo-org",
               owner_type: :organization,
               project_number: "1"
             })

    assert locator.owner_type == :organization
    assert locator.project_number == 1
    assert locator.status_field_name == "Status"

    assert {:error, :missing_github_project_endpoint} =
             ProjectLocator.parse(%{
               endpoint: 123,
               token: "token",
               owner: "octo-org",
               owner_type: "organization",
               project_number: 1,
               status_field_name: "Status"
             })
  end

  test "project config fetch normalizes fields and status options" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    body = %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_kwDOAA",
            "title" => "Roadmap",
            "fields" => %{
              "nodes" => [
                %{
                  "__typename" => "ProjectV2SingleSelectField",
                  "id" => "F_status",
                  "name" => "Status",
                  "dataType" => "SINGLE_SELECT",
                  "options" => [
                    %{"id" => "O_todo", "name" => "Todo"},
                    %{"id" => "O_doing", "name" => "In progress"}
                  ]
                },
                %{
                  "__typename" => "ProjectV2Field",
                  "id" => "F_text",
                  "name" => "Notes",
                  "dataType" => "TEXT"
                }
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      }
    }

    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: body}} end

    assert {:ok, config} = ProjectConfig.fetch(locator, request_fun: request_fun)
    assert config.project_id == "PVT_kwDOAA"
    assert config.project_title == "Roadmap"
    assert config.project_number == 1
    assert Enum.map(config.fields, & &1.id) == ["F_status", "F_text"]

    assert config.status_field.id == "F_status"
    assert Enum.map(config.status_field.options, & &1.name) == ["Todo", "In progress"]
  end

  test "project config ignores malformed field nodes and options" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    body = %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_kwDOAA",
            "title" => "Roadmap",
            "fields" => %{
              "nodes" => [
                %{
                  "__typename" => "ProjectV2SingleSelectField",
                  "id" => "F_status",
                  "name" => "Status",
                  "dataType" => "SINGLE_SELECT",
                  "options" => [
                    %{"id" => "O_todo", "name" => "Todo"},
                    %{"name" => "missing-id"}
                  ]
                },
                %{"id" => "F_missing_name"}
              ]
            }
          }
        }
      }
    }

    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: body}} end
    assert {:ok, config} = ProjectConfig.fetch(locator, request_fun: request_fun)
    assert Enum.map(config.fields, & &1.id) == ["F_status"]
    assert Enum.map(config.status_field.options, & &1.id) == ["O_todo"]
  end

  test "project config fetch paginates and preserves field order" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    page_1 = %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_kwDOAA",
            "title" => "Roadmap",
            "fields" => %{
              "nodes" => [
                %{
                  "__typename" => "ProjectV2Field",
                  "id" => "F_1",
                  "name" => "First",
                  "dataType" => "TEXT"
                }
              ],
              "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-1"}
            }
          }
        }
      }
    }

    page_2 = %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_kwDOAA",
            "title" => "Roadmap",
            "fields" => %{
              "nodes" => [
                %{
                  "__typename" => "ProjectV2Field",
                  "id" => "F_2",
                  "name" => "Second",
                  "dataType" => "TEXT"
                }
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      }
    }

    request_fun = fn payload, _headers ->
      case payload.variables[:after] do
        nil -> {:ok, %{status: 200, body: page_1}}
        "cursor-1" -> {:ok, %{status: 200, body: page_2}}
      end
    end

    assert {:ok, config} = ProjectConfig.fetch(locator, request_fun: request_fun)
    assert Enum.map(config.fields, & &1.id) == ["F_1", "F_2"]
  end

  test "project config fetch supports user-owned projects" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-user",
      owner_type: :user,
      project_number: 1,
      status_field_name: "status"
    }

    body = %{
      "data" => %{
        "user" => %{
          "projectV2" => %{
            "id" => "PVT_user",
            "title" => "Personal",
            "fields" => %{
              "nodes" => [
                %{
                  "__typename" => "ProjectV2SingleSelectField",
                  "id" => "F_status",
                  "name" => "Status",
                  "dataType" => "SINGLE_SELECT",
                  "options" => [%{"id" => "O_todo", "name" => "Todo"}]
                }
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      }
    }

    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: body}} end
    assert {:ok, config} = ProjectConfig.fetch(locator, request_fun: request_fun)
    assert config.project_id == "PVT_user"
    assert config.status_field.id == "F_status"
  end

  test "project config sets status_field to nil when no valid field name is provided" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: nil
    }

    body = %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_kwDOAA",
            "title" => "Roadmap",
            "fields" => %{
              "nodes" => [
                %{
                  "__typename" => "ProjectV2Field",
                  "id" => "F_1",
                  "name" => "Status",
                  "dataType" => "TEXT"
                }
              ],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      }
    }

    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: body}} end
    assert {:ok, config} = ProjectConfig.fetch(locator, request_fun: request_fun)
    assert config.status_field == nil
  end

  test "project config fetch surfaces github graphql errors" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    body = %{"errors" => [%{"message" => "bad request"}]}
    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: body}} end

    assert {:error, {:github_graphql_errors, [%{"message" => "bad request"}]}} =
             ProjectConfig.fetch(locator, request_fun: request_fun)
  end

  test "project config fetch returns descriptive errors for unexpected payloads" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    missing_cursor = %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_kwDOAA",
            "title" => "Roadmap",
            "fields" => %{
              "nodes" => [],
              "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}
            }
          }
        }
      }
    }

    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: missing_cursor}} end
    assert {:error, :github_missing_end_cursor} = ProjectConfig.fetch(locator, request_fun: request_fun)

    not_found = %{"data" => %{"organization" => nil}}
    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: not_found}} end
    assert {:error, :github_project_not_found} = ProjectConfig.fetch(locator, request_fun: request_fun)

    unknown = "oops"
    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: unknown}} end
    assert {:error, :github_unknown_payload} = ProjectConfig.fetch(locator, request_fun: request_fun)
  end

  test "project config can be fetched via workflow config convenience helper" do
    previous_token = System.get_env("GITHUB_TOKEN")
    env_token = "test-github-token"

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    System.put_env("GITHUB_TOKEN", env_token)

    write_workflow_file!(Workflow.workflow_file_path(),
      github_project_owner: "octo-org",
      github_project_owner_type: "organization",
      github_project_number: 1
    )

    body = %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_kwDOAA",
            "title" => "Roadmap",
            "fields" => %{
              "nodes" => [],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      }
    }

    request_fun = fn _payload, _headers -> {:ok, %{status: 200, body: body}} end
    assert {:ok, config} = ProjectConfig.fetch_from_workflow(request_fun: request_fun)
    assert config.project_id == "PVT_kwDOAA"
  end

  test "github graphql client logs response bodies for non-200 responses" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    log =
      capture_log(fn ->
        assert {:error, {:github_api_status, 401}} =
                 Client.graphql(
                   locator,
                   "query Viewer { viewer { login } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 401, body: %{"message" => "unauthorized"}}}
                   end
                 )
      end)

    assert log =~ "GitHub GraphQL request failed status=401"
    assert log =~ "unauthorized"
  end

  test "github graphql client includes operation name and truncates long string bodies" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    big_body = String.duplicate("x", 2_000)

    log =
      capture_log(fn ->
        assert {:error, {:github_api_status, 500}} =
                 Client.graphql(
                   locator,
                   "query Viewer { viewer { login } }",
                   %{},
                   operation_name: "Viewer",
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 500, body: big_body}}
                   end
                 )
      end)

    assert log =~ "status=500"
    assert log =~ "operation=Viewer"
    assert log =~ "...<truncated>"
  end

  test "github graphql client handles responses without bodies" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: "token",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    log =
      capture_log(fn ->
        assert {:error, {:github_api_status, 502}} =
                 Client.graphql(
                   locator,
                   "query Viewer { viewer { login } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 502}}
                   end
                 )
      end)

    assert log =~ "body=:unknown"
  end

  test "github graphql client rejects missing token" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: " ",
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    assert {:error, {:github_api_request, :missing_github_project_api_token}} =
             Client.graphql(locator, "query Viewer { viewer { login } }", %{}, request_fun: fn _, _ -> :ok end)
  end

  test "github graphql client handles non-binary tokens" do
    locator = %ProjectLocator{
      endpoint: "https://api.github.com/graphql",
      token: nil,
      owner: "octo-org",
      owner_type: :organization,
      project_number: 1,
      status_field_name: "Status"
    }

    assert {:error, {:github_api_request, :missing_github_project_api_token}} =
             Client.graphql(locator, "query Viewer { viewer { login } }", %{}, request_fun: fn _, _ -> :ok end)
  end
end
