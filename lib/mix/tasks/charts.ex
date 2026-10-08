defmodule Mix.Tasks.Charts do
  @shortdoc "Render the README charts from a sweep's measurements.csv"
  @moduledoc """
  Renders the SVG charts shown in the README from a sweep's `measurements.csv`.

      mix charts [results/my-device]

  The argument is a results folder written by `bench/concurrency.exs`
  (default: `results/example`). Light and dark variants of each chart are
  written to `<folder>/charts/`. The charts show the heaviest sweep load
  (32 writers, 4 readers), averaged over repeats.
  """
  use Mix.Task

  @strategies ~w(pooled single writer)
  @scenarios ~w(deferred immediate snapshot_window immediate_window no_busy_wait
                slow_transactions checkout_overload full_sync)

  @themes %{
    light: %{
      surface: "#fcfcfb",
      primary: "#0b0b0b",
      secondary: "#52514e",
      muted: "#898781",
      grid: "#e1e0d9",
      axis: "#c3c2b7",
      series: %{"pooled" => "#2a78d6", "single" => "#eb6834", "writer" => "#1baf7a"}
    },
    dark: %{
      surface: "#1a1a19",
      primary: "#ffffff",
      secondary: "#c3c2b7",
      muted: "#898781",
      grid: "#2c2c2a",
      axis: "#383835",
      series: %{"pooled" => "#3987e5", "single" => "#d95926", "writer" => "#199e70"}
    }
  }

  @font ~s(font-family="system-ui, -apple-system, &quot;Segoe UI&quot;, sans-serif")

  @impl true
  def run(argv) do
    folder = List.first(argv) || Path.join("results", "example")
    rows = read_csv!(Path.join(folder, "measurements.csv"))
    heavy = Enum.filter(rows, &(&1["writers"] == "32" and &1["readers"] == "4"))

    if heavy == [] do
      Mix.raise("no rows with 32 writers and 4 readers in #{folder}/measurements.csv")
    end

    data = aggregate(heavy)
    out = Path.join(folder, "charts")
    File.mkdir_p!(out)

    for mode <- [:light, :dark] do
      File.write!(Path.join(out, "failure-rates-#{mode}.svg"), failure_chart(mode, data))
      File.write!(Path.join(out, "sync-throughput-#{mode}.svg"), throughput_chart(mode, data))
    end

    Mix.shell().info("4 charts written to #{out}")
  end

  # Values in measurements.csv are always quoted and never contain quotes or commas.
  defp read_csv!(path) do
    [header | lines] =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        line |> String.trim() |> String.trim("\"") |> String.split("\",\"")
      end)

    Enum.map(lines, fn fields -> Map.new(Enum.zip(header, fields)) end)
  end

  defp aggregate(heavy) do
    cells =
      for scenario <- @scenarios, strategy <- @strategies, into: %{} do
        sel = Enum.filter(heavy, &(&1["scenario"] == scenario and &1["strategy"] == strategy))
        ok = sum_int(sel, "write_ok")
        errors = sum_int(sel, "sqlite_errors") + sum_int(sel, "pool_errors")

        throughput =
          Enum.sum(Enum.map(sel, &String.to_float(&1["committed_per_s"]))) / length(sel)

        {{scenario, strategy}, %{failure: 100 * errors / (ok + errors), throughput: throughput}}
      end

    sample = Enum.find(heavy, &(&1["scenario"] == hd(@scenarios)))

    Map.merge(cells, %{
      writes_per_writer: sample["writes_per_writer"],
      repeats: Enum.count(heavy, &(&1["scenario"] == hd(@scenarios))) |> div(3)
    })
  end

  defp sum_int(rows, key), do: Enum.sum(Enum.map(rows, &String.to_integer(&1[key])))

  ## Chart: write failure rate by scenario and strategy

  defp failure_chart(mode, data) do
    t = @themes[mode]
    {w, left, right, top} = {760, 150, 46, 92}
    {bar_h, gap, group_gap} = {13, 2, 16}
    group_h = 3 * bar_h + 2 * gap
    plot_w = w - left - right
    h = top + length(@scenarios) * (group_h + group_gap) + 34

    subtitle =
      "32 writers × #{data.writes_per_writer} writes each, 4 looping readers · " <>
        "share of write transactions that failed · average of #{data.repeats} runs"

    grid =
      for g <- [0, 25, 50, 75, 100] do
        gx = left + plot_w * g / 100

        line(gx, top, gx, h - 30, t.grid) <>
          text(gx, h - 12, "#{g}%", t.muted, 10.5, anchor: "middle", tabular: true)
      end

    groups =
      @scenarios
      |> Enum.with_index()
      |> Enum.map(fn {scenario, i} ->
        y = top + 4 + i * (group_h + group_gap)

        bars =
          @strategies
          |> Enum.with_index()
          |> Enum.map(fn {strategy, j} ->
            value = data[{scenario, strategy}].failure
            by = y + j * (bar_h + gap)
            x1 = left + plot_w * value / 100
            label_x = if value > 0, do: x1 + 6, else: left + 6

            hbar(left, x1, by, bar_h, t.series[strategy]) <>
              text(label_x, by + bar_h - 3, pct(value), t.muted, 10.5, tabular: true)
          end)

        text(left - 10, y + group_h / 2 + 4, scenario, t.secondary, 11.5, anchor: "end") <>
          Enum.join(bars)
      end)

    svg(w, h, t, [
      text(24, 32, "Write failure rate under contention", t.primary, 15, weight: "600"),
      text(24, 52, subtitle, t.secondary, 11.5),
      legend(24, 74, t),
      Enum.join(grid),
      Enum.join(groups),
      line(left, top, left, h - 30, t.axis)
    ])
  end

  ## Chart: throughput under synchronous NORMAL vs FULL

  defp throughput_chart(mode, data) do
    t = @themes[mode]
    {w, h, top, bottom, left} = {560, 330, 96, 44, 64}
    plot_h = h - top - bottom
    groups = [{"immediate", "NORMAL (immediate)"}, {"full_sync", "FULL (full_sync)"}]

    peak =
      for({scenario, _} <- groups, s <- @strategies, do: data[{scenario, s}].throughput)
      |> Enum.max()

    step = Enum.find([100, 250, 500, 1000, 1500, 2500, 5000], 10_000, &(peak / &1 <= 4))
    vmax = ceil(peak / step) * step

    grid =
      for g <- 0..vmax//step do
        gy = h - bottom - plot_h * g / vmax

        line(left, gy, w - 28, gy, t.grid) <>
          text(left - 8, gy + 3.5, thousands(g), t.muted, 10.5, anchor: "end", tabular: true)
      end

    {bar_w, gap} = {42, 2}
    group_w = 3 * bar_w + 2 * gap
    pitch = (w - left - 28) / length(groups)

    columns =
      groups
      |> Enum.with_index()
      |> Enum.map(fn {{scenario, label}, i} ->
        gx = left + pitch * i + (pitch - group_w) / 2

        bars =
          @strategies
          |> Enum.with_index()
          |> Enum.map(fn {strategy, j} ->
            value = data[{scenario, strategy}].throughput
            x = gx + j * (bar_w + gap)
            y1 = h - bottom - plot_h * value / vmax

            vbar(x, bar_w, h - bottom, y1, t.series[strategy]) <>
              text(x + bar_w / 2, y1 - 6, thousands(value), t.muted, 10.5,
                anchor: "middle",
                tabular: true
              )
          end)

        Enum.join(bars) <>
          text(gx + group_w / 2, h - bottom + 18, label, t.secondary, 11.5, anchor: "middle")
      end)

    svg(w, h, t, [
      text(24, 32, "Throughput: synchronous NORMAL vs FULL", t.primary, 15, weight: "600"),
      text(
        24,
        52,
        "Committed writes per second, same load as above · immediate transactions, no added pauses",
        t.secondary,
        11.5
      ),
      legend(24, 78, t),
      Enum.join(grid),
      Enum.join(columns),
      line(left, h - bottom, w - 28, h - bottom, t.axis)
    ])
  end

  ## SVG helpers

  defp svg(w, h, t, parts) do
    ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{w}" height="#{h}" viewBox="0 0 #{w} #{h}">) <>
      ~s(<rect width="#{w}" height="#{h}" fill="#{t.surface}"/>) <>
      Enum.join(parts) <> "</svg>"
  end

  # Horizontal bar, square at the baseline, 4px rounded corners at the value end.
  defp hbar(x0, x1, y, h, fill) do
    if x1 - x0 < 1 do
      ""
    else
      r = min(4, min(x1 - x0, h / 2))

      ~s(<path d="M#{f(x0)},#{f(y)} L#{f(x1 - r)},#{f(y)} ) <>
        ~s(Q#{f(x1)},#{f(y)} #{f(x1)},#{f(y + r)} L#{f(x1)},#{f(y + h - r)} ) <>
        ~s(Q#{f(x1)},#{f(y + h)} #{f(x1 - r)},#{f(y + h)} L#{f(x0)},#{f(y + h)} Z" fill="#{fill}"/>)
    end
  end

  defp vbar(x, w, y0, y1, fill) do
    if y0 - y1 < 1 do
      ""
    else
      r = min(4, min(y0 - y1, w / 2))

      ~s(<path d="M#{f(x)},#{f(y0)} L#{f(x)},#{f(y1 + r)} ) <>
        ~s(Q#{f(x)},#{f(y1)} #{f(x + r)},#{f(y1)} L#{f(x + w - r)},#{f(y1)} ) <>
        ~s(Q#{f(x + w)},#{f(y1)} #{f(x + w)},#{f(y1 + r)} L#{f(x + w)},#{f(y0)} Z" fill="#{fill}"/>)
    end
  end

  defp line(x1, y1, x2, y2, stroke),
    do:
      ~s(<line x1="#{f(x1)}" y1="#{f(y1)}" x2="#{f(x2)}" y2="#{f(y2)}" stroke="#{stroke}" stroke-width="1"/>)

  defp text(x, y, content, fill, size, opts \\ []) do
    anchor = Keyword.get(opts, :anchor, "start")
    weight = Keyword.get(opts, :weight, "normal")
    style = if opts[:tabular], do: ~s( style="font-variant-numeric: tabular-nums"), else: ""

    ~s(<text x="#{f(x)}" y="#{f(y)}" #{@font} font-size="#{size}" fill="#{fill}" ) <>
      ~s(text-anchor="#{anchor}" font-weight="#{weight}"#{style}>#{content}</text>)
  end

  defp legend(x, y, t) do
    {parts, _} =
      Enum.map_reduce(@strategies, x, fn strategy, cx ->
        swatch =
          ~s(<rect x="#{cx}" y="#{y - 9}" width="12" height="12" rx="3" fill="#{t.series[strategy]}"/>) <>
            text(cx + 17, y + 1, strategy, t.secondary, 12)

        {swatch, cx + 17 + 8 * String.length(strategy) + 28}
      end)

    Enum.join(parts)
  end

  defp f(n), do: :erlang.float_to_binary(n / 1, decimals: 1)

  defp pct(v) when v > 0 and v < 10, do: :erlang.float_to_binary(v / 1, decimals: 1) <> "%"
  defp pct(v), do: "#{round(v)}%"

  defp thousands(n) do
    n
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
