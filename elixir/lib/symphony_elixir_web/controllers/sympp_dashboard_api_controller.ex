defmodule SymphonyElixirWeb.SymppDashboardApiController do
  @moduledoc """
  Read-oriented JSON API for sympp dashboard state.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.SymphonyPlusPlus.Asks
  alias SymphonyElixir.SymphonyPlusPlus.Cards
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.OperatorAudit
  alias SymphonyElixir.SymphonyPlusPlus.OperatorAudit.Target
  alias SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionFeedback
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppDashboardApi.LocalOperatorActions
  alias SymphonyElixirWeb.SymppDashboardApi.Runtime

  alias SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard

  @dangerous_local_operator_actions [:dangerous_override, :dangerous_delete]

  @spec local_operator_browser?(Conn.t()) :: boolean()
  def local_operator_browser?(%Conn{} = conn) do
    SymphonyElixirWeb.FactoryAccessPlug.authenticated?(conn) or
      (local_operator_request?(conn) and same_origin_browser_request?(conn))
  end

  @spec herdr_consumer?(Conn.t()) :: boolean()
  def herdr_consumer?(%Conn{} = conn), do: local_operator_request?(conn)

  defp local_operator_request?(%Conn{} = conn) do
    SymphonyElixirWeb.FactoryAccessPlug.authenticated?(conn) or
      (loopback_request?(conn.remote_ip) and local_host?(conn.host) and direct_local_request?(conn))
  end

  defp loopback_request?({127, _second, _third, _fourth}), do: true
  defp loopback_request?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_request?(_remote_ip), do: false

  defp local_host?(host) do
    host = String.downcase(host)
    host in ["localhost", "127.0.0.1", "::1", "[::1]"] or String.ends_with?(host, ".localhost")
  end

  defp direct_local_request?(conn) do
    not forwarded_request?(conn)
  end

  defp forwarded_request?(conn) do
    Enum.any?(["forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip"], fn header ->
      Conn.get_req_header(conn, header) != []
    end)
  end

  defp same_origin_browser_request?(conn) do
    fetch_site = conn |> Conn.get_req_header("sec-fetch-site") |> List.first()

    case conn |> Conn.get_req_header("origin") |> List.first() do
      origin when is_binary(origin) ->
        trusted_origin_header?(conn, origin, fetch_site)

      nil ->
        browser_same_origin_metadata?(conn, fetch_site)
    end
  end

  defp trusted_origin_header?(conn, origin, fetch_site) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        origin = %URI{scheme: scheme, host: host, port: port}

        cond do
          same_request_origin?(conn, origin) -> fetch_site in [nil, "none", "same-origin"]
          configured_dashboard_origin?(origin) -> fetch_site in [nil, "none", "same-origin", "same-site"]
          true -> false
        end

      _parsed ->
        false
    end
  end

  defp same_request_origin?(conn, %URI{scheme: scheme, host: host, port: port}) do
    local_host?(host) and String.downcase(host) == String.downcase(conn.host) and scheme == Atom.to_string(conn.scheme) and
      normalize_origin_port(scheme, port) == conn.port
  end

  defp configured_dashboard_origin?(%URI{} = origin) do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    endpoint_config
    |> Keyword.get(:sympp_dashboard_origin)
    |> configured_dashboard_origin()
    |> origin_matches?(origin)
  end

  defp configured_dashboard_origin(origin) when is_binary(origin) do
    case URI.parse(String.trim_trailing(origin, "/")) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) and scheme == "http" ->
        %URI{scheme: scheme, host: host, port: port}
        |> require_local_origin()

      _parsed ->
        nil
    end
  end

  defp configured_dashboard_origin(_origin), do: nil

  defp require_local_origin(%URI{host: host} = origin) do
    if local_host?(host), do: origin
  end

  defp origin_matches?(%URI{scheme: expected_scheme, host: expected_host, port: expected_port}, %URI{
         scheme: actual_scheme,
         host: actual_host,
         port: actual_port
       })
       when is_binary(actual_scheme) and is_binary(actual_host) do
    String.downcase(actual_scheme) == String.downcase(expected_scheme) and
      String.downcase(actual_host) == String.downcase(expected_host) and
      normalize_origin_port(actual_scheme, actual_port) == normalize_origin_port(expected_scheme, expected_port)
  end

  defp origin_matches?(_expected_origin, _actual_origin), do: false

  defp browser_navigation_request?(conn) do
    mode = conn |> Conn.get_req_header("sec-fetch-mode") |> List.first()
    is_nil(mode) or mode == "navigate"
  end

  defp browser_same_origin_metadata?(conn, "none"), do: browser_navigation_request?(conn)

  defp browser_same_origin_metadata?(conn, "same-origin") do
    mode = conn |> Conn.get_req_header("sec-fetch-mode") |> List.first()
    destination = conn |> Conn.get_req_header("sec-fetch-dest") |> List.first()

    mode in ["cors", "same-origin"] and destination in [nil, "empty"]
  end

  defp browser_same_origin_metadata?(_conn, _fetch_site), do: false

  defp normalize_origin_port("http", nil), do: 80
  defp normalize_origin_port("https", nil), do: 443
  defp normalize_origin_port(_scheme, port), do: port

  @spec operator_dashboard(Conn.t(), map()) :: Conn.t()
  def operator_dashboard(conn, %{"surface" => surface}) when surface in ["archived"] do
    send_local_operator_response(conn, :dashboard_read, Target.new(:dashboard), :operator_dashboard_surface, fn repo ->
      with {:ok, payload} <- LocalOperatorDashboard.operator_dashboard_surface_payload(repo, surface) do
        json(conn, payload)
      end
    end)
  end

  def operator_dashboard(conn, _params) do
    send_local_operator_response(conn, :dashboard_read, Target.new(:dashboard), :operator_dashboard, fn repo ->
      with {:ok, payload} <- LocalOperatorDashboard.operator_dashboard_payload(repo) do
        json(conn, payload)
      end
    end)
  end

  @spec operator_dashboard_deferred(Conn.t(), map()) :: Conn.t()
  def operator_dashboard_deferred(conn, _params) do
    send_local_operator_response(conn, :dashboard_read, Target.new(:dashboard), :operator_dashboard_deferred, fn repo ->
      with {:ok, payload} <- LocalOperatorDashboard.operator_dashboard_deferred_payload(repo) do
        json(conn, payload)
      end
    end)
  end

  @spec operator_dashboard_hydrated(Conn.t(), map()) :: Conn.t()
  def operator_dashboard_hydrated(conn, _params) do
    send_local_operator_response(conn, :dashboard_read, Target.new(:dashboard), :operator_dashboard_hydrated, fn repo ->
      with {:ok, payload} <- LocalOperatorDashboard.operator_dashboard_hydrated_payload(repo) do
        json(conn, payload)
      end
    end)
  end

  @spec operator_dashboard_events(Conn.t(), map()) :: Conn.t()
  def operator_dashboard_events(conn, _params) do
    with true <- SymphonyElixirWeb.FactoryAccessPlug.board_read_only?(conn) or local_operator_browser?(conn),
         :ok <- OperatorDashboardOpener.ensure_started(),
         :ok <- DashboardPubSub.subscribe() do
      conn =
        conn
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.put_resp_header("connection", "keep-alive")
        |> Conn.put_resp_content_type("text/event-stream")
        |> Conn.send_chunked(200)

      OperatorDashboardOpener.dashboard_connected()

      try do
        stream_dashboard_events(conn)
      after
        OperatorDashboardOpener.dashboard_disconnected()
      end
    else
      false -> error_response(conn, :unauthorized)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  @spec herdr_dashboard(Conn.t(), map()) :: Conn.t()
  def herdr_dashboard(conn, _params) do
    if herdr_consumer?(conn) do
      Runtime.with_dashboard_repo(&herdr_dashboard_response(&1, conn), migrate?: false)
      |> case do
        {:error, reason} -> error_response(conn, reason)
        %Conn{} = conn -> conn
      end
    else
      error_response(conn, :unauthorized)
    end
  end

  defp herdr_dashboard_response(repo, conn) do
    with {:ok, payload} <- LocalOperatorDashboard.herdr_dashboard_payload(repo) do
      json(conn, payload)
    end
  end

  @spec herdr_work_request_detail(Conn.t(), map()) :: Conn.t()
  def herdr_work_request_detail(conn, %{"work_request_id" => work_request_id}) do
    if herdr_consumer?(conn) do
      Runtime.with_dashboard_repo(&herdr_work_request_detail_response(&1, conn, work_request_id), migrate?: false)
      |> case do
        {:error, reason} -> error_response(conn, reason)
        %Conn{} = conn -> conn
      end
    else
      error_response(conn, :unauthorized)
    end
  end

  defp herdr_work_request_detail_response(repo, conn, work_request_id) do
    with {:ok, payload} <- LocalOperatorDashboard.herdr_work_request_detail_payload(repo, work_request_id) do
      json(conn, payload)
    end
  end

  @spec herdr_events(Conn.t(), map()) :: Conn.t()
  def herdr_events(conn, _params) do
    notification_events(conn, herdr_consumer?(conn))
  end

  @spec operator_events(Conn.t(), map()) :: Conn.t()
  def operator_events(conn, _params) do
    notification_events(conn, local_operator_browser?(conn))
  end

  defp notification_events(conn, authorized?) do
    with true <- authorized?,
         :ok <- DashboardPubSub.subscribe() do
      conn =
        conn
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.put_resp_header("connection", "keep-alive")
        |> Conn.put_resp_content_type("text/event-stream")
        |> Conn.send_chunked(200)

      case Conn.chunk(conn, "event: ready\ndata: {}\n\n") do
        {:ok, conn} -> stream_herdr_events(conn)
        {:error, _reason} -> conn
      end
    else
      false -> error_response(conn, :unauthorized)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  @spec operator_config(Conn.t(), map()) :: Conn.t()
  def operator_config(conn, _params) do
    case local_operator_browser?(conn) do
      true -> json(conn, operator_runtime_config(conn) |> maybe_put_dashboard_bootstrap())
      false -> error_response(conn, :unauthorized)
    end
  end

  @spec operator_options(Conn.t(), map()) :: Conn.t()
  def operator_options(conn, _params) do
    send_resp(conn, 204, "")
  end

  @spec operator_package_detail(Conn.t(), map()) :: Conn.t()
  def operator_package_detail(conn, %{"work_package_id" => work_package_id}) do
    send_local_operator_response(
      conn,
      :work_package_read,
      work_package_target(work_package_id),
      :operator_package_detail,
      fn repo ->
        with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo),
             {:ok, payload} <-
               Dashboard.detail(repo, work_package_id, repo_identity_catalog: repo_identity_catalog) do
          json(conn, payload)
        end
      end
    )
  end

  @spec operator_work_request_detail(Conn.t(), map()) :: Conn.t()
  def operator_work_request_detail(conn, %{"work_request_id" => work_request_id} = params) do
    send_local_operator_response(
      conn,
      :dashboard_read,
      Target.new(:dashboard),
      :operator_work_request_detail,
      fn repo ->
        with {:ok, payload} <-
               LocalOperatorDashboard.operator_work_request_detail_payload(repo, work_request_id, work_package_id: Map.get(params, "work_package_id")) do
          json(conn, payload)
        end
      end
    )
  end

  @spec operator_create_work_request(Conn.t(), map()) :: Conn.t()
  def operator_create_work_request(conn, params) do
    send_local_operator_response(conn, :work_request_update, Target.ledger(), :operator_create_work_request, &create_work_request_response(&1, conn, params))
  end

  @spec herdr_create_work_request(Conn.t(), map()) :: Conn.t()
  def herdr_create_work_request(conn, params) do
    send_native_operator_response(conn, :work_request_update, Target.ledger(), :operator_create_work_request, &create_work_request_response(&1, conn, params))
  end

  defp create_work_request_response(repo, conn, params) do
    attrs = LocalOperatorDashboard.work_request_attrs(params)

    with {:ok, work_request} <- WorkRequestService.create(repo, attrs),
         {:ok, detail} <- LocalOperatorDashboard.operator_work_request_detail_payload(repo, work_request.id) do
      conn
      |> put_status(201)
      |> json(mutation_success_payload(%{work_request: detail}, %{work_request_id: work_request.id}))
    end
  end

  @spec operator_update_settings(Conn.t(), map()) :: Conn.t()
  def operator_update_settings(conn, params) do
    send_local_operator_response(conn, :dangerous_override, Target.ledger(), :operator_update_settings, fn repo ->
      with {:ok, settings} <- OperatorSettingsRepository.update(repo, LocalOperatorDashboard.operator_settings_attrs(params)),
           :ok <- LocalOperatorDashboard.run_operator_retention(repo, settings, force: true) do
        json(conn, mutation_success_payload(%{settings: LocalOperatorDashboard.operator_settings_payload(settings)}))
      end
    end)
  end

  # Finish, Release, Complete, Archive, Restore and Delete each have an operator
  # route (browser or remote-authenticated board) and a native Herdr route
  # (local JSON process). Both run the same handler, audit and error shape.

  @spec operator_archive_work_request(Conn.t(), map()) :: Conn.t()
  def operator_archive_work_request(conn, params), do: archive_work_request(&send_local_operator_response/5, conn, params)

  @spec herdr_archive_work_request(Conn.t(), map()) :: Conn.t()
  def herdr_archive_work_request(conn, params), do: archive_work_request(&send_native_operator_response/5, conn, params)

  defp archive_work_request(send, conn, %{"work_request_id" => work_request_id}) do
    send.(conn, :dangerous_delete, work_request_target(work_request_id), :operator_archive_work_request, fn repo ->
      with {:ok, work_request} <- WorkRequestService.archive(repo, work_request_id),
           {:ok, payload} <- LocalOperatorDashboard.work_request_mutation_payload(repo, work_request) do
        json(conn, mutation_success_payload(%{work_request: payload}, %{work_request_id: work_request.id}))
      end
    end)
  end

  @spec operator_delete_work_request(Conn.t(), map()) :: Conn.t()
  def operator_delete_work_request(conn, params), do: delete_work_request(&send_local_operator_response/5, conn, params)

  @spec herdr_delete_work_request(Conn.t(), map()) :: Conn.t()
  def herdr_delete_work_request(conn, params), do: delete_work_request(&send_native_operator_response/5, conn, params)

  defp delete_work_request(send, conn, %{"work_request_id" => work_request_id}) do
    send.(conn, :dangerous_delete, work_request_target(work_request_id), :operator_delete_work_request, fn repo ->
      with {:ok, deleted_id} <- WorkRequestService.delete(repo, work_request_id) do
        json(conn, mutation_success_payload(%{work_request: %{id: deleted_id}}, %{work_request_id: deleted_id}))
      end
    end)
  end

  @spec operator_restore_work_request(Conn.t(), map()) :: Conn.t()
  def operator_restore_work_request(conn, params), do: restore_work_request(&send_local_operator_response/5, conn, params)

  @spec herdr_restore_work_request(Conn.t(), map()) :: Conn.t()
  def herdr_restore_work_request(conn, params), do: restore_work_request(&send_native_operator_response/5, conn, params)

  defp restore_work_request(send, conn, %{"work_request_id" => work_request_id}) do
    send.(conn, :dangerous_override, work_request_target(work_request_id), :operator_restore_work_request, fn repo ->
      with {:ok, work_request} <- WorkRequestService.restore(repo, work_request_id),
           {:ok, payload} <- LocalOperatorDashboard.work_request_mutation_payload(repo, work_request) do
        json(conn, mutation_success_payload(%{work_request: payload}, %{work_request_id: work_request.id}))
      end
    end)
  end

  @spec operator_complete_work_request(Conn.t(), map()) :: Conn.t()
  def operator_complete_work_request(conn, params), do: complete_work_request(&send_local_operator_response/5, conn, params)

  @spec herdr_complete_work_request(Conn.t(), map()) :: Conn.t()
  def herdr_complete_work_request(conn, params), do: complete_work_request(&send_native_operator_response/5, conn, params)

  defp complete_work_request(send, conn, %{"work_request_id" => work_request_id}) do
    send.(conn, :dangerous_override, work_request_target(work_request_id), :operator_complete_work_request, fn repo ->
      with {:ok, work_request} <- WorkRequestService.complete(repo, work_request_id),
           {:ok, payload} <- LocalOperatorDashboard.work_request_mutation_payload(repo, work_request) do
        json(conn, mutation_success_payload(%{work_request: payload}, %{dashboard: false, work_request_id: work_request.id}))
      end
    end)
  end

  @spec operator_finish_work_package(Conn.t(), map()) :: Conn.t()
  def operator_finish_work_package(conn, params), do: finish_work_package(&send_local_operator_response/5, conn, params)

  @spec herdr_finish_work_package(Conn.t(), map()) :: Conn.t()
  def herdr_finish_work_package(conn, params), do: finish_work_package(&send_native_operator_response/5, conn, params)

  defp finish_work_package(send, conn, %{"work_package_id" => work_package_id}) do
    send.(conn, :dangerous_override, work_package_target(work_package_id), :operator_finish_work_package, fn repo ->
      with {:ok, work_package} <- LocalOperatorActions.finish_work_package_for_local_operator(repo, work_package_id) do
        payload = %{work_package_id: work_package.id, status: work_package.status}
        json(conn, mutation_success_payload(payload, %{work_package_id: work_package.id}))
      end
    end)
  end

  @doc """
  Operator Release: ends a WorkRequest's live ownership, for an owner that
  crashed on a machine the factory can't see. The next owner-gated write from
  any Herdr terminal takes it.
  """
  @spec operator_release_work_request(Conn.t(), map()) :: Conn.t()
  def operator_release_work_request(conn, params), do: release_work_request(&send_local_operator_response/5, conn, params)

  @spec herdr_release_work_request(Conn.t(), map()) :: Conn.t()
  def herdr_release_work_request(conn, params), do: release_work_request(&send_native_operator_response/5, conn, params)

  defp release_work_request(send, conn, %{"work_request_id" => work_request_id}) do
    send.(conn, :dangerous_override, work_request_target(work_request_id), :operator_release_work_request, fn repo ->
      with {:ok, released} <- Ownership.release(repo, work_request_id) do
        payload = %{work_request_id: work_request_id, released: Ownership.public(released)}
        json(conn, mutation_success_payload(payload, %{work_request_id: work_request_id}))
      end
    end)
  end

  @spec operator_clear_work_package_blocker(Conn.t(), map()) :: Conn.t()
  def operator_clear_work_package_blocker(conn, %{"work_package_id" => work_package_id, "blocker_id" => blocker_id} = params) do
    send_local_operator_response(
      conn,
      :dangerous_override,
      work_package_target(work_package_id),
      :operator_clear_work_package_blocker,
      fn repo ->
        with {:ok, blocker} <-
               LocalOperatorActions.clear_work_package_blocker_for_local_operator(
                 repo,
                 work_package_id,
                 blocker_id,
                 params
               ) do
          json(
            conn,
            mutation_success_payload(
              %{progress_event: %{id: blocker.event_id, blocker_id: blocker.id}},
              %{work_package_id: work_package_id}
            )
          )
        end
      end
    )
  end

  @spec operator_archive_work_package(Conn.t(), map()) :: Conn.t()
  def operator_archive_work_package(conn, %{"work_package_id" => work_package_id}) do
    send_local_operator_response(
      conn,
      :dangerous_delete,
      work_package_target(work_package_id),
      :operator_archive_work_package,
      fn repo ->
        with {:ok, work_package} <- LocalOperatorActions.hide_work_package_for_local_operator(repo, work_package_id) do
          json(conn, mutation_success_payload(%{work_package_id: work_package.id}, %{work_package_id: work_package.id}))
        end
      end
    )
  end

  @spec operator_answer_ask(Conn.t(), map()) :: Conn.t()
  def operator_answer_ask(conn, params) do
    send_local_operator_response(conn, :ask_answer, Target.new(:ask), :operator_answer_ask, &answer_ask_response(&1, conn, params))
  end

  @spec herdr_answer_ask(Conn.t(), map()) :: Conn.t()
  def herdr_answer_ask(conn, params) do
    send_native_operator_response(conn, :ask_answer, Target.new(:ask), :operator_answer_ask, &answer_ask_response(&1, conn, params))
  end

  # The answer is stored, then typed into the asking terminal without being
  # submitted; `delivery` says whether that reached it.
  defp answer_ask_response(repo, conn, %{"ask_id" => ask_id} = params) do
    with {:ok, ask, delivery} <- Asks.answer_by_operator(repo, ask_id, params) do
      subject = if ask.card_id, do: %{card_id: ask.card_id}, else: %{work_request_id: ask.work_request_id}
      json(conn, mutation_success_payload(Map.merge(%{ask_id: ask.id, delivery: delivery}, subject), subject))
    end
  end

  @doc "Operator dismisses a card: it drops off the boards after the card retention window."
  @spec operator_dismiss_card(Conn.t(), map()) :: Conn.t()
  def operator_dismiss_card(conn, params), do: send_local_operator_response(conn, :card_dismiss, Target.new(:card), :operator_dismiss_card, &dismiss_card_response(&1, conn, params))

  @spec herdr_dismiss_card(Conn.t(), map()) :: Conn.t()
  def herdr_dismiss_card(conn, params), do: send_native_operator_response(conn, :card_dismiss, Target.new(:card), :operator_dismiss_card, &dismiss_card_response(&1, conn, params))

  defp dismiss_card_response(repo, conn, %{"card_id" => card_id}) do
    case Cards.dismiss(repo, card_id) do
      {:ok, card} -> json(conn, mutation_success_payload(%{card_id: card.id, state: card.state}))
      {:error, :not_found} -> {:error, :card_not_found}
    end
  end

  @doc "Operator acknowledges a flagged decision: recorded -> acknowledged."
  @spec operator_ack_decision(Conn.t(), map()) :: Conn.t()
  def operator_ack_decision(conn, params), do: send_local_operator_response(conn, :decision_review, Target.new(:decision), :operator_ack_decision, &ack_decision_response(&1, conn, params))

  @spec herdr_ack_decision(Conn.t(), map()) :: Conn.t()
  def herdr_ack_decision(conn, params), do: send_native_operator_response(conn, :decision_review, Target.new(:decision), :operator_ack_decision, &ack_decision_response(&1, conn, params))

  @doc "Operator feedback on a flagged decision: recorded -> feedback, typed into the recording terminal."
  @spec operator_feedback_decision(Conn.t(), map()) :: Conn.t()
  def operator_feedback_decision(conn, params),
    do: send_local_operator_response(conn, :decision_review, Target.new(:decision), :operator_feedback_decision, &feedback_decision_response(&1, conn, params))

  @spec herdr_feedback_decision(Conn.t(), map()) :: Conn.t()
  def herdr_feedback_decision(conn, params),
    do: send_native_operator_response(conn, :decision_review, Target.new(:decision), :operator_feedback_decision, &feedback_decision_response(&1, conn, params))

  @doc "Clears the undelivered marker on decision feedback; the feedback text stays."
  @spec operator_dismiss_decision(Conn.t(), map()) :: Conn.t()
  def operator_dismiss_decision(conn, params),
    do: send_local_operator_response(conn, :decision_review, Target.new(:decision), :operator_dismiss_decision, &dismiss_decision_response(&1, conn, params))

  @spec herdr_dismiss_decision(Conn.t(), map()) :: Conn.t()
  def herdr_dismiss_decision(conn, params),
    do: send_native_operator_response(conn, :decision_review, Target.new(:decision), :operator_dismiss_decision, &dismiss_decision_response(&1, conn, params))

  defp ack_decision_response(repo, conn, %{"decision_id" => decision_id}) do
    with {:ok, decision} <- DecisionFeedback.ack(repo, decision_id),
         do: json(conn, decision_review_payload(decision, %{}))
  end

  # The feedback is stored, then typed into the recording terminal without
  # being submitted; `delivery` says whether that reached it.
  defp feedback_decision_response(repo, conn, %{"decision_id" => decision_id} = params) do
    with {:ok, decision, delivery} <- DecisionFeedback.feedback(repo, decision_id, params["text"]),
         do: json(conn, decision_review_payload(decision, %{delivery: delivery}))
  end

  defp dismiss_decision_response(repo, conn, %{"decision_id" => decision_id}) do
    with {:ok, decision} <- DecisionFeedback.dismiss(repo, decision_id),
         do: json(conn, decision_review_payload(decision, %{}))
  end

  defp decision_review_payload(decision, extra) do
    %{decision_id: decision.id, work_request_id: decision.work_request_id, review_state: decision.review_state}
    |> Map.merge(extra)
    |> mutation_success_payload(%{work_request_id: decision.work_request_id})
  end

  defp send_local_operator_response(conn, action, %Target{} = target, tool, fun)
       when is_atom(action) and is_atom(tool) and is_function(fun, 1) do
    send_online_or_local_response(conn, action, target, tool, fun)
  end

  defp send_online_or_local_response(conn, action, target, tool_name, fun) do
    if local_operator_browser?(conn) or
         (tool_name == :operator_dashboard_hydrated and SymphonyElixirWeb.FactoryAccessPlug.board_read_only?(conn)) do
      send_authorized_operator_response(conn, action, target, tool_name, fun)
    else
      error_response(conn, :unauthorized)
    end
  end

  defp send_native_operator_response(conn, action, target, tool_name, fun) do
    if native_operator_request?(conn) do
      send_authorized_operator_response(conn, action, target, tool_name, fun)
    else
      error_response(conn, :unauthorized)
    end
  end

  defp native_operator_request?(conn) do
    herdr_consumer?(conn) and native_json_request?(conn) and
      (SymphonyElixirWeb.FactoryAccessPlug.authenticated?(conn) or
         Enum.all?(conn.req_headers, fn {name, _value} ->
           name != "origin" and not String.starts_with?(name, ["sec-fetch-", "x-forwarded-"])
         end))
  end

  defp native_json_request?(conn) do
    case Conn.get_req_header(conn, "content-type") do
      [content_type] -> match?({:ok, "application", "json", _params}, Conn.Utils.media_type(content_type))
      _headers -> false
    end
  end

  defp send_authorized_operator_response(conn, action, target, tool_name, fun) do
    Runtime.with_dashboard_repo(fn repo ->
      local_operator_response(repo, conn, action, target, tool_name, fun)
    end)
    |> case do
      {:error, reason} -> error_response(conn, reason)
      %Conn{} = conn -> conn
    end
  end

  defp local_operator_response(repo, conn, action, %Target{} = target, tool_name, fun) do
    with :ok <- maybe_append_operator_audit(repo, conn, action, target, tool_name) do
      {result, invalidated?} = run_local_operator_action(repo, action, fun)
      finalize_local_operator_result(result, action, invalidated?)
    end
  end

  defp run_local_operator_action(repo, action, fun) when action in [:dashboard_read, :work_package_read],
    do: {fun.(repo), false}

  defp run_local_operator_action(repo, _action, fun),
    do: DashboardPubSub.coalesce_changed(fn -> fun.(repo) end)

  defp finalize_local_operator_result(%Conn{} = conn, action, false) do
    unless conn.private[:sympp_skip_dashboard_invalidation], do: maybe_broadcast_dashboard_change(action)
    conn
  end

  defp finalize_local_operator_result(%Conn{} = conn, _action, true), do: conn
  defp finalize_local_operator_result(other, _action, _invalidated?), do: other

  defp maybe_broadcast_dashboard_change(:dashboard_read), do: :ok
  defp maybe_broadcast_dashboard_change(:work_package_read), do: :ok
  defp maybe_broadcast_dashboard_change(_action), do: DashboardPubSub.broadcast_changed()

  defp stream_dashboard_events(conn) do
    receive do
      :operator_dashboard_changed ->
        case Conn.chunk(conn, "event: dashboard_changed\ndata: {}\n\n") do
          {:ok, conn} -> stream_dashboard_events(conn)
          {:error, _reason} -> conn
        end
    after
      30_000 ->
        case Conn.chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} -> stream_dashboard_events(conn)
          {:error, _reason} -> conn
        end
    end
  end

  defp stream_herdr_events(conn) do
    receive do
      :operator_dashboard_changed ->
        case Conn.chunk(conn, "event: invalidated\ndata: {}\n\n") do
          {:ok, conn} -> stream_herdr_events(conn)
          {:error, _reason} -> conn
        end
    after
      30_000 ->
        case Conn.chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} -> stream_herdr_events(conn)
          {:error, _reason} -> conn
        end
    end
  end

  defp maybe_append_operator_audit(repo, conn, action, %Target{} = target, tool_name) do
    if action in @dangerous_local_operator_actions do
      case OperatorAudit.append(repo, action, target, operator_request_metadata(conn), operator_tool_metadata(tool_name)) do
        {:ok, %OperatorAudit{}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp operator_request_metadata(%Conn{} = conn) do
    %{
      method: conn.method,
      path: conn.request_path,
      host: conn.host,
      remote_ip: conn |> Map.get(:remote_ip) |> remote_ip_string()
    }
  end

  defp operator_tool_metadata(tool_name) when is_atom(tool_name) do
    %{name: Atom.to_string(tool_name)}
  end

  defp remote_ip_string(remote_ip) when is_tuple(remote_ip) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  rescue
    _error -> nil
  end

  defp remote_ip_string(_remote_ip), do: nil

  defp work_request_target(work_request_id), do: Target.work_request(work_request_id)

  defp work_package_target(work_package_id), do: Target.work_package(work_package_id)

  defp operator_runtime_config(conn) do
    %{
      apiBase: prefixed_path(conn, "/api/v1/sympp/operator"),
      basePath: script_name_prefix(conn),
      logoUrl: prefixed_path(conn, "/splusplus-logo.png")
    }
  end

  defp maybe_put_dashboard_bootstrap(config) do
    case Runtime.with_dashboard_repo(&LocalOperatorDashboard.operator_dashboard_payload/1) do
      {:ok, dashboard} -> Map.put(config, :dashboard, dashboard)
      {:error, _reason} -> config
    end
  end

  defp mutation_success_payload(payload, refresh \\ %{}) when is_map(payload) and is_map(refresh) do
    payload
    |> Map.put(:ok, true)
    |> Map.put(:refresh, Map.merge(%{dashboard: true}, refresh))
  end

  defp script_name_prefix(%Conn{script_name: []}), do: ""
  defp script_name_prefix(%Conn{script_name: script_name}), do: "/" <> Enum.join(script_name, "/")

  defp error_response(conn, :not_found), do: error_response(conn, 404, "not_found", "Work package not found")
  defp error_response(conn, :card_not_found), do: error_response(conn, 404, "not_found", "Card not found")
  defp error_response(conn, :unauthorized), do: error_response(conn, 401, "unauthorized", "Unauthorized")
  defp error_response(conn, :forbidden), do: error_response(conn, 403, "forbidden", "Forbidden")
  defp error_response(conn, :database_busy), do: error_response(conn, 503, "database_busy", "Dashboard ledger is busy")
  defp error_response(conn, {:ask_not_open, state}), do: error_response(conn, 409, "ask_not_open", "This ask is already #{state}")
  defp error_response(conn, :invalid_answer_choice), do: error_response(conn, 422, "invalid_answer_choice", "Answer choice is invalid")
  defp error_response(conn, :invalid_archive_after_days), do: error_response(conn, 422, "invalid_archive_after_days", "Archive cutoff is invalid")
  defp error_response(conn, :missing_answer), do: error_response(conn, 422, "missing_answer", "Answer is required")
  defp error_response(conn, :missing_feedback), do: error_response(conn, 422, "missing_feedback", "Feedback text is required")

  defp error_response(conn, {:decision_transition_refused, state, next_action}) do
    conn
    |> put_status(409)
    |> json(%{error: %{code: "decision_transition_refused", message: "This decision is #{state}", state: state, next_action: next_action}})
  end

  defp error_response(conn, :not_owned), do: error_response(conn, 409, "not_owned", "No terminal works on this WorkRequest")

  defp error_response(conn, :not_completed), do: error_response(conn, 422, "not_completed", "Only a done or unresolved WorkRequest can be archived")

  defp error_response(conn, :work_request_archived) do
    conn
    |> put_status(409)
    |> json(%{error: %{code: "work_request_archived", message: "WorkRequest is archived; restore it first", phase: "archived", next_action: "restore"}})
  end

  defp error_response(conn, :not_delivered), do: error_response(conn, 422, "not_delivered", "WorkPackage is not delivered")
  defp error_response(conn, :work_request_package), do: error_response(conn, 422, "work_request_package", "WorkRequest WorkPackages cannot be archived independently")

  defp error_response(conn, :work_request_package_required),
    do: error_response(conn, 422, "work_request_package_required", "A WorkRequest WorkPackage is required")

  defp error_response(conn, :active_runtime), do: error_response(conn, 412, "active_runtime", "Closeout is blocked by active worker state")
  defp error_response(conn, :stale_status), do: error_response(conn, 409, "stale_status", "WorkPackage status changed; refresh and retry")
  defp error_response(conn, :work_package_scope_mismatch), do: error_response(conn, :not_found)
  defp error_response(conn, :work_package_mismatch), do: error_response(conn, 409, "work_package_mismatch", "WorkPackage no longer matches its WorkPackage")

  defp error_response(conn, {:ending_not_allowed, _status, _outcome}),
    do: error_response(conn, 422, "ending_not_allowed", "WorkPackage can only be finished while dispatched or ready")

  defp error_response(conn, {:delivery_outcome_conflict, outcome}),
    do: error_response(conn, 409, "already_ended", "WorkPackage already ended as #{outcome}")

  defp error_response(conn, :missing_custom_redirect_note) do
    error_response(conn, 422, "missing_custom_redirect_note", "A note is required for the custom answer")
  end

  defp error_response(conn, :invalid_status), do: error_response(conn, 422, "invalid_status", "Action is not valid for the current status")

  defp error_response(conn, %Ecto.Changeset{} = changeset) do
    error_response(conn, 422, "invalid_request", changeset_error_message(changeset))
  end

  defp error_response(conn, {:invalid_work_package_status, _status}) do
    error_response(conn, 422, "invalid_work_package_status", "WorkPackage is not ready for this action")
  end

  defp error_response(conn, {:storage_failed, _reason}) do
    error_response(conn, 503, "storage_failed", "Dashboard ledger storage failed")
  end

  defp error_response(conn, {:worktree_cleanup_failed, _reason}) do
    error_response(conn, 409, "request_delete_cleanup_failed", "Request could not be deleted safely")
  end

  defp error_response(conn, _reason), do: error_response(conn, 500, "dashboard_unavailable", "Dashboard API unavailable")

  defp changeset_error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
    |> case do
      "" -> "Request did not pass validation"
      message -> message
    end
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp prefixed_path(%Conn{script_name: []}, path), do: path

  defp prefixed_path(%Conn{script_name: script_name}, path) do
    "/" <> Enum.join(script_name ++ [String.trim_leading(path, "/")], "/")
  end
end
