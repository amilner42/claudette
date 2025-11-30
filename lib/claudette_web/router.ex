defmodule ClaudetteWeb.Router do
  use ClaudetteWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClaudetteWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ClaudetteWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/projects/:project_id/tasks/:id", TaskLive, :show
    live "/projects/:project_id/tasks/:id/edit", TaskLive, :edit
    live "/terminal", TerminalLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", ClaudetteWeb do
  #   pipe_through :api
  # end
end
