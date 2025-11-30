defmodule Claudette.Integrations.GitHub do
  @moduledoc """
  GitHub API client for fetching issue and PR details.
  """

  alias Claudette.Config

  @api_base "https://api.github.com"

  @doc """
  Parse a GitHub URL or shorthand (owner/repo#number) and fetch the issue/PR.
  Returns {:ok, data} or {:error, reason}.
  """
  def fetch_issue(github_ref) do
    case parse_github_ref(github_ref) do
      {:ok, owner, repo, number} ->
        do_fetch_issue(owner, repo, number)

      :error ->
        {:error, :invalid_format}
    end
  end

  @doc """
  Fetch an issue or PR by owner, repo, and number.
  """
  def do_fetch_issue(owner, repo, number) do
    api_key = Config.load_api_keys().github_token

    headers =
      [
        {"Accept", "application/vnd.github+json"},
        {"User-Agent", "Claudette"}
      ] ++
        if api_key, do: [{"Authorization", "Bearer #{api_key}"}], else: []

    url = "#{@api_base}/repos/#{owner}/#{repo}/issues/#{number}"

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, normalize_issue(body, owner, repo)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List issues for a repository.
  """
  def list_issues(owner, repo, opts \\ []) do
    api_key = Config.load_api_keys().github_token

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      headers = [
        {"Accept", "application/vnd.github+json"},
        {"User-Agent", "Claudette"},
        {"Authorization", "Bearer #{api_key}"}
      ]

      state = Keyword.get(opts, :state, "open")
      per_page = Keyword.get(opts, :per_page, 30)
      url = "#{@api_base}/repos/#{owner}/#{repo}/issues?state=#{state}&per_page=#{per_page}"

      case Req.get(url, headers: headers) do
        {:ok, %{status: 200, body: body}} ->
          # Filter out PRs - they have a "pull_request" key
          issues =
            body
            |> Enum.reject(&Map.has_key?(&1, "pull_request"))
            |> Enum.map(&normalize_issue(&1, owner, repo))

          {:ok, issues}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: 403}} ->
          {:error, :rate_limited}

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  List user's assigned issues across all repos.
  """
  def list_my_issues(opts \\ []) do
    api_key = Config.load_api_keys().github_token

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      headers = [
        {"Accept", "application/vnd.github+json"},
        {"User-Agent", "Claudette"},
        {"Authorization", "Bearer #{api_key}"}
      ]

      state = Keyword.get(opts, :state, "open")
      filter = Keyword.get(opts, :filter, "assigned")
      per_page = Keyword.get(opts, :per_page, 50)
      url = "#{@api_base}/issues?filter=#{filter}&state=#{state}&per_page=#{per_page}"

      case Req.get(url, headers: headers) do
        {:ok, %{status: 200, body: body}} ->
          # Filter out PRs - they have a "pull_request" key
          issues =
            body
            |> Enum.reject(&Map.has_key?(&1, "pull_request"))
            |> Enum.map(fn issue ->
              # Extract owner/repo from the issue's repository_url
              [owner, repo] =
                issue["repository_url"]
                |> String.split("/")
                |> Enum.take(-2)

              normalize_issue(issue, owner, repo)
            end)

          {:ok, issues}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: 403}} ->
          {:error, :rate_limited}

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Parse GitHub reference formats:
  - "owner/repo#123"
  - "https://github.com/owner/repo/issues/123"
  - "https://github.com/owner/repo/pull/123"
  """
  def parse_github_ref(ref) do
    cond do
      # owner/repo#123 format
      Regex.match?(~r/^[\w.-]+\/[\w.-]+#\d+$/, ref) ->
        [repo_part, number] = String.split(ref, "#")
        [owner, repo] = String.split(repo_part, "/")
        {:ok, owner, repo, String.to_integer(number)}

      # Full URL format
      match = Regex.run(~r/github\.com\/([\w.-]+)\/([\w.-]+)\/(?:issues|pull)\/(\d+)/, ref) ->
        [_, owner, repo, number] = match
        {:ok, owner, repo, String.to_integer(number)}

      true ->
        :error
    end
  end

  defp normalize_issue(body, owner, repo) do
    is_pr = Map.has_key?(body, "pull_request")

    %{
      type: if(is_pr, do: :pull_request, else: :issue),
      number: body["number"],
      title: body["title"],
      body: body["body"],
      url: body["html_url"],
      state: body["state"],
      author: get_in(body, ["user", "login"]),
      labels: Enum.map(body["labels"] || [], & &1["name"]),
      assignees: Enum.map(body["assignees"] || [], & &1["login"]),
      created_at: body["created_at"],
      updated_at: body["updated_at"],
      closed_at: body["closed_at"],
      owner: owner,
      repo: repo
    }
  end
end
