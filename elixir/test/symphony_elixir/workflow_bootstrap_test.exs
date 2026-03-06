defmodule SymphonyElixir.WorkflowBootstrapTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DefaultWorkflow.Bootstrap

  test "guided bootstrap can select an existing project and reconcile the status field" do
    parent = self()
    set_bootstrap_inputs(["1\n", "1\n", "1\n", "1\n"])

    github_query_fun = fn _query, variables, opts ->
      send(parent, {:graphql_call, opts[:operation_name], variables, opts})

      case opts[:operation_name] do
        "WorkflowBootstrapViewerProjects" ->
          {:ok,
           %{
             "data" => %{
               "viewer" => %{
                 "id" => "viewer-id",
                 "login" => "viewer-user",
                 "viewerCanCreateProjects" => true,
                 "projectsV2" => %{
                   "nodes" => [
                     %{
                       "id" => "project-1",
                       "number" => 1,
                       "title" => "Shipping Board",
                       "url" => "https://github.com/users/viewer-user/projects/1"
                     }
                   ]
                 }
               }
             }
           }}

        "WorkflowBootstrapOrganizationProjects" ->
          {:ok,
           %{
             "data" => %{
               "viewer" => %{
                 "organizations" => %{
                   "nodes" => [
                     %{
                       "id" => "org-1",
                       "login" => "octo-org",
                       "viewerCanCreateProjects" => false,
                       "projectsV2" => %{"nodes" => []}
                     }
                   ]
                 }
               }
             }
           }}

        "WorkflowBootstrapProjectFields" ->
          {:ok,
           %{
             "data" => %{
               "repositoryOwner" => %{
                 "projectV2" => %{
                   "id" => "project-node-1",
                   "fields" => %{
                     "nodes" => [
                       %{
                         "__typename" => "ProjectV2SingleSelectField",
                         "id" => "status-field-1",
                         "name" => "Status",
                         "options" => [
                           %{
                             "name" => "Todo",
                             "color" => "BLUE",
                             "description" => "Existing Todo"
                           },
                           %{
                             "name" => "Needs Design",
                             "color" => "PURPLE",
                             "description" => "Keep me"
                           }
                         ]
                       }
                     ]
                   }
                 }
               }
             }
           }}

        "WorkflowBootstrapUpdateStatusField" ->
          assert opts[:token] == "token-123"
          assert variables[:fieldId] == "status-field-1"

          option_names = Enum.map(variables[:options], & &1.name)
          assert option_names == Bootstrap.required_status_names() ++ ["Needs Design"]

          {:ok,
           %{
             "data" => %{
               "updateProjectV2Field" => %{
                 "projectV2Field" => %{"name" => "Status"}
               }
             }
           }}
      end
    end

    assert {:ok, contents} =
             Bootstrap.run(
               gets: &scripted_gets/1,
               puts: &scripted_puts/1,
               env_getter: env_getter(%{"GITHUB_TOKEN" => "token-123"}),
               github_query_fun: github_query_fun
             )

    assert contents =~ ~s(project_owner: "viewer-user")
    assert contents =~ "project_number: 1"
    assert contents =~ ~s(approval_policy: "untrusted")
    assert contents =~ ~s(thread_sandbox: "workspace-write")
    assert contents =~ "`Backlog` remains available for manual triage"

    assert_received {:graphql_call, "WorkflowBootstrapViewerProjects", _variables, _opts}
    assert_received {:graphql_call, "WorkflowBootstrapOrganizationProjects", _variables, _opts}
    assert_received {:graphql_call, "WorkflowBootstrapProjectFields", _variables, _opts}
    assert_received {:graphql_call, "WorkflowBootstrapUpdateStatusField", _variables, _opts}
  end

  test "guided bootstrap can create a new project and initialize the status field" do
    parent = self()
    set_bootstrap_inputs(["1\n", "1\n", "1\n", "Team Launch Board\n", "4\n", "3\n"])

    github_query_fun = fn _query, variables, opts ->
      send(parent, {:graphql_call, opts[:operation_name], variables})

      case opts[:operation_name] do
        "WorkflowBootstrapViewerProjects" ->
          {:ok,
           %{
             "data" => %{
               "viewer" => %{
                 "id" => "viewer-id",
                 "login" => "viewer-user",
                 "viewerCanCreateProjects" => true,
                 "projectsV2" => %{"nodes" => []}
               }
             }
           }}

        "WorkflowBootstrapOrganizationProjects" ->
          {:ok, %{"data" => %{"viewer" => %{"organizations" => %{"nodes" => []}}}}}

        "WorkflowBootstrapCreateProject" ->
          assert variables[:ownerId] == "viewer-id"
          assert variables[:title] == "Team Launch Board"

          {:ok,
           %{
             "data" => %{
               "createProjectV2" => %{
                 "projectV2" => %{
                   "id" => "project-7",
                   "number" => 7,
                   "title" => "Team Launch Board",
                   "url" => "https://github.com/users/viewer-user/projects/7"
                 }
               }
             }
           }}

        "WorkflowBootstrapProjectFields" ->
          {:ok,
           %{
             "data" => %{
               "repositoryOwner" => %{
                 "projectV2" => %{
                   "id" => "project-7",
                   "fields" => %{"nodes" => []}
                 }
               }
             }
           }}

        "WorkflowBootstrapCreateStatusField" ->
          assert variables[:projectId] == "project-7"
          assert Enum.map(variables[:options], & &1.name) == Bootstrap.required_status_names()

          {:ok,
           %{
             "data" => %{
               "createProjectV2Field" => %{
                 "projectV2Field" => %{"name" => "Status"}
               }
             }
           }}
      end
    end

    assert {:ok, contents} =
             Bootstrap.run(
               gets: &scripted_gets/1,
               puts: &scripted_puts/1,
               env_getter: env_getter(%{"GITHUB_TOKEN" => "token-123"}),
               github_query_fun: github_query_fun
             )

    assert contents =~ ~s(project_owner: "viewer-user")
    assert contents =~ "project_number: 7"
    assert contents =~ ~s(approval_policy: "never")
    assert contents =~ ~s(thread_sandbox: "danger-full-access")

    assert_received {:graphql_call, "WorkflowBootstrapCreateProject", _variables}
    assert_received {:graphql_call, "WorkflowBootstrapCreateStatusField", _variables}
  end

  test "guided bootstrap surfaces missing auth guidance before writing a workflow" do
    set_bootstrap_inputs(["1\n"])

    github_cli_runner = fn "gh", ["auth", "status", "--hostname", "github.com", "--json", "hosts"], _opts ->
      {:ok, ~s({"hosts":{}})}
    end

    assert {:error, message} =
             Bootstrap.run(
               gets: &scripted_gets/1,
               puts: &scripted_puts/1,
               env_getter: env_getter(%{}),
               github_cli_runner: github_cli_runner
             )

    assert message =~ "gh auth login --hostname github.com --scopes repo,project,read:org"
  end

  test "guided bootstrap reports permission failures with operation context" do
    set_bootstrap_inputs(["1\n"])

    github_query_fun = fn _query, _variables, opts ->
      case opts[:operation_name] do
        "WorkflowBootstrapViewerProjects" ->
          {:ok,
           %{
             "data" => %{
               "viewer" => %{
                 "id" => "viewer-id",
                 "login" => "viewer-user",
                 "viewerCanCreateProjects" => false,
                 "projectsV2" => %{"nodes" => []}
               }
             }
           }}

        "WorkflowBootstrapOrganizationProjects" ->
          {:ok, %{"errors" => [%{"type" => "FORBIDDEN", "message" => "denied"}]}}
      end
    end

    assert {:error, message} =
             Bootstrap.run(
               gets: &scripted_gets/1,
               puts: &scripted_puts/1,
               env_getter: env_getter(%{"GITHUB_TOKEN" => "token-123"}),
               github_query_fun: github_query_fun
             )

    assert message =~ "GitHub denied the listing organization-owned GitHub Projects operation"
  end

  test "guided bootstrap reports GitHub API status failures with the failing operation" do
    set_bootstrap_inputs(["1\n", "1\n"])

    github_query_fun = fn _query, _variables, opts ->
      case opts[:operation_name] do
        "WorkflowBootstrapViewerProjects" ->
          {:ok,
           %{
             "data" => %{
               "viewer" => %{
                 "id" => "viewer-id",
                 "login" => "viewer-user",
                 "viewerCanCreateProjects" => false,
                 "projectsV2" => %{
                   "nodes" => [
                     %{
                       "id" => "project-1",
                       "number" => 1,
                       "title" => "Shipping Board",
                       "url" => "https://github.com/users/viewer-user/projects/1"
                     }
                   ]
                 }
               }
             }
           }}

        "WorkflowBootstrapOrganizationProjects" ->
          {:ok, %{"data" => %{"viewer" => %{"organizations" => %{"nodes" => []}}}}}

        "WorkflowBootstrapProjectFields" ->
          {:error, {:github_api_status, 502}}
      end
    end

    assert {:error, message} =
             Bootstrap.run(
               gets: &scripted_gets/1,
               puts: &scripted_puts/1,
               env_getter: env_getter(%{"GITHUB_TOKEN" => "token-123"}),
               github_query_fun: github_query_fun
             )

    assert message == "GitHub returned HTTP 502 while loading status fields for viewer-user#1."
  end

  defp env_getter(env) do
    fn key -> Map.get(env, key) end
  end

  defp set_bootstrap_inputs(inputs) do
    Process.put(:workflow_bootstrap_inputs, inputs)
  end

  defp scripted_gets(prompt) do
    send(self(), {:prompt, prompt})

    case Process.get(:workflow_bootstrap_inputs, []) do
      [next | rest] ->
        Process.put(:workflow_bootstrap_inputs, rest)
        next

      [] ->
        nil
    end
  end

  defp scripted_puts(message) do
    send(self(), {:output, message})
    :ok
  end
end
