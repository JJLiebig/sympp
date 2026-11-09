defmodule SymphonyElixir.SymphonyPlusPlus.Cards do
  @moduledoc """
  Cards: the work of the terminals the operator talks to, observed by the
  factory with no setup by the agent.

  A card belongs to one terminal on the factory's herdr-core. Its id is derived
  from the terminal key, and the terminal works on it through a
  `sympp_worked_on` row (subject `card`, role `card`).

  **Eligible terminals** are live, are not dispatched workers
  (`sympp.role=worker`), and either carry the label `sympp.card=1` or are
  children of a chief or architect terminal: one labelled `sympp.role=chief`,
  or one that has worked on a WorkRequest as chief or architect.

  | From | Observed | To |
  |---|---|---|
  | (hidden) | eligible live terminal on a branch other than its base, no PR | `working` |
  | (hidden) | eligible live terminal whose branch has an open PR | `review_ci` |
  | `working` | the branch's PR is open | `review_ci` |
  | `working`, `review_ci` | the PR merged | `merged` |
  | `working`, `review_ci` | the PR closed without merging | `done` |
  | `working` | the terminal finished and GitHub reports no PR for the branch | `done` |
  | `merged`, `done`, `dismissed` | the live terminal is on another branch, not its base | `working` or `review_ci` |
  | any but `dismissed` | the operator dismisses it | `dismissed` |

  Unknown inputs never end a card: an unreadable GitHub or Review Suite host
  only flags it `stale`, and a terminal counts as finished only once the
  factory's core has reported it finished. Ending a card withdraws its open
  asks and ends its worked-on row. `merged`, `done` and `dismissed` cards drop
  off after the `card_retention_days` operator setting.

  The `Observer` runs `watch/2` and `apply/4` on every sweep, so card PRs are
  read in the same batched GitHub snapshot as package PRs.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.{Asks, BaseBranch, DashboardPubSub, HerdrCore, Id, Ownership, ReviewStatus}
  alias SymphonyElixir.SymphonyPlusPlus.Cards.{Card, Git}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}

  @active ["working", "review_ci"]
  @ended ["merged", "done", "dismissed"]
  @review_concurrency 4
  @review_timeout_ms 8_000

  @type repo :: module()
  @type entry :: SymphonyElixir.SymphonyPlusPlus.GitHub.Snapshot.entry()
  @type item :: %{required(atom()) => term()}

  @doc "A terminal's card id."
  @spec card_id(String.t()) :: String.t()
  def card_id(terminal_key) when is_binary(terminal_key),
    do: "card_" <> (:crypto.hash(:sha256, terminal_key) |> Base.encode16(case: :lower) |> binary_part(0, 16))

  @doc """
  What one sweep observes: each eligible live terminal and each open card,
  with the GitHub entry it needs (`:skip` when it needs none). Options (tests):
  `:core` replaces `HerdrCore.current/0`, `:terminal` replaces
  `HerdrCore.get/1`, `:git` replaces `Cards.Git.read/1`.
  """
  @spec watch(repo(), keyword()) :: [item()]
  def watch(repo, opts \\ []) do
    cards = repo.all(Card)
    by_key = Map.new(cards, &{&1.terminal_key, &1})
    finished = finished_keys(repo, cards)

    live =
      case Keyword.get_lazy(opts, :core, &HerdrCore.current/0) do
        {:ok, %{core_id: _id, terminals: _terminals} = core} -> live_items(repo, core, by_key, opts)
        _unavailable -> []
      end

    seen = MapSet.new(live, & &1.key)

    open =
      for %Card{state: state} = card <- cards, state in @active, not MapSet.member?(seen, card.terminal_key) do
        terminal = if MapSet.member?(finished, card.terminal_key), do: :finished, else: :unknown
        %{key: card.terminal_key, card: card, terminal: terminal, git: nil, title: nil, cwd: nil, review_id: nil}
      end

    Enum.map(live ++ open, &Map.put(&1, :entry, entry(&1)))
  end

  # Open cards whose terminal the factory's core reported finished.
  defp finished_keys(repo, cards) do
    ids = for %Card{state: state, id: id} <- cards, state in @active, do: id
    rows = repo.all(from(row in WorkedOn, where: row.subject_kind == "card" and row.subject_id in ^ids, select: {row.subject_id, row.state, row.finish_reason}))
    live = for {id, "live", _reason} <- rows, into: MapSet.new(), do: id
    finished = for {id, "finished", "terminal_finished"} <- rows, not MapSet.member?(live, id), into: MapSet.new(), do: id

    for %Card{id: id, terminal_key: key} <- cards, MapSet.member?(finished, id), into: MapSet.new(), do: key
  end

  # Eligible live terminals whose directory is a GitHub checkout. `git` runs
  # once per directory.
  defp live_items(repo, %{core_id: core_id, terminals: terminals} = core, by_key, opts) do
    get = Keyword.get(opts, :terminal, &HerdrCore.get/1)
    git = Keyword.get(opts, :git, &Git.read/1)
    parent? = parent_predicate(repo, core_id, terminals)

    candidates =
      terminals
      |> Enum.filter(fn {_address, record} -> candidate?(record, parent?) end)
      |> Enum.map(fn {address, record} -> {address, full_record(get, address, record)} end)
      |> Enum.reject(fn {_address, record} -> worker?(record) end)

    reads = candidates |> Enum.map(fn {_address, record} -> record["cwd"] end) |> Enum.uniq() |> Map.new(&{&1, git.(&1)})

    for {address, record} <- candidates, {:ok, git_info} <- [Map.get(reads, record["cwd"])] do
      key = Terminal.key(core_id, address)

      %{
        key: key,
        card: Map.get(by_key, key),
        terminal: :live,
        git: git_info,
        cwd: record["cwd"],
        title: title(record),
        review_id: get_in(record, ["labels", "sympp.review_id"]),
        address: display_address(core[:core_name], address)
      }
    end
  end

  defp display_address(name, address) when is_binary(name) and name != "", do: name <> "/" <> address
  defp display_address(_name, address), do: address

  defp candidate?(%{"state" => "live", "cwd" => cwd} = record, parent?) when is_binary(cwd) and cwd != "",
    do: not worker?(record) and (get_in(record, ["labels", "sympp.card"]) == "1" or parent?.(record["parent"]))

  defp candidate?(_record, _parent?), do: false

  defp worker?(record), do: get_in(record, ["labels", "sympp.role"]) == "worker"

  # The full record adds labels `hc ls` leaves out, such as `sympp.review_id`.
  defp full_record(get, address, record) do
    case get.(address) do
      {:ok, %{} = full} -> Map.merge(record, full, &merge_field/3)
      _unavailable -> record
    end
  end

  defp merge_field(_key, %{} = listed, %{} = read), do: Map.merge(listed, read)
  defp merge_field(_key, _listed, read), do: read

  defp title(record) do
    Enum.find_value([record["title"], record["name"]], fn
      value when is_binary(value) -> if String.trim(value) != "", do: String.trim(value)
      _missing -> nil
    end)
  end

  # A parent is an address on this core (`t81`) or `machine/address` on
  # another one. Chiefs and architects are known from their labels on this
  # core and from the terminals that have worked on a WorkRequest.
  defp parent_predicate(repo, core_id, terminals) do
    owners = repo.all(from(row in WorkedOn, where: row.role in ["chief", "architect"], distinct: true, select: {row.terminal_key, row.display_address}))
    keys = MapSet.new(owners, &elem(&1, 0))
    addresses = MapSet.new(owners, &elem(&1, 1))

    fn
      parent when is_binary(parent) ->
        if String.contains?(parent, "/") do
          MapSet.member?(addresses, parent)
        else
          MapSet.member?(keys, Terminal.key(core_id, parent)) or get_in(terminals, [parent, "labels", "sympp.role"]) == "chief"
        end

      _none ->
        false
    end
  end

  # The PR an open card watches, or the branch whose PR it looks for.
  defp entry(%{card: %Card{state: "review_ci", pr: %{"number" => number} = pr}}) when is_integer(number), do: pr_entry(pr["repository"], number)

  defp entry(%{card: %Card{state: state} = card} = item) when state in @active do
    branch = if working_branch?(item.git), do: item.git.branch, else: card.branch
    head_entry((item.git && item.git.repository) || card.repository, branch)
  end

  defp entry(%{terminal: :live, git: git} = item) do
    if new_work?(item), do: head_entry(git.repository, git.branch), else: :skip
  end

  defp entry(_item), do: :skip

  # A live terminal shows new work on a branch that isn't its base and, for an
  # ended card, isn't the branch that card ended on. Without a known base,
  # only an open PR shows it.
  defp new_work?(%{git: %{branch: branch} = git} = item) when is_binary(branch) do
    base? = is_binary(git.base_branch) and BaseBranch.equivalent?(branch, git.base_branch)

    case item.card do
      nil -> not base?
      %Card{branch: ended_branch} -> not base? and branch != ended_branch
    end
  end

  defp new_work?(_item), do: false

  defp working_branch?(%{branch: branch, base_branch: base}) when is_binary(branch) and is_binary(base), do: not BaseBranch.equivalent?(branch, base)
  defp working_branch?(_git), do: false

  defp pr_entry(repository, number) do
    case String.split(repository || "", "/") do
      [owner, name] when owner != "" and name != "" -> {:pr, owner, name, number}
      _unknown -> :skip
    end
  end

  defp head_entry(repository, branch) when is_binary(branch) do
    case String.split(repository || "", "/") do
      [owner, name] when owner != "" and name != "" -> {:head, owner, name, branch}
      _unknown -> :skip
    end
  end

  defp head_entry(_repository, _branch), do: :skip

  @doc """
  The transition one observation causes. `github` is the snapshot result for
  the item's entry: `{:ok, pr}`, `{:ok, nil}` (no PR), `{:error, _}`
  (unknown) or `:skip` (not read).
  """
  @spec decide(item(), {:ok, map() | nil} | {:error, term()} | :skip) ::
          {:open, String.t()} | {:move, String.t()} | :stay | :none
  def decide(%{card: nil} = item, github) do
    if item.terminal == :live and new_work?(item), do: opening(item, github), else: :none
  end

  def decide(%{card: %Card{state: state}} = item, github) when state in @ended do
    if item.terminal == :live and new_work?(item), do: opening(item, github), else: :none
  end

  def decide(%{card: %Card{state: state}} = item, github) when state in @active do
    case github do
      {:ok, %{"state" => "merged"}} -> {:move, "merged"}
      {:ok, %{"state" => "closed"}} -> {:move, "done"}
      {:ok, %{"state" => "open"}} -> if state == "review_ci", do: :stay, else: {:move, "review_ci"}
      {:ok, nil} when state == "working" and item.terminal == :finished -> {:move, "done"}
      _unknown_or_no_pr -> :stay
    end
  end

  # A merged or closed PR on the branch is old work: the card stays hidden.
  defp opening(_item, {:ok, %{"state" => "open"}}), do: {:open, "review_ci"}
  defp opening(_item, {:ok, %{"state" => _merged_or_closed}}), do: :none
  defp opening(%{git: git}, _no_pr_or_unknown), do: if(working_branch?(git), do: {:open, "working"}, else: :none)

  @doc """
  Applies one sweep's GitHub results (by entry) to the watched items: opens,
  moves and refreshes cards. Options (tests): `:review` replaces
  `ReviewStatus.read/2`.
  """
  @spec apply(repo(), [item()], %{entry() => term()}, keyword()) :: :ok
  def apply(repo, items, results, opts \\ []) do
    decided =
      Enum.map(items, fn item ->
        github = if item.entry == :skip, do: :skip, else: Map.get(results, item.entry, {:error, :request_failed})
        {item, github, decide(item, github)}
      end)

    reviews = reviews(decided, opts)

    changed? =
      Enum.reduce(decided, false, fn {item, github, decision}, changed? ->
        persist(repo, item, github, decision, Map.get(reviews, item.key, :none)) or changed?
      end)

    if changed?, do: DashboardPubSub.broadcast_changed()
    :ok
  end

  # Review Suite is read for cards that watch an open PR and whose terminal
  # labels `sympp.review_id`.
  defp reviews(decided, opts) do
    read = Keyword.get(opts, :review, &ReviewStatus.read/2)

    decided
    |> Enum.flat_map(fn {item, github, decision} ->
      review_id = item.review_id || (item.card && item.card.review_id)
      watching? = match?({:ok, %{"state" => "open"}}, github) and decision != :none
      if is_binary(review_id) and watching?, do: [{item.key, review_id}], else: []
    end)
    |> Task.async_stream(fn {key, review_id} -> {key, read.(review_id, nil)} end,
      max_concurrency: @review_concurrency,
      ordered: false,
      timeout: @review_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, result} -> [result]
      {:exit, _reason} -> []
    end)
    |> Map.new()
  end

  defp persist(_repo, _item, _github, :none, _review), do: false

  defp persist(repo, item, github, decision, review) do
    {:ok, changed?} =
      repo.transaction(fn ->
        case decision do
          {:open, state} -> open(repo, item, github, state, review)
          {:move, state} -> update(repo, item, item.card, state, github, review)
          :stay -> update(repo, item, item.card, item.card.state, github, review)
        end
      end)

    changed?
  end

  defp open(repo, item, github, state, review) do
    now = DateTime.utc_now(:microsecond)
    id = card_id(item.key)
    base = item.card || %Card{id: id, terminal_key: item.key, inserted_at: now}

    attrs =
      observed(item, github, review, nil, state)
      |> Map.merge(%{state: state, branch: item.git.branch, pr: pr(github), ended_at: nil, observed_at: now})

    if item.card,
      do: repo.update!(Ecto.Changeset.change(base, attrs)),
      else: repo.insert!(Ecto.Changeset.change(base, attrs))

    work_on(repo, id, item)
    true
  end

  defp update(repo, item, %Card{} = card, state, github, review) do
    attrs =
      observed(item, github, review, card, state)
      |> Map.put(:state, state)
      |> then(&if(state == "working" and working_branch?(item.git), do: Map.put(&1, :branch, item.git.branch), else: &1))
      |> then(&if(pr(github), do: Map.merge(&1, %{pr: pr(github), branch: pr(github)["branch"] || card.branch}), else: &1))

    case Ecto.Changeset.change(card, attrs) do
      %Ecto.Changeset{changes: changes} when changes == %{} ->
        false

      changeset ->
        now = DateTime.utc_now(:microsecond)
        ended? = state in @ended
        repo.update!(Ecto.Changeset.change(changeset, observed_at: now, ended_at: if(ended?, do: now, else: card.ended_at)))
        if ended?, do: end_card(repo, card.id)
        true
    end
  end

  # What an observation refreshes on a card. A live terminal refreshes its
  # title, cwd and review id, and while the card is `working` its repository
  # and base (a PR keeps its own); an unknown input is only flagged.
  defp observed(item, github, review, card, state) do
    live =
      case {item.terminal, state} do
        {:live, "working"} -> %{title: item.title, cwd: item.cwd, review_id: item.review_id, repository: item.git.repository, base_branch: item.git.base_branch}
        {:live, _state} -> %{title: item.title, cwd: item.cwd, review_id: item.review_id}
        _unknown -> %{}
      end

    stale = if(match?({:error, _reason}, github), do: ["github"], else: []) ++ if(review == :unknown, do: ["review"], else: [])
    Map.merge(live, %{stale: stale, review: review_payload(review, card && card.review)})
  end

  defp pr({:ok, %{} = pr}), do: Map.take(pr, ~w(repository number url state draft merged merged_at head_sha branch base_branch ci github_review))
  defp pr(_none_or_unknown), do: nil

  defp review_payload({:ok, review}, _previous), do: review
  defp review_payload(:not_started, _previous), do: %{"status" => "not_started"}
  # An unreachable host keeps the last status it reported.
  defp review_payload(_none_or_unknown, previous), do: previous

  defp work_on(repo, card_id, item) do
    if is_nil(repo.one(from(row in WorkedOn, where: row.subject_kind == "card" and row.subject_id == ^card_id and row.state == "live", select: row.id))) do
      now = DateTime.utc_now(:microsecond)

      repo.insert!(%WorkedOn{
        id: Id.random("wo"),
        subject_kind: "card",
        subject_id: card_id,
        terminal_key: item.key,
        display_address: item.address,
        role: "card",
        state: "live",
        started_at: now
      })
    end

    :ok
  end

  # An ended card's asks are withdrawn and its terminal stops working on it.
  defp end_card(repo, card_id) do
    Asks.withdraw_for_cards(repo, [card_id])
    Ownership.end_subject(repo, "card", card_id)
  end

  @doc "The operator dismisses a card; dismissing it again changes nothing."
  @spec dismiss(repo(), String.t()) :: {:ok, Card.t()} | {:error, :not_found}
  def dismiss(repo, card_id) when is_binary(card_id) do
    repo.transaction(
      fn ->
        case repo.get(Card, card_id) do
          nil ->
            repo.rollback(:not_found)

          %Card{state: "dismissed"} = card ->
            card

          %Card{} = card ->
            now = DateTime.utc_now(:microsecond)
            card = repo.update!(Ecto.Changeset.change(card, state: "dismissed", ended_at: card.ended_at || now, observed_at: now))
            end_card(repo, card.id)
            card
        end
      end,
      mode: :immediate
    )
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  @doc "The open card of a terminal, if it has one."
  @spec open_card(repo(), String.t()) :: Card.t() | nil
  def open_card(repo, terminal_key) when is_binary(terminal_key),
    do: repo.one(from(card in Card, where: card.terminal_key == ^terminal_key and card.state in ^@active))

  @doc """
  Cards for the boards: open cards, and ended ones until they drop off after
  `retention_days`. Open cards come first, then the most recently changed.
  """
  @spec list(repo(), pos_integer(), DateTime.t()) :: [map()]
  def list(repo, retention_days, now \\ DateTime.utc_now(:microsecond)) when is_integer(retention_days) do
    cutoff = DateTime.add(now, -retention_days * 86_400, :second)
    cards = repo.all(from(card in Card, where: card.state in ^@active or card.ended_at > ^cutoff, order_by: [desc: card.updated_at, asc: card.id]))
    ids = Enum.map(cards, & &1.id)
    rows = workers(repo, ids)
    asks = Asks.open_by_card(repo, ids)

    cards
    |> Enum.sort_by(&(&1.state not in @active))
    |> Enum.map(&public(&1, Map.get(rows, &1.id), Map.get(asks, &1.id, [])))
  end

  # The latest worked-on row of each card: live first, else the latest.
  defp workers(_repo, []), do: %{}

  defp workers(repo, ids) do
    repo.all(from(row in WorkedOn, where: row.subject_kind == "card" and row.subject_id in ^ids))
    |> Enum.group_by(& &1.subject_id)
    |> Map.new(fn {id, rows} -> {id, Enum.max_by(rows, &{&1.state == "live", DateTime.to_unix(&1.started_at, :microsecond)})} end)
  end

  @doc "A card as the boards show it."
  @spec public(Card.t(), WorkedOn.t() | nil, [map()]) :: map()
  def public(%Card{} = card, row, asks) do
    %{
      "id" => card.id,
      "state" => card.state,
      "title" => card.title,
      "worked_on" => row && Ownership.public(row),
      "repository" => card.repository,
      "base_branch" => card.base_branch,
      "branch" => card.branch,
      "pr" => public_pr(card.pr),
      "review" => public_review(card),
      "stale" => card.stale,
      "asks" => Enum.map(asks, &Asks.public/1),
      "since" => iso(card.inserted_at),
      "ended_at" => iso(card.ended_at),
      "updated_at" => iso(card.updated_at)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp public_pr(%{} = pr), do: Map.take(pr, ~w(repository number url state draft head_sha ci github_review))
  defp public_pr(_pr), do: nil

  defp public_review(%Card{review_id: id} = card) when is_binary(id) do
    %{"id" => id, "state" => Atom.to_string(review_state(card)), "status" => card.review && card.review["status"]}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp public_review(_card), do: nil

  # Not read yet is pending; never read because the host is unreachable is unknown.
  defp review_state(%Card{review: nil, stale: stale}), do: if("review" in stale, do: :unknown, else: :pending)
  defp review_state(%Card{review: %{"status" => "not_started"}}), do: :pending
  defp review_state(%Card{review: review, pr: pr}), do: ReviewStatus.state({:ok, review}, pr && pr["head_sha"])

  @doc "Deletes cards that ended more than `retention_days` ago, with their asks and worked-on rows."
  @spec delete_expired(repo(), pos_integer(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_expired(repo, retention_days, now \\ DateTime.utc_now(:microsecond)) when is_integer(retention_days) do
    cutoff = DateTime.add(now, -retention_days * 86_400, :second)

    repo.transaction(fn ->
      ids = repo.all(from(card in Card, where: card.state in ^@ended and card.ended_at <= ^cutoff, select: card.id))
      Asks.delete_for_cards(repo, ids)
      Ownership.delete_subjects(repo, "card", ids)
      {count, _rows} = repo.delete_all(from(card in Card, where: card.id in ^ids))
      count
    end)
    |> case do
      {:ok, 0} -> {:ok, 0}
      {:ok, count} -> DashboardPubSub.broadcast_changed_on_success({:ok, count})
      {:error, reason} -> {:error, reason}
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
