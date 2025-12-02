defmodule ClaudetteWeb.DashboardLive do
  use ClaudetteWeb, :live_view

  alias Claudette.Config
  alias Claudette.Tasks
  alias Claudette.Git
  alias Claudette.Integrations.GitHub
  alias Claudette.Terminal.Session

  @impl true
  def mount(_params, _session, socket) do
    projects = Config.list_projects()

    # Auto-select project if there's only one
    {current_project, tasks, task_github_urls, show_modal, github_loading} =
      case projects do
        [single_project] ->
          tasks = Tasks.list_tasks(single_project.id)

          urls =
            tasks
            |> Enum.filter(& &1.github_url)
            |> Enum.map(& &1.github_url)
            |> MapSet.new()

          # Trigger GitHub fetch if project has a repo configured and socket is connected
          if connected?(socket) && single_project.github_repo do
            send(self(), :fetch_github_issues)
            {single_project, tasks, urls, false, true}
          else
            {single_project, tasks, urls, false, false}
          end

        _ ->
          {nil, [], MapSet.new(), true, false}
      end

    {:ok,
     assign(socket,
       projects: projects,
       current_project: current_project,
       tasks: tasks,
       task_github_urls: task_github_urls,
       github_issues: [],
       github_loading: github_loading,
       github_error: nil,
       search: "",
       show_project_modal: show_modal,
       modal_mode: "select",
       form_name: "",
       form_repo: "",
       form_token: "",
       form_worktrees_dir: "",
       form_branch_prefix: "",
       # Task creation state (inline creation)
       creating_task: false,
       creation_issue: nil,
       creation_github_data: nil,
       creation_workspace: nil,
       creation_branch: "",
       creation_base: "main",
       creation_context: "",
       creation_error: nil,
       creation_loading: false,
       # Set after worktree is initialized
       creation_initialized_task: nil,
       available_branches: [],
       # Map of worktree path -> %{dirty: bool, in_use_by: task_id or nil}
       worktree_status: %{},
       # Selected instruction template name
       creation_instruction_template: nil,
       # Bottom panel state: nil, :terminal, or :settings
       bottom_panel: nil,
       # Currently selected workspace for terminal
       terminal_workspace: nil,
       # Selected task for inline view
       selected_task: nil,
       task_github_data: nil,
       task_github_loading: false,
       task_github_error: nil,
       # Selected issue for split view
       selected_issue: nil,
       # Task editing
       editing_task: false,
       task_form: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # Project selection events
  @impl true
  def handle_event("select_project", %{"id" => project_id}, socket) do
    project = Config.load_project_config(project_id)
    load_project_data(socket, project)
  end

  @impl true
  def handle_event("show_new_project", _params, socket) do
    {:noreply,
     assign(socket,
       show_project_modal: true,
       modal_mode: "new",
       form_name: "",
       form_repo: "",
       form_token: "",
       form_worktrees_dir: "",
       form_branch_prefix: "issue",
       bottom_panel: nil
     )}
  end

  @impl true
  def handle_event("show_select_project", _params, socket) do
    {:noreply, assign(socket, modal_mode: "select")}
  end

  @impl true
  def handle_event(
        "create_project",
        %{"name" => name, "repo" => repo, "token" => token} = params,
        socket
      ) do
    worktrees_dir = params["worktrees_dir"] || ""
    branch_prefix = params["branch_prefix"] || "issue"

    attrs = %{
      name: name,
      github_repo: repo,
      github_token: if(token == "", do: nil, else: token),
      worktrees_dir: if(worktrees_dir == "", do: nil, else: worktrees_dir),
      branch_prefix: if(branch_prefix == "", do: "issue", else: branch_prefix)
    }

    case Config.create_project(attrs) do
      {:ok, project_id} ->
        project = Config.load_project_config(project_id)
        projects = Config.list_projects()

        socket =
          socket
          |> assign(projects: projects)
          |> put_flash(:info, "Project created!")

        load_project_data(socket, project)

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create project")}
    end
  end

  @impl true
  def handle_event("edit_project", _params, socket) do
    project = socket.assigns.current_project

    {:noreply,
     assign(socket,
       show_project_modal: true,
       modal_mode: "edit",
       form_name: project.name,
       form_repo: project.github_repo || "",
       form_token: project.github_token || "",
       form_worktrees_dir: project.worktrees_dir || "",
       form_branch_prefix: project.branch_prefix || "issue"
     )}
  end

  # Bottom panel events
  @impl true
  def handle_event("toggle_terminal", _params, socket) do
    new_panel = if socket.assigns.bottom_panel == :terminal, do: nil, else: :terminal
    # Set default workspace if none selected
    terminal_workspace =
      socket.assigns.terminal_workspace || List.first(socket.assigns.current_project.worktrees)

    socket = assign(socket, bottom_panel: new_panel, terminal_workspace: terminal_workspace)

    # Subscribe and send scrollback when opening terminal
    if new_panel == :terminal && terminal_workspace do
      # Unsubscribe from old workspace if any
      if socket.assigns.terminal_workspace &&
           socket.assigns.terminal_workspace != terminal_workspace do
        Session.unsubscribe(socket.assigns.terminal_workspace)
      end

      # Subscribe to new workspace
      Session.subscribe(terminal_workspace)
      Session.ensure_terminal(terminal_workspace)
      scrollback = Session.get_scrollback(terminal_workspace)

      if scrollback != "" do
        send(self(), {:send_scrollback, scrollback})
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_settings", _params, socket) do
    project = socket.assigns.current_project

    if socket.assigns.bottom_panel == :settings do
      {:noreply, assign(socket, bottom_panel: nil)}
    else
      {:noreply,
       assign(socket,
         bottom_panel: :settings,
         form_name: project.name,
         form_repo: project.github_repo || "",
         form_token: project.github_token || "",
         form_worktrees_dir: project.worktrees_dir || "",
         form_branch_prefix: project.branch_prefix || "issue"
       )}
    end
  end

  @impl true
  def handle_event("close_bottom_panel", _params, socket) do
    {:noreply, assign(socket, bottom_panel: nil)}
  end

  @impl true
  def handle_event("open_project_selector", _params, socket) do
    {:noreply, assign(socket, show_project_modal: true, modal_mode: "select", bottom_panel: nil)}
  end

  @impl true
  def handle_event("select_terminal_workspace", %{"workspace" => workspace}, socket) do
    old_workspace = socket.assigns.terminal_workspace

    # Unsubscribe from old, subscribe to new
    if old_workspace && old_workspace != workspace do
      Session.unsubscribe(old_workspace)
    end

    Session.subscribe(workspace)
    Session.ensure_terminal(workspace)

    # Clear terminal and send new scrollback
    send(self(), {:clear_and_load_scrollback, workspace})

    {:noreply, assign(socket, terminal_workspace: workspace)}
  end

  # Terminal events
  @impl true
  def handle_event("terminal:input", %{"data" => data}, socket) do
    workspace = socket.assigns.terminal_workspace

    if workspace do
      case Base.decode64(data) do
        {:ok, decoded} -> Session.send_input(workspace, decoded)
        :error -> Session.send_input(workspace, data)
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal:resize", %{"rows" => rows, "cols" => cols}, socket) do
    workspace = socket.assigns.terminal_workspace

    if workspace do
      Session.resize(workspace, rows, cols)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal:reset", _, socket) do
    workspace = socket.assigns.terminal_workspace

    if workspace do
      Session.reset(workspace)
    end

    {:noreply, socket}
  end

  # Task selection (shows in right panel)
  @impl true
  def handle_event("select_task", %{"id" => task_id}, socket) do
    project = socket.assigns.current_project

    case Tasks.get_task(project.id, task_id) do
      {:ok, task} ->
        # Find the corresponding issue from the task's github_url
        matching_issue =
          if task.github_url do
            Enum.find(socket.assigns.github_issues, fn issue ->
              issue.url == task.github_url
            end)
          else
            nil
          end

        # If we have a github_url but no matching issue, fetch it
        socket =
          if task.github_url && !matching_issue && project.github_token do
            send(self(), {:fetch_task_github_issue, task.github_url})
            assign(socket, task_github_loading: true)
          else
            socket
          end

        {:noreply,
         assign(socket,
           selected_task: task,
           selected_issue: matching_issue
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Task not found")}
    end
  end

  @impl true
  def handle_event(
        "update_project",
        %{"name" => name, "repo" => repo, "token" => token} = params,
        socket
      ) do
    project = socket.assigns.current_project
    worktrees_dir = params["worktrees_dir"] || ""
    branch_prefix = params["branch_prefix"] || "issue"

    attrs = %{
      name: name,
      github_repo: repo,
      github_token: if(token == "", do: nil, else: token),
      worktrees_dir: if(worktrees_dir == "", do: nil, else: worktrees_dir),
      branch_prefix: if(branch_prefix == "", do: "issue", else: branch_prefix)
    }

    Config.save_project_config(project.id, attrs)
    updated_project = Config.load_project_config(project.id)
    projects = Config.list_projects()

    socket =
      socket
      |> assign(
        projects: projects,
        current_project: updated_project,
        show_project_modal: false,
        bottom_panel: nil
      )
      |> put_flash(:info, "Project updated!")

    if updated_project.github_repo do
      send(self(), :fetch_github_issues)
      {:noreply, assign(socket, github_loading: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_project", _params, socket) do
    {:noreply, assign(socket, show_project_modal: true, modal_mode: "select")}
  end

  @impl true
  def handle_event("close_project_modal", _params, socket) do
    if socket.assigns.current_project do
      {:noreply, assign(socket, show_project_modal: false)}
    else
      {:noreply, socket}
    end
  end

  # Dashboard events
  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, search: search)}
  end

  # Task creation - NEW inline creation flow
  @impl true
  def handle_event(
        "begin_task_creation",
        %{"owner" => owner, "repo" => repo, "number" => number},
        socket
      ) do
    project = socket.assigns.current_project
    number_int = String.to_integer(number)

    issue =
      Enum.find(socket.assigns.github_issues, fn i ->
        i.owner == owner && i.repo == repo && i.number == number_int
      end)

    # Generate suggested branch name
    suggested_branch =
      if issue do
        Git.suggest_branch_name(number_int, issue.title, project.branch_prefix)
      else
        "#{project.branch_prefix}-#{number}"
      end

    # Fetch branches from first available worktree
    available_branches =
      if project.worktrees != [] do
        first_worktree = List.first(project.worktrees)

        case Git.list_branches(first_worktree) do
          {:ok, branches} -> branches
          {:error, _} -> ["main", "master", "develop"]
        end
      else
        []
      end

    socket =
      assign(socket,
        creating_task: true,
        # Ensure task detail view is closed
        selected_task: nil,
        creation_issue: issue,
        creation_github_data: nil,
        creation_workspace: nil,
        creation_branch: suggested_branch,
        creation_base: "main",
        creation_context: "",
        creation_error: nil,
        creation_loading: false,
        available_branches: available_branches
      )

    # Fetch full GitHub data if available
    if issue do
      github_url = "#{owner}/#{repo}##{number}"
      send(self(), {:fetch_creation_github, github_url})
      {:noreply, assign(socket, creation_loading: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_task_creation", _params, socket) do
    {:noreply,
     assign(socket,
       creating_task: false,
       creation_issue: nil,
       creation_github_data: nil,
       creation_error: nil,
       creation_loading: false,
       creation_initialized_task: nil
     )}
  end

  @impl true
  def handle_event(
        "select_issue",
        %{"owner" => owner, "repo" => repo, "number" => number},
        socket
      ) do
    project = socket.assigns.current_project
    tasks = socket.assigns.tasks
    number_int = String.to_integer(number)

    issue =
      Enum.find(socket.assigns.github_issues, fn i ->
        i.owner == owner && i.repo == repo && i.number == number_int
      end)

    # Generate suggested branch name
    suggested_branch =
      if issue do
        Git.suggest_branch_name(number_int, issue.title, project.branch_prefix)
      else
        "#{project.branch_prefix}-#{number}"
      end

    # Fetch branches from first available worktree
    available_branches =
      if project.worktrees != [] do
        first_worktree = List.first(project.worktrees)

        case Git.list_branches(first_worktree) do
          {:ok, branches} -> branches
          {:error, _} -> ["main", "master", "develop"]
        end
      else
        []
      end

    # Check worktree status (dirty/clean and in-use)
    worktree_status =
      project.worktrees
      |> Enum.map(fn worktree ->
        in_use_task =
          Enum.find(tasks, fn t -> t.worktree_path == worktree && t.status == "active" end)

        dirty = Git.has_changes?(worktree)

        {worktree,
         %{
           dirty: dirty,
           in_use_by: if(in_use_task, do: in_use_task.id, else: nil)
         }}
      end)
      |> Map.new()

    # Select default instruction template from project config, or fall back to first available
    template_name =
      project.default_instructions ||
        List.first(project.instructions)
        |> then(fn t -> if t, do: Map.get(t, "name"), else: nil end)

    # Preserve workspace selection and initialized task if already set, only reset if viewing a different issue
    # Compare by issue identity (owner/repo/number) rather than map equality
    is_same_issue =
      case socket.assigns[:creation_issue] do
        existing_issue when not is_nil(existing_issue) ->
          existing_issue.owner == owner && existing_issue.repo == repo &&
            existing_issue.number == number_int

        _ ->
          false
      end

    preserve_workspace =
      if is_same_issue && socket.assigns[:creation_workspace] do
        socket.assigns.creation_workspace
      else
        nil
      end

    preserve_initialized_task =
      if is_same_issue && socket.assigns[:creation_initialized_task] do
        socket.assigns.creation_initialized_task
      else
        nil
      end

    {:noreply,
     assign(socket,
       selected_issue: issue,
       selected_task: nil,
       creating_task: false,
       creation_issue: issue,
       creation_workspace: preserve_workspace,
       creation_branch: suggested_branch,
       creation_base: "main",
       creation_context: "",
       creation_error: nil,
       creation_loading: false,
       creation_initialized_task: preserve_initialized_task,
       available_branches: available_branches,
       worktree_status: worktree_status,
       creation_instruction_template: template_name
     )}
  end

  @impl true
  def handle_event("close_issue_detail", _params, socket) do
    {:noreply, assign(socket, selected_issue: nil)}
  end

  @impl true
  def handle_event("copy_command", %{"command" => command}, socket) do
    # Use clipboard API via JS hook
    {:noreply, push_event(socket, "copy-to-clipboard", %{text: command})}
  end

  @impl true
  def handle_event("done_reset_worktree", %{"task_id" => task_id}, socket) do
    project_id = socket.assigns.current_project.id

    case Tasks.get_task(project_id, task_id) do
      {:ok, task} ->
        if task.status == "active" && task.worktree_path do
          case Tasks.complete_task_with_reset(project_id, task_id) do
            {:ok, updated_task} ->
              # Reload tasks list and update selected task
              tasks = Tasks.list_tasks(project_id)

              {:noreply,
               socket
               |> assign(tasks: tasks, selected_task: updated_task)
               |> put_flash(:info, "Task completed and worktree reset successfully")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to reset worktree: #{reason}")}
          end
        else
          {:noreply, put_flash(socket, :error, "Task must be active and have a worktree")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Task not found")}
    end
  end

  @impl true
  def handle_event("update_creation_form", params, socket) do
    # Check if workspace changed and fetch branches for it
    {new_workspace, new_branches} =
      if Map.has_key?(params, "workspace") do
        workspace = params["workspace"]

        if workspace != "" do
          branches =
            case Git.list_branches(workspace) do
              {:ok, branches} -> branches
              {:error, _} -> ["main", "master", "develop"]
            end

          {workspace, branches}
        else
          {socket.assigns.creation_workspace, socket.assigns.available_branches}
        end
      else
        {socket.assigns.creation_workspace, socket.assigns.available_branches}
      end

    {:noreply,
     assign(socket,
       creation_workspace: new_workspace,
       available_branches: new_branches,
       creation_branch: params["branch"] || socket.assigns.creation_branch,
       creation_base: params["base"] || socket.assigns.creation_base,
       creation_context: params["context"] || socket.assigns.creation_context,
       creation_instruction_template:
         params["instruction_template"] || socket.assigns.creation_instruction_template
     )}
  end

  @impl true
  def handle_event("select_creation_workspace", %{"workspace" => workspace}, socket) do
    # Don't clear workspace if empty string is sent (e.g., "Select..." option clicked)
    if workspace == "" do
      {:noreply, socket}
    else
      # Fetch available branches for this workspace
      branches =
        case Git.list_branches(workspace) do
          {:ok, branches} -> branches
          # Fallback to common branches
          {:error, _} -> ["main", "master", "develop"]
        end

      {:noreply, assign(socket, creation_workspace: workspace, available_branches: branches)}
    end
  end

  @impl true
  def handle_event("create_task_from_issue", _params, socket) do
    project = socket.assigns.current_project
    issue = socket.assigns.creation_issue
    workspace = socket.assigns.creation_workspace
    branch = String.trim(socket.assigns.creation_branch)
    base = String.trim(socket.assigns.creation_base)
    context = socket.assigns.creation_context

    cond do
      # If worktrees configured but none selected
      project.worktrees != [] && (is_nil(workspace) || workspace == "") ->
        {:noreply, assign(socket, creation_error: "Please select a workspace")}

      # Check if workspace is dirty or in use
      workspace && workspace != "" ->
        status =
          Map.get(socket.assigns.worktree_status, workspace, %{dirty: false, in_use_by: nil})

        cond do
          status.dirty ->
            {:noreply,
             assign(socket,
               creation_error:
                 "Selected workspace has uncommitted changes. Please commit or stash them first."
             )}

          status.in_use_by ->
            {:noreply,
             assign(socket,
               creation_error: "Selected workspace is already in use by another task"
             )}

          branch == "" ->
            {:noreply, assign(socket, creation_error: "Please enter a branch name")}

          true ->
            # Workspace is safe, proceed
            socket = assign(socket, creation_loading: true, creation_error: nil)

            github_url =
              if issue do
                "#{issue.owner}/#{issue.repo}##{issue.number}"
              else
                nil
              end

            # Start async task creation
            send(
              self(),
              {:do_create_task_from_issue, github_url, issue, workspace, branch, base, context}
            )

            {:noreply, socket}
        end

      # No workspace selected (allowed if worktrees not configured)
      true ->
        socket = assign(socket, creation_loading: true, creation_error: nil)

        github_url =
          if issue do
            "#{issue.owner}/#{issue.repo}##{issue.number}"
          else
            nil
          end

        # Start async task creation
        send(
          self(),
          {:do_create_task_from_issue, github_url, issue, workspace, branch, base, context}
        )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create_task_without_workspace_new", _params, socket) do
    issue = socket.assigns.creation_issue
    context = socket.assigns.creation_context

    github_url =
      if issue do
        "#{issue.owner}/#{issue.repo}##{issue.number}"
      else
        nil
      end

    socket = assign(socket, creation_loading: true, creation_error: nil)
    send(self(), {:do_create_task_from_issue, github_url, issue, nil, "", "main", context})
    {:noreply, socket}
  end

  # Terminal output handlers
  @impl true
  def handle_info({:terminal_output, worktree_path, data}, socket) do
    # Only forward output if it's from the currently selected workspace
    if worktree_path == socket.assigns.terminal_workspace do
      {:noreply, push_event(socket, "terminal:output", %{data: Base.encode64(data)})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:send_scrollback, data}, socket) do
    {:noreply, push_event(socket, "terminal:output", %{data: Base.encode64(data)})}
  end

  @impl true
  def handle_info({:clear_and_load_scrollback, workspace}, socket) do
    # Clear the terminal first
    socket = push_event(socket, "terminal:clear", %{})
    # Then load scrollback
    scrollback = Session.get_scrollback(workspace)

    if scrollback != "" do
      {:noreply, push_event(socket, "terminal:output", %{data: Base.encode64(scrollback)})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:fetch_creation_github, github_url}, socket) do
    case GitHub.fetch_issue(github_url) do
      {:ok, data} ->
        {:noreply, assign(socket, creation_github_data: data, creation_loading: false)}

      {:error, _} ->
        # Non-blocking - just disable loading state
        {:noreply, assign(socket, creation_loading: false)}
    end
  end

  @impl true
  def handle_info(
        {:do_create_task_from_issue, github_url, issue, workspace, branch, base, context},
        socket
      ) do
    project = socket.assigns.current_project
    template_name = socket.assigns.creation_instruction_template

    # Run git setup if workspace is provided
    git_result =
      if workspace && workspace != "" do
        Git.setup_workspace(
          workspace,
          branch,
          base
        )
      else
        {:ok, nil}
      end

    case git_result do
      {:ok, _} ->
        # Parse GitHub URL to extract owner, repo, and issue number
        {github_owner, github_repo, github_issue_number} = parse_github_url(github_url)

        # Create the task
        task_attrs = %{
          title: if(issue, do: issue.title, else: "Task from issue"),
          github_url: github_url,
          github_owner: github_owner,
          github_repo: github_repo,
          github_issue_number: github_issue_number,
          worktree_path: workspace,
          branch_name: if(workspace && workspace != "", do: branch, else: nil),
          instruction_template: socket.assigns.creation_instruction_template,
          context_md: context
        }

        case Tasks.create_task(project.id, task_attrs) do
          {:ok, task} ->
            # Reload tasks and keep creation state to show command
            # Stay on the issue view, don't switch to task detail
            tasks = Tasks.list_tasks(project.id)

            {:noreply,
             assign(socket,
               tasks: tasks,
               creation_initialized_task: task,
               creation_loading: false,
               creation_error: nil
             )}

          {:error, changeset} ->
            error_msg = "Failed to create task: #{inspect(changeset.errors)}"
            {:noreply, assign(socket, creation_error: error_msg, creation_loading: false)}
        end

      {:error, reason} ->
        error_msg = "Git setup failed: #{reason}"
        {:noreply, assign(socket, creation_error: error_msg, creation_loading: false)}
    end
  end

  @impl true
  def handle_info(:fetch_github_issues, socket) do
    project = socket.assigns.current_project

    case parse_repo(project.github_repo) do
      {:ok, owner, repo} ->
        opts = [state: "open"]

        case GitHub.list_issues(owner, repo, opts) do
          {:ok, issues} ->
            {:noreply,
             assign(socket, github_issues: issues, github_loading: false, github_error: nil)}

          {:error, :no_api_key} ->
            {:noreply,
             assign(socket, github_loading: false, github_error: "No GitHub token configured")}

          {:error, :not_found} ->
            {:noreply,
             assign(socket, github_loading: false, github_error: "Repository not found")}

          {:error, _} ->
            {:noreply,
             assign(socket, github_loading: false, github_error: "Failed to fetch issues")}
        end

      :error ->
        {:noreply,
         assign(socket, github_loading: false, github_error: "Invalid repository format")}
    end
  end

  def handle_info({:fetch_task_github_issue, github_url}, socket) do
    case GitHub.fetch_issue(github_url) do
      {:ok, issue} ->
        {:noreply,
         assign(socket,
           selected_issue: issue,
           task_github_loading: false,
           task_github_error: nil
         )}

      {:error, :not_found} ->
        {:noreply,
         assign(socket,
           task_github_loading: false,
           task_github_error: "Issue not found"
         )}

      {:error, _} ->
        {:noreply,
         assign(socket,
           task_github_loading: false,
           task_github_error: "Failed to fetch issue"
         )}
    end
  end

  defp load_project_data(socket, project) do
    tasks = Tasks.list_tasks(project.id)

    task_github_urls =
      tasks
      |> Enum.map(& &1.github_url)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    socket =
      assign(socket,
        current_project: project,
        tasks: tasks,
        task_github_urls: task_github_urls,
        github_issues: [],
        github_loading: false,
        github_error: nil,
        show_project_modal: false
      )

    if project.github_repo do
      send(self(), :fetch_github_issues)
      {:noreply, assign(socket, github_loading: true)}
    else
      {:noreply, socket}
    end
  end

  defp parse_repo(nil), do: :error
  defp parse_repo(""), do: :error

  defp parse_repo(repo) do
    case String.split(repo, "/") do
      [owner, repo_name] when owner != "" and repo_name != "" ->
        {:ok, owner, repo_name}

      _ ->
        :error
    end
  end

  defp filter_items(assigns) do
    search = String.downcase(assigns.search)

    # Get active tasks, sorted alphabetically by title
    active_tasks =
      assigns.tasks
      |> Enum.filter(fn task ->
        task.status == "active" &&
          (search == "" or
             String.contains?(String.downcase(task.title || ""), search) or
             String.contains?(String.downcase(task.github_url || ""), search))
      end)
      |> Enum.sort_by(fn task -> String.downcase(task.title || "") end)
      |> Enum.map(fn task -> {:task, task} end)

    # Get open issues (excluding those already linked to tasks)
    open_issues =
      assigns.github_issues
      |> Enum.reject(fn issue ->
        github_url = "#{issue.owner}/#{issue.repo}##{issue.number}"
        MapSet.member?(assigns.task_github_urls, github_url)
      end)
      |> Enum.filter(fn issue ->
        search == "" or
          String.contains?(String.downcase(issue.title || ""), search) or
          String.contains?(String.downcase(to_string(issue.number)), search)
      end)
      |> Enum.map(fn issue -> {:issue, issue} end)

    # Active tasks first (alphabetically), then open issues
    active_tasks ++ open_issues
  end

  # Get workspaces that are currently in use by active tasks
  defp workspaces_in_use(tasks) do
    tasks
    |> Enum.filter(fn task -> task.status == "active" && task.worktree_path end)
    |> Enum.map(fn task -> {task.worktree_path, task} end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :items, filter_items(assigns))
    assigns = assign(assigns, :workspaces_in_use, workspaces_in_use(assigns.tasks))

    ~H"""
    <div class="h-screen bg-gray-950 text-gray-100 overflow-hidden">
      <!-- Project Selection Modal -->
      <%= if @show_project_modal do %>
        <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-50">
          <div class="bg-gray-900 border border-gray-800 rounded-xl shadow-2xl w-full max-w-lg mx-4 max-h-[90vh] overflow-y-auto">
            <%= if @modal_mode == "select" do %>
              <div class="p-6">
                <h2 class="text-2xl font-bold text-white mb-6">Select Project</h2>

                <%= if @projects == [] do %>
                  <p class="text-gray-400 mb-6">
                    No projects yet. Create your first project to get started.
                  </p>
                <% else %>
                  <div class="space-y-2 mb-6 max-h-64 overflow-y-auto">
                    <%= for project <- @projects do %>
                      <button
                        phx-click="select_project"
                        phx-value-id={project.id}
                        class="w-full text-left p-4 bg-gray-800 hover:bg-gray-700 rounded-lg transition"
                      >
                        <div class="font-medium text-white">{project.name}</div>
                        <div class="flex items-center gap-2 mt-1">
                          <%= if project.github_repo do %>
                            <span class="text-sm text-gray-400">{project.github_repo}</span>
                          <% end %>
                          <%= if project.worktrees != [] do %>
                            <span class="text-xs text-gray-500">
                              {length(project.worktrees)} workspace(s)
                            </span>
                          <% end %>
                        </div>
                      </button>
                    <% end %>
                  </div>
                <% end %>

                <button
                  phx-click="show_new_project"
                  class="w-full py-3 bg-indigo-600 hover:bg-indigo-500 rounded-lg text-white font-medium transition"
                >
                  + New Project
                </button>
              </div>
            <% else %>
              <div class="p-6">
                <div class="flex items-center justify-between mb-6">
                  <h2 class="text-2xl font-bold text-white">
                    {if @modal_mode == "edit", do: "Edit Project", else: "New Project"}
                  </h2>
                  <%= if @modal_mode == "new" and @projects != [] do %>
                    <button phx-click="show_select_project" class="text-gray-400 hover:text-gray-200">
                      Cancel
                    </button>
                  <% end %>
                  <%= if @modal_mode == "edit" do %>
                    <button phx-click="close_project_modal" class="text-gray-400 hover:text-gray-200">
                      Close
                    </button>
                  <% end %>
                </div>

                <form
                  phx-submit={if @modal_mode == "edit", do: "update_project", else: "create_project"}
                  class="space-y-4"
                >
                  <div>
                    <label class="block text-sm font-medium text-gray-400 mb-2">Project Name</label>
                    <input
                      type="text"
                      name="name"
                      value={@form_name}
                      placeholder="My Project"
                      required
                      class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 focus:outline-none focus:border-indigo-500"
                    />
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-400 mb-2">
                      GitHub Repository
                    </label>
                    <input
                      type="text"
                      name="repo"
                      value={@form_repo}
                      placeholder="owner/repo"
                      class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 font-mono text-sm focus:outline-none focus:border-indigo-500"
                    />
                    <p class="text-gray-500 text-xs mt-1">e.g., anthropics/claude-code</p>
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-400 mb-2">GitHub Token</label>
                    <input
                      type="password"
                      name="token"
                      value={@form_token}
                      placeholder="ghp_..."
                      class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 font-mono text-sm focus:outline-none focus:border-indigo-500"
                    />
                    <p class="text-gray-500 text-xs mt-1">
                      Optional. Uses GITHUB_TOKEN env var if not set.
                    </p>
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-400 mb-2">
                      Worktrees Directory
                    </label>
                    <input
                      type="text"
                      name="worktrees_dir"
                      value={@form_worktrees_dir}
                      placeholder="/path/to/worktrees"
                      class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 font-mono text-sm focus:outline-none focus:border-indigo-500"
                    />
                    <p class="text-gray-500 text-xs mt-1">
                      Directory containing your git worktrees. Subdirectories will be auto-discovered as workspaces.
                    </p>
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-400 mb-2">Branch Prefix</label>
                    <input
                      type="text"
                      name="branch_prefix"
                      value={@form_branch_prefix}
                      placeholder="issue"
                      class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 font-mono text-sm focus:outline-none focus:border-indigo-500"
                    />
                    <p class="text-gray-500 text-xs mt-1">
                      Prefix for branch names (e.g., "issue-34-fix-bug"). Defaults to "issue".
                    </p>
                  </div>

                  <div class="flex gap-3 pt-2">
                    <button
                      type="submit"
                      class="flex-1 py-3 bg-indigo-600 hover:bg-indigo-500 rounded-lg text-white font-medium transition"
                    >
                      {if @modal_mode == "edit", do: "Save Changes", else: "Create Project"}
                    </button>
                  </div>
                </form>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
      
    <!-- Main Dashboard -->
      <%= if @current_project do %>
        <div class="h-full flex flex-col">
          
    <!-- Error message -->
          <%= if @github_error do %>
            <div class="flex-shrink-0 px-4 py-2 bg-red-900/30 border-b border-red-800 text-red-300 text-sm">
              {@github_error} -
              <button phx-click="toggle_settings" class="underline">Go to Settings</button>
            </div>
          <% end %>
          
    <!-- Content area - scrollable -->
          <div
            class={"flex-1 overflow-y-auto min-h-0 transition-all duration-300 #{if @bottom_panel, do: "pb-10", else: "pb-10"}"}
            style={if @bottom_panel, do: "padding-bottom: 672px", else: ""}
          >
            <!-- Split View: Items List (1/3) + Detail View (2/3) -->
            <div class="flex h-full">
              <!-- Left Column: Items List (1/3 width) -->
              <div class="w-1/3 border-r border-gray-800 overflow-y-auto">
                <%= if Enum.empty?(@items) do %>
                  <div class="flex items-center justify-center h-full text-gray-500 p-4">
                    <%= cond do %>
                      <% @search != "" -> %>
                        No items match your search
                      <% !@current_project.github_repo -> %>
                        <button
                          phx-click="toggle_settings"
                          class="text-indigo-400 hover:text-indigo-300"
                        >
                          Configure your GitHub repository to get started
                        </button>
                      <% true -> %>
                        No issues
                    <% end %>
                  </div>
                <% else %>
                  <div class="divide-y divide-gray-800">
                    <%= for item <- @items do %>
                      <%= case item do %>
                        <% {:task, task} -> %>
                          <button
                            phx-click="select_task"
                            phx-value-id={task.id}
                            class={"block w-full text-left px-4 py-3 cursor-pointer transition group #{if @selected_task && @selected_task.id == task.id, do: "bg-gray-900", else: "hover:bg-gray-900/50"}"}
                          >
                            <div class="flex items-start justify-between">
                              <div class="flex-1 min-w-0">
                                <div class="flex items-center gap-2 mb-1">
                                  <span class="px-2 py-0.5 text-xs rounded bg-gray-700 text-gray-300">
                                    Issue
                                  </span>
                                  <span class={"px-2 py-0.5 text-xs rounded #{status_color(task.status)}"}>
                                    {task.status}
                                  </span>
                                  <% # Get issue number from field or parse from github_url
                                  issue_number =
                                    task.github_issue_number ||
                                      case parse_github_url(task.github_url || "") do
                                        {_, _, num} -> num
                                        _ -> nil
                                      end %>
                                  <%= if issue_number do %>
                                    <span class="text-gray-500 text-sm">
                                      #{issue_number}
                                    </span>
                                  <% end %>
                                </div>
                                <%= if task.github_url do %>
                                  <% # Parse github_url to get owner, repo, issue_number for link
                                  {owner, repo, issue_num} =
                                    if task.github_owner && task.github_repo &&
                                         task.github_issue_number do
                                      {task.github_owner, task.github_repo, task.github_issue_number}
                                    else
                                      parse_github_url(task.github_url)
                                    end %>
                                  <%= if owner && repo && issue_num do %>
                                    <a
                                      href={"https://github.com/#{owner}/#{repo}/issues/#{issue_num}"}
                                      target="_blank"
                                      class="text-white font-medium group-hover:text-indigo-400 transition hover:underline inline-flex items-center gap-1"
                                      onclick="event.stopPropagation()"
                                    >
                                      {task.title}
                                      <svg
                                        xmlns="http://www.w3.org/2000/svg"
                                        viewBox="0 0 20 20"
                                        fill="currentColor"
                                        class="w-3 h-3 opacity-50"
                                      >
                                        <path
                                          fill-rule="evenodd"
                                          d="M4.25 5.5a.75.75 0 00-.75.75v8.5c0 .414.336.75.75.75h8.5a.75.75 0 00.75-.75v-4a.75.75 0 011.5 0v4A2.25 2.25 0 0112.75 17h-8.5A2.25 2.25 0 012 14.75v-8.5A2.25 2.25 0 014.25 4h5a.75.75 0 010 1.5h-5z"
                                          clip-rule="evenodd"
                                        />
                                        <path
                                          fill-rule="evenodd"
                                          d="M6.194 12.753a.75.75 0 001.06.053L16.5 4.44v2.81a.75.75 0 001.5 0v-4.5a.75.75 0 00-.75-.75h-4.5a.75.75 0 000 1.5h2.553l-9.056 8.194a.75.75 0 00-.053 1.06z"
                                          clip-rule="evenodd"
                                        />
                                      </svg>
                                    </a>
                                  <% else %>
                                    <h3 class="text-white font-medium group-hover:text-indigo-400 transition">
                                      {task.title}
                                    </h3>
                                  <% end %>
                                <% else %>
                                  <h3 class="text-white font-medium group-hover:text-indigo-400 transition">
                                    {task.title}
                                  </h3>
                                <% end %>
                                <div class="flex items-center gap-2 mt-1">
                                  <span class="text-gray-500 text-xs">
                                    Updated {format_time(task.updated_at)}
                                  </span>
                                </div>
                              </div>
                              <div class="flex items-center gap-2 flex-shrink-0 ml-2">
                                <%= if task.worktree_path do %>
                                  <span class="flex items-center gap-1.5 text-gray-400 text-sm font-mono">
                                    <span class={"w-2 h-2 rounded-full #{if task.status == "active", do: "bg-green-500", else: "bg-gray-500"}"}>
                                    </span>
                                    {Path.basename(task.worktree_path)}
                                  </span>
                                <% end %>
                                <svg
                                  class="w-5 h-5 text-gray-600 group-hover:text-gray-400 transition flex-shrink-0"
                                  xmlns="http://www.w3.org/2000/svg"
                                  fill="none"
                                  viewBox="0 0 24 24"
                                  stroke="currentColor"
                                >
                                  <path
                                    stroke-linecap="round"
                                    stroke-linejoin="round"
                                    stroke-width="2"
                                    d="M9 5l7 7-7 7"
                                  />
                                </svg>
                              </div>
                            </div>
                          </button>
                        <% {:issue, issue} -> %>
                          <button
                            phx-click="select_issue"
                            phx-value-owner={issue.owner}
                            phx-value-repo={issue.repo}
                            phx-value-number={issue.number}
                            class={"block w-full text-left px-4 py-3 cursor-pointer transition group #{if @selected_issue && @selected_issue.number == issue.number, do: "bg-gray-900", else: "hover:bg-gray-900/50"}"}
                          >
                            <div class="flex items-start justify-between">
                              <div class="flex-1 min-w-0">
                                <div class="flex items-center gap-2 mb-1">
                                  <span class={"px-2 py-0.5 text-xs rounded #{if issue.type == :pull_request, do: "bg-blue-900 text-blue-300", else: "bg-gray-700 text-gray-300"}"}>
                                    {if issue.type == :pull_request, do: "PR", else: "Issue"}
                                  </span>
                                  <span class={"px-2 py-0.5 text-xs rounded #{if issue.state == "open", do: "bg-green-900 text-green-300", else: "bg-purple-900 text-purple-300"}"}>
                                    {issue.state}
                                  </span>
                                  <span class="text-gray-500 text-sm">
                                    #{issue.number}
                                  </span>
                                </div>
                                <a
                                  href={"https://github.com/#{issue.owner}/#{issue.repo}/#{if issue.type == :pull_request, do: "pull", else: "issues"}/#{issue.number}"}
                                  target="_blank"
                                  class="text-white font-medium group-hover:text-indigo-400 transition hover:underline inline-flex items-center gap-1"
                                  onclick="event.stopPropagation()"
                                >
                                  {issue.title}
                                  <svg
                                    xmlns="http://www.w3.org/2000/svg"
                                    viewBox="0 0 20 20"
                                    fill="currentColor"
                                    class="w-3 h-3 opacity-50"
                                  >
                                    <path
                                      fill-rule="evenodd"
                                      d="M4.25 5.5a.75.75 0 00-.75.75v8.5c0 .414.336.75.75.75h8.5a.75.75 0 00.75-.75v-4a.75.75 0 011.5 0v4A2.25 2.25 0 0112.75 17h-8.5A2.25 2.25 0 012 14.75v-8.5A2.25 2.25 0 014.25 4h5a.75.75 0 010 1.5h-5z"
                                      clip-rule="evenodd"
                                    />
                                    <path
                                      fill-rule="evenodd"
                                      d="M6.194 12.753a.75.75 0 001.06.053L16.5 4.44v2.81a.75.75 0 001.5 0v-4.5a.75.75 0 00-.75-.75h-4.5a.75.75 0 000 1.5h2.553l-9.056 8.194a.75.75 0 00-.053 1.06z"
                                      clip-rule="evenodd"
                                    />
                                  </svg>
                                </a>
                                <div class="flex items-center gap-2 mt-1">
                                  <%= if issue.labels != [] do %>
                                    <%= for label <- Enum.take(issue.labels, 3) do %>
                                      <span class="px-1.5 py-0.5 bg-gray-800 rounded text-xs text-gray-400">
                                        {label}
                                      </span>
                                    <% end %>
                                  <% end %>
                                  <span class="text-gray-500 text-xs">
                                    {issue.author} - {format_time(issue.updated_at)}
                                  </span>
                                </div>
                              </div>
                              <svg
                                class="w-5 h-5 text-gray-600 group-hover:text-gray-400 transition flex-shrink-0 ml-2"
                                fill="none"
                                stroke="currentColor"
                                viewBox="0 0 24 24"
                              >
                                <path
                                  stroke-linecap="round"
                                  stroke-linejoin="round"
                                  stroke-width="2"
                                  d="M9 5l7 7-7 7"
                                >
                                </path>
                              </svg>
                            </div>
                          </button>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              </div>
              
    <!-- Right Column: Detail View (2/3 width) -->
              <div class="w-2/3 overflow-y-auto">
                <%= if @selected_issue do %>
                  <div class="p-6 flex gap-6">
                    <!-- Issue Preview (770px max width) -->
                    <div style="max-width: 770px; width: 100%;">
                      <div class="bg-gray-900 border border-gray-800 rounded-lg p-6">
                        <div class="flex items-start justify-between mb-4">
                          <div class="flex-1">
                            <div class="flex items-center gap-2 mb-2">
                              <span class={"px-2 py-0.5 text-xs rounded #{if @selected_issue.state == "open", do: "bg-green-900 text-green-300", else: "bg-purple-900 text-purple-300"}"}>
                                {@selected_issue.state}
                              </span>
                              <span class="text-gray-500 text-sm">#{@selected_issue.number}</span>
                            </div>
                            <a
                              href={"https://github.com/#{@selected_issue.owner}/#{@selected_issue.repo}/#{if @selected_issue.type == :pull_request, do: "pull", else: "issues"}/#{@selected_issue.number}"}
                              target="_blank"
                              class="text-2xl font-bold text-white mb-2 hover:text-indigo-400 hover:underline inline-flex items-center gap-2 transition"
                            >
                              {@selected_issue.title}
                              <svg
                                xmlns="http://www.w3.org/2000/svg"
                                viewBox="0 0 20 20"
                                fill="currentColor"
                                class="w-4 h-4 opacity-50"
                              >
                                <path
                                  fill-rule="evenodd"
                                  d="M4.25 5.5a.75.75 0 00-.75.75v8.5c0 .414.336.75.75.75h8.5a.75.75 0 00.75-.75v-4a.75.75 0 011.5 0v4A2.25 2.25 0 0112.75 17h-8.5A2.25 2.25 0 012 14.75v-8.5A2.25 2.25 0 014.25 4h5a.75.75 0 010 1.5h-5z"
                                  clip-rule="evenodd"
                                />
                                <path
                                  fill-rule="evenodd"
                                  d="M6.194 12.753a.75.75 0 001.06.053L16.5 4.44v2.81a.75.75 0 001.5 0v-4.5a.75.75 0 00-.75-.75h-4.5a.75.75 0 000 1.5h2.553l-9.056 8.194a.75.75 0 00-.053 1.06z"
                                  clip-rule="evenodd"
                                />
                              </svg>
                            </a>
                            <%= if @selected_issue.labels != [] do %>
                              <div class="flex items-center gap-2 flex-wrap">
                                <%= for label <- @selected_issue.labels do %>
                                  <span class="px-2 py-0.5 bg-gray-800 rounded text-xs text-gray-400">
                                    {label}
                                  </span>
                                <% end %>
                              </div>
                            <% end %>
                          </div>
                        </div>
                        <%= if @selected_issue.body && @selected_issue.body != "" do %>
                          <div class="mt-4 pt-4 border-t border-gray-800">
                            <h3 class="text-sm font-medium text-gray-400 mb-2">Description</h3>
                            <div class="prose prose-invert prose-sm max-w-none text-gray-300">
                              {render_markdown(@selected_issue.body)}
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                    
    <!-- Configuration Box / Task Details -->
                    <div class="flex-shrink-0" style="width: 640px;">
                      <div class="bg-gray-900 border border-gray-800 rounded-lg p-5 sticky top-6">
                        <%= if @selected_task do %>
                          <!-- Task Details -->
                          <h2 class="text-lg font-semibold text-white mb-4">Issue Details</h2>
                          <div class="space-y-4">
                            <!-- Claude Command -->
                            <div>
                              <label class="block text-sm font-medium text-gray-400 mb-2">
                                Claude Command
                              </label>
                              <div class="relative">
                                <code class="block w-full px-3 py-2 bg-gray-950 border border-gray-700 rounded text-indigo-300 text-sm font-mono pr-20">
                                  /claudette {@current_project.id}/{@selected_task.id}
                                </code>
                                <button
                                  type="button"
                                  phx-click="copy_command"
                                  phx-value-command={"/claudette #{@current_project.id}/#{@selected_task.id}"}
                                  class="absolute right-2 top-2 px-2 py-1 bg-gray-800 hover:bg-gray-700 rounded text-xs text-gray-300 transition"
                                >
                                  Copy
                                </button>
                              </div>
                            </div>
                            
    <!-- Configuration -->
                            <%= if @selected_task.worktree_path || @selected_task.branch_name || @selected_task.instruction_template || (@selected_task.context_md && @selected_task.context_md != "") do %>
                              <div class="pt-3 border-t border-gray-800">
                                <h3 class="text-sm font-medium text-gray-400 mb-2">
                                  Configuration
                                </h3>
                                <dl class="space-y-2 text-sm">
                                  <%= if @selected_task.worktree_path do %>
                                    <div class="flex justify-between">
                                      <dt class="text-gray-500">Workspace:</dt>
                                      <dd class="flex items-center gap-1.5 text-gray-400 font-mono">
                                        <span class={"w-2 h-2 rounded-full #{if @selected_task.status == "active", do: "bg-green-500", else: "bg-gray-500"}"}>
                                        </span>
                                        {Path.basename(@selected_task.worktree_path)}
                                      </dd>
                                    </div>
                                  <% end %>
                                  <%= if @selected_task.branch_name do %>
                                    <div class="flex justify-between">
                                      <dt class="text-gray-500">Branch:</dt>
                                      <dd class="text-gray-300 font-mono">
                                        {@selected_task.branch_name}
                                      </dd>
                                    </div>
                                  <% end %>
                                  <%= if @selected_task.instruction_template do %>
                                    <div class="flex justify-between">
                                      <dt class="text-gray-500">Instruction Template:</dt>
                                      <dd class="text-gray-300 text-right max-w-xs truncate">
                                        {@selected_task.instruction_template}
                                      </dd>
                                    </div>
                                  <% end %>
                                  <%= if @selected_task.context_md && @selected_task.context_md != "" do %>
                                    <div>
                                      <dt class="text-gray-500 mb-2">Context:</dt>
                                      <dd>
                                        <pre class="bg-gray-800 p-3 rounded text-gray-300 text-xs whitespace-pre-wrap max-h-48 overflow-y-auto"><%= @selected_task.context_md %></pre>
                                      </dd>
                                    </div>
                                  <% end %>
                                </dl>
                              </div>
                            <% end %>
                            
    <!-- Actions -->
                            <%= if @selected_task.status == "active" && @selected_task.worktree_path do %>
                              <div class="pt-3 border-t border-gray-800">
                                <button
                                  phx-click="done_reset_worktree"
                                  phx-value-task_id={@selected_task.id}
                                  data-confirm="This will reset the worktree to origin/main and mark the task as completed. The feature branch will be preserved. Continue?"
                                  class="w-full px-3 py-2 bg-green-900 hover:bg-green-800 rounded text-green-300 text-sm font-medium transition"
                                >
                                  Done, Reset Worktree
                                </button>
                              </div>
                            <% end %>
                          </div>
                        <% else %>
                          <h2 class="text-lg font-semibold text-white mb-4">Configuration</h2>
                          <div>
                            <%= if @creation_initialized_task do %>
                              <!-- Initialized State -->
                              <div class="space-y-4">
                                <div class="bg-green-900/30 border border-green-800 rounded p-4">
                                  <div class="flex items-start gap-3">
                                    <svg
                                      class="w-5 h-5 text-green-400 flex-shrink-0 mt-0.5"
                                      fill="none"
                                      stroke="currentColor"
                                      viewBox="0 0 24 24"
                                    >
                                      <path
                                        stroke-linecap="round"
                                        stroke-linejoin="round"
                                        stroke-width="2"
                                        d="M5 13l4 4L19 7"
                                      >
                                      </path>
                                    </svg>
                                    <div class="flex-1">
                                      <h3 class="text-sm font-semibold text-green-300 mb-1">
                                        Worktree Initialized
                                      </h3>
                                      <p class="text-xs text-green-400/80">
                                        Git workspace setup complete. Use the command below to start working.
                                      </p>
                                    </div>
                                  </div>
                                </div>

                                <div>
                                  <label class="block text-sm font-medium text-gray-400 mb-2">
                                    Claude Command
                                  </label>
                                  <div class="relative">
                                    <code class="block w-full px-3 py-2 bg-gray-950 border border-gray-700 rounded text-green-400 text-sm font-mono">
                                      /claudette {@current_project.id}/{@creation_initialized_task.id}
                                    </code>
                                    <button
                                      type="button"
                                      phx-click="copy_command"
                                      phx-value-command={"/claudette #{@current_project.id}/#{@creation_initialized_task.id}"}
                                      class="absolute right-2 top-2 px-2 py-1 bg-gray-800 hover:bg-gray-700 rounded text-xs text-gray-300 transition"
                                    >
                                      Copy
                                    </button>
                                  </div>
                                  <p class="text-xs text-gray-500 mt-1">
                                    Run this command in Claude Code to load the task workspace
                                  </p>
                                </div>

                                <div class="pt-3 border-t border-gray-800">
                                  <h3 class="text-xs font-medium text-gray-400 mb-2">
                                    Configuration Used
                                  </h3>
                                  <dl class="space-y-1 text-xs">
                                    <%= if @creation_initialized_task.worktree_path do %>
                                      <div class="flex justify-between">
                                        <dt class="text-gray-500">Workspace:</dt>
                                        <dd class="text-gray-300 font-mono">
                                          {Path.basename(@creation_initialized_task.worktree_path)}
                                        </dd>
                                      </div>
                                    <% end %>
                                    <%= if @creation_initialized_task.branch_name do %>
                                      <div class="flex justify-between">
                                        <dt class="text-gray-500">Branch:</dt>
                                        <dd class="text-gray-300 font-mono">
                                          {@creation_initialized_task.branch_name}
                                        </dd>
                                      </div>
                                    <% end %>
                                  </dl>
                                </div>
                              </div>
                            <% else %>
                              <!-- Form State -->
                              <form phx-change="update_creation_form">
                                <div class="space-y-4">
                                  <!-- Workspace Dropdown -->
                                  <%= if @current_project.worktrees != [] do %>
                                    <div>
                                      <label class="block text-sm font-medium text-gray-400 mb-2">
                                        Workspace
                                      </label>
                                      <select
                                        name="workspace"
                                        class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 text-sm focus:outline-none focus:border-indigo-500"
                                      >
                                        <option value="" selected={@creation_workspace == nil}>
                                          Select...
                                        </option>
                                        <%= for worktree <- @current_project.worktrees do %>
                                          <% status =
                                            Map.get(@worktree_status, worktree, %{
                                              dirty: false,
                                              in_use_by: nil
                                            }) %>
                                          <% disabled = status.dirty or status.in_use_by != nil %>
                                          <option
                                            value={worktree}
                                            selected={@creation_workspace == worktree}
                                            disabled={disabled}
                                          >
                                            {Path.basename(worktree)}
                                            <%= if status.dirty && status.in_use_by do %>
                                              (Dirty & In use)
                                            <% end %>
                                            <%= if status.dirty && !status.in_use_by do %>
                                              (Uncommitted changes)
                                            <% end %>
                                            <%= if !status.dirty && status.in_use_by do %>
                                              (In use)
                                            <% end %>
                                          </option>
                                        <% end %>
                                      </select>
                                      <%= if Enum.all?(@current_project.worktrees, fn wt ->
                                  status = Map.get(@worktree_status, wt, %{dirty: false, in_use_by: nil})
                                  status.dirty or status.in_use_by != nil
                                end) do %>
                                        <p class="text-yellow-500 text-xs mt-1">
                                          All worktrees are busy or have uncommitted changes
                                        </p>
                                      <% end %>
                                    </div>
                                    
    <!-- Branch Name Input -->
                                    <div>
                                      <label class="block text-sm font-medium text-gray-400 mb-2">
                                        Branch *
                                      </label>
                                      <input
                                        type="text"
                                        name="branch"
                                        value={@creation_branch}
                                        placeholder="feature/my-branch"
                                        class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 text-sm focus:outline-none focus:border-indigo-500"
                                      />
                                    </div>
                                    
    <!-- Base Branch Dropdown -->
                                    <div>
                                      <label class="block text-sm font-medium text-gray-400 mb-2">
                                        Base
                                      </label>
                                      <select
                                        name="base"
                                        class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 text-sm focus:outline-none focus:border-indigo-500"
                                      >
                                        <%= if @available_branches == [] do %>
                                          <option value="main" selected={@creation_base == "main"}>
                                            main
                                          </option>
                                          <option value="master" selected={@creation_base == "master"}>
                                            master
                                          </option>
                                          <option
                                            value="develop"
                                            selected={@creation_base == "develop"}
                                          >
                                            develop
                                          </option>
                                        <% else %>
                                          <%= for branch <- @available_branches do %>
                                            <option value={branch} selected={@creation_base == branch}>
                                              {branch}
                                            </option>
                                          <% end %>
                                        <% end %>
                                      </select>
                                    </div>
                                  <% end %>
                                  
    <!-- Instruction Template Dropdown -->
                                  <%= if @current_project.instructions != [] do %>
                                    <div>
                                      <label class="block text-sm font-medium text-gray-400 mb-2">
                                        Instructions Template
                                      </label>
                                      <select
                                        name="instruction_template"
                                        class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 text-sm focus:outline-none focus:border-indigo-500"
                                      >
                                        <%= for template <- @current_project.instructions do %>
                                          <option
                                            value={template["name"]}
                                            selected={
                                              @creation_instruction_template == template["name"]
                                            }
                                          >
                                            {template["name"]}{if template["default"],
                                              do: " (default)",
                                              else: ""}
                                          </option>
                                        <% end %>
                                      </select>
                                    </div>
                                  <% end %>
                                  
    <!-- Context Textarea -->
                                  <div>
                                    <label class="block text-sm font-medium text-gray-400 mb-2">
                                      Extra Context
                                    </label>
                                    <textarea
                                      name="context"
                                      rows="8"
                                      placeholder="Additional instructions..."
                                      class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 text-sm font-mono focus:outline-none focus:border-indigo-500"
                                    >{@creation_context}</textarea>
                                  </div>
                                  
    <!-- Error Display -->
                                  <%= if @creation_error do %>
                                    <div class="bg-red-900/30 border border-red-800 rounded p-3 text-red-300 text-xs">
                                      {@creation_error}
                                    </div>
                                  <% end %>
                                  
    <!-- Initialize Worktree Button -->
                                  <button
                                    type="button"
                                    phx-click="create_task_from_issue"
                                    disabled={@creation_loading}
                                    class="w-full px-4 py-3 bg-indigo-600 hover:bg-indigo-500 rounded-lg text-white font-semibold transition disabled:opacity-50 disabled:cursor-not-allowed"
                                  >
                                    {if @creation_loading,
                                      do: "Initializing...",
                                      else: "Initialize Worktree"}
                                  </button>
                                </div>
                              </form>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% else %>
                  <div class="flex items-center justify-center h-full text-gray-500">
                    Click a task or issue
                  </div>
                <% end %>
              </div>
            </div>
          </div>
          
    <!-- Bottom Panel (animated) -->
          <div
            class={"fixed bottom-8 left-0 right-0 bg-gray-900 border-t border-gray-800 transition-transform duration-300 ease-out #{if @bottom_panel, do: "translate-y-0", else: "translate-y-full"}"}
            style="height: 640px;"
          >
            <%= if @bottom_panel == :terminal do %>
              <!-- Terminal Panel -->
              <div class="h-full flex flex-col">
                <div class="flex items-center justify-between px-4 py-2 border-b border-gray-800 flex-shrink-0">
                  <div class="flex items-center gap-4">
                    <span class="text-sm font-medium text-gray-300">Terminal</span>
                    <%= if @current_project.worktrees != [] do %>
                      <div class="flex items-center gap-1">
                        <%= for worktree <- @current_project.worktrees do %>
                          <button
                            phx-click="select_terminal_workspace"
                            phx-value-workspace={worktree}
                            class={"px-2 py-1 rounded text-xs font-mono transition #{if @terminal_workspace == worktree, do: "bg-gray-700 text-white", else: "text-gray-500 hover:text-gray-300 hover:bg-gray-800"}"}
                          >
                            {Path.basename(worktree)}
                          </button>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                  <button phx-click="close_bottom_panel" class="text-gray-500 hover:text-gray-300">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M6 18L18 6M6 6l12 12"
                      >
                      </path>
                    </svg>
                  </button>
                </div>
                <div class="flex-1 overflow-hidden">
                  <div
                    id="dashboard-terminal"
                    phx-hook="Terminal"
                    phx-update="ignore"
                    class="h-full w-full"
                  >
                  </div>
                </div>
              </div>
            <% end %>

            <%= if @bottom_panel == :settings do %>
              <!-- Settings Panel -->
              <div class="h-full flex flex-col">
                <div class="flex items-center justify-between px-4 py-2 border-b border-gray-800">
                  <span class="text-sm font-medium text-gray-300">Project Settings</span>
                  <button phx-click="close_bottom_panel" class="text-gray-500 hover:text-gray-300">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M6 18L18 6M6 6l12 12"
                      >
                      </path>
                    </svg>
                  </button>
                </div>
                <div class="flex-1 overflow-y-auto p-4">
                  <form phx-submit="update_project" class="max-w-2xl space-y-4">
                    <div class="grid grid-cols-2 gap-4">
                      <div>
                        <label class="block text-xs font-medium text-gray-500 mb-1">
                          Project Name
                        </label>
                        <input
                          type="text"
                          name="name"
                          value={@form_name}
                          required
                          class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 text-sm focus:outline-none focus:border-indigo-500"
                        />
                      </div>
                      <div>
                        <label class="block text-xs font-medium text-gray-500 mb-1">
                          GitHub Repository
                        </label>
                        <input
                          type="text"
                          name="repo"
                          value={@form_repo}
                          placeholder="owner/repo"
                          class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 font-mono text-sm focus:outline-none focus:border-indigo-500"
                        />
                      </div>
                    </div>
                    <div class="grid grid-cols-2 gap-4">
                      <div>
                        <label class="block text-xs font-medium text-gray-500 mb-1">
                          GitHub Token
                        </label>
                        <input
                          type="password"
                          name="token"
                          value={@form_token}
                          placeholder="ghp_..."
                          class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 font-mono text-sm focus:outline-none focus:border-indigo-500"
                        />
                      </div>
                      <div>
                        <label class="block text-xs font-medium text-gray-500 mb-1">
                          Worktrees Directory
                        </label>
                        <input
                          type="text"
                          name="worktrees_dir"
                          value={@form_worktrees_dir}
                          placeholder="/path/to/worktrees"
                          class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 font-mono text-sm focus:outline-none focus:border-indigo-500"
                        />
                      </div>
                    </div>
                    <div>
                      <label class="block text-xs font-medium text-gray-500 mb-1">
                        Branch Prefix
                      </label>
                      <input
                        type="text"
                        name="branch_prefix"
                        value={@form_branch_prefix}
                        placeholder="issue"
                        class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-gray-100 font-mono text-sm focus:outline-none focus:border-indigo-500"
                      />
                      <p class="text-gray-500 text-xs mt-1">
                        Prefix for branch names (e.g., "issue-34-fix-bug"). Defaults to "issue".
                      </p>
                    </div>
                    <div class="flex items-center gap-3 pt-2">
                      <button
                        type="submit"
                        class="px-4 py-2 bg-indigo-600 hover:bg-indigo-500 rounded text-white text-sm font-medium transition"
                      >
                        Save Changes
                      </button>
                      <button
                        type="button"
                        phx-click="close_bottom_panel"
                        class="px-4 py-2 text-gray-400 hover:text-gray-200 text-sm transition"
                      >
                        Cancel
                      </button>
                    </div>
                  </form>
                  <div class="mt-6 pt-6 border-t border-gray-800">
                    <h3 class="text-sm font-medium text-gray-400 mb-3">Project Management</h3>
                    <div class="flex gap-2">
                      <%= if length(@projects) > 1 do %>
                        <button
                          type="button"
                          phx-click="open_project_selector"
                          class="px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded text-gray-300 text-sm font-medium transition"
                        >
                          Switch Project
                        </button>
                      <% end %>
                      <button
                        type="button"
                        phx-click="show_new_project"
                        class="px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded text-gray-300 text-sm font-medium transition"
                      >
                        Create New Project
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Fixed Bottom Bar -->
        <div class="fixed bottom-0 left-0 right-0 h-8 bg-gray-900 border-t border-gray-800 flex items-center justify-between px-4 z-40">
          <!-- Left: GitHub link -->
          <div class="flex items-center gap-2">
            <%= if @current_project.github_repo do %>
              <a
                href={"https://github.com/#{@current_project.github_repo}"}
                target="_blank"
                class="text-gray-500 hover:text-gray-300 text-xs font-mono transition"
              >
                {@current_project.github_repo}
              </a>
            <% end %>
          </div>
          <!-- Right: Terminal and Settings -->
          <div class="flex items-center gap-2">
            <button
              phx-click="toggle_terminal"
              class={"p-1.5 rounded transition #{if @bottom_panel == :terminal, do: "text-indigo-400 bg-gray-800", else: "text-gray-500 hover:text-gray-300 hover:bg-gray-800"}"}
              title="Terminal"
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
                >
                </path>
              </svg>
            </button>
            <button
              phx-click="toggle_settings"
              class={"p-1.5 rounded transition #{if @bottom_panel == :settings, do: "text-indigo-400 bg-gray-800", else: "text-gray-500 hover:text-gray-300 hover:bg-gray-800"}"}
              title="Settings"
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
                >
                </path>
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                >
                </path>
              </svg>
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp status_color("active"), do: "bg-yellow-900 text-yellow-300"
  defp status_color("completed"), do: "bg-purple-900 text-purple-300"
  defp status_color("archived"), do: "bg-gray-800 text-gray-400"
  defp status_color(_), do: "bg-gray-800 text-gray-400"

  defp format_time(nil), do: "never"

  defp format_time(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        now = DateTime.utc_now()
        diff = DateTime.diff(now, dt, :second)

        cond do
          diff < 60 -> "just now"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86400 -> "#{div(diff, 3600)}h ago"
          diff < 604_800 -> "#{div(diff, 86400)}d ago"
          true -> Calendar.strftime(dt, "%b %d")
        end

      _ ->
        "unknown"
    end
  end

  defp render_markdown(nil), do: ""
  defp render_markdown(""), do: ""

  defp render_markdown(markdown) do
    case Earmark.as_html(markdown) do
      {:ok, html, _} -> Phoenix.HTML.raw(html)
      {:error, _, _} -> Phoenix.HTML.raw("<p>#{Phoenix.HTML.html_escape(markdown)}</p>")
    end
  end

  # Parse GitHub URL to extract owner, repo, and issue number
  # Expected format: https://github.com/owner/repo/issues/123
  defp parse_github_url(nil), do: {nil, nil, nil}
  defp parse_github_url(""), do: {nil, nil, nil}

  defp parse_github_url(url) do
    cond do
      # Handle short format: "owner/repo#123"
      String.contains?(url, "#") ->
        case String.split(url, ["#", "/"]) do
          [owner, repo, issue_num_str] ->
            case Integer.parse(issue_num_str) do
              {issue_num, _} -> {owner, repo, issue_num}
              :error -> {nil, nil, nil}
            end

          _ ->
            {nil, nil, nil}
        end

      # Handle full URL format: "https://github.com/owner/repo/issues/123"
      String.contains?(url, "github.com") ->
        case String.split(url, "/") do
          [_protocol, "", _host, owner, repo, "issues", issue_num_str] ->
            case Integer.parse(issue_num_str) do
              {issue_num, _} -> {owner, repo, issue_num}
              :error -> {nil, nil, nil}
            end

          _ ->
            {nil, nil, nil}
        end

      true ->
        {nil, nil, nil}
    end
  end
end
