defmodule ClaudetteWeb.TaskLive do
  use ClaudetteWeb, :live_view

  alias Claudette.Tasks
  alias Claudette.Config
  alias Claudette.Integrations.GitHub

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       project_id: nil,
       project: nil,
       task: nil,
       form: nil,
       editing: false,
       github_data: nil,
       github_loading: false,
       github_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, %{"project_id" => project_id, "id" => id}) do
    project = Config.load_project_config(project_id)

    case Tasks.get_task(project_id, id) do
      {:ok, task} ->
        socket =
          assign(socket,
            project_id: project_id,
            project: project,
            task: task,
            editing: false,
            page_title: task.title
          )

        if connected?(socket) do
          if task.github_url, do: send(self(), {:fetch_github, task.github_url})
        end

        socket

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Task not found")
        |> push_navigate(to: ~p"/")
    end
  end

  defp apply_action(socket, :edit, %{"project_id" => project_id, "id" => id}) do
    project = Config.load_project_config(project_id)

    case Tasks.get_task(project_id, id) do
      {:ok, task} ->
        form =
          to_form(%{
            "title" => task.title || "",
            "github_url" => task.github_url || "",
            "context_md" => task.context_md || "",
            "status" => task.status || "active"
          })

        assign(socket,
          project_id: project_id,
          project: project,
          task: task,
          form: form,
          page_title: "Edit: #{task.title}"
        )

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Task not found")
        |> push_navigate(to: ~p"/")
    end
  end

  @impl true
  def handle_event("save", %{"title" => title} = params, socket) do
    project_id = socket.assigns.project_id
    task = socket.assigns.task

    attrs = %{
      title: title,
      github_url: blank_to_nil(params["github_url"]),
      context_md: params["context_md"] || "",
      status: params["status"] || "active"
    }

    case Tasks.update_task(project_id, task.id, attrs) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> put_flash(:info, "Task updated")
         |> push_navigate(to: ~p"/projects/#{project_id}/tasks/#{task.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update task")}
    end
  end

  @impl true
  def handle_event("delete", _, socket) do
    project_id = socket.assigns.project_id
    task = socket.assigns.task

    case Tasks.delete_task(project_id, task.id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Task deleted")
         |> push_navigate(to: ~p"/")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete task")}
    end
  end

  @impl true
  def handle_event("change_status", %{"status" => status}, socket) do
    project_id = socket.assigns.project_id
    task = socket.assigns.task

    case Tasks.change_status(project_id, task.id, status) do
      {:ok, updated_task} ->
        {:noreply, assign(socket, task: updated_task)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  @impl true
  def handle_event("done_reset_worktree", _, socket) do
    project_id = socket.assigns.project_id
    task = socket.assigns.task

    # Validation: Only allow for active tasks with a worktree
    if task.status == "active" && task.worktree_path do
      case Tasks.complete_task_with_reset(project_id, task.id) do
        {:ok, updated_task} ->
          {:noreply,
           socket
           |> assign(task: updated_task)
           |> put_flash(:info, "Task completed and worktree reset successfully")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to reset worktree: #{reason}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Task must be active and have a worktree")}
    end
  end

  @impl true
  def handle_info({:fetch_github, github_url}, socket) do
    socket = assign(socket, github_loading: true, github_error: nil)

    case GitHub.fetch_issue(github_url) do
      {:ok, data} ->
        {:noreply, assign(socket, github_data: data, github_loading: false)}

      {:error, :not_found} ->
        {:noreply, assign(socket, github_error: "Issue not found", github_loading: false)}

      {:error, :invalid_format} ->
        {:noreply, assign(socket, github_error: "Invalid format", github_loading: false)}

      {:error, _} ->
        {:noreply, assign(socket, github_error: "Failed to fetch", github_loading: false)}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(str), do: str

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto px-4 py-8">
        <.link navigate={~p"/"} class="text-gray-500 hover:text-gray-300 transition mb-6 inline-block">
          ← Back to Dashboard
        </.link>

        <%= if @live_action == :edit do %>
          <.task_form form={@form} task={@task} project_id={@project_id} />
        <% else %>
          <.task_show
            task={@task}
            project_id={@project_id}
            github_data={@github_data}
            github_loading={@github_loading}
            github_error={@github_error}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp task_form(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-800 rounded-lg p-6">
      <h1 class="text-2xl font-bold text-white mb-6">Edit Task</h1>

      <.form for={@form} phx-submit="save" class="space-y-6">
        <div>
          <label class="block text-sm font-medium text-gray-400 mb-2">Title</label>
          <input
            type="text"
            name="title"
            value={@form[:title].value}
            required
            class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 focus:outline-none focus:border-indigo-500"
            placeholder="Task title..."
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-400 mb-2">GitHub Issue/PR</label>
          <input
            type="text"
            name="github_url"
            value={@form[:github_url].value}
            class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 focus:outline-none focus:border-indigo-500"
            placeholder="owner/repo#42"
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-400 mb-2">Status</label>
          <select
            name="status"
            class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 focus:outline-none focus:border-indigo-500"
          >
            <option value="active" selected={@form[:status].value == "active"}>Active</option>
            <option value="completed" selected={@form[:status].value == "completed"}>
              Completed
            </option>
            <option value="archived" selected={@form[:status].value == "archived"}>Archived</option>
          </select>
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-400 mb-2">
            Context (Markdown) - Instructions for Claude
          </label>
          <textarea
            name="context_md"
            rows="10"
            class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 font-mono text-sm focus:outline-none focus:border-indigo-500"
            placeholder="Add context, instructions, or notes for Claude..."
          ><%= @form[:context_md].value %></textarea>
        </div>

        <div class="flex justify-end gap-3">
          <.link
            navigate={~p"/projects/#{@project_id}/tasks/#{@task.id}"}
            class="px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-gray-300 transition"
          >
            Cancel
          </.link>
          <button
            type="submit"
            class="px-6 py-2 bg-indigo-600 hover:bg-indigo-500 rounded-lg text-white font-medium transition"
          >
            Save Changes
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp task_show(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="bg-gray-900 border border-gray-800 rounded-lg p-6">
        <div class="flex items-start justify-between mb-4">
          <div>
            <h1 class="text-2xl font-bold text-white">{@task.title}</h1>
            <%= if @task.github_url do %>
              <div class="flex items-center gap-4 mt-2 text-sm text-gray-500">
                <span><span class="text-green-400">GitHub:</span> {@task.github_url}</span>
              </div>
            <% end %>
          </div>
          <div class="flex items-center gap-2">
            <select
              phx-change="change_status"
              name="status"
              class={"px-3 py-1.5 rounded-lg text-sm font-medium #{status_bg(@task.status)}"}
            >
              <option value="active" selected={@task.status == "active"}>Active</option>
              <option value="completed" selected={@task.status == "completed"}>Completed</option>
              <option value="archived" selected={@task.status == "archived"}>Archived</option>
            </select>
          </div>
        </div>

        <div class="flex items-center gap-3 p-3 bg-gray-800 rounded-lg">
          <code class="flex-1 text-indigo-300 font-mono">/claudette {@project_id}/{@task.id}</code>
          <button
            phx-hook="Clipboard"
            id="copy-command"
            data-content={"/claudette #{@project_id}/#{@task.id}"}
            class="px-3 py-1 bg-gray-700 hover:bg-gray-600 rounded text-sm text-gray-300 transition"
          >
            Copy
          </button>
        </div>

        <div class="flex gap-3 mt-4">
          <.link
            navigate={~p"/projects/#{@project_id}/tasks/#{@task.id}/edit"}
            class="px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-gray-300 transition"
          >
            Edit Task
          </.link>
          <.link
            navigate={~p"/terminal"}
            class="px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-gray-300 transition"
          >
            Open Terminal
          </.link>
          <%= if @task.status == "active" && @task.worktree_path do %>
            <button
              phx-click="done_reset_worktree"
              data-confirm="This will reset the worktree to origin/main and mark the task as completed. The feature branch will be preserved. Continue?"
              class="px-4 py-2 bg-green-900 hover:bg-green-800 rounded-lg text-green-300 transition"
            >
              Done, Reset Worktree
            </button>
          <% end %>
          <button
            phx-click="delete"
            data-confirm="Are you sure you want to delete this task?"
            class="px-4 py-2 bg-red-900 hover:bg-red-800 rounded-lg text-red-300 transition"
          >
            Delete
          </button>
        </div>
      </div>
      
    <!-- GitHub Integration -->
      <%= if @task.github_url do %>
        <div class="bg-gray-900 border border-gray-800 rounded-lg p-6">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold text-white flex items-center gap-2">
              <span class="text-green-400">GitHub</span>
              {@task.github_url}
            </h2>
            <%= if @github_data do %>
              <a
                href={@github_data.url}
                target="_blank"
                class="text-sm text-green-400 hover:text-green-300"
              >
                Open on GitHub →
              </a>
            <% end %>
          </div>

          <%= cond do %>
            <% @github_loading -> %>
              <div class="text-gray-500">Loading...</div>
            <% @github_error -> %>
              <div class="text-red-400">{@github_error}</div>
            <% @github_data -> %>
              <div class="space-y-3">
                <div>
                  <span class="text-gray-500 text-sm">Title:</span>
                  <span class="text-white ml-2">{@github_data.title}</span>
                </div>
                <div class="flex items-center gap-4">
                  <span class={"px-2 py-1 rounded text-xs #{if @github_data.state == "open", do: "bg-green-900 text-green-300", else: "bg-purple-900 text-purple-300"}"}>
                    {@github_data.state}
                  </span>
                  <span class={"px-2 py-1 rounded text-xs #{if @github_data.type == :pull_request, do: "bg-blue-900 text-blue-300", else: "bg-gray-700 text-gray-300"}"}>
                    {if @github_data.type == :pull_request, do: "Pull Request", else: "Issue"}
                  </span>
                  <span class="text-gray-500 text-sm">by {@github_data.author}</span>
                </div>
                <%= if @github_data.labels != [] do %>
                  <div class="flex items-center gap-2">
                    <%= for label <- @github_data.labels do %>
                      <span class="px-2 py-0.5 bg-gray-700 rounded text-xs text-gray-300">
                        {label}
                      </span>
                    <% end %>
                  </div>
                <% end %>
                <%= if @github_data.body do %>
                  <div class="mt-3">
                    <span class="text-gray-500 text-sm block mb-2">Description:</span>
                    <pre class="bg-gray-800 p-3 rounded text-gray-300 text-sm whitespace-pre-wrap max-h-64 overflow-y-auto"><%= @github_data.body %></pre>
                  </div>
                <% end %>
              </div>
            <% true -> %>
              <div class="text-gray-500">No data</div>
          <% end %>
        </div>
      <% end %>

      <%= if @task.context_md && @task.context_md != "" do %>
        <div class="bg-gray-900 border border-gray-800 rounded-lg p-6">
          <h2 class="text-lg font-semibold text-white mb-4">Context</h2>
          <div class="prose prose-invert prose-sm max-w-none">
            <pre class="bg-gray-800 p-4 rounded-lg overflow-x-auto text-gray-300 text-sm whitespace-pre-wrap"><%= @task.context_md %></pre>
          </div>
        </div>
      <% end %>

      <%= if @task.claude_notes_md && @task.claude_notes_md != "" do %>
        <div class="bg-gray-900 border border-gray-800 rounded-lg p-6">
          <h2 class="text-lg font-semibold text-white mb-4">Claude's Notes</h2>
          <div class="prose prose-invert prose-sm max-w-none">
            <pre class="bg-gray-800 p-4 rounded-lg overflow-x-auto text-gray-300 text-sm whitespace-pre-wrap"><%= @task.claude_notes_md %></pre>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp status_bg("active"), do: "bg-green-900 text-green-300 border border-green-800"
  defp status_bg("completed"), do: "bg-blue-900 text-blue-300 border border-blue-800"
  defp status_bg("archived"), do: "bg-gray-800 text-gray-400 border border-gray-700"
  defp status_bg(_), do: "bg-gray-800 text-gray-400 border border-gray-700"
end
