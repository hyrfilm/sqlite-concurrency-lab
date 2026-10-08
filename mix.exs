defmodule SqliteLab.MixProject do
  use Mix.Project

  def project do
    [
      app: :sqlite_lab,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [
        {:ecto_sql, "~> 3.14.0"},
        {:ecto_sqlite3, "~> 0.25.0"},
        {:stream_data, "~> 1.4.0", only: :test}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
