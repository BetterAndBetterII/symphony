defmodule SymphonyElixir.DefaultWorkflowTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, DefaultWorkflow, Workflow}

  test "writes a valid default workflow once required env vars are present" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_path = Path.join(System.tmp_dir!(), "default-workflow-#{System.unique_integer([:positive])}.md")

    env_keys = [
      "GITHUB_TOKEN",
      "GITHUB_PROJECT_OWNER",
      "GITHUB_PROJECT_NUMBER",
      "SOURCE_REPO_URL",
      "SYMPHONY_WORKSPACE_ROOT"
    ]

    previous_env = Map.new(env_keys, fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm(workflow_path)

      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env("GITHUB_TOKEN", "token-123")
    System.put_env("GITHUB_PROJECT_OWNER", "example-org")
    System.put_env("GITHUB_PROJECT_NUMBER", "42")
    System.put_env("SOURCE_REPO_URL", "git@github.com:example-org/example-repo.git")
    System.put_env("SYMPHONY_WORKSPACE_ROOT", Path.join(System.tmp_dir!(), "default-workflow-root"))

    assert :ok = DefaultWorkflow.write(workflow_path)
    assert File.read!(workflow_path) == DefaultWorkflow.contents()

    assert :ok = Workflow.set_workflow_file_path(workflow_path)
    assert {:ok, workflow} = Workflow.current()
    assert get_in(workflow, [:config, "tracker", "kind"]) == "github_project"
    assert workflow.prompt =~ "You are working on an issue from the configured tracker."
    assert :ok = Config.validate!()
  end
end
