defmodule AshHq.Repo.Migrations.MigrateResources47 do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  This file was autogenerated with `mix ash_postgres.generate_migrations`
  """

  use Ecto.Migration

  def up do
    alter table(:extensions) do
      add(:module, :text)
    end
  end

  def down do
    alter table(:extensions) do
      remove(:module)
    end
  end
end
