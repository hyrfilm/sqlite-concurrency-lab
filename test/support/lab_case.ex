defmodule SqliteLab.LabCase do
  use ExUnit.CaseTemplate
  alias SqliteLab.{Direct, Store}

  using do
    quote do
      import SqliteLab.LabCase
      alias SqliteLab.{Direct, Store, Repo, WriteRepo, ReadRepo, Schema, Workload, Metrics}
      @moduletag capture_log: true
      @moduletag timeout: 120_000
    end
  end

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "sqlite-lab-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{database: Path.join(directory, "db.sqlite")}
  end

  def with_strategy(:writer, database, opts, fun) do
    {:ok, pid} = Store.start_link(Keyword.put(opts, :database, database))

    try do
      Store.create_schema!()
      fun.(Store.workload())
    after
      Supervisor.stop(pid)
    end
  end

  def with_strategy(strategy, database, opts, fun) when strategy in [:pooled, :single] do
    pool = if strategy == :pooled, do: 5, else: 1
    direct = Direct.start([database: database, pool_size: pool] ++ opts)

    try do
      fun.(direct)
    after
      Direct.stop(direct)
    end
  end
end
