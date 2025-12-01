# Claudette

> ⚠️ This is a WIP and doesn't contain friendly documentation / setup (yet)

A simple local-only liveview app that provides a UI to manage claude working in worktrees & cranking on GitHub issues.

### Setup

- Set up your local git worktrees environments (I use 5, `tree1`, `tree2`, ...)
- `mix setup` -> `mix phx.server` to spin up the liveview app
- Visit localhost:7070 and add your project config (github token, directories of worktrees)
- Add some instructions in the `instructions/` folders for context about how you want it to solve the issue.
- 🎉Done

### How to use

* Click a GitHub issue from the list
* Assign it a worktree to use
* Hit "Initialize"
* Open up claude code in that worktree directory and run the command it'll give you, like: `/claudette be83c4ab/e2c36f73`
* Repeat on other issues in different workspaces.
* When issues are solved, you can mark them as done in the UI and it'll safely clean up the worktree. You can now use this worktree for another GitHub issue.
* 🔁 Repeat.
