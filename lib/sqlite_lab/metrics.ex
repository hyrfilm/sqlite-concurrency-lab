defmodule SqliteLab.Metrics do
  @moduledoc "Counts and bounded histograms; successful and failed call latencies stay separate."
  @buckets [
    100,
    250,
    500,
    1_000,
    2_500,
    5_000,
    10_000,
    25_000,
    50_000,
    100_000,
    250_000,
    500_000,
    1_000_000,
    2_500_000,
    5_000_000,
    30_000_000
  ]

  def empty do
    %{
      ok: 0,
      errors: %{},
      sample: [],
      failure_details: %{},
      latency: %{ok: %{}, error: %{}},
      max_us: %{ok: 0, error: 0}
    }
  end

  def attempt(fun) do
    {:ok, fun.()}
  rescue
    e in Exqlite.Error -> {:error, :sqlite, e.message, e.statement || ""}
    e in DBConnection.ConnectionError -> {:error, :pool, Exception.message(e), ""}
  end

  def timed(metrics, fun) do
    start = System.monotonic_time(:microsecond)
    outcome = attempt(fun)
    us = System.monotonic_time(:microsecond) - start
    bucket = Enum.find(@buckets, :overflow, &(us <= &1))
    group = if match?({:ok, _}, outcome), do: :ok, else: :error
    metrics = update_in(metrics, [:latency, group], &Map.update(&1, bucket, 1, fn n -> n + 1 end))
    metrics = update_in(metrics, [:max_us, group], &max(&1, us))

    metrics =
      case outcome do
        {:ok, _} ->
          %{metrics | ok: metrics.ok + 1}

        {:error, kind, message, statement} ->
          %{
            metrics
            | errors: Map.update(metrics.errors, kind, 1, &(&1 + 1)),
              failure_details:
                Map.update(metrics.failure_details, {kind, statement, message}, 1, &(&1 + 1)),
              sample: Enum.take(Enum.uniq(metrics.sample ++ [{kind, message}]), 2)
          }
      end

    {outcome, metrics}
  end

  def sum(results) do
    Enum.reduce(results, empty(), fn a, b ->
      %{
        ok: a.ok + b.ok,
        errors: merge_counts(a.errors, b.errors),
        failure_details: merge_counts(a.failure_details, b.failure_details),
        sample: Enum.take(Enum.uniq(a.sample ++ b.sample), 2),
        latency: Map.new([:ok, :error], &{&1, merge_counts(a.latency[&1], b.latency[&1])}),
        max_us: Map.new([:ok, :error], &{&1, max(a.max_us[&1], b.max_us[&1])})
      }
    end)
  end

  def errors(metrics), do: metrics.errors |> Map.values() |> Enum.sum()

  # Bucket upper bounds, not exact quantiles. Overflow uses that group's maximum.
  def percentile_ms(metrics, fraction, group \\ :all) do
    {histogram, max_us} =
      case group do
        :all ->
          {merge_counts(metrics.latency.ok, metrics.latency.error),
           max(metrics.max_us.ok, metrics.max_us.error)}

        group when group in [:ok, :error] ->
          {metrics.latency[group], metrics.max_us[group]}
      end

    target = ceil(Enum.sum(Map.values(histogram)) * fraction)

    if target == 0 do
      nil
    else
      {bucket, _} =
        histogram
        |> Enum.sort()
        |> Enum.reduce_while({0, 0}, fn {bucket, n}, {_, seen} ->
          if seen + n >= target,
            do: {:halt, {bucket, seen + n}},
            else: {:cont, {bucket, seen + n}}
        end)

      if bucket == :overflow, do: max_us / 1_000, else: bucket / 1_000
    end
  end

  def max_ms(metrics, group \\ :all) do
    value =
      if group == :all,
        do: max(metrics.max_us.ok, metrics.max_us.error),
        else: metrics.max_us[group]

    value / 1_000
  end

  defp merge_counts(a, b), do: Map.merge(a, b, fn _, x, y -> x + y end)
end
