defmodule Unfinal.Repo.Migrations.AddDocumentTitles do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :title, :text, null: false, default: ""
    end
  end
end
