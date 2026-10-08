defmodule SqliteLab.Experiment do
  @moduledoc "A small failure-oriented matrix shared by the tests and measurement sweep."
  alias SqliteLab.{Direct, Store, Metrics, Workload}

  def scenarios do
    defaults = %{
      mode: :deferred,
      synchronous: :normal,
      busy_timeout: 2_000,
      queue_target: 50,
      queue_interval: 1_000,
      pause_ms: 0
    }

    for {name, overrides} <- [
          {"deferred", %{}},
          {"immediate", %{mode: :immediate}},
          {"snapshot_window", %{pause_ms: 5}},
          {"immediate_window", %{mode: :immediate, pause_ms: 5}},
          {"no_busy_wait", %{mode: :immediate, pause_ms: 5, busy_timeout: 0}},
          {"slow_transactions", %{mode: :immediate, pause_ms: 25}},
          {"checkout_overload",
           %{mode: :immediate, pause_ms: 25, queue_target: 1, queue_interval: 10}},
          {"full_sync", %{mode: :immediate, synchronous: :full}}
        ],
        do: Map.merge(defaults, overrides) |> Map.put(:scenario, name)
  end

  def with_route(strategy, database, settings, fun) do
    opts = [
      database: database,
      default_transaction_mode: settings.mode,
      synchronous: settings.synchronous,
      busy_timeout: settings.busy_timeout,
      queue_target: settings.queue_target,
      queue_interval: settings.queue_interval
    ]

    {pid, route} =
      case strategy do
        :writer ->
          {:ok, pid} = Store.start_link(database: database, repo_opts: opts)
          Store.create_schema!()
          {pid, Store.workload()}

        direct when direct in [:pooled, :single] ->
          route =
            Direct.start(Keyword.put(opts, :pool_size, if(direct == :pooled, do: 5, else: 1)))

          {route.pid, route}
      end

    write =
      case strategy do
        :writer -> fn w, n, d, p -> Store.record(w, n, d, p, settings.pause_ms) end
        _ -> fn w, n, d, p -> Direct.record(w, n, d, p, settings.pause_ms) end
      end

    try do
      fun.(Map.put(route, :write, write))
    after
      Supervisor.stop(pid)
    end
  end

  def run(strategy, database, settings, load) do
    with_route(strategy, database, settings, fn route ->
      result = Workload.run(Map.merge(route, load))

      for metrics <- [result.writes, result.reads] do
        unless Enum.sum(Map.values(metrics.failure_details)) == Metrics.errors(metrics),
          do: raise("failure detail counts do not match operation totals")
      end

      Map.merge(settings, load) |> Map.merge(%{strategy: strategy, result: result})
    end)
  end

  def summary(entry) do
    w = entry.result.writes
    errors = Metrics.errors(w)

    IO.puts(
      "#{entry.scenario}/#{entry.strategy}: #{entry.writers}w #{entry.readers}r; " <>
        "ok=#{w.ok} failed=#{errors}/#{w.ok + errors} " <>
        "sqlite=#{Map.get(w.errors, :sqlite, 0)} pool=#{Map.get(w.errors, :pool, 0)}; " <>
        "read_errors=#{Metrics.errors(entry.result.reads)} " <>
        "ok_p99_ms=#{Metrics.percentile_ms(w, 0.99, :ok)} " <>
        "fail_p99_ms=#{Metrics.percentile_ms(w, 0.99, :error)} " <>
        "mailbox_peak=#{entry.result.resources.writer_mailbox_peak}; audit=ok"
    )
  end

  @columns ~w(scenario strategy repeat writers writes_per_writer readers mode synchronous
    busy_timeout queue_target queue_interval pause_ms write_ok sqlite_errors pool_errors
    error_percent read_ok read_sqlite_errors read_pool_errors elapsed_ms committed_per_s
    ok_p50_ms ok_p95_ms ok_p99_ms ok_max_ms failure_p50_ms failure_p95_ms failure_p99_ms
    failure_max_ms read_p95_ms writer_mailbox_peak beam_start_bytes beam_end_bytes
    beam_peak_bytes audit_ok)a

  def header, do: csv(@columns)

  def row(entry) do
    %{writes: w, reads: r} = entry.result
    total = w.ok + Metrics.errors(w)

    values =
      Map.merge(entry, %{
        write_ok: w.ok,
        sqlite_errors: Map.get(w.errors, :sqlite, 0),
        pool_errors: Map.get(w.errors, :pool, 0),
        error_percent: 100 * Metrics.errors(w) / max(total, 1),
        read_ok: r.ok,
        read_sqlite_errors: Map.get(r.errors, :sqlite, 0),
        read_pool_errors: Map.get(r.errors, :pool, 0),
        elapsed_ms: entry.result.elapsed_us / 1_000,
        committed_per_s: w.ok * 1_000_000 / max(entry.result.elapsed_us, 1),
        ok_p50_ms: Metrics.percentile_ms(w, 0.50, :ok),
        ok_p95_ms: Metrics.percentile_ms(w, 0.95, :ok),
        ok_p99_ms: Metrics.percentile_ms(w, 0.99, :ok),
        ok_max_ms: Metrics.max_ms(w, :ok),
        failure_p50_ms: Metrics.percentile_ms(w, 0.50, :error),
        failure_p95_ms: Metrics.percentile_ms(w, 0.95, :error),
        failure_p99_ms: Metrics.percentile_ms(w, 0.99, :error),
        failure_max_ms: Metrics.max_ms(w, :error),
        read_p95_ms: Metrics.percentile_ms(r, 0.95),
        audit_ok: true
      })
      |> Map.merge(entry.result.resources)

    csv(Enum.map(@columns, &Map.get(values, &1)))
  end

  def error_header,
    do: csv(~w(scenario strategy repeat writers readers operation kind statement message count))

  def error_rows(entry) do
    for {operation, metrics} <- [write: entry.result.writes, read: entry.result.reads],
        {{kind, statement, message}, count} <- Enum.sort(metrics.failure_details),
        do:
          csv([
            entry.scenario,
            entry.strategy,
            entry.repeat,
            entry.writers,
            entry.readers,
            operation,
            kind,
            statement,
            message,
            count
          ])
  end

  defp csv(values),
    do:
      Enum.map_join(values, ",", fn value ->
        "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
      end) <> "\n"
end
