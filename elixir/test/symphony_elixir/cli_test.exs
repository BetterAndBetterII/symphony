defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  test "defaults to WORKFLOW.md when workflow path is missing and bootstraps it" do
    parent = self()

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        false
      end,
      write_default_workflow: fn path ->
        send(parent, {:workflow_bootstrapped, path})
        :ok
      end,
      notify: fn message ->
        send(parent, {:notified, message})
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([], deps)
    assert_received {:workflow_checked, expanded_path}
    assert_received {:workflow_bootstrapped, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
    assert_received {:notified, message}
    assert expanded_path == Path.expand("WORKFLOW.md")
    assert message =~ "Created default WORKFLOW.md"
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      write_default_workflow: fn _path ->
        send(parent, :unexpected_bootstrap)
        :ok
      end,
      notify: fn _message ->
        send(parent, :unexpected_notify)
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
    refute_received :unexpected_bootstrap
    refute_received :unexpected_notify
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      write_default_workflow: fn _path -> :ok end,
      notify: fn _message -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate(["--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when an explicit workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      write_default_workflow: fn _path -> :ok end,
      notify: fn _message -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      write_default_workflow: fn _path -> :ok end,
      notify: fn _message -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      write_default_workflow: fn _path -> :ok end,
      notify: fn _message -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate(["WORKFLOW.md"], deps)
  end
end
