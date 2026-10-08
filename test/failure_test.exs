defmodule SqliteLab.FailureTest do
  use SqliteLab.LabCase, async: false
  alias SqliteLab.Experiment

  for strategy <- [:pooled, :single, :writer],
      scenario <- ["snapshot_window", "no_busy_wait", "checkout_overload", "full_sync"] do
    @strategy strategy
    @scenario scenario
    test "measure #{@scenario}/#{@strategy}: failures remain observations, not lost writes", %{
      database: db
    } do
      settings = Enum.find(Experiment.scenarios(), &(&1.scenario == @scenario))
      load = %{writers: 8, writes_per_writer: 6, readers: 2}
      entry = Experiment.run(@strategy, db, settings, load) |> Map.put(:repeat, 1)
      Experiment.summary(entry)
      # The exact rate is hardware/scheduling dependent. Workload audits successes separately.
      assert entry.result.writes.ok + Metrics.errors(entry.result.writes) == 48

      assert Enum.sum(Map.values(entry.result.writes.failure_details)) ==
               Metrics.errors(entry.result.writes)

      assert length(entry.result.acknowledged) == entry.result.writes.ok
    end
  end

  for strategy <- [:pooled, :single, :writer] do
    @strategy strategy
    test "#{strategy}: an external writer causes failures, then writes recover", %{database: db} do
      settings =
        Experiment.scenarios()
        |> Enum.find(&(&1.scenario == "immediate"))
        |> Map.merge(%{scenario: "external_lock", busy_timeout: 20, queue_target: 10_000})

      Experiment.with_route(@strategy, db, settings, fn route ->
        holder = Direct.start(database: db, pool_size: 1)
        parent = self()

        task =
          Task.async(fn ->
            holder.init.()

            Repo.transaction(
              fn ->
                send(parent, :locked)

                receive do
                  :release -> :ok
                after
                  5_000 -> raise "external holder was not released"
                end
              end,
              mode: :immediate
            )
          end)

        try do
          try do
            assert_receive :locked, 5_000
            load = %{writers: 4, writes_per_writer: 2, readers: 2}
            result = Workload.run(Map.merge(route, load))

            entry =
              Map.merge(settings, load)
              |> Map.merge(%{strategy: @strategy, repeat: 1, result: result})

            Experiment.summary(entry)
            assert result.writes.ok == 0
            assert result.writes.errors == %{sqlite: 8}
          after
            send(task.pid, :release)
            Task.await(task, 5_000)
          end

          load = %{writers: 1, writes_per_writer: 1, readers: 0}
          recovered = Workload.run(Map.merge(route, load))

          Experiment.summary(
            Map.merge(settings, load)
            |> Map.merge(%{
              scenario: "after_external_lock",
              strategy: @strategy,
              repeat: 1,
              result: recovered
            })
          )

          assert recovered.writes.ok == 1
          assert Metrics.errors(recovered.writes) == 0
        after
          Direct.stop(holder)
        end
      end)
    end
  end
end
