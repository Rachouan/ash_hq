defmodule AshHq.Repo.Migrations.MigrateResources49 do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  This file was autogenerated with `mix ash_postgres.generate_migrations`
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:encrypted_address_text, :text)
      add(:encrypted_name_text, :text)
    end

    execute("""
    UPDATE users SET
      encrypted_address_text = encode(encrypted_address, 'base64'),
      encrypted_name_text = encode(encrypted_name, 'base64'),
      encrypted_address = NULL,
      encrypted_name = NULL
    """)

    alter table(:users) do
      modify(:encrypted_address, :text)
      modify(:encrypted_name, :text)
    end

    execute("""
    UPDATE users SET
      encrypted_address = encrypted_address_text,
      encrypted_name = encrypted_name_text
    """)

    alter table(:users) do
      remove(:encrypted_address_text)
      remove(:encrypted_name_text)
    end
  end

  def down do
    raise "non reversible migration"
  end
end