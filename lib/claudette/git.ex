defmodule Claudette.Git do
  @moduledoc """
  Git operations for workspace management.
  """

  @doc """
  Setup a workspace for a new task:
  1. Fetch from origin
  2. Checkout the worktree's placeholder branch (named after the worktree)
  3. Reset it to the base branch (e.g., main)
  4. Create and checkout the new feature branch

  Each worktree has a placeholder branch that matches its directory name.
  This avoids git's "branch already in use" error when multiple worktrees exist.
  """
  def setup_workspace(worktree_path, branch_name, base_ref \\ "main") do
    # Get the worktree's placeholder branch name (last directory component)
    placeholder_branch = Path.basename(worktree_path)

    with :ok <- fetch_origin(worktree_path),
         :ok <- ensure_placeholder_branch(worktree_path, placeholder_branch),
         :ok <- checkout(worktree_path, placeholder_branch),
         :ok <- reset_to_base(worktree_path, base_ref),
         :ok <- create_branch(worktree_path, branch_name) do
      {:ok, branch_name}
    end
  end

  @doc """
  Reset a worktree to a clean state for task completion.

  Steps:
  1. Verify no uncommitted changes exist (BLOCKING check)
  2. Checkout the placeholder branch (named after worktree directory)
  3. Fetch from origin
  4. Reset to origin/main (or specified base branch)

  The feature branch is preserved and NOT deleted.

  ## Parameters
  - worktree_path: Path to the worktree directory
  - base_ref: Base branch to reset to (default: "main")

  ## Returns
  - {:ok, placeholder_branch} on success
  - {:error, reason} on failure
  """
  def done_reset_worktree(worktree_path, base_ref \\ "main") do
    placeholder_branch = Path.basename(worktree_path)

    # CRITICAL: Check for uncommitted changes first (BLOCKING)
    if has_changes?(worktree_path) do
      {:error, "Worktree has uncommitted changes. Please commit or stash them first."}
    else
      with :ok <- checkout(worktree_path, placeholder_branch),
           :ok <- fetch_origin(worktree_path),
           :ok <- reset_to_base(worktree_path, base_ref) do
        {:ok, placeholder_branch}
      end
    end
  end

  @doc """
  Fetch from origin.
  """
  def fetch_origin(worktree_path) do
    case System.cmd("git", ["fetch", "origin"], cd: worktree_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {error, _} -> {:error, "Failed to fetch: #{error}"}
    end
  end

  @doc """
  Checkout a branch or commit.
  """
  def checkout(worktree_path, ref) do
    case System.cmd("git", ["checkout", ref], cd: worktree_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {error, _} -> {:error, "Failed to checkout #{ref}: #{error}"}
    end
  end

  @doc """
  Create and checkout a new branch.
  """
  def create_branch(worktree_path, branch_name) do
    case System.cmd("git", ["checkout", "-b", branch_name],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {error, _} -> {:error, "Failed to create branch #{branch_name}: #{error}"}
    end
  end

  @doc """
  Ensure the placeholder branch exists, create it if it doesn't.
  The placeholder branch is just a marker - it will be reset to the base branch.
  """
  def ensure_placeholder_branch(worktree_path, placeholder_branch) do
    # Check if branch exists
    case System.cmd("git", ["rev-parse", "--verify", placeholder_branch],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        # Branch exists, we're good
        :ok

      {_error, _} ->
        # Branch doesn't exist, create it from current HEAD
        case System.cmd("git", ["branch", placeholder_branch],
               cd: worktree_path,
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            :ok

          {error, _} ->
            {:error, "Failed to create placeholder branch #{placeholder_branch}: #{error}"}
        end
    end
  end

  @doc """
  Reset the current branch to match the base branch (e.g., origin/main).
  This is a hard reset that discards any local changes.
  """
  def reset_to_base(worktree_path, base_ref) do
    # Use origin/base_ref to ensure we're getting the remote version
    remote_ref = "origin/#{base_ref}"

    case System.cmd("git", ["reset", "--hard", remote_ref],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {error, _} -> {:error, "Failed to reset to #{remote_ref}: #{error}"}
    end
  end

  @doc """
  Get the current branch name for a worktree.
  """
  def current_branch(worktree_path) do
    case System.cmd("git", ["branch", "--show-current"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {error, _} -> {:error, "Failed to get current branch: #{error}"}
    end
  end

  @doc """
  Check if a worktree has uncommitted changes.
  """
  def has_changes?(worktree_path) do
    case System.cmd("git", ["status", "--porcelain"], cd: worktree_path, stderr_to_stdout: true) do
      {"", 0} -> false
      {_output, 0} -> true
      _ -> false
    end
  end

  @doc """
  List all branches (local and remote) for a worktree.
  Returns {:ok, branches} where branches is a list of branch names.
  """
  def list_branches(worktree_path) do
    case System.cmd("git", ["branch", "-a", "--format=%(refname:short)"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        branches =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn branch ->
            # Remove origin/ prefix from remote branches for cleaner display
            String.replace(branch, ~r/^origin\//, "")
          end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, branches}

      {error, _} ->
        {:error, "Failed to list branches: #{error}"}
    end
  end

  @doc """
  Generate a branch name from an issue title and number.
  """
  def suggest_branch_name(issue_number, issue_title, prefix \\ "issue") do
    slug =
      issue_title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.slice(0, 40)
      |> String.trim("-")

    "#{prefix}-#{issue_number}-#{slug}"
  end
end
