defmodule AshHq.Accounts.User do
  @moduledoc false

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication],
    fragments: [AshHq.Accounts.User.Policies]

  require Ash.Query

  alias AshHq.Calculations.Decrypt

  actions do
    defaults [:read]

    create :register_with_github do
      argument :user_info, :map do
        allow_nil? false
      end

      argument :oauth_tokens, :map do
        allow_nil? false
      end

      change fn changeset, _ ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)

        changeset =
          if user_info["email_verified"] do
            Ash.Changeset.force_change_attribute(
              changeset,
              :confirmed_at,
              Ash.Changeset.get_attribute(changeset, :confirmed_at) || DateTime.utc_now()
            )
          else
            changeset
          end

        changeset
        |> Ash.Changeset.change_attribute(:email, Map.get(user_info, "email"))
        |> Ash.Changeset.change_attribute(:github_info, user_info)
      end

      change AshAuthentication.GenerateTokenChange
      upsert? true
      upsert_identity :unique_email
    end

    update :change_password do
      accept []

      argument :current_password, :string do
        sensitive? true
        allow_nil? false
      end

      argument :password, :string do
        sensitive? true
        allow_nil? false
      end

      argument :password_confirmation, :string do
        sensitive? true
        allow_nil? false
      end

      change set_context(%{strategy_name: :password})

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password} do
        only_when_valid? true
        before_action? true
      end

      change AshAuthentication.Strategy.Password.HashPasswordChange
    end

    update :update_email do
      accept [:email]

      argument :current_password, :string do
        sensitive? true
        allow_nil? false
      end

      change set_context(%{strategy_name: :password})

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                password_argument: :current_password} do
        only_when_valid? true
        before_action? true
      end
    end

    update :resend_confirmation_instructions do
      accept []

      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          case AshHq.Accounts.UserToken.email_token_for_user(changeset.data.id,
                 authorize?: false
               ) do
            {:ok, %{extra_data: %{"email" => changing_to}}} ->
              temp_changeset = %{
                changeset
                | attributes: Map.put(changeset.attributes, :email, changing_to)
              }

              strategy = AshAuthentication.Info.strategy!(changeset.resource, :confirm)

              {:ok, token} =
                AshAuthentication.AddOn.Confirmation.confirmation_token(
                  strategy,
                  temp_changeset,
                  changeset.data
                )

              AshHq.Accounts.User.Senders.SendConfirmationEmail.send(changeset.data, token, [])

              changeset

            _ ->
              Ash.Changeset.add_error(changeset, "Could not determine what email to use")
          end
        end)
      end
    end

    update :update_merch_settings do
      argument :address, :string
      argument :name, :string

      accept [:shirt_size]
      change set_attribute(:encrypted_address, arg(:address))
      change set_attribute(:encrypted_name, arg(:name))
    end
  end

  authentication do
    api AshHq.Accounts

    strategies do
      password :password do
        identity_field :email
        hashed_password_field :hashed_password
        sign_in_tokens_enabled? true

        resettable do
          sender AshHq.Accounts.User.Senders.SendPasswordResetEmail
        end
      end

      github do
        client_id AshHq.Accounts.Secrets
        client_secret AshHq.Accounts.Secrets
        redirect_uri AshHq.Accounts.Secrets
      end
    end

    tokens do
      enabled? true
      token_resource AshHq.Accounts.UserToken
      signing_secret AshHq.Accounts.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    add_ons do
      confirmation :confirm do
        monitor_fields [:email]

        sender AshHq.Accounts.User.Senders.SendConfirmationEmail
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string,
      allow_nil?: false,
      constraints: [
        max_length: 160
      ]

    attribute :hashed_password, :string, private?: true, sensitive?: true

    attribute :encrypted_name, :string
    attribute :encrypted_address, :string
    attribute :shirt_size, :string
    attribute :github_info, :map

    attribute :ashley_access, :boolean do
      default false
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_one :token, AshHq.Accounts.UserToken do
      destination_attribute :user_id
      private? true
    end
  end

  postgres do
    table "users"
    repo AshHq.Repo
  end

  code_interface do
    define_for AshHq.Accounts
    define :resend_confirmation_instructions
    define :register_with_password, args: [:email, :password, :password_confirmation]
  end

  resource do
    description """
    Represents the user of a system.
    """
  end

  identities do
    identity :unique_email, [:email] do
      eager_check_with AshHq.Accounts
    end
  end

  changes do
    change AshHq.Accounts.User.Changes.RemoveAllTokens,
      where: [action_is(:password_reset_with_password)]

    change {AshHq.Changes.Encrypt, fields: [:encrypted_address, :encrypted_name]}
  end

  validations do
    validate match(:email, ~r/^[^\s]+@[^\s]+$/), message: "must have the @ sign and no spaces"
  end

  calculations do
    calculate :address, :string, {Decrypt, field: :encrypted_address}
    calculate :name, :string, {Decrypt, field: :encrypted_name}
  end
end
