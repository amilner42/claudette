defmodule Claudette.Tasks.Task do
  @moduledoc """
  Struct representing a Claudette task.
  """

  @derive {Jason.Encoder,
           only: [
             :id,
             :title,
             :created_at,
             :updated_at,
             :status,
             :github_url,
             :github_owner,
             :github_repo,
             :github_issue_number,
             :worktree_path,
             :branch_name,
             :instruction_template,
             :tags
           ]}

  defstruct [
    :id,
    :title,
    :created_at,
    :updated_at,
    :status,
    :github_url,
    :github_owner,
    :github_repo,
    :github_issue_number,
    :worktree_path,
    :branch_name,
    :instruction_template,
    :tags,
    :context_md,
    :claude_notes_md
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          created_at: String.t(),
          updated_at: String.t(),
          status: String.t(),
          github_url: String.t() | nil,
          github_owner: String.t() | nil,
          github_repo: String.t() | nil,
          github_issue_number: integer() | nil,
          worktree_path: String.t() | nil,
          branch_name: String.t() | nil,
          instruction_template: String.t() | nil,
          tags: [String.t()] | nil,
          context_md: String.t() | nil,
          claude_notes_md: String.t() | nil
        }

  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      title: map["title"],
      created_at: map["created_at"],
      updated_at: map["updated_at"],
      status: map["status"] || "active",
      github_url: map["github_url"],
      github_owner: map["github_owner"],
      github_repo: map["github_repo"],
      github_issue_number: map["github_issue_number"],
      worktree_path: map["worktree_path"],
      branch_name: map["branch_name"],
      instruction_template: map["instruction_template"],
      tags: map["tags"] || []
    }
  end

  def to_meta_map(%__MODULE__{} = task) do
    %{
      "id" => task.id,
      "title" => task.title,
      "created_at" => task.created_at,
      "updated_at" => task.updated_at,
      "status" => task.status,
      "github_url" => task.github_url,
      "github_owner" => task.github_owner,
      "github_repo" => task.github_repo,
      "github_issue_number" => task.github_issue_number,
      "worktree_path" => task.worktree_path,
      "branch_name" => task.branch_name,
      "instruction_template" => task.instruction_template,
      "tags" => task.tags || []
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
