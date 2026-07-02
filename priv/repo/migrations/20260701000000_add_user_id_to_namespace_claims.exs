defmodule Unfinal.Repo.Migrations.AddUserIdToNamespaceClaims do
  use Ecto.Migration

  def up do
    # Add user_id column — nullable for existing rows until data migration populates it
    alter table(:namespace_claims) do
      add :user_id, :string
    end

    # Unique index on user_id — SQLite allows multiple NULLs in a unique index,
    # so pre-migration rows (user_id IS NULL) don't conflict.
    create unique_index(:namespace_claims, [:user_id])
  end

  def down do
    drop index(:namespace_claims, [:user_id])

    alter table(:namespace_claims) do
      remove :user_id
    end
  end
end
