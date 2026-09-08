defmodule SymphonyElixir.ManagedResponsibility.Manifest do
  @moduledoc """
  Loads a bounded operator-issued authorization document from a host-pinned file.
  This input is configuration; the orchestrator remains the sole graph writer.
  """

  import Bitwise, only: [band: 2]
  alias SymphonyElixir.{Config, ManagedResponsibility}

  @max_bytes 262_144

  @spec load(map(), non_neg_integer()) :: {:ok, map() | nil} | {:error, term()}
  def load(env, now_ms) do
    case Config.managed_delegation_config(env) do
      %{path: nil, sha256: nil, pool_key: nil, repository_ref: nil} -> {:ok, nil}
      %{path: nil, sha256: nil} -> {:error, :managed_delegation_manifest_required}
      config -> load_config(config, now_ms)
    end
  end

  defp load_config(%{path: path, sha256: digest} = config, now_ms)
       when is_binary(path) and is_binary(digest) do
    with true <- Path.type(path) == :absolute and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         :ok <- plain_ancestors(path),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.uid == 0 and band(stat.mode, 0o022) == 0 and stat.size <= @max_bytes,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @max_bytes,
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest,
         {:ok, payload} <- Jason.decode(bytes),
         {:ok, manifest} <- ManagedResponsibility.decode(payload, config, now_ms) do
      {:ok, Map.put(manifest, :source_sha256, digest)}
    else
      false -> {:error, :untrusted_managed_delegation_file}
      {:error, reason} -> {:error, {:managed_delegation_file, reason}}
    end
  end

  defp load_config(_config, _now_ms), do: {:error, :incomplete_managed_delegation_config}

  defp plain_ancestors(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type in [:regular, :directory] do
      parent = Path.dirname(path)
      if parent == path, do: :ok, else: plain_ancestors(parent)
    else
      false -> {:error, :managed_delegation_link}
      {:error, reason} -> {:error, reason}
    end
  end
end
