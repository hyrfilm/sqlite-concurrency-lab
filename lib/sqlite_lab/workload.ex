defmodule SqliteLab.Workload do
  @moduledoc "Starts concurrent workers together; audits every acknowledged event afterwards."
  alias SqliteLab.Metrics

  def run(opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      execute(opts, supervisor)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp execute(opts, supervisor) do
    parent = self()
    gate = make_ref()
    deadline = System.monotonic_time(:millisecond) + Map.get(opts, :timeout, 120_000)

    spawn_worker = fn fun ->
      Task.Supervisor.async_nolink(
        supervisor,
        fn ->
          opts.init.()
          send(parent, {gate, :ready})
          receive do: ({^gate, :start} -> fun.())
        end,
        shutdown: :brutal_kill
      )
    end

    readers =
      for _ <- indices(opts.readers),
          do: spawn_worker.(fn -> read_loop(opts.read, Metrics.empty()) end)

    writers =
      for w <- indices(opts.writers) do
        spawn_worker.(fn ->
          Enum.reduce(indices(opts.writes_per_writer), {Metrics.empty(), []}, fn n,
                                                                                 {metrics, ack} ->
            delta = Map.get(opts, :delta, 1)
            payload = Map.get(opts, :payload, "event")

            {outcome, metrics} =
              Metrics.timed(metrics, fn -> opts.write.(w, n, delta, payload) end)

            ack =
              case outcome do
                {:ok, _} -> [{w, n, delta, payload} | ack]
                _ -> ack
              end

            {metrics, ack}
          end)
        end)
      end

    workers = readers ++ writers

    for _ <- workers do
      receive do
        {^gate, :ready} -> :ok
      after
        remaining(deadline) -> raise "workload workers did not become ready"
      end
    end

    memory_start = :erlang.memory(:total)

    sampler =
      Task.Supervisor.async_nolink(supervisor, fn ->
        sample_resources(Map.get(opts, :writer_pid), memory_start, 0)
      end)

    started = System.monotonic_time(:microsecond)
    for task <- workers, do: send(task.pid, {gate, :start})
    writes = Task.await_many(writers, remaining(deadline))
    for task <- readers, do: send(task.pid, :stop)
    reads = Task.await_many(readers, remaining(deadline))
    elapsed_us = System.monotonic_time(:microsecond) - started
    send(sampler.pid, :stop)
    resources = Task.await(sampler, remaining(deadline))
    acknowledged = writes |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort()

    # Audit is outside the measured interval but still covered by the run deadline.
    audit =
      Task.Supervisor.async_nolink(supervisor, fn ->
        opts.init.()
        %{events: opts.audit.(), snapshot: opts.read.()}
      end)

    stored = Task.await(audit, remaining(deadline))
    expected_sum = Enum.sum(Enum.map(acknowledged, &elem(&1, 2)))

    unless stored.events == acknowledged and
             stored.snapshot ==
               %{counter: expected_sum, delta: expected_sum, events: length(acknowledged)} do
      raise "stored events/counter do not match acknowledged writes"
    end

    %{
      writes: Metrics.sum(Enum.map(writes, &elem(&1, 0))),
      reads: Metrics.sum(reads),
      elapsed_us: elapsed_us,
      resources:
        Map.merge(resources, %{
          beam_start_bytes: memory_start,
          beam_end_bytes: :erlang.memory(:total)
        }),
      acknowledged: acknowledged
    }
  end

  # BEAM memory only (excludes SQLite native allocations); 50 ms sampling can miss spikes.
  defp sample_resources(writer, memory_peak, queue_peak) do
    queue =
      case writer && Process.info(writer, :message_queue_len) do
        {:message_queue_len, n} -> n
        _ -> 0
      end

    memory_peak = max(memory_peak, :erlang.memory(:total))
    queue_peak = max(queue_peak, queue)

    receive do
      :stop -> %{beam_peak_bytes: memory_peak, writer_mailbox_peak: queue_peak}
    after
      50 -> sample_resources(writer, memory_peak, queue_peak)
    end
  end

  defp read_loop(read, metrics) do
    {_, metrics} =
      Metrics.timed(metrics, fn ->
        snapshot = read.()
        unless snapshot.counter == snapshot.delta, do: raise("inconsistent reader snapshot")
        snapshot
      end)

    receive do
      :stop -> metrics
    after
      0 -> read_loop(read, metrics)
    end
  end

  defp indices(0), do: []
  defp indices(n) when is_integer(n) and n > 0, do: 1..n
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
