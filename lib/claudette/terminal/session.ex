defmodule Claudette.Terminal.Session do
  @moduledoc """
  A GenServer that manages multiple persistent PTY shell sessions.
  Each worktree gets its own terminal session that persists.
  """

  use GenServer
  require Logger

  @name __MODULE__

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  @doc """
  Send input to a terminal for a specific worktree.
  """
  def send_input(worktree_path, data) do
    GenServer.cast(@name, {:input, worktree_path, data})
  end

  @doc """
  Resize a terminal for a specific worktree.
  """
  def resize(worktree_path, rows, cols) do
    GenServer.cast(@name, {:resize, worktree_path, rows, cols})
  end

  @doc """
  Subscribe to terminal output for a specific worktree.
  The calling process will receive {:terminal_output, worktree_path, data} messages.
  """
  def subscribe(worktree_path) do
    Phoenix.PubSub.subscribe(Claudette.PubSub, "terminal:output:#{worktree_path}")
  end

  @doc """
  Unsubscribe from terminal output for a specific worktree.
  """
  def unsubscribe(worktree_path) do
    Phoenix.PubSub.unsubscribe(Claudette.PubSub, "terminal:output:#{worktree_path}")
  end

  @doc """
  Get the current terminal scrollback for a specific worktree.
  """
  def get_scrollback(worktree_path) do
    GenServer.call(@name, {:get_scrollback, worktree_path})
  end

  @doc """
  Reset the terminal session for a specific worktree.
  """
  def reset(worktree_path) do
    GenServer.call(@name, {:reset, worktree_path})
  end

  @doc """
  Ensure a terminal exists for a worktree (creates if doesn't exist).
  """
  def ensure_terminal(worktree_path) do
    GenServer.call(@name, {:ensure_terminal, worktree_path})
  end

  @doc """
  List all active terminal sessions.
  """
  def list_terminals do
    GenServer.call(@name, :list_terminals)
  end

  # Server callbacks

  @impl true
  def init(_) do
    # Map of worktree_path => terminal_state
    {:ok, %{terminals: %{}}}
  end

  @impl true
  def handle_cast({:input, worktree_path, data}, state) do
    case Map.get(state.terminals, worktree_path) do
      %{port: port} when not is_nil(port) ->
        Port.command(port, data)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:resize, worktree_path, rows, cols}, state) do
    case Map.get(state.terminals, worktree_path) do
      nil ->
        {:noreply, state}

      terminal ->
        terminals = Map.put(state.terminals, worktree_path, %{terminal | rows: rows, cols: cols})
        {:noreply, %{state | terminals: terminals}}
    end
  end

  @impl true
  def handle_call({:get_scrollback, worktree_path}, _from, state) do
    scrollback =
      case Map.get(state.terminals, worktree_path) do
        nil -> ""
        terminal -> terminal.scrollback
      end

    {:reply, scrollback, state}
  end

  @impl true
  def handle_call({:reset, worktree_path}, _from, state) do
    case Map.get(state.terminals, worktree_path) do
      nil ->
        # Create new terminal
        terminal = start_pty(worktree_path)
        terminals = Map.put(state.terminals, worktree_path, terminal)
        {:reply, :ok, %{state | terminals: terminals}}

      old_terminal ->
        # Close old port if exists
        if old_terminal.port && Port.info(old_terminal.port) do
          Port.close(old_terminal.port)
        end

        # Create new terminal
        terminal = start_pty(worktree_path)
        terminals = Map.put(state.terminals, worktree_path, terminal)
        {:reply, :ok, %{state | terminals: terminals}}
    end
  end

  @impl true
  def handle_call({:ensure_terminal, worktree_path}, _from, state) do
    case Map.get(state.terminals, worktree_path) do
      nil ->
        terminal = start_pty(worktree_path)
        terminals = Map.put(state.terminals, worktree_path, terminal)
        {:reply, :ok, %{state | terminals: terminals}}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:list_terminals, _from, state) do
    {:reply, Map.keys(state.terminals), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) do
    # Find which worktree this port belongs to
    case find_worktree_by_port(state.terminals, port) do
      nil ->
        {:noreply, state}

      worktree_path ->
        # Broadcast output to subscribers for this worktree
        Phoenix.PubSub.broadcast(
          Claudette.PubSub,
          "terminal:output:#{worktree_path}",
          {:terminal_output, worktree_path, data}
        )

        # Update scrollback buffer
        terminal = Map.get(state.terminals, worktree_path)
        scrollback = terminal.scrollback <> data

        scrollback =
          if byte_size(scrollback) > 100_000 do
            binary_part(scrollback, byte_size(scrollback) - 50_000, 50_000)
          else
            scrollback
          end

        terminals = Map.put(state.terminals, worktree_path, %{terminal | scrollback: scrollback})
        {:noreply, %{state | terminals: terminals}}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, state) do
    case find_worktree_by_port(state.terminals, port) do
      nil ->
        {:noreply, state}

      worktree_path ->
        Logger.info("Terminal for #{worktree_path} exited with status #{status}, restarting...")

        Phoenix.PubSub.broadcast(
          Claudette.PubSub,
          "terminal:output:#{worktree_path}",
          {:terminal_output, worktree_path,
           "\r\n[Shell exited with status #{status}, restarting...]\r\n"}
        )

        # Schedule restart
        Process.send_after(self(), {:restart_shell, worktree_path}, 500)

        # Mark port as nil
        terminal = Map.get(state.terminals, worktree_path)
        terminals = Map.put(state.terminals, worktree_path, %{terminal | port: nil})
        {:noreply, %{state | terminals: terminals}}
    end
  end

  @impl true
  def handle_info({:restart_shell, worktree_path}, state) do
    terminal = start_pty(worktree_path)
    terminals = Map.put(state.terminals, worktree_path, terminal)
    {:noreply, %{state | terminals: terminals}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Terminal received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp find_worktree_by_port(terminals, port) do
    Enum.find_value(terminals, fn {worktree_path, terminal} ->
      if terminal.port == port, do: worktree_path
    end)
  end

  defp start_pty(worktree_path) do
    shell = System.get_env("SHELL") || "/bin/bash"

    # Ensure the worktree path exists, fallback to home
    cwd =
      if File.dir?(worktree_path) do
        worktree_path
      else
        System.get_env("HOME") || "/"
      end

    port =
      Port.open(
        {:spawn_executable, "/usr/bin/script"},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: ["-q", "/dev/null", shell],
          env: build_env(),
          cd: String.to_charlist(cwd)
        ]
      )

    %{
      port: port,
      scrollback: "",
      rows: 24,
      cols: 80,
      worktree_path: worktree_path
    }
  end

  defp build_env do
    base_env = [
      {~c"TERM", ~c"xterm-256color"},
      {~c"LANG", ~c"en_US.UTF-8"},
      {~c"LC_ALL", ~c"en_US.UTF-8"}
    ]

    path = System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin"
    home = System.get_env("HOME") || "/"

    base_env ++
      [
        {~c"PATH", String.to_charlist(path)},
        {~c"HOME", String.to_charlist(home)}
      ]
  end
end
