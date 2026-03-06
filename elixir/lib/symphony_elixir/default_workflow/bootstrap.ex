defmodule SymphonyElixir.DefaultWorkflow.Bootstrap do
  @moduledoc false

  alias SymphonyElixir.Config.GitHubAuth
  alias SymphonyElixir.GitHub.Client

  @github_endpoint "https://api.github.com/graphql"
  @github_api_key "$GITHUB_TOKEN"
  @status_field_name "Status"
  @project_list_limit 50
  @organization_list_limit 50
  @required_gh_scopes ["project", "repo", "read:org"]
  @guided_active_states ["Todo", "Spec", "In Progress", "Rework", "In Review", "Merging"]
  @guided_terminal_states ["Done", "Canceled", "Duplicated"]
  @required_status_options [
    %{name: "Backlog", color: "GRAY", description: "Manual triage before automation."},
    %{name: "Todo", color: "BLUE", description: "Ready for an agent to pick up."},
    %{name: "Spec", color: "YELLOW", description: "Specification or planning is in progress."},
    %{name: "In Progress", color: "ORANGE", description: "Implementation is actively underway."},
    %{name: "Rework", color: "RED", description: "Feedback requires additional changes."},
    %{name: "In Review", color: "PURPLE", description: "Waiting for human review."},
    %{name: "Merging", color: "PINK", description: "Approved and landing the change."},
    %{name: "Done", color: "GREEN", description: "Completed successfully."},
    %{name: "Canceled", color: "GRAY", description: "Stopped without completing the work."},
    %{name: "Duplicated", color: "GRAY", description: "Superseded by another item."}
  ]
  @approval_options [
    %{value: "untrusted", label: "Untrusted (recommended)", description: "Ask for approval before running risky commands."},
    %{value: "on-failure", label: "On-failure", description: "Retry outside the sandbox only after a sandbox failure."},
    %{value: "on-request", label: "On-request", description: "Let the agent request elevated access when needed."},
    %{value: "never", label: "Never", description: "Run unattended without asking for approvals."}
  ]
  @sandbox_options [
    %{value: "workspace-write", label: "Workspace-write (recommended)", description: "Allow edits in the issue workspace while keeping broader access constrained."},
    %{value: "read-only", label: "Read-only", description: "Inspect files without allowing writes by default."},
    %{value: "danger-full-access", label: "Danger-full-access", description: "Allow unrestricted filesystem access for the session."}
  ]

  @viewer_projects_query """
  query WorkflowBootstrapViewerProjects($projectsFirst: Int!) {
    viewer {
      id
      login
      viewerCanCreateProjects
      projectsV2(first: $projectsFirst) {
        nodes {
          id
          number
          title
          url
        }
      }
    }
  }
  """

  @organization_projects_query """
  query WorkflowBootstrapOrganizationProjects($ownersFirst: Int!, $projectsFirst: Int!) {
    viewer {
      organizations(first: $ownersFirst) {
        nodes {
          id
          login
          viewerCanCreateProjects
          projectsV2(first: $projectsFirst) {
            nodes {
              id
              number
              title
              url
            }
          }
        }
      }
    }
  }
  """

  @project_fields_query """
  query WorkflowBootstrapProjectFields($owner: String!, $number: Int!, $fieldsFirst: Int!) {
    repositoryOwner(login: $owner) {
      __typename
      ... on Organization {
        projectV2(number: $number) {
          id
          fields(first: $fieldsFirst) {
            nodes {
              __typename
              ... on ProjectV2SingleSelectField {
                id
                name
                options {
                  name
                  color
                  description
                }
              }
            }
          }
        }
      }
      ... on User {
        projectV2(number: $number) {
          id
          fields(first: $fieldsFirst) {
            nodes {
              __typename
              ... on ProjectV2SingleSelectField {
                id
                name
                options {
                  name
                  color
                  description
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @create_project_mutation """
  mutation WorkflowBootstrapCreateProject($ownerId: ID!, $title: String!) {
    createProjectV2(input: {ownerId: $ownerId, title: $title}) {
      projectV2 {
        id
        number
        title
        url
      }
    }
  }
  """

  @create_field_mutation """
  mutation WorkflowBootstrapCreateStatusField(
    $projectId: ID!
    $fieldName: String!
    $options: [ProjectV2SingleSelectFieldOptionInput!]
  ) {
    createProjectV2Field(
      input: {
        projectId: $projectId
        dataType: SINGLE_SELECT
        name: $fieldName
        singleSelectOptions: $options
      }
    ) {
      projectV2Field {
        ... on ProjectV2SingleSelectField {
          id
          name
        }
      }
    }
  }
  """

  @update_field_mutation """
  mutation WorkflowBootstrapUpdateStatusField(
    $fieldId: ID!
    $options: [ProjectV2SingleSelectFieldOptionInput!]
  ) {
    updateProjectV2Field(input: {fieldId: $fieldId, singleSelectOptions: $options}) {
      projectV2Field {
        ... on ProjectV2SingleSelectField {
          id
          name
        }
      }
    }
  }
  """

  defmodule Owner do
    @moduledoc false

    @enforce_keys [:id, :login, :kind, :can_create_projects]
    defstruct [:id, :login, :kind, :can_create_projects, projects: []]

    @type t :: %__MODULE__{
            id: String.t(),
            login: String.t(),
            kind: :user | :organization,
            can_create_projects: boolean(),
            projects: [SymphonyElixir.DefaultWorkflow.Bootstrap.Project.t()]
          }
  end

  defmodule Project do
    @moduledoc false

    @enforce_keys [:id, :owner_login, :number, :title, :url]
    defstruct [:id, :owner_login, :number, :title, :url]

    @type t :: %__MODULE__{
            id: String.t(),
            owner_login: String.t(),
            number: pos_integer(),
            title: String.t(),
            url: String.t()
          }
  end

  defmodule GuidedWorkflow do
    @moduledoc false

    @enforce_keys [:project, :status_field_name, :approval_policy, :thread_sandbox]
    defstruct [:project, :status_field_name, :approval_policy, :thread_sandbox]

    @type t :: %__MODULE__{
            project: SymphonyElixir.DefaultWorkflow.Bootstrap.Project.t(),
            status_field_name: String.t(),
            approval_policy: String.t(),
            thread_sandbox: String.t()
          }
  end

  @type bootstrap_result :: {:ok, String.t()} | {:error, String.t()}
  @type query_fun :: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})
  @type prompt_io :: %{gets: (String.t() -> String.t() | nil), puts: (String.t() -> term())}

  @spec run(keyword()) :: bootstrap_result()
  def run(opts \\ []) do
    io = prompt_io(opts)

    case choose_bootstrap_mode(io) do
      {:ok, mode} -> build_contents(mode, io, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec guided_active_states() :: [String.t()]
  def guided_active_states, do: @guided_active_states

  @spec guided_terminal_states() :: [String.t()]
  def guided_terminal_states, do: @guided_terminal_states

  @spec required_status_names() :: [String.t()]
  def required_status_names do
    Enum.map(@required_status_options, & &1.name)
  end

  @spec render_guided_workflow(GuidedWorkflow.t()) :: String.t()
  def render_guided_workflow(%GuidedWorkflow{} = workflow) do
    [
      "---",
      "tracker:",
      "  kind: github_project",
      "  endpoint: #{yaml_scalar(@github_endpoint)}",
      "  api_key: #{yaml_scalar(@github_api_key)}",
      "  project_owner: #{yaml_scalar(workflow.project.owner_login)}",
      "  project_number: #{workflow.project.number}",
      "  project_field_status: #{yaml_scalar(workflow.status_field_name)}",
      yaml_list("  active_states:", @guided_active_states),
      yaml_list("  terminal_states:", @guided_terminal_states),
      "polling:",
      "  interval_ms: 5000",
      "workspace:",
      "  root: $SYMPHONY_WORKSPACE_ROOT",
      "hooks:",
      "  after_create: |",
      "    git clone --depth 1 \"$SOURCE_REPO_URL\" .",
      "agent:",
      "  max_concurrent_agents: 10",
      "  max_turns: 20",
      "codex:",
      "  command: codex app-server",
      "  approval_policy: #{yaml_scalar(workflow.approval_policy)}",
      "  thread_sandbox: #{yaml_scalar(workflow.thread_sandbox)}",
      "server:",
      "  port: 0",
      "  host: 127.0.0.1",
      "---",
      "",
      "This WORKFLOW.md was bootstrapped for GitHub Project `#{workflow.project.owner_login}##{workflow.project.number}` (#{workflow.project.title}).",
      "",
      "Set these environment variables before running Symphony against your repo:",
      "",
      "- `GITHUB_TOKEN`: GitHub token with access to the project and repository.",
      "- `SOURCE_REPO_URL`: repository clone URL used for new workspaces.",
      "- `SYMPHONY_WORKSPACE_ROOT`: directory for local issue workspaces.",
      "- GitHub Project URL: #{workflow.project.url}",
      "- Status field `#{workflow.status_field_name}` includes `#{Enum.join(required_status_names(), "`, `")}`. `Backlog` remains available for manual triage and is intentionally excluded from `tracker.active_states` until work is ready for automation.",
      "",
      "You are working on an issue from the configured tracker.",
      "",
      "Identifier: {{ issue.identifier }}",
      "Title: {{ issue.title }}",
      "",
      "Body:",
      "{% if issue.description %}",
      "{{ issue.description }}",
      "{% else %}",
      "No description provided.",
      "{% endif %}",
      ""
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp build_contents(:baseline_template, _io, _opts) do
    {:ok, SymphonyElixir.DefaultWorkflow.contents()}
  end

  defp build_contents(:cancel, _io, _opts) do
    {:error, "Canceled WORKFLOW.md bootstrap before creating a file."}
  end

  defp build_contents(:guided_github, io, opts) do
    with {:ok, auth} <- resolve_auth(opts),
         {:ok, %{owners: owners, projects: projects}} <- fetch_accessible_projects(auth, opts),
         {:ok, project} <- choose_project(io, owners, projects, auth, opts),
         {:ok, status_field_name} <- ensure_status_field(project, auth, opts),
         {:ok, approval_policy} <- choose_approval_policy(io),
         {:ok, thread_sandbox} <- choose_thread_sandbox(io) do
      {:ok,
       render_guided_workflow(%GuidedWorkflow{
         project: project,
         status_field_name: status_field_name,
         approval_policy: approval_policy,
         thread_sandbox: thread_sandbox
       })}
    end
  end

  defp choose_bootstrap_mode(io) do
    choose_option(
      io,
      "Choose how to create WORKFLOW.md:",
      [
        %{value: :guided_github, label: "Guided GitHub Project setup", description: "Discover or create a GitHub Project and write a ready-to-run workflow."},
        %{value: :baseline_template, label: "Write the baseline template", description: "Create the non-interactive template and fill in the project details later."},
        %{value: :cancel, label: "Cancel startup", description: "Stop without writing WORKFLOW.md."}
      ]
    )
  end

  defp choose_project(io, owners, projects, auth, opts) do
    createable_owners = Enum.filter(owners, & &1.can_create_projects)

    project_options =
      Enum.map(projects, fn project ->
        %{
          value: {:existing, project},
          label: "#{project.owner_login}/#{project.title} (##{project.number})",
          description: project.url
        }
      end)

    options =
      if createable_owners == [] do
        project_options
      else
        project_options ++
          [
            %{
              value: :create_new,
              label: "Create a new GitHub Project",
              description: "Provision a new ProjectV2 board and configure Symphony status options."
            }
          ]
      end

    if options == [] do
      {:error,
       "Guided GitHub bootstrap could not find any accessible ProjectV2 boards, and the authenticated account cannot create one. Ensure the account can read or create GitHub Projects for the target owner."}
    else
      case choose_option(io, "Select the GitHub Project to write into WORKFLOW.md:", options) do
        {:ok, {:existing, project}} -> {:ok, project}
        {:ok, :create_new} -> create_project(io, createable_owners, auth, opts)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_project(io, owners, auth, opts) do
    with {:ok, owner} <- choose_owner(io, owners),
         {:ok, title} <- prompt_non_empty(io, "New GitHub Project title") do
      do_create_project(owner, title, auth, opts)
    end
  end

  defp choose_owner(io, owners) do
    owner_options =
      Enum.map(owners, fn owner ->
        %{
          value: owner,
          label: owner.login,
          description: owner_description(owner)
        }
      end)

    choose_option(io, "Choose the owner for the new GitHub Project:", owner_options)
  end

  defp owner_description(%Owner{kind: :user}), do: "Viewer-owned project"
  defp owner_description(%Owner{kind: :organization}), do: "Organization-owned project"

  defp choose_approval_policy(io) do
    choose_option(io, "Choose the default Codex approval policy:", @approval_options)
  end

  defp choose_thread_sandbox(io) do
    choose_option(io, "Choose the default Codex sandbox mode:", @sandbox_options)
  end

  defp resolve_auth(opts) do
    endpoint = github_endpoint(opts)
    host = github_cli_host(endpoint)
    env_getter = Keyword.get(opts, :env_getter, &System.get_env/1)

    cond do
      present_token?(env_getter.("GITHUB_TOKEN")) ->
        {:ok, %GitHubAuth{host: host, source: :explicit_config, token: String.trim(env_getter.("GITHUB_TOKEN"))}}

      present_token?(env_getter.("GH_TOKEN")) ->
        {:ok, %GitHubAuth{host: host, source: :explicit_config, token: String.trim(env_getter.("GH_TOKEN"))}}

      true ->
        runner = Keyword.get(opts, :github_cli_runner, &GitHubAuth.default_command_runner/3)

        case GitHubAuth.resolve_cli_token(host, runner: runner, required_scopes: @required_gh_scopes) do
          {:ok, %GitHubAuth{} = auth} -> {:ok, auth}
          {:error, reason} -> {:error, format_auth_error(reason, host)}
        end
    end
  end

  defp fetch_accessible_projects(%GitHubAuth{} = auth, opts) do
    with {:ok, viewer} <- fetch_viewer_projects(auth, opts),
         {:ok, organizations} <- fetch_organization_projects(auth, opts) do
      viewer_owner = %Owner{
        id: viewer.id,
        login: viewer.login,
        kind: :user,
        can_create_projects: viewer.can_create_projects
      }

      owners = [viewer_owner | organizations]

      projects =
        viewer.projects ++
          Enum.flat_map(organizations, fn owner ->
            Map.get(owner, :projects, [])
          end)

      {:ok, %{owners: owners, projects: projects}}
    end
  end

  defp fetch_viewer_projects(%GitHubAuth{} = auth, opts) do
    case github_query(
           @viewer_projects_query,
           %{projectsFirst: @project_list_limit},
           auth,
           opts,
           operation: :list_viewer_projects,
           operation_name: "WorkflowBootstrapViewerProjects"
         ) do
      {:ok, %{"data" => %{"viewer" => %{"id" => id, "login" => login} = viewer}}} ->
        {:ok,
         %{
           id: id,
           login: login,
           can_create_projects: Map.get(viewer, "viewerCanCreateProjects") == true,
           projects:
             viewer
             |> get_in(["projectsV2", "nodes"])
             |> normalize_projects(login)
         }}

      {:ok, _body} ->
        {:error, "GitHub returned an unexpected payload while listing viewer-owned projects."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_organization_projects(%GitHubAuth{} = auth, opts) do
    case github_query(
           @organization_projects_query,
           %{ownersFirst: @organization_list_limit, projectsFirst: @project_list_limit},
           auth,
           opts,
           operation: :list_organization_projects,
           operation_name: "WorkflowBootstrapOrganizationProjects"
         ) do
      {:ok, %{"data" => %{"viewer" => %{"organizations" => %{"nodes" => owners}}}}} when is_list(owners) ->
        {:ok,
         Enum.flat_map(owners, fn owner ->
           case normalize_owner(owner) do
             {:ok, normalized_owner} -> [normalized_owner]
             :error -> []
           end
         end)}

      {:ok, _body} ->
        {:error, "GitHub returned an unexpected payload while listing organization-owned projects."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_owner(%{"id" => id, "login" => login} = owner)
       when is_binary(id) and is_binary(login) do
    {:ok,
     %Owner{
       id: id,
       login: login,
       kind: :organization,
       can_create_projects: Map.get(owner, "viewerCanCreateProjects") == true,
       projects:
         owner
         |> get_in(["projectsV2", "nodes"])
         |> normalize_projects(login)
     }}
  end

  defp normalize_owner(_owner), do: :error

  defp normalize_projects(nodes, owner_login) when is_list(nodes) and is_binary(owner_login) do
    nodes
    |> Enum.map(fn
      %{"id" => id, "number" => number, "title" => title, "url" => url}
      when is_binary(id) and is_integer(number) and number > 0 and is_binary(title) and is_binary(url) ->
        %Project{id: id, owner_login: owner_login, number: number, title: title, url: url}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_projects(_nodes, _owner_login), do: []

  defp do_create_project(%Owner{} = owner, title, %GitHubAuth{} = auth, opts) do
    case github_query(
           @create_project_mutation,
           %{ownerId: owner.id, title: title},
           auth,
           opts,
           operation: {:create_project, owner.login},
           operation_name: "WorkflowBootstrapCreateProject"
         ) do
      {:ok, %{"data" => %{"createProjectV2" => %{"projectV2" => project}}}} ->
        parse_created_project(project, owner.login)

      {:ok, _body} ->
        unexpected_project_create_payload()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_created_project(project, owner_login) when is_binary(owner_login) do
    case project do
      %{"id" => id, "number" => number, "title" => created_title, "url" => url}
      when is_binary(id) and is_integer(number) and number > 0 and is_binary(created_title) and
             is_binary(url) ->
        {:ok,
         %Project{
           id: id,
           owner_login: owner_login,
           number: number,
           title: created_title,
           url: url
         }}

      _ ->
        unexpected_project_create_payload()
    end
  end

  defp unexpected_project_create_payload do
    {:error, "GitHub returned an unexpected payload after creating the ProjectV2 board."}
  end

  defp ensure_status_field(%Project{} = project, %GitHubAuth{} = auth, opts) do
    with {:ok, %{project_id: project_id, fields: fields}} <- fetch_project_fields(project, auth, opts) do
      case find_status_field(fields) do
        %{id: field_id, name: field_name, options: options} ->
          merged_options = merge_status_options(options)
          maybe_update_status_field(field_id, field_name, options, merged_options, project, auth, opts)

        nil ->
          create_status_field(project_id, project, auth, opts)
      end
    end
  end

  defp fetch_project_fields(%Project{} = project, %GitHubAuth{} = auth, opts) do
    case github_query(
           @project_fields_query,
           %{owner: project.owner_login, number: project.number, fieldsFirst: @project_list_limit},
           auth,
           opts,
           operation: {:fetch_project_fields, project.owner_login, project.number},
           operation_name: "WorkflowBootstrapProjectFields"
         ) do
      {:ok, %{"data" => %{"repositoryOwner" => %{"projectV2" => %{"id" => project_id, "fields" => %{"nodes" => nodes}}}}}}
      when is_binary(project_id) and is_list(nodes) ->
        {:ok, %{project_id: project_id, fields: normalize_fields(nodes)}}

      {:ok, _body} ->
        {:error, "GitHub returned an unexpected payload while loading ProjectV2 fields."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_fields(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      %{"__typename" => "ProjectV2SingleSelectField", "id" => id, "name" => name, "options" => options}
      when is_binary(id) and is_binary(name) and is_list(options) ->
        [
          %{
            id: id,
            name: name,
            options: normalize_field_options(options)
          }
        ]

      _ ->
        []
    end)
  end

  defp normalize_field_options(options) when is_list(options) do
    Enum.flat_map(options, fn
      %{"name" => name, "color" => color, "description" => description}
      when is_binary(name) and is_binary(color) and is_binary(description) ->
        [%{name: name, color: color, description: description}]

      _ ->
        []
    end)
  end

  defp find_status_field(fields) when is_list(fields) do
    desired_name = normalize_name(@status_field_name)

    Enum.find(fields, fn field ->
      normalize_name(field.name) == desired_name
    end)
  end

  defp merge_status_options(existing_options) when is_list(existing_options) do
    existing_by_name = Map.new(existing_options, fn option -> {normalize_name(option.name), option} end)
    canonical_names = MapSet.new(Enum.map(@required_status_options, &normalize_name(&1.name)))

    preserved_required =
      Enum.map(@required_status_options, fn option ->
        Map.get(existing_by_name, normalize_name(option.name), option)
      end)

    preserved_other =
      existing_options
      |> Enum.reject(fn option ->
        MapSet.member?(canonical_names, normalize_name(option.name))
      end)

    preserved_required ++ preserved_other
  end

  defp maybe_update_status_field(field_id, field_name, existing_options, merged_options, project, auth, opts) do
    if existing_options == merged_options do
      {:ok, field_name}
    else
      case github_query(
             @update_field_mutation,
             %{fieldId: field_id, options: Enum.map(merged_options, &field_option_input/1)},
             auth,
             opts,
             operation: {:update_status_field, project.owner_login, project.number},
             operation_name: "WorkflowBootstrapUpdateStatusField"
           ) do
        {:ok, %{"data" => %{"updateProjectV2Field" => %{"projectV2Field" => %{"name" => updated_name}}}}}
        when is_binary(updated_name) ->
          {:ok, updated_name}

        {:ok, _body} ->
          {:error, "GitHub returned an unexpected payload while updating the ProjectV2 status field."}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create_status_field(project_id, %Project{} = project, %GitHubAuth{} = auth, opts) do
    case github_query(
           @create_field_mutation,
           %{
             projectId: project_id,
             fieldName: @status_field_name,
             options: Enum.map(@required_status_options, &field_option_input/1)
           },
           auth,
           opts,
           operation: {:create_status_field, project.owner_login, project.number},
           operation_name: "WorkflowBootstrapCreateStatusField"
         ) do
      {:ok, %{"data" => %{"createProjectV2Field" => %{"projectV2Field" => %{"name" => field_name}}}}}
      when is_binary(field_name) ->
        {:ok, field_name}

      {:ok, _body} ->
        {:error, "GitHub returned an unexpected payload while creating the ProjectV2 status field."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp choose_option(io, prompt, options) when is_list(options) and options != [] do
    io.puts.(prompt)

    Enum.with_index(options, 1)
    |> Enum.each(fn {option, index} ->
      io.puts.("#{index}. #{option.label}")

      case Map.get(option, :description) do
        description when is_binary(description) and description != "" ->
          io.puts.("   #{description}")

        _ ->
          :ok
      end
    end)

    do_choose_option(io, options)
  end

  defp do_choose_option(io, options) do
    case io.gets.("Enter choice [1-#{length(options)}]: ") do
      nil ->
        {:error, "Canceled WORKFLOW.md bootstrap before creating a file."}

      raw ->
        case parse_menu_choice(raw, length(options)) do
          {:ok, index} ->
            {:ok, Enum.at(options, index - 1).value}

          {:error, message} ->
            io.puts.(message)
            do_choose_option(io, options)
        end
    end
  end

  defp prompt_non_empty(io, label) do
    case io.gets.(label <> ": ") do
      nil ->
        {:error, "Canceled WORKFLOW.md bootstrap before creating a file."}

      raw ->
        case parse_non_empty_text(raw, label) do
          {:ok, value} ->
            {:ok, value}

          {:error, message} ->
            io.puts.(message)
            prompt_non_empty(io, label)
        end
    end
  end

  defp parse_menu_choice(raw, option_count) when is_binary(raw) and option_count > 0 do
    trimmed = String.trim(raw)

    case Integer.parse(trimmed) do
      {index, ""} when index >= 1 and index <= option_count ->
        {:ok, index}

      _ ->
        {:error, "Enter a number between 1 and #{option_count}."}
    end
  end

  defp parse_non_empty_text(raw, label) when is_binary(raw) and is_binary(label) do
    case String.trim(raw) do
      "" -> {:error, "#{label} cannot be blank."}
      value -> {:ok, value}
    end
  end

  defp github_query(query, variables, %GitHubAuth{} = auth, opts, metadata) do
    query_fun = Keyword.get(opts, :github_query_fun, &Client.graphql/3)
    operation = Keyword.fetch!(metadata, :operation)
    operation_name = Keyword.fetch!(metadata, :operation_name)

    case query_fun.(query, variables, token: auth.token, endpoint: github_endpoint(opts), operation_name: operation_name) do
      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        {:error, format_graphql_error(operation, errors, auth.host)}

      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error, format_transport_error(operation, reason)}
    end
  end

  defp format_auth_error(reason, host) do
    case GitHubAuth.error_message(reason, host) do
      nil -> "Guided GitHub bootstrap could not resolve GitHub authentication."
      message -> message
    end
  end

  defp format_graphql_error(operation, errors, host) when is_list(errors) do
    condensed_errors = Enum.map(errors, &condense_graphql_error/1)

    cond do
      Enum.any?(condensed_errors, &(&1.type == "INSUFFICIENT_SCOPES")) ->
        "Guided GitHub bootstrap needs GitHub scopes `repo`, `project`, and `read:org`. Refresh auth with `gh auth refresh --hostname #{host} --scopes repo,project,read:org`, or update `GITHUB_TOKEN` / `GH_TOKEN` with those scopes."

      Enum.any?(condensed_errors, &(&1.type in ["FORBIDDEN", "UNAUTHORIZED"])) ->
        "GitHub denied the #{operation_label(operation)} operation. Ensure the authenticated principal can read and manage ProjectV2 boards for the selected owner."

      true ->
        detail = Enum.map_join(condensed_errors, "; ", & &1.message)
        "GitHub reported an error while #{operation_label(operation)}: #{detail}"
    end
  end

  defp format_transport_error(operation, {:github_api_status, status}) do
    "GitHub returned HTTP #{status} while #{operation_label(operation)}."
  end

  defp format_transport_error(operation, {:github_api_request, reason}) do
    "GitHub request failed while #{operation_label(operation)}: #{inspect(reason)}"
  end

  defp format_transport_error(operation, reason) do
    "GitHub request failed while #{operation_label(operation)}: #{inspect(reason)}"
  end

  defp condense_graphql_error(%{"message" => message} = error) when is_binary(message) do
    %{message: String.trim(message), type: Map.get(error, "type")}
  end

  defp condense_graphql_error(error) do
    %{message: inspect(error), type: nil}
  end

  defp operation_label(:list_viewer_projects), do: "listing viewer-owned GitHub Projects"
  defp operation_label(:list_organization_projects), do: "listing organization-owned GitHub Projects"
  defp operation_label({:create_project, owner_login}), do: "creating a GitHub Project for #{owner_login}"

  defp operation_label({:fetch_project_fields, owner_login, number}),
    do: "loading status fields for #{owner_login}##{number}"

  defp operation_label({:create_status_field, owner_login, number}),
    do: "creating the status field for #{owner_login}##{number}"

  defp operation_label({:update_status_field, owner_login, number}),
    do: "reconciling the status field for #{owner_login}##{number}"

  defp prompt_io(opts) do
    %{
      gets: Keyword.get(opts, :gets, &IO.gets/1),
      puts: Keyword.get(opts, :puts, &IO.puts/1)
    }
  end

  defp github_endpoint(opts) do
    Keyword.get(opts, :github_endpoint, @github_endpoint)
  end

  defp github_cli_host(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{host: "api.github.com"} -> "github.com"
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "github.com"
    end
  end

  defp present_token?(value) when is_binary(value) do
    String.trim(value) != ""
  end

  defp present_token?(_value), do: false

  defp field_option_input(option) do
    %{
      name: option.name,
      color: option_color_atom(option.color),
      description: option.description
    }
  end

  defp option_color_atom(color) when is_binary(color) do
    case String.downcase(String.trim(color)) do
      "blue" -> :BLUE
      "green" -> :GREEN
      "yellow" -> :YELLOW
      "orange" -> :ORANGE
      "red" -> :RED
      "pink" -> :PINK
      "purple" -> :PURPLE
      _ -> :GRAY
    end
  end

  defp option_color_atom(_color), do: :GRAY

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_name(_value), do: ""

  defp yaml_scalar(value) when is_binary(value) do
    escaped = String.replace(value, "\"", "\\\"")
    "\"#{escaped}\""
  end

  defp yaml_list(header, values) when is_list(values) do
    [header | Enum.map(values, &"    - #{yaml_scalar(&1)}")]
  end
end
