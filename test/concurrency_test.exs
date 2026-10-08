defmodule SqliteLab.ConcurrencyTest do
  use SqliteLab.LabCase, async: false
  use ExUnitProperties

  for strategy <- [:pooled, :single, :writer] do
    @strategy strategy
    property "#{strategy}: concurrent writes preserve identities, payloads and counter", %{
      database: db
    } do
      check all(
              writers <- integer(1..16),
              operations <- integer(1..64),
              readers <- integer(0..16),
              delta <- integer(-100_000_000..100_000_000),
              max_runs: 100
            ) do
        # Each generated case needs a fresh database.
        file = "#{db}-#{System.unique_integer([:positive])}"

        opts =
          if @strategy == :writer,
            do: [repo_opts: [queue_target: 10_000, default_transaction_mode: :immediate]],
            else: [queue_target: 10_000, default_transaction_mode: :immediate]

        with_strategy(@strategy, file, opts, fn route ->
          result =
            Workload.run(
              Map.merge(route, %{
                writers: writers,
                writes_per_writer: operations,
                readers: readers,
                delta: delta,
                payload: "writable"
              })
            )

          assert result.writes.ok == writers * operations
          assert Metrics.errors(result.writes) == 0, inspect(result.writes.sample)
          assert Metrics.errors(result.reads) == 0, inspect(result.reads.sample)
          if readers > 0, do: assert(result.reads.ok >= readers)
          expected = for w <- 1..writers, n <- 1..operations, do: {w, n, delta, "writable"}
          assert result.acknowledged == expected
        end)
      end
    end
  end

  test "raised jobs and constraint failures roll back; the writer serves the next caller", %{
    database: db
  } do
    with_strategy(:writer, db, [], fn _ ->
      writer = Process.whereis(SqliteLab.Store.Writer)

      assert_raise RuntimeError, "intentional job failure", fn ->
        Store.transaction(fn ->
          Schema.record!(WriteRepo, 1, 1)
          raise "intentional job failure"
        end)
      end

      assert_raise Exqlite.Error, fn ->
        Store.transaction(fn ->
          Schema.record!(WriteRepo, 1, 2)
          Schema.record!(WriteRepo, 1, 2)
        end)
      end

      assert Store.snapshot() == %{counter: 0, delta: 0, events: 0}
      assert :ok = Store.record(2, 1)
      assert Process.whereis(SqliteLab.Store.Writer) == writer
      assert Store.events() == [{2, 1, 1, "event"}]
    end)
  end

  test "a killed writer is restarted; committed data survives, the in-flight job is rolled back",
       %{database: db} do
    with_strategy(:writer, db, [], fn _ ->
      for n <- 1..5, do: Store.record(1, n)

      writer = Process.whereis(SqliteLab.Store.Writer)
      parent = self()

      caller =
        Task.async(fn ->
          try do
            Store.transaction(fn ->
              Schema.record!(WriteRepo, 9, 9)
              send(parent, :mid_transaction)
              Process.sleep(:infinity)
            end)
          catch
            :exit, reason -> {:exit, reason}
          end
        end)

      assert_receive :mid_transaction, 5_000
      Process.exit(writer, :kill)

      # The waiting caller is told, not left hanging or given a fake success.
      assert {:exit, {:killed, _}} = Task.await(caller, 5_000)

      restarted = wait_for_writer_restart(writer)
      assert is_pid(restarted) and restarted != writer

      assert Store.events() == for(n <- 1..5, do: {1, n, 1, "event"})
      assert :ok = Store.record(1, 6)
      assert Store.snapshot() == %{counter: 6, delta: 6, events: 6}
    end)
  end

  defp wait_for_writer_restart(old, attempts \\ 200) do
    case Process.whereis(SqliteLab.Store.Writer) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_writer_restart(old, attempts - 1)

      _ ->
        nil
    end
  end

  test "committed data remains after an orderly close and reopen", %{database: db} do
    with_strategy(:writer, db, [], fn _ ->
      for n <- 1..20, do: Store.record(1, n, n)
    end)

    with_strategy(:writer, db, [], fn _ ->
      assert Store.events() == for(n <- 1..20, do: {1, n, n, "event"})
      assert Store.snapshot() == %{counter: 210, delta: 210, events: 20}
    end)
  end
end
