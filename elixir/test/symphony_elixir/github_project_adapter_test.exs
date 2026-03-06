defmodule SymphonyElixir.GitHub.Project.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Project.Adapter
  alias SymphonyElixir.Tracker.{Issue, StateCount}

  defmodule FakeGitHubClient do
    def graphql(query, variables \\ %{}, _opts \\ []) do
      responder = Process.get({__MODULE__, :responder})

      if is_function(responder, 2) do
        responder.(query, variables)
      else
        {:error, :missing_responder}
      end
    end
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :github_client_module)
    previous_token = System.get_env("GITHUB_TOKEN")

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    System.put_env("GITHUB_TOKEN", "token-123")

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, previous_client)
      end

      restore_env("GITHUB_TOKEN", previous_token)
      Process.delete({FakeGitHubClient, :responder})
    end)

    :ok
  end

  test "fetch_candidate_issues normalizes ProjectV2 items into tracker issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github_project",
      tracker_project_owner: "octo-org",
      tracker_project_number: 1,
      tracker_project_field_status: "Status",
      tracker_active_states: ["Todo", "In Progress"]
    )

    Process.put({FakeGitHubClient, :responder}, fn query, variables ->
      send(self(), {:graphql_called, query, variables})

      if String.contains?(query, "SymphonyGitHubProjectItems(") do
        {:ok,
         %{
           "data" => %{
             "repositoryOwner" => %{
               "__typename" => "Organization",
               "projectV2" => %{
                 "id" => "proj_1",
                 "items" => %{
                   "nodes" => [
                     %{
                       "id" => "item_1",
                       "fieldValues" => %{
                         "nodes" => [
                           %{
                             "__typename" => "ProjectV2ItemFieldSingleSelectValue",
                             "name" => "Todo",
                             "optionId" => "opt_todo",
                             "field" => %{
                               "__typename" => "ProjectV2SingleSelectField",
                               "id" => "fld_status",
                               "name" => "Status"
                             }
                           }
                         ]
                       },
                       "content" => %{
                         "__typename" => "Issue",
                         "id" => "issue_node_1",
                         "number" => 123,
                         "title" => "Fix the thing",
                         "body" => "Work details",
                         "url" => "https://github.com/octo/repo/issues/123",
                         "createdAt" => "2026-01-01T00:00:00Z",
                         "updatedAt" => "2026-01-02T00:00:00Z",
                         "repository" => %{"nameWithOwner" => "octo/repo"},
                         "labels" => %{"nodes" => [%{"name" => "Bug"}, %{"name" => "Enhancement"}]},
                         "assignees" => %{"nodes" => [%{"login" => "me"}]}
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      else
        flunk("Unexpected GitHub query: #{inspect(query)}")
      end
    end)

    assert {:ok, [%Issue{} = issue]} = Adapter.fetch_candidate_issues()
    assert issue.id == "item_1"
    assert issue.identifier == "octo/repo#123"
    assert issue.title == "Fix the thing"
    assert issue.description == "Work details"
    assert issue.state == "Todo"
    assert issue.url == "https://github.com/octo/repo/issues/123"
    assert issue.labels == ["bug", "enhancement"]
    assert issue.assignee_id == "me"
    assert issue.assigned_to_worker == true
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    assert_received {:graphql_called, query, variables}
    assert String.contains?(query, "SymphonyGitHubProjectItems(")
    assert variables[:owner] == "octo-org"
    assert variables[:number] == 1
  end

  test "create_comment adds a comment to the underlying GitHub issue content" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github_project",
      tracker_project_owner: "octo-org",
      tracker_project_number: 1
    )

    Process.put({FakeGitHubClient, :responder}, fn query, variables ->
      send(self(), {:graphql_called, query, variables})

      cond do
        String.contains?(query, "SymphonyGitHubProjectItemsById(") ->
          {:ok,
           %{
             "data" => %{
               "nodes" => [
                 %{
                   "__typename" => "ProjectV2Item",
                   "id" => "item_1",
                   "fieldValues" => %{"nodes" => []},
                   "content" => %{"__typename" => "Issue", "id" => "issue_node_1"}
                 }
               ]
             }
           }}

        String.contains?(query, "SymphonyGitHubAddComment(") ->
          assert variables[:subjectId] == "issue_node_1"
          assert variables[:body] == "hello"

          {:ok,
           %{
             "data" => %{
               "addComment" => %{
                 "commentEdge" => %{
                   "node" => %{"id" => "comment_1", "url" => "https://github.com/comment/1"}
                 }
               }
             }
           }}

        true ->
          flunk("Unexpected GitHub query: #{inspect(query)}")
      end
    end)

    assert :ok = Adapter.create_comment("item_1", "hello")

    assert_received {:graphql_called, query, _vars}
    assert String.contains?(query, "SymphonyGitHubProjectItemsById(")

    assert_received {:graphql_called, query, _vars}
    assert String.contains?(query, "SymphonyGitHubAddComment(")
  end

  test "update_issue_state updates the ProjectV2 status field value by item id" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github_project",
      tracker_project_owner: "octo-org",
      tracker_project_number: 1,
      tracker_project_field_status: "Status"
    )

    Process.put({FakeGitHubClient, :responder}, fn query, variables ->
      send(self(), {:graphql_called, query, variables})

      cond do
        String.contains?(query, "SymphonyGitHubProjectFields(") ->
          {:ok,
           %{
             "data" => %{
               "repositoryOwner" => %{
                 "__typename" => "Organization",
                 "projectV2" => %{
                   "id" => "proj_1",
                   "fields" => %{
                     "nodes" => [
                       %{
                         "__typename" => "ProjectV2SingleSelectField",
                         "id" => "fld_status",
                         "name" => "Status",
                         "options" => [
                           %{"id" => "opt_todo", "name" => "Todo"},
                           %{"id" => "opt_in_progress", "name" => "In Progress"}
                         ]
                       }
                     ]
                   }
                 }
               }
             }
           }}

        String.contains?(query, "SymphonyGitHubUpdateStatus(") ->
          assert variables[:projectId] == "proj_1"
          assert variables[:itemId] == "item_1"
          assert variables[:fieldId] == "fld_status"
          assert variables[:optionId] == "opt_in_progress"

          {:ok,
           %{
             "data" => %{
               "updateProjectV2ItemFieldValue" => %{
                 "projectV2Item" => %{"id" => "item_1"}
               }
             }
           }}

        true ->
          flunk("Unexpected GitHub query: #{inspect(query)}")
      end
    end)

    assert :ok = Adapter.update_issue_state("item_1", "In Progress")

    assert_received {:graphql_called, query, _vars}
    assert String.contains?(query, "SymphonyGitHubProjectFields(")

    assert_received {:graphql_called, query, _vars}
    assert String.contains?(query, "SymphonyGitHubUpdateStatus(")
  end

  test "fetch_state_counts returns ordered project status counts including zeros" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github_project",
      tracker_project_owner: "octo-org",
      tracker_project_number: 1,
      tracker_project_field_status: "Status"
    )

    Process.put({FakeGitHubClient, :responder}, fn query, variables ->
      send(self(), {:graphql_called, query, variables})

      cond do
        String.contains?(query, "SymphonyGitHubProjectFields(") ->
          {:ok,
           %{
             "data" => %{
               "repositoryOwner" => %{
                 "__typename" => "Organization",
                 "projectV2" => %{
                   "fields" => %{
                     "nodes" => [
                       %{
                         "__typename" => "ProjectV2SingleSelectField",
                         "id" => "fld_status",
                         "name" => "Status",
                         "options" => [
                           %{"id" => "opt_todo", "name" => "Todo"},
                           %{"id" => "opt_in_progress", "name" => "In Progress"},
                           %{"id" => "opt_done", "name" => "Done"}
                         ]
                       }
                     ]
                   }
                 }
               }
             }
           }}

        String.contains?(query, "SymphonyGitHubProjectItemStates(") ->
          {:ok,
           %{
             "data" => %{
               "repositoryOwner" => %{
                 "__typename" => "Organization",
                 "projectV2" => %{
                   "items" => %{
                     "nodes" => [
                       %{
                         "id" => "item_1",
                         "fieldValues" => %{
                           "nodes" => [
                             %{
                               "__typename" => "ProjectV2ItemFieldSingleSelectValue",
                               "name" => "Todo",
                               "field" => %{
                                 "__typename" => "ProjectV2SingleSelectField",
                                 "name" => "Status"
                               }
                             }
                           ]
                         },
                         "content" => %{"__typename" => "Issue"}
                       },
                       %{
                         "id" => "item_2",
                         "fieldValues" => %{
                           "nodes" => [
                             %{
                               "__typename" => "ProjectV2ItemFieldSingleSelectValue",
                               "name" => "Done",
                               "field" => %{
                                 "__typename" => "ProjectV2SingleSelectField",
                                 "name" => "Status"
                               }
                             }
                           ]
                         },
                         "content" => %{"__typename" => "Issue"}
                       },
                       %{
                         "id" => "item_3",
                         "fieldValues" => %{
                           "nodes" => [
                             %{
                               "__typename" => "ProjectV2ItemFieldSingleSelectValue",
                               "name" => "Todo",
                               "field" => %{
                                 "__typename" => "ProjectV2SingleSelectField",
                                 "name" => "Status"
                               }
                             }
                           ]
                         },
                         "content" => %{"__typename" => "Issue"}
                       }
                     ],
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                   }
                 }
               }
             }
           }}

        true ->
          flunk("Unexpected GitHub query: #{inspect(query)}")
      end
    end)

    assert {:ok,
            [
              %StateCount{name: "Todo", count: 2},
              %StateCount{name: "In Progress", count: 0},
              %StateCount{name: "Done", count: 1}
            ]} = Adapter.fetch_state_counts()

    assert_received {:graphql_called, query, _vars}
    assert String.contains?(query, "SymphonyGitHubProjectFields(")

    assert_received {:graphql_called, query, _vars}
    assert String.contains?(query, "SymphonyGitHubProjectItemStates(")
  end
end
