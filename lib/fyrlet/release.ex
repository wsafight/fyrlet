defmodule Fyrlet.Release do
  @moduledoc "Release helpers: `bin/app eval \"Fyrlet.Release.migrate()\"`."
  def migrate do
    Application.load(:fyrlet)
    Fyrlet.Migrator.migrate()
  end
end
