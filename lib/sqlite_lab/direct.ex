defmodule SqliteLab.Direct do
  @moduledoc "Processes read and write directly through one Ecto pool."
  alias SqliteLab.{Repo, Schema}

  def start(opts) do
    opts = Schema.options(Keyword.put_new(opts, :pool_size, 5))
    Schema.prepare_file!(Keyword.fetch!(opts, :database))
    {:ok, pid} = Repo.start_link(Keyword.put(opts, :name, nil))
    Repo.put_dynamic_repo(pid)
    Schema.create!(Repo)

    %{
      pid: pid,
      init: fn -> Repo.put_dynamic_repo(pid) end,
      write: &record/4,
      read: fn -> Schema.snapshot(Repo) end,
      audit: fn -> Schema.events(Repo) end
    }
  end

  def record(writer, n, delta \\ 1, payload \\ "event", pause_ms \\ 0) do
    {:ok, :ok} =
      Repo.transaction(fn -> Schema.record!(Repo, writer, n, delta, payload, pause_ms) end)

    :ok
  end

  def stop(%{pid: pid}), do: Supervisor.stop(pid)
end
