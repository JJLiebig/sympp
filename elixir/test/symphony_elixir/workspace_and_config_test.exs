defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport

  test "workspace rejects symlink escapes under the configured root" do
    if symlink_supported?() do
      test_root = unique_tmp_path("symphony-elixir-workspace-symlink")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_root = Path.join(test_root, "outside")
        symlink_path = Path.join(workspace_root, "MT-SYM")

        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_root)
        File.ln_s!(outside_root, symlink_path)

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
        assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

        assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
                 Workspace.create_for_issue("MT-SYM")
      after
        File.rm_rf(test_root)
      end
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    if symlink_supported?() do
      test_root = unique_tmp_path("symphony-elixir-workspace-root-symlink")

      try do
        actual_root = Path.join(test_root, "actual-workspaces")
        linked_root = Path.join(test_root, "linked-workspaces")

        File.mkdir_p!(actual_root)
        File.ln_s!(actual_root, linked_root)

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

        assert {:ok, canonical_workspace} =
                 SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

        assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
        assert workspace == canonical_workspace
        assert File.dir?(workspace)
      after
        File.rm_rf(test_root)
      end
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace does not rerun after_create hook while one is in flight" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-in-flight-#{System.os_time(:nanosecond)}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      counter = Path.join(test_root, "after_create.count")
      gate = Path.join(test_root, "after_create.release")

      File.mkdir_p!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 5_000,
        hook_after_create: "echo call >> #{shell_path(counter)}\nwhile [ ! -f #{shell_path(gate)} ]; do sleep 0.05; done"
      )

      task = Task.async(fn -> Workspace.create_for_issue("MT-CONCURRENT") end)
      assert_eventually(fn -> File.exists?(counter) end)

      workspace = Path.join(workspace_root, "MT-CONCURRENT")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-CONCURRENT")

      File.write!(gate, "go")
      assert {:ok, ^canonical_workspace} = Task.await(task, 5_000)

      assert File.read!(counter) |> String.trim() |> String.split("\n") |> length() == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace failed after_create retry is claimed once" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-retry-claim-#{System.os_time(:nanosecond)}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      counter = Path.join(test_root, "after_create.count")
      block_retry = Path.join(test_root, "block_retry")
      gate = Path.join(test_root, "after_create.release")

      File.mkdir_p!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 5_000,
        hook_after_create: "echo call >> #{shell_path(counter)}\nif [ -f #{shell_path(block_retry)} ]; then while [ ! -f #{shell_path(gate)} ]; do sleep 0.05; done; fi\nexit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-RETRY-CLAIM")

      File.write!(block_retry, "block")

      first_retry = Task.async(fn -> Workspace.create_for_issue("MT-RETRY-CLAIM") end)
      assert_eventually(fn -> after_create_call_count(counter) == 2 end)
      second_retry = Task.async(fn -> Workspace.create_for_issue("MT-RETRY-CLAIM") end)

      workspace = Path.join(workspace_root, "MT-RETRY-CLAIM")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert {:ok, ^canonical_workspace} = Task.await(second_retry, 5_000)

      File.write!(gate, "go")

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Task.await(first_retry, 5_000)

      assert after_create_call_count(counter) == 2
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "path safety does not reject valid Windows unicode segments by byte length" do
    if match?({:win32, _}, :os.type()) do
      unicode_segment = String.duplicate("ü", 200)
      path = Path.join(System.tmp_dir!(), unicode_segment)
      expanded_path = Path.expand(path)

      assert {:ok, ^expanded_path} = SymphonyElixir.PathSafety.canonicalize(path)
    end
  end

  test "path safety rejects Windows segments beyond UTF-16 code unit limits" do
    if match?({:win32, _}, :os.type()) do
      invalid_segment = String.duplicate("😀", 200)
      path = Path.join(System.tmp_dir!(), invalid_segment)
      expanded_path = Path.expand(path)

      assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
               SymphonyElixir.PathSafety.canonicalize(path)
    end
  end

  defp assert_eventually(fun, attempts_remaining \\ 100)

  defp assert_eventually(_fun, 0), do: flunk("condition was not met before timeout")

  defp assert_eventually(fun, attempts_remaining) when is_function(fun, 0) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts_remaining - 1)
    end
  end

  defp after_create_call_count(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.trim()
      |> String.split("\n", trim: true)
      |> length()
    else
      0
    end
  end
end
