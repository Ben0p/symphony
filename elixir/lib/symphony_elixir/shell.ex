defmodule SymphonyElixir.Shell do
  @moduledoc false

  @spec bash_executable() :: String.t() | nil
  def bash_executable do
    case :os.type() do
      {:win32, _name} -> windows_bash_executable()
      _other -> System.find_executable("bash")
    end
  end

  @spec shim_executable() :: String.t() | nil
  def shim_executable do
    case :os.type() do
      {:win32, _name} -> bash_executable()
      _other -> System.find_executable("sh")
    end
  end

  defp windows_bash_executable do
    [System.find_executable("bash") | windows_bash_candidates()]
    |> Enum.map(&normalize_candidate/1)
    |> Enum.find(&usable_windows_bash?/1)
  end

  defp windows_bash_candidates do
    git_executable_candidates() ++
      env_candidates("ProgramFiles") ++
      env_candidates("ProgramFiles(x86)") ++
      env_candidates("LOCALAPPDATA")
  end

  defp git_executable_candidates do
    case System.find_executable("git") do
      nil ->
        []

      git_executable ->
        git_root = git_executable |> Path.expand() |> Path.dirname() |> Path.dirname()
        [Path.join(git_root, "bin/bash.exe"), Path.join(git_root, "usr/bin/bash.exe")]
    end
  end

  defp env_candidates(environment_variable) do
    case System.get_env(environment_variable) do
      value when is_binary(value) and value != "" ->
        git_root = Path.join(value, "Git")
        [Path.join(git_root, "bin/bash.exe"), Path.join(git_root, "usr/bin/bash.exe")]

      _other ->
        []
    end
  end

  defp normalize_candidate(nil), do: nil
  defp normalize_candidate(candidate), do: candidate |> Path.expand() |> String.replace("\\", "/")

  defp usable_windows_bash?(nil), do: false

  defp usable_windows_bash?(candidate) do
    lowered = String.downcase(candidate)

    File.regular?(candidate) and
      not String.ends_with?(lowered, "/windows/system32/bash.exe") and
      not String.ends_with?(lowered, "/windowsapps/bash.exe")
  end
end
