defmodule Claudette.Config do
  @moduledoc """
  Configuration for Claudette data paths and project configs.
  Each project has its own config (github_repo, github_token, worktrees) and tasks.
  """

  @default_data_path "~/claudette-data"

  def data_path do
    System.get_env("CLAUDETTE_DATA_PATH", @default_data_path)
    |> Path.expand()
  end

  def projects_path, do: Path.join(data_path(), "projects")

  def project_path(project_id), do: Path.join(projects_path(), project_id)

  def project_config_path(project_id), do: Path.join(project_path(project_id), "config.json")

  def project_tasks_path(project_id), do: Path.join(project_path(project_id), "tasks")

  def project_instructions_path(project_id),
    do: Path.join(project_path(project_id), "instructions")

  def ensure_data_dirs! do
    File.mkdir_p!(projects_path())
  end

  def ensure_project_dirs!(project_id) do
    File.mkdir_p!(project_tasks_path(project_id))
    File.mkdir_p!(project_instructions_path(project_id))
  end

  @doc """
  List all projects with their configs.
  """
  def list_projects do
    ensure_data_dirs!()
    projects_dir = projects_path()

    case File.ls(projects_dir) do
      {:ok, dirs} ->
        dirs
        |> Enum.filter(fn dir ->
          path = Path.join(projects_dir, dir)
          File.dir?(path)
        end)
        |> Enum.map(fn project_id ->
          load_project_config(project_id)
        end)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        []
    end
  end

  @doc """
  Load config for a specific project.
  """
  def load_project_config(project_id) do
    config_path = project_config_path(project_id)

    json_config =
      if File.exists?(config_path) do
        case File.read(config_path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, config} when is_map(config) -> config
              _ -> %{}
            end

          _ ->
            %{}
        end
      else
        # Try legacy yaml format
        yaml_path = Path.join(project_path(project_id), "config.yaml")

        if File.exists?(yaml_path) do
          case YamlElixir.read_from_file(yaml_path) do
            {:ok, config} when is_map(config) -> config
            _ -> %{}
          end
        else
          %{}
        end
      end

    worktrees_dir = json_config["worktrees_dir"]

    # Auto-discover worktrees from the base directory
    worktrees =
      if worktrees_dir && File.dir?(worktrees_dir) do
        case File.ls(worktrees_dir) do
          {:ok, entries} ->
            entries
            |> Enum.map(&Path.join(worktrees_dir, &1))
            |> Enum.filter(&File.dir?/1)
            |> Enum.sort()

          _ ->
            []
        end
      else
        []
      end

    # Load instruction templates from files
    instructions_dir = project_instructions_path(project_id)

    instructions =
      if File.dir?(instructions_dir) do
        case File.ls(instructions_dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".md"))
            |> Enum.map(fn file ->
              name = Path.basename(file, ".md")
              %{"name" => name, "file" => file}
            end)
            |> Enum.sort_by(& &1["name"])

          _ ->
            []
        end
      else
        []
      end

    %{
      id: project_id,
      name: json_config["name"] || project_id,
      github_token: json_config["github_token"] || System.get_env("GITHUB_TOKEN"),
      github_repo: json_config["github_repo"],
      worktrees_dir: worktrees_dir,
      worktrees: worktrees,
      branch_prefix: json_config["branch_prefix"] || "issue",
      default_instructions: json_config["default_instructions"],
      instructions: instructions
    }
  end

  @doc """
  Create a new project with the given config.
  """
  def create_project(attrs) do
    project_id = generate_id()
    ensure_project_dirs!(project_id)

    save_project_config(project_id, attrs)
    {:ok, project_id}
  end

  @doc """
  Save config for a specific project.
  Instructions are saved as separate .md files in the instructions directory.
  """
  def save_project_config(project_id, attrs) do
    ensure_project_dirs!(project_id)
    config_path = project_config_path(project_id)

    # Handle instructions separately - save as .md files
    instructions = attrs[:instructions] || attrs["instructions"] || []

    if is_list(instructions) do
      # Get existing instruction files
      instructions_dir = project_instructions_path(project_id)

      existing_files =
        if File.dir?(instructions_dir) do
          case File.ls(instructions_dir) do
            {:ok, files} -> MapSet.new(files)
            _ -> MapSet.new()
          end
        else
          MapSet.new()
        end

      # Save new/updated instructions
      saved_files =
        Enum.reduce(instructions, MapSet.new(), fn instruction, acc ->
          name = instruction["name"]
          content = instruction["content"] || ""
          filename = "#{name}.md"

          if name && !String.contains?(name, " ") do
            save_instruction(project_id, name, content)
            MapSet.put(acc, filename)
          else
            acc
          end
        end)

      # Delete removed instructions
      files_to_delete =
        MapSet.difference(existing_files, saved_files)
        |> Enum.filter(&String.ends_with?(&1, ".md"))

      Enum.each(files_to_delete, fn file ->
        name = Path.basename(file, ".md")
        delete_instruction(project_id, name)
      end)
    end

    # Save config (without instructions field - those are separate .md files)
    config =
      %{
        "name" => attrs[:name] || attrs["name"],
        "github_repo" => attrs[:github_repo] || attrs["github_repo"],
        "github_token" => attrs[:github_token] || attrs["github_token"],
        "worktrees_dir" => attrs[:worktrees_dir] || attrs["worktrees_dir"],
        "branch_prefix" => attrs[:branch_prefix] || attrs["branch_prefix"] || "issue"
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    File.write(config_path, Jason.encode!(config, pretty: true))
  end

  @doc """
  Delete a project and all its data.
  """
  def delete_project(project_id) do
    path = project_path(project_id)

    if File.exists?(path) do
      File.rm_rf(path)
    else
      {:error, :not_found}
    end
  end

  # Legacy functions for backwards compatibility
  def tasks_path, do: Path.join(data_path(), "tasks")
  def config_file_path, do: Path.join(data_path(), "config.yaml")

  def load_config do
    config_path = config_file_path()

    yaml_config =
      if File.exists?(config_path) do
        case YamlElixir.read_from_file(config_path) do
          {:ok, config} when is_map(config) -> config
          _ -> %{}
        end
      else
        %{}
      end

    %{
      github_token: yaml_config["GITHUB_TOKEN"] || System.get_env("GITHUB_TOKEN"),
      github_repo: yaml_config["GITHUB_REPO"] || System.get_env("GITHUB_REPO")
    }
  end

  def load_api_keys, do: load_config()

  @doc """
  Save an instruction template to a file.
  Name must not contain spaces.
  """
  def save_instruction(project_id, name, content) do
    # Validate name (no spaces allowed)
    if String.contains?(name, " ") do
      {:error, "Instruction name cannot contain spaces"}
    else
      ensure_project_dirs!(project_id)
      file_path = Path.join(project_instructions_path(project_id), "#{name}.md")

      case File.write(file_path, content) do
        :ok -> {:ok, name}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Load an instruction template from a file.
  """
  def load_instruction(project_id, name) do
    file_path = Path.join(project_instructions_path(project_id), "#{name}.md")

    case File.read(file_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete an instruction template file.
  """
  def delete_instruction(project_id, name) do
    file_path = Path.join(project_instructions_path(project_id), "#{name}.md")

    case File.rm(file_path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
