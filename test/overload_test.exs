defmodule SqliteLab.OverloadTest do
  use SqliteLab.LabCase, async: false

  for route <- [:direct, :writer] do
    @route route
    test "#{route}: slow transactions distinguish checkout rejection from mailbox waiting", %{
      database: db
    } do
      with_strategy(
        :writer,
        db,
        [write_repo_opts: [queue_target: 1, queue_interval: 10]],
        fn route ->
          write = fn w, n, delta, payload ->
            job = fn ->
              Process.sleep(25)
              Schema.record!(WriteRepo, w, n, delta, payload)
            end

            if @route == :direct, do: WriteRepo.transaction(job), else: Store.transaction(job)
          end

          result =
            Workload.run(
              Map.merge(route, %{writers: 20, writes_per_writer: 3, readers: 4, write: write})
            )

          assert result.writes.ok + Metrics.errors(result.writes) == 60

          IO.puts(
            "checkout comparison/#{@route}: ok=#{result.writes.ok} failures=#{inspect(result.writes.errors)} " <>
              "ok_p99_ms=#{Metrics.percentile_ms(result.writes, 0.99, :ok)} " <>
              "failure_p99_ms=#{Metrics.percentile_ms(result.writes, 0.99, :error)} " <>
              "mailbox_peak=#{result.resources.writer_mailbox_peak}; audit=ok"
          )

          assert Metrics.errors(result.reads) == 0, inspect(result.reads.sample)

          if @route == :direct do
            assert Map.get(result.writes.errors, :pool, 0) > 0
            assert Map.keys(result.writes.errors) == [:pool]
          else
            assert Metrics.errors(result.writes) == 0
            assert result.writes.ok == 60
          end

          {outcome, recovery} =
            Metrics.timed(Metrics.empty(), fn -> write.(99, 1, 1, "recovered") end)

          IO.puts(
            "after checkout overload/#{@route}: ok=#{recovery.ok} failures=#{inspect(recovery.errors)} " <>
              "latency_ms=#{Metrics.max_ms(recovery)}"
          )

          assert match?({:ok, _}, outcome)
          assert {99, 1, 1, "recovered"} in Store.events()
          assert Store.snapshot().events == result.writes.ok + 1
          assert Store.snapshot().counter == Store.snapshot().delta
        end
      )
    end
  end
end
