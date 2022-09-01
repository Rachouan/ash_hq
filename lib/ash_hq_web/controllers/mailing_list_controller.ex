defmodule AshHqWeb.MailingListController do
  use AshHqWeb, :controller

  import Ecto.Query, only: [from: 2]

  def unsubscribe(conn, %{"email" => email}) do
    query =
      from row in AshHq.MailingList.Email,
        where: row.email == ^email

    AshHq.Repo.delete_all(query)

    conn
    |> put_flash(:info, "You have been unsubscribed!")
    |> redirect(to: "/")
  end
end
