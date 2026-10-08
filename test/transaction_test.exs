defmodule SqliteLab.TransactionTest do
  use SqliteLab.LabCase, async: false

  test "a deferred reader cannot upgrade after another connection commits", %{database: db} do
    a = Direct.start(database: db, pool_size: 1)
    b = Direct.start(database: db, pool_size: 1)

    try do
      a.init.()

      assert_raise Exqlite.Error, ~r/busy|locked/i, fn ->
        Repo.transaction(
          fn ->
            Repo.query!("SELECT value FROM counters WHERE id = 1")

            task =
              Task.async(fn ->
                b.init.()
                Direct.record(2, 1)
              end)

            Task.await(task, 5_000)
            Schema.record!(Repo, 1, 1)
          end,
          mode: :deferred
        )
      end

      assert Schema.events(Repo) == [{2, 1, 1, "event"}]
    after
      Direct.stop(a)
      Direct.stop(b)
    end
  end

  test "BEGIN IMMEDIATE still fails when another connection holds the writer lock", %{
    database: db
  } do
    holder = Direct.start(database: db, pool_size: 1)

    contender =
      Direct.start(
        database: db,
        pool_size: 1,
        busy_timeout: 20,
        default_transaction_mode: :immediate
      )

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
              5_000 -> raise "holder was not released"
            end
          end,
          mode: :immediate
        )
      end)

    try do
      assert_receive :locked, 5_000
      contender.init.()
      assert_raise Exqlite.Error, ~r/busy|locked/i, fn -> Direct.record(1, 1) end
    after
      send(task.pid, :release)
      Task.await(task, 5_000)
      Direct.stop(holder)
      Direct.stop(contender)
    end
  end

  test "a WAL reader keeps its snapshot while the writer commits", %{database: db} do
    with_strategy(:writer, db, [], fn _ ->
      parent = self()

      reader =
        Task.async(fn ->
          ReadRepo.transaction(
            fn ->
              before = Store.snapshot()
              send(parent, :snapshot_open)

              receive do
                :check -> {before, Store.snapshot()}
              after
                5_000 -> raise "reader was not released"
              end
            end,
            mode: :deferred
          )
        end)

      try do
        assert_receive :snapshot_open, 5_000
        Store.record(1, 1)
        send(reader.pid, :check)
        assert {:ok, {old, old_again}} = Task.await(reader, 5_000)
        assert old == old_again
        assert old.events == 0
        assert Store.snapshot() == %{counter: 1, delta: 1, events: 1}
      after
        if Process.alive?(reader.pid), do: Task.shutdown(reader, :brutal_kill)
      end
    end)
  end
end
