defmodule ClaudetteWeb.TerminalLive do
  use ClaudetteWeb, :live_view

  alias Claudette.Terminal.Session

  # Use home directory as default workspace for standalone terminal
  @default_workspace System.get_env("HOME") || "/"

  @impl true
  def mount(params, _session, socket) do
    workspace = params["workspace"] || @default_workspace

    if connected?(socket) do
      # Subscribe to terminal output for this workspace
      Session.subscribe(workspace)
      Session.ensure_terminal(workspace)

      # Get existing scrollback for this session
      scrollback = Session.get_scrollback(workspace)

      # If we have scrollback, send it to the client
      if scrollback != "" do
        send(self(), {:send_scrollback, scrollback})
      end
    end

    task_id = params["task"]

    {:ok,
     assign(socket,
       page_title: "Terminal",
       task_id: task_id,
       workspace: workspace
     )}
  end

  @impl true
  def handle_info({:send_scrollback, data}, socket) do
    {:noreply, push_event(socket, "terminal:output", %{data: Base.encode64(data)})}
  end

  @impl true
  def handle_info({:terminal_output, _worktree_path, data}, socket) do
    {:noreply, push_event(socket, "terminal:output", %{data: Base.encode64(data)})}
  end

  @impl true
  def handle_event("terminal:input", %{"data" => data}, socket) do
    workspace = socket.assigns.workspace

    case Base.decode64(data) do
      {:ok, decoded} ->
        Session.send_input(workspace, decoded)

      :error ->
        Session.send_input(workspace, data)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal:resize", %{"rows" => rows, "cols" => cols}, socket) do
    Session.resize(socket.assigns.workspace, rows, cols)
    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal:reset", _, socket) do
    Session.reset(socket.assigns.workspace)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen bg-gray-950 flex flex-col">
      <header class="flex items-center justify-between px-4 py-3 bg-gray-900 border-b border-gray-800">
        <div class="flex items-center gap-4">
          <.link navigate={~p"/"} class="text-gray-400 hover:text-gray-200 transition">
            ← Dashboard
          </.link>
          <h1 class="text-lg font-semibold text-white">Terminal</h1>
          <%= if @task_id do %>
            <span class="text-sm text-gray-500">
              Task: <code class="text-indigo-400">{@task_id}</code>
            </span>
          <% end %>
        </div>
        <div class="flex items-center gap-2">
          <button
            phx-click="terminal:reset"
            class="px-3 py-1.5 bg-gray-800 hover:bg-gray-700 rounded text-sm text-gray-300 transition"
          >
            Reset Shell
          </button>
        </div>
      </header>

      <div class="flex-1 overflow-hidden">
        <div
          id="terminal-container"
          phx-hook="Terminal"
          phx-update="ignore"
          class="h-full w-full"
          data-task-id={@task_id}
        >
        </div>
      </div>
    </div>
    """
  end
end
