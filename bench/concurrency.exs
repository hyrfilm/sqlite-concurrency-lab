alias SqliteLab.Experiment

# Edit this small matrix to probe another device or workload.
writer_counts = [1, 8, 32]
reader_counts = [0, 4]
writes_per_writer = 12
repeats = 2
strategies = [:pooled, :single, :writer]
scenarios = Experiment.scenarios()
started_at = DateTime.utc_now() |> DateTime.to_iso8601()
run_id = String.replace(started_at, ":", "-")
output = Path.expand(List.first(System.argv()) || "results/run-#{run_id}")
File.mkdir_p!(output)
summary_file = Path.join(output, "measurements.csv")
errors_file = Path.join(output, "errors.csv")
File.write!(summary_file, Experiment.header())
File.write!(errors_file, Experiment.error_header())

directory =
  Path.join(
    System.tmp_dir!(),
    "sqlite-sweep-#{System.unique_integer([:positive])}-#{System.pid()}"
  )

File.mkdir_p!(directory)

{:ok, db} = Exqlite.Sqlite3.open(":memory:")
{:ok, statement} = Exqlite.Sqlite3.prepare(db, "SELECT sqlite_version()")
{:ok, [[sqlite]]} = Exqlite.Sqlite3.fetch_all(db, statement)
:ok = Exqlite.Sqlite3.release(db, statement)
:ok = Exqlite.Sqlite3.close(db)

metadata = %{
  started_at_utc: started_at,
  elixir: System.version(),
  otp: System.otp_release(),
  sqlite: sqlite,
  os: :os.type(),
  schedulers: :erlang.system_info(:schedulers_online),
  dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
  dirty_io_schedulers: :erlang.system_info(:dirty_io_schedulers),
  versions:
    Map.new(
      [:ecto, :ecto_sql, :ecto_sqlite3, :exqlite, :db_connection],
      &{&1, to_string(Application.spec(&1, :vsn))}
    ),
  writer_counts: writer_counts,
  reader_counts: reader_counts,
  writes_per_writer: writes_per_writer,
  repeats: repeats,
  scenarios: scenarios,
  journal_mode: :wal,
  write_pools: %{pooled: 5, single: 1, writer: 1},
  writer_read_pool: 4,
  timeout_ms: 120_000,
  resource_sampling_ms: 50,
  retries: 0
}

File.write!(
  Path.join(output, "environment.txt"),
  inspect(metadata, pretty: true, limit: :infinity) <> "\n"
)

IO.puts("Evidence: #{output}")

IO.puts(
  "#{length(scenarios) * length(writer_counts) * length(reader_counts) * repeats * 3} cases; no retries; no zero-error assumption."
)

try do
  completed =
    for settings <- scenarios, writers <- writer_counts, readers <- reader_counts do
      for repeat <- 1..repeats do
        order =
          Enum.drop(strategies, rem(repeat - 1, 3)) ++ Enum.take(strategies, rem(repeat - 1, 3))

        for strategy <- order do
          name = "#{settings.scenario}-#{strategy}-#{writers}-#{readers}-#{repeat}"
          load = %{writers: writers, writes_per_writer: writes_per_writer, readers: readers}

          entry =
            Experiment.run(strategy, Path.join(directory, name <> ".sqlite"), settings, load)
            |> Map.put(:repeat, repeat)

          # Append each case immediately: earlier evidence survives a later fatal failure.
          File.write!(summary_file, Experiment.row(entry), [:append])
          File.write!(errors_file, Experiment.error_rows(entry), [:append])
          Experiment.summary(entry)
          {Experiment.row(entry), Experiment.error_rows(entry)}
        end
      end
    end

  # Finalize from the retained rows, keeping both exports complete and consistent.
  completed = List.flatten(completed)
  File.write!(summary_file, [Experiment.header(), Enum.map(completed, &elem(&1, 0))])
  File.write!(errors_file, [Experiment.error_header(), Enum.map(completed, &elem(&1, 1))])
rescue
  exception ->
    File.write!(
      Path.join(output, "fatal.txt"),
      Exception.format(:error, exception, __STACKTRACE__)
    )

    reraise exception, __STACKTRACE__
catch
  kind, reason ->
    File.write!(Path.join(output, "fatal.txt"), Exception.format(kind, reason, __STACKTRACE__))
    :erlang.raise(kind, reason, __STACKTRACE__)
after
  File.rm_rf!(directory)
end

IO.puts(
  "Sweep complete. Latency percentiles are histogram upper bounds; memory is sampled BEAM memory."
)
