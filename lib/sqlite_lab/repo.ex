defmodule SqliteLab.Repo do
  @moduledoc "One pool shared by readers and writers."
  use Ecto.Repo, otp_app: :sqlite_lab, adapter: Ecto.Adapters.SQLite3
end

defmodule SqliteLab.WriteRepo do
  @moduledoc "One connection for the serialized writer."
  use Ecto.Repo, otp_app: :sqlite_lab, adapter: Ecto.Adapters.SQLite3
end

defmodule SqliteLab.ReadRepo do
  @moduledoc "A separate pool accessing the same database file."
  use Ecto.Repo, otp_app: :sqlite_lab, adapter: Ecto.Adapters.SQLite3
end

defmodule SqliteLab.Schema do
  @moduledoc "An event log and a counter equal to its committed deltas."

  def options(opts) do
    Keyword.merge(
      [
        journal_mode: :wal,
        synchronous: :normal,
        busy_timeout: 2_000,
        default_transaction_mode: :deferred,
        timeout: 30_000
      ],
      opts
    )
  end

  def prepare_file!(database) do
    File.mkdir_p!(Path.dirname(database))
    {:ok, db} = Exqlite.Sqlite3.open(database)

    try do
      :ok = Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=wal")
    after
      :ok = Exqlite.Sqlite3.close(db)
    end
  end

  def create!(repo) do
    repo.query!("""
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY,
      writer INTEGER NOT NULL,
      n INTEGER NOT NULL,
      delta INTEGER NOT NULL,
      payload TEXT NOT NULL,
      UNIQUE (writer, n)
    )
    """)

    repo.query!(
      "CREATE TABLE IF NOT EXISTS counters (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)"
    )

    repo.query!("INSERT OR IGNORE INTO counters (id, value) VALUES (1, 0)")
  end

  # The caller must wrap both changes in one transaction.
  def record!(repo, writer, n, delta \\ 1, payload \\ "event", pause_ms \\ 0) do
    %{rows: [[value]]} = repo.query!("SELECT value FROM counters WHERE id = 1")
    # Widen the snapshot/lock window without pretending to emulate slow storage.
    if pause_ms > 0, do: Process.sleep(pause_ms)
    repo.query!("UPDATE counters SET value = ? WHERE id = 1", [value + delta])

    repo.query!(
      "INSERT INTO events (writer, n, delta, payload) VALUES (?, ?, ?, ?)",
      [writer, n, delta, payload]
    )

    :ok
  end

  def snapshot(repo) do
    %{rows: [[counter, delta, events]]} =
      repo.query!("""
      SELECT value,
        (SELECT COALESCE(SUM(delta), 0) FROM events),
        (SELECT COUNT(*) FROM events)
      FROM counters WHERE id = 1
      """)

    %{counter: counter, delta: delta, events: events}
  end

  def events(repo) do
    repo.query!("SELECT writer, n, delta, payload FROM events ORDER BY writer, n").rows
    |> Enum.map(&List.to_tuple/1)
  end
end
