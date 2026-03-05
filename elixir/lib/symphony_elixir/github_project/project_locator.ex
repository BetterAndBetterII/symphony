defmodule SymphonyElixir.GitHubProject.ProjectLocator do
  @moduledoc """
  Domain type for locating and authenticating a GitHub ProjectV2.

  This struct intentionally holds *validated* values. Use `parse/1` at the
  boundary (YAML config, env vars, CLI args, etc.) and keep downstream
  functions typed to `t()`.
  """

  @type owner_type :: :organization | :user

  @enforce_keys [:endpoint, :token, :owner, :owner_type, :project_number, :status_field_name]
  defstruct [:endpoint, :token, :owner, :owner_type, :project_number, :status_field_name]

  @type t :: %__MODULE__{
          endpoint: String.t(),
          token: String.t(),
          owner: String.t(),
          owner_type: owner_type(),
          project_number: pos_integer(),
          status_field_name: String.t()
        }

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{} = raw) do
    with {:ok, endpoint} <- parse_non_empty(get_value(raw, :endpoint), :missing_github_project_endpoint),
         {:ok, token} <- parse_non_empty(get_value(raw, :token), :missing_github_project_api_token),
         {:ok, owner} <- parse_non_empty(get_value(raw, :owner), :missing_github_project_owner),
         {:ok, owner_type} <- parse_owner_type(get_value(raw, :owner_type)),
         {:ok, project_number} <- parse_project_number(get_value(raw, :project_number)),
         {:ok, status_field_name} <- parse_status_field_name(get_value(raw, :status_field_name)) do
      {:ok,
       %__MODULE__{
         endpoint: endpoint,
         token: token,
         owner: owner,
         owner_type: owner_type,
         project_number: project_number,
         status_field_name: status_field_name
       }}
    end
  end

  def parse(_raw), do: {:error, :invalid_github_project_locator}

  defp get_value(raw, key) when is_atom(key) do
    Map.get(raw, key, Map.get(raw, Atom.to_string(key)))
  end

  defp parse_non_empty(value, error_atom) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error_atom}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_non_empty(_value, error_atom), do: {:error, error_atom}

  defp parse_owner_type(nil), do: {:error, :missing_github_project_owner_type}

  defp parse_owner_type(value) when is_atom(value) do
    parse_owner_type(Atom.to_string(value))
  end

  defp parse_owner_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> {:error, :missing_github_project_owner_type}
      "org" -> {:ok, :organization}
      "organization" -> {:ok, :organization}
      "user" -> {:ok, :user}
      other -> {:error, {:invalid_github_project_owner_type, other}}
    end
  end

  defp parse_owner_type(_value), do: {:error, :missing_github_project_owner_type}

  defp parse_project_number(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_project_number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, {:invalid_github_project_number, trimmed}}
    end
  end

  defp parse_project_number(nil), do: {:error, :missing_github_project_number}
  defp parse_project_number(value), do: {:error, {:invalid_github_project_number, value}}

  defp parse_status_field_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, "Status"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_status_field_name(nil), do: {:ok, "Status"}
  defp parse_status_field_name(_value), do: {:ok, "Status"}
end
