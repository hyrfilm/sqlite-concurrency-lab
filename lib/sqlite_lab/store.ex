defmodule SqliteLab.Store do
  @moduledoc """
  One writer connection and a separate read pool share one WAL database.
  Requests wait in an unbounded GenServer mailbox; calls wait indefinitely.
  This deliberately demonstrates queuing, not production admission control.
  """
  use Supervisor
  alias SqliteLab.{WriteRepo, ReadRepo, Schema}
  alias SqliteLab.Store.Writer

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    database = Keyword.fetch!(opts, :database)
    Schema.prepare_file!(database)
    common = Schema.options(Keyword.put(Keyword.get(opts, :repo_opts, []), :database, database))

    write_opts =
      common
      |> Keyword.merge(Keyword.get(opts, :write_repo_opts, []))
      |> Keyword.put(:pool_size, 1)

    read_opts = Keyword.put(common, :pool_size, Keyword.get(opts, :read_pool_size, 4))

    Supervisor.init([{WriteRepo, write_opts}, {ReadRepo, read_opts}, Writer],
      strategy: :one_for_one
    )
  end

  def workload do
    %{
      init: fn -> :ok end,
      writer_pid: Process.whereis(Writer),
      write: &record/4,
      read: &snapshot/0,
      audit: &events/0
    }
  end

  def transaction(fun) when is_function(fun, 0) do
    case GenServer.call(Writer, {:write, fun}, :infinity) do
      {:ok, result} -> result
      {:error, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  def record(writer, n, delta \\ 1, payload \\ "event", pause_ms \\ 0),
    do: transaction(fn -> Schema.record!(WriteRepo, writer, n, delta, payload, pause_ms) end)

  def snapshot, do: Schema.snapshot(ReadRepo)
  def events, do: Schema.events(ReadRepo)
  def create_schema!, do: Schema.create!(WriteRepo)
end

defmodule SqliteLab.Store.Writer do
  @moduledoc "Commits one job at a time; rolls back and returns raised exceptions to the caller."
  use GenServer
  alias SqliteLab.WriteRepo

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:write, fun}, _from, state) do
    case WriteRepo.transaction(fun) do
      {:ok, result} -> {:reply, {:ok, result}, state}
      {:error, reason} -> raise "writer transaction rolled back: #{inspect(reason)}"
    end
  rescue
    exception -> {:reply, {:error, exception, __STACKTRACE__}, state}
  end
end
