defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor
  require Logger
  alias SymphonyElixir.WorkPackageRuntime

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)

    orchestrator_opts = [name: orchestrator_name, task_supervisor: task_supervisor_name]

    orchestrator_opts =
      case WorkPackageRuntime.configuration() do
        :disabled ->
          if WorkPackageRuntime.managed_pool?() do
            Logger.error("Managed Symphony pool requires the complete work-package runtime configuration")
            raise ArgumentError, "managed Symphony pool work-package runtime is not configured"
          else
            orchestrator_opts
          end

        {:ok, runtime} ->
          Keyword.merge(orchestrator_opts, execution_supervisor: :systemd_user, work_package_runtime: runtime)

        {:error, reason} ->
          Logger.error("Managed work-package runtime configuration is incomplete: #{inspect(reason)}")
          raise ArgumentError, "invalid managed work-package runtime configuration: #{inspect(reason)}"
      end

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor_name},
        id: task_supervisor_name
      ),
      Supervisor.child_spec(
        {SymphonyElixir.Orchestrator, orchestrator_opts},
        id: orchestrator_name
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
