defmodule Claudette.Tasks do
  @moduledoc """
  Context for managing Claudette tasks.
  All operations are file-based - no database.
  Tasks are scoped to a project.
  """

  alias Claudette.Config
  alias Claudette.Git
  alias Claudette.Tasks.Task

  @doc """
  List all tasks for a project by scanning the tasks directory.
  Returns tasks sorted by updated_at descending.
  """
  def list_tasks(project_id) do
    tasks_path = Config.project_tasks_path(project_id)

    if File.exists?(tasks_path) do
      tasks_path
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(tasks_path, &1)))
      |> Enum.map(&load_task_meta(project_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.updated_at, :desc)
    else
      []
    end
  end

  @doc """
  Get a task by ID, including context.md and claude-notes.md content.
  """
  def get_task(project_id, id) do
    task_path = task_path(project_id, id)

    if File.exists?(task_path) do
      case load_task_meta(project_id, id) do
        nil ->
          {:error, :not_found}

        task ->
          context_md = read_file_or_nil(Path.join(task_path, "context.md"))
          claude_notes_md = read_file_or_nil(Path.join(task_path, "claude-notes.md"))

          {:ok, %{task | context_md: context_md, claude_notes_md: claude_notes_md}}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Create a new task with the given attributes.
  """
  def create_task(project_id, attrs) do
    Config.ensure_project_dirs!(project_id)

    id = generate_id()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    task = %Task{
      id: id,
      title: attrs[:title] || attrs["title"] || "Untitled",
      created_at: now,
      updated_at: now,
      status: attrs[:status] || attrs["status"] || "active",
      github_url: attrs[:github_url] || attrs["github_url"],
      github_owner: attrs[:github_owner] || attrs["github_owner"],
      github_repo: attrs[:github_repo] || attrs["github_repo"],
      github_issue_number: attrs[:github_issue_number] || attrs["github_issue_number"],
      worktree_path: attrs[:worktree_path] || attrs["worktree_path"],
      branch_name: attrs[:branch_name] || attrs["branch_name"],
      instruction_template: attrs[:instruction_template] || attrs["instruction_template"],
      tags: attrs[:tags] || attrs["tags"] || []
    }

    task_dir = task_path(project_id, id)
    File.mkdir_p!(task_dir)

    # Write meta.json
    meta_path = Path.join(task_dir, "meta.json")
    File.write!(meta_path, Jason.encode!(Task.to_meta_map(task), pretty: true))

    # Write initial context.md
    context_md = attrs[:context_md] || attrs["context_md"] || ""
    context_path = Path.join(task_dir, "context.md")
    File.write!(context_path, context_md)

    {:ok, %{task | context_md: context_md}}
  end

  @doc """
  Update an existing task.
  """
  def update_task(project_id, id, attrs) do
    case get_task(project_id, id) do
      {:ok, task} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        updated_task = %{
          task
          | title: attrs[:title] || attrs["title"] || task.title,
            updated_at: now,
            status: attrs[:status] || attrs["status"] || task.status,
            github_url: get_attr(attrs, :github_url, task.github_url),
            github_owner: get_attr(attrs, :github_owner, task.github_owner),
            github_repo: get_attr(attrs, :github_repo, task.github_repo),
            github_issue_number: get_attr(attrs, :github_issue_number, task.github_issue_number),
            worktree_path: get_attr(attrs, :worktree_path, task.worktree_path),
            instruction_template:
              get_attr(attrs, :instruction_template, task.instruction_template),
            tags: attrs[:tags] || attrs["tags"] || task.tags
        }

        task_dir = task_path(project_id, id)

        # Write meta.json
        meta_path = Path.join(task_dir, "meta.json")
        File.write!(meta_path, Jason.encode!(Task.to_meta_map(updated_task), pretty: true))

        # Update context.md if provided
        if context_md = attrs[:context_md] || attrs["context_md"] do
          context_path = Path.join(task_dir, "context.md")
          File.write!(context_path, context_md)
          {:ok, %{updated_task | context_md: context_md}}
        else
          {:ok, updated_task}
        end

      error ->
        error
    end
  end

  @doc """
  Delete a task and its folder.
  """
  def delete_task(project_id, id) do
    task_dir = task_path(project_id, id)

    if File.exists?(task_dir) do
      File.rm_rf!(task_dir)
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  Change a task's status.
  """
  def change_status(project_id, id, new_status) do
    update_task(project_id, id, %{status: new_status})
  end

  @doc """
  Complete a task by resetting its worktree and marking it as completed.

  This is an ATOMIC operation - the task status only changes if the git
  reset succeeds. If git operations fail, the task status remains unchanged.

  ## Parameters
  - project_id: Project identifier
  - id: Task identifier
  - base_ref: Base branch to reset to (default: "main")

  ## Returns
  - {:ok, updated_task} on success
  - {:error, reason} on failure
  """
  def complete_task_with_reset(project_id, id, base_ref \\ "main") do
    case get_task(project_id, id) do
      {:ok, task} ->
        # Check if task has a worktree configured
        if task.worktree_path && task.worktree_path != "" do
          # Attempt git reset
          case Git.done_reset_worktree(task.worktree_path, base_ref) do
            {:ok, _placeholder_branch} ->
              # Git reset succeeded, mark task as completed
              change_status(project_id, id, "completed")

            {:error, reason} ->
              # Git reset failed, return error without changing status
              {:error, reason}
          end
        else
          # No worktree configured, just mark as completed
          change_status(project_id, id, "completed")
        end

      error ->
        error
    end
  end

  # Private helpers

  defp task_path(project_id, id) do
    Path.join(Config.project_tasks_path(project_id), id)
  end

  defp load_task_meta(project_id, id) do
    meta_path = Path.join([Config.project_tasks_path(project_id), id, "meta.json"])

    if File.exists?(meta_path) do
      case File.read(meta_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, map} -> Task.from_map(map)
            _ -> nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp read_file_or_nil(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp get_attr(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, to_string(key)) -> Map.get(attrs, to_string(key))
      true -> default
    end
  end
end
