# Claudette - Build Plan

A local Phoenix LiveView app for managing Claude Code tasks with external context (Linear, GitHub) and custom markdown notes. Everything backed by local files. No database.

## Quick Start

```bash
cd ~/Desktop/programming/git
mix phx.new claudette --no-ecto --no-mailer --no-dashboard
cd claudette
mix deps.get
```

## Project Overview

**What it does**: Web UI to create/manage "tasks" that Claude Code can load via `/claudette <task-id>` slash command.

**Key principle**: The web app manages *metadata and context files only*. Git operations (worktrees, etc.) are done by Claude Code, not the web app.

---

## Data Directory Structure

Location: Configurable via `CLAUDETTE_DATA_PATH` env var, defaults to `~/claudette-data/`

```
~/claudette-data/
├── config.yaml                     # API keys (LINEAR_API_KEY, GITHUB_TOKEN)
└── tasks/
    └── <task-id>/                  # Short UUID or slug
        ├── meta.json               # Task metadata
        ├── context.md              # User's custom context/instructions
        └── claude-notes.md         # Claude's working notes (created by Claude Code)
```

### meta.json schema

```json
{
  "id": "abc123",
  "title": "Task title",
  "created_at": "2025-01-15T10:00:00Z",
  "updated_at": "2025-01-15T10:00:00Z",
  "status": "active",
  "linear_id": "TEAM-123",
  "github_url": "owner/repo#42",
  "worktree_path": "/path/to/worktree",
  "tags": ["feature", "urgent"]
}
```

All fields except `id`, `title`, `created_at`, `updated_at`, `status` are optional.

---

## Implementation Phases

### Phase 1: Config & Tasks Context

**File: `lib/claudette/config.ex`**

```elixir
defmodule Claudette.Config do
  @default_data_path "~/claudette-data"

  def data_path do
    System.get_env("CLAUDETTE_DATA_PATH", @default_data_path)
    |> Path.expand()
  end

  def tasks_path, do: Path.join(data_path(), "tasks")

  def ensure_data_dirs! do
    File.mkdir_p!(tasks_path())
  end
end
```

**File: `lib/claudette/tasks/task.ex`**

```elixir
defmodule Claudette.Tasks.Task do
  @derive Jason.Encoder
  defstruct [
    :id,
    :title,
    :created_at,
    :updated_at,
    :status,
    :linear_id,
    :github_url,
    :worktree_path,
    :tags,
    :context_md,        # loaded from context.md
    :claude_notes_md    # loaded from claude-notes.md
  ]
end
```

**File: `lib/claudette/tasks.ex`**

CRUD operations that read/write to file system:
- `list_tasks/0` - scan tasks/ dir, load each meta.json
- `get_task/1` - load meta.json + context.md + claude-notes.md
- `create_task/1` - generate ID, create folder, write meta.json + empty context.md
- `update_task/2` - update meta.json and/or context.md
- `delete_task/1` - remove task folder

Use short IDs (8 chars) via `:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)`

---

### Phase 2: Core LiveView Pages

**Router (`lib/claudette_web/router.ex`)**

```elixir
scope "/", ClaudetteWeb do
  pipe_through :browser

  live "/", DashboardLive, :index
  live "/tasks/new", TaskLive, :new
  live "/tasks/:id", TaskLive, :show
  live "/tasks/:id/edit", TaskLive, :edit
end
```

**DashboardLive** (`lib/claudette_web/live/dashboard_live.ex`)
- List all tasks in a table/grid
- Show: title, status, linear_id, github_url, updated_at
- Click to view task
- "New Task" button
- Simple search/filter (client-side is fine for MVP)

**TaskLive** (`lib/claudette_web/live/task_live.ex`)
- `:new` - form to create task (title, optional linear_id, github_url)
- `:show` - view task details:
  - Title, status, links
  - context.md content (read-only view or editable)
  - claude-notes.md content (read-only)
  - **Copy button** for `/claudette <task-id>` command
  - Link to Linear/GitHub if set (external links)
- `:edit` - edit title, links, context.md

**Key UI element - the copy button:**
```elixir
<button phx-click={JS.dispatch("phx:copy", to: "#command-text")}>
  Copy Command
</button>
<span id="command-text" class="hidden">/claudette <%= @task.id %></span>
```

With JS hook to copy to clipboard.

---

### Phase 3: Linear & GitHub Integration (On-Demand Fetch)

**File: `lib/claudette/integrations/linear.ex`**

```elixir
defmodule Claudette.Integrations.Linear do
  @graphql_url "https://api.linear.app/graphql"

  def fetch_issue(issue_id) do
    # GraphQL query to fetch issue by ID
    # Returns {:ok, %{title: ..., description: ..., state: ..., url: ...}}
    # or {:error, reason}
  end
end
```

**File: `lib/claudette/integrations/github.ex`**

```elixir
defmodule Claudette.Integrations.GitHub do
  def fetch_issue(owner, repo, number) do
    # GET https://api.github.com/repos/{owner}/{repo}/issues/{number}
    # Returns {:ok, %{title: ..., body: ..., state: ..., url: ...}}
  end
end
```

**In TaskLive**: When viewing a task with linear_id or github_url, fetch the current issue data and display it. Show loading state while fetching.

API keys come from:
1. `CLAUDETTE_DATA_PATH/config.yaml` (preferred)
2. Environment variables `LINEAR_API_KEY`, `GITHUB_TOKEN`

---

### Phase 4: The /claudette Slash Command

The web app should display instructions for setting up the slash command.

**File to create in user's project: `.claude/commands/claudette.md`**

```markdown
---
description: Load context from Claudette task
---

Load task context for: $ARGUMENTS

## Instructions

1. Read task metadata from the file at path: `<CLAUDETTE_DATA_PATH>/tasks/$ARGUMENTS/meta.json`
   - Default CLAUDETTE_DATA_PATH is ~/claudette-data if not set

2. If `linear_id` exists in metadata, use the Linear MCP tools to fetch current issue details

3. If `github_url` exists (format: owner/repo#number), fetch the GitHub issue/PR details

4. Read user context from: `<CLAUDETTE_DATA_PATH>/tasks/$ARGUMENTS/context.md`

5. Read Claude's previous notes from: `<CLAUDETTE_DATA_PATH>/tasks/$ARGUMENTS/claude-notes.md` (if exists)

6. If `worktree_path` exists, that's where the code for this task lives

7. Present all gathered context to the user and ask how they'd like to proceed

## Working Notes

As you work on this task, save important notes, decisions, and progress to:
`<CLAUDETTE_DATA_PATH>/tasks/$ARGUMENTS/claude-notes.md`

This helps maintain continuity across sessions.
```

**In the web UI**: Show a "Setup" page or section that displays this command file content with a copy button.

---

### Phase 5: Polish (Optional/Later)

- [ ] Tags support with filtering
- [ ] Status management (active/completed/archived)
- [ ] Keyboard shortcuts (j/k navigation, / to search)
- [ ] Dark mode
- [ ] Task sorting options
- [ ] Bulk operations

---

## File Structure Summary

```
claudette/
├── lib/
│   ├── claudette/
│   │   ├── application.ex          # Ensure data dirs on startup
│   │   ├── config.ex               # Data path configuration
│   │   ├── tasks.ex                # Task CRUD operations
│   │   ├── tasks/
│   │   │   └── task.ex             # Task struct
│   │   └── integrations/
│   │       ├── linear.ex           # Linear API client
│   │       └── github.ex           # GitHub API client
│   └── claudette_web/
│       ├── router.ex
│       ├── live/
│       │   ├── dashboard_live.ex   # Task list
│       │   └── task_live.ex        # Task view/edit/new
│       └── components/
│           └── core_components.ex  # Shared UI components
├── config/
│   ├── config.exs
│   ├── dev.exs
│   └── runtime.exs                 # Read CLAUDETTE_DATA_PATH here
└── assets/
    └── js/
        └── app.js                  # Clipboard copy hook
```

---

## Key Design Decisions

1. **No database** - All data in JSON/markdown files. Simple, portable, git-friendly.

2. **On-demand fetching** - Don't cache Linear/GitHub data. Always fetch fresh when viewing.

3. **Web app doesn't run git** - Just stores metadata. Claude Code handles git operations.

4. **Short task IDs** - 8 character hex strings for easy typing in `/claudette abc123de`

5. **Separation of concerns** - Web app = task management. Claude Code = execution.

---

## Getting Started Checklist

1. [ ] Create Phoenix project: `mix phx.new claudette --no-ecto --no-mailer --no-dashboard`
2. [ ] Add Jason dependency (should be included)
3. [ ] Add HTTPoison or Req for API calls: `{:req, "~> 0.4"}`
4. [ ] Implement Config module
5. [ ] Implement Tasks context with file-based CRUD
6. [ ] Create DashboardLive
7. [ ] Create TaskLive (new/show/edit)
8. [ ] Add clipboard copy JS hook
9. [ ] Implement Linear integration
10. [ ] Implement GitHub integration
11. [ ] Add setup/command page showing the slash command to copy

---

## Example Usage Flow

1. Open Claudette web UI at localhost:4000
2. Click "New Task"
3. Enter title: "Fix authentication bug"
4. Enter Linear ID: "ENG-123"
5. Add context.md: "The bug is in the JWT validation. Check the middleware."
6. Save task (gets ID: `a1b2c3d4`)
7. Copy command: `/claudette a1b2c3d4`
8. In your project, run Claude Code
9. Paste `/claudette a1b2c3d4`
10. Claude loads the Linear issue, your context, and asks how to proceed
11. As Claude works, it saves notes to `claude-notes.md`
12. Next session, those notes are loaded automatically
