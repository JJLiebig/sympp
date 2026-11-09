defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router

  pipeline :browser do
    plug(:put_secure_browser_headers)
  end

  pipeline :operator_dashboard_api do
    plug(:put_local_operator_cors_headers)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/", ReactDashboardController, :index)
    get("/sympp", ReactDashboardController, :index)
    get("/sympp/*path", ReactDashboardController, :index)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    post("/api/v1/sympp/herdr/work-requests", SymppDashboardApiController, :herdr_create_work_request)

    post("/api/v1/sympp/herdr/asks/:ask_id/answer", SymppDashboardApiController, :herdr_answer_ask)
    post("/api/v1/sympp/herdr/decisions/:decision_id/ack", SymppDashboardApiController, :herdr_ack_decision)
    post("/api/v1/sympp/herdr/decisions/:decision_id/feedback", SymppDashboardApiController, :herdr_feedback_decision)
    post("/api/v1/sympp/herdr/decisions/:decision_id/dismiss", SymppDashboardApiController, :herdr_dismiss_decision)

    match(:*, "/api/v1/sympp/herdr/work-requests", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/herdr/asks/:ask_id/answer", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/herdr/decisions/:decision_id/ack", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/herdr/decisions/:decision_id/feedback", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/herdr/decisions/:decision_id/dismiss", ObservabilityApiController, :method_not_allowed)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:operator_dashboard_api)

    options("/api/v1/sympp/operator/*path", SymppDashboardApiController, :operator_options)
    get("/api/v1/sympp/operator/config", SymppDashboardApiController, :operator_config)
    get("/api/v1/sympp/operator/dashboard", SymppDashboardApiController, :operator_dashboard)
    get("/api/v1/sympp/operator/dashboard/deferred", SymppDashboardApiController, :operator_dashboard_deferred)
    get("/api/v1/sympp/operator/dashboard/hydrated", SymppDashboardApiController, :operator_dashboard_hydrated)
    get("/api/v1/sympp/operator/events", SymppDashboardApiController, :operator_events)
    get("/api/v1/sympp/operator/dashboard/events", SymppDashboardApiController, :operator_dashboard_events)
    get("/api/v1/sympp/herdr/dashboard", SymppDashboardApiController, :herdr_dashboard)
    get("/api/v1/sympp/herdr/events", SymppDashboardApiController, :herdr_events)
    get("/api/v1/sympp/herdr/work-requests/:work_request_id", SymppDashboardApiController, :herdr_work_request_detail)
    post("/api/v1/sympp/operator/settings", SymppDashboardApiController, :operator_update_settings)
    get("/api/v1/sympp/operator/work-packages/:work_package_id", SymppDashboardApiController, :operator_package_detail)
    get("/api/v1/sympp/operator/solo-sessions/:solo_session_id", SymppDashboardApiController, :operator_solo_session_detail)
    post("/api/v1/sympp/operator/work-requests", SymppDashboardApiController, :operator_create_work_request)
    get("/api/v1/sympp/operator/work-requests/:work_request_id", SymppDashboardApiController, :operator_work_request_detail)
    post("/api/v1/sympp/operator/work-requests/:work_request_id/complete", SymppDashboardApiController, :operator_complete_work_request)
    post("/api/v1/sympp/operator/work-requests/:work_request_id/archive", SymppDashboardApiController, :operator_archive_work_request)
    post("/api/v1/sympp/operator/work-requests/:work_request_id/delete", SymppDashboardApiController, :operator_delete_work_request)
    post("/api/v1/sympp/operator/work-requests/:work_request_id/restore", SymppDashboardApiController, :operator_restore_work_request)
    post("/api/v1/sympp/operator/work-requests/:work_request_id/release", SymppDashboardApiController, :operator_release_work_request)
    post("/api/v1/sympp/operator/work-packages/:work_package_id/finish", SymppDashboardApiController, :operator_finish_work_package)
    post("/api/v1/sympp/operator/work-packages/:work_package_id/blockers/:blocker_id/clear", SymppDashboardApiController, :operator_clear_work_package_blocker)
    post("/api/v1/sympp/operator/work-packages/:work_package_id/archive", SymppDashboardApiController, :operator_archive_work_package)
    post("/api/v1/sympp/operator/asks/:ask_id/answer", SymppDashboardApiController, :operator_answer_ask)
    post("/api/v1/sympp/operator/decisions/:decision_id/ack", SymppDashboardApiController, :operator_ack_decision)
    post("/api/v1/sympp/operator/decisions/:decision_id/feedback", SymppDashboardApiController, :operator_feedback_decision)
    post("/api/v1/sympp/operator/decisions/:decision_id/dismiss", SymppDashboardApiController, :operator_dismiss_decision)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/config", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/dashboard", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/dashboard/deferred", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/dashboard/hydrated", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/events", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/dashboard/events", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/herdr/dashboard", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/herdr/events", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/herdr/work-requests/:work_request_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/settings", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id/complete", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-packages/:work_package_id/finish", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-packages/:work_package_id/blockers/:blocker_id/clear", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-packages/:work_package_id/archive", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/asks/:ask_id/answer", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/decisions/:decision_id/ack", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/decisions/:decision_id/feedback", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/decisions/:decision_id/dismiss", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-packages/:work_package_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/solo-sessions/:solo_session_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id/archive", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id/delete", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id/restore", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id/release", ObservabilityApiController, :method_not_allowed)

    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end

  defp put_local_operator_cors_headers(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [origin | _rest] when is_binary(origin) ->
        if local_operator_cors_origin?(conn, origin) do
          conn
          |> Plug.Conn.put_resp_header("access-control-allow-origin", origin)
          |> Plug.Conn.put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
          |> Plug.Conn.put_resp_header("access-control-allow-headers", "accept, content-type")
          |> Plug.Conn.put_resp_header("vary", "origin")
        else
          conn
        end

      _origin ->
        conn
    end
  end

  defp local_operator_cors_origin?(conn, origin) do
    loopback_request?(conn.remote_ip) and
      local_host?(conn.host) and
      direct_local_request?(conn) and
      configured_dashboard_origin_matches?(origin)
  end

  defp loopback_request?({127, _second, _third, _fourth}), do: true
  defp loopback_request?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_request?(_remote_ip), do: false

  defp local_host?(host) when is_binary(host) do
    host = String.downcase(host)
    host in ["localhost", "127.0.0.1", "::1", "[::1]"] or String.ends_with?(host, ".localhost")
  end

  defp direct_local_request?(conn) do
    Enum.all?(["forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip"], fn header ->
      Plug.Conn.get_req_header(conn, header) == []
    end)
  end

  defp configured_dashboard_origin_matches?(origin) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    with %URI{} = expected <- configured_dashboard_origin(Keyword.get(endpoint_config, :sympp_dashboard_origin)),
         %URI{} = actual <- configured_dashboard_origin(origin) do
      origin_matches?(expected, actual)
    else
      _value -> false
    end
  end

  defp configured_dashboard_origin(origin) when is_binary(origin) do
    case URI.parse(String.trim_trailing(origin, "/")) do
      %URI{scheme: "http", host: host} = parsed when is_binary(host) ->
        if local_host?(host), do: parsed

      _parsed ->
        nil
    end
  end

  defp configured_dashboard_origin(_origin), do: nil

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

  defp normalize_origin_port("http", nil), do: 80
  defp normalize_origin_port(_scheme, port), do: port
end
