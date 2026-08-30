defmodule SymphonyElixir.ExecutionFence do
  @moduledoc """
  Serializable coordination contract for issue execution ownership.

  The orchestrator currently keeps scheduling state in memory. This module keeps
  the generation, lease, and quiescence rules pure and serializable so a caller
  can persist the returned state atomically without giving this contract any
  Git, process, tracker, or cleanup side effects.

  A generation token is required for every worker, reviewer, mutation guard,
  and cleanup decision. Terminal fencing never releases leases implicitly;
  cleanup becomes admissible only after all known leases are released or
  expired and active-session ownership has been reconciled.
  """

  @schema_version 1
  @default_lease_ttl_ms 300_000
  @roles [:worker, :reviewer]
  @mutable_actions [:commit, :push, :state_mutation]

  @type token :: %{issue_id: String.t(), generation: pos_integer()}
  @type state :: %{
          schema_version: 1,
          executions: %{optional(String.t()) => map()},
          sessions: %{optional(String.t()) => map()},
          history: [map()]
        }

  @doc "Creates an empty, versioned execution-fence snapshot."
  @spec new() :: state()
  def new do
    %{schema_version: @schema_version, executions: %{}, sessions: %{}, history: []}
  end

  @doc "Returns a sanitized, deterministic projection for operator/API observability."
  @spec snapshot(state()) :: map() | {:error, :invalid_state}
  def snapshot(state) do
    case validate_state(state) do
      :ok ->
        %{
          schema_version: @schema_version,
          executions: state.executions |> Map.values() |> Enum.sort_by(&execution_sort_key/1) |> Enum.map(&sanitize_execution/1),
          sessions: state.sessions |> Map.values() |> Enum.sort_by(&session_sort_key/1) |> Enum.map(&sanitize_session/1),
          history: Enum.map(state.history, &sanitize_execution/1)
        }

      {:error, :invalid_state} = error ->
        error
    end
  end

  @doc "Admits one mutable generation for an issue and repository."
  @spec admit(state(), map(), non_neg_integer()) ::
          {:ok, state(), token()} | {:error, atom() | tuple()}
  def admit(state, attrs, now_ms) do
    with :ok <- validate_state(state),
         :ok <- validate_admission(attrs, now_ms),
         :ok <- admission_allowed(state, attrs) do
      issue_id = attrs.issue_id
      previous = Map.get(state.executions, issue_id)
      generation = if previous, do: previous.generation + 1, else: 1

      execution = %{
        issue_id: issue_id,
        repository: attrs.repository,
        generation: generation,
        branch: attrs.branch,
        worktree: attrs.worktree,
        status: :active,
        ownership: :reconciled,
        leases: %{},
        terminal: nil,
        cleanup: :pending,
        admitted_at_ms: now_ms
      }

      next_state =
        state
        |> archive_previous_execution(previous)
        |> remove_previous_sessions(previous)
        |> put_in([:executions, issue_id], execution)

      {:ok, next_state, token(issue_id, generation)}
    end
  end

  @doc "Registers or renews an explicitly identified worker or reviewer lease."
  @spec register(state(), token(), :worker | :reviewer, map(), non_neg_integer()) ::
          {:ok, state(), :registered | :already_registered} | {:error, term()}
  def register(state, token, role, attrs, now_ms) do
    with :ok <- validate_state(state),
         {:ok, execution} <- current_execution(state, token),
         :ok <- active_execution(execution),
         :ok <- validate_registration(role, attrs, now_ms),
         :ok <- session_available(state, token, attrs.session_id),
         :ok <- worker_available(execution, role, attrs.session_id) do
      session =
        Map.merge(
          %{
            issue_id: execution.issue_id,
            repository: execution.repository,
            generation: execution.generation,
            role: role,
            session_id: attrs.session_id,
            process_id: attrs.process_id,
            branch: attrs.branch,
            worktree: attrs.worktree,
            status: :active,
            registered_at_ms: now_ms
          },
          Map.take(attrs, [:linear_state, :pr_state, :head, :last_heartbeat_at])
        )

      registration_result(state, execution, session)
    end
  end

  @doc "Renews a live lease; terminal or stale generations cannot renew."
  @spec heartbeat(state(), token(), String.t(), non_neg_integer()) ::
          {:ok, state()} | {:error, term()}
  def heartbeat(state, token, session_id, now_ms)
      when is_binary(session_id) and is_integer(now_ms) and now_ms >= 0 do
    with :ok <- validate_state(state),
         {:ok, execution} <- current_execution(state, token),
         :ok <- active_execution(execution),
         %{status: :active} = lease <- Map.get(execution.leases, session_id) do
      updated_lease = Map.put(lease, :last_heartbeat_at, now_ms)
      {:ok, put_lease(state, execution, updated_lease)}
    else
      nil -> {:error, :unknown_session}
      {:error, _reason} = error -> error
      _ -> {:error, :unknown_session}
    end
  end

  def heartbeat(_state, _token, _session_id, _now_ms), do: {:error, :invalid_session}

  @doc "Releases one generation-bound lease. Releasing twice is harmless."
  @spec release(state(), token(), String.t(), atom()) ::
          {:ok, state(), :released | :already_released} | {:error, term()}
  def release(state, token, session_id, reason \\ :released)

  @spec release(state(), token(), String.t(), atom()) ::
          {:ok, state(), :released | :already_released} | {:error, term()}
  def release(state, token, session_id, reason)
      when is_binary(session_id) and is_atom(reason) do
    with :ok <- validate_state(state),
         {:ok, execution} <- current_execution(state, token),
         %{status: status} = lease when status in [:active, :released, :expired] <-
           Map.get(execution.leases, session_id) do
      if status == :active do
        updated_lease = lease |> Map.put(:status, :released) |> Map.put(:release_reason, reason)
        {:ok, put_lease(state, execution, updated_lease), :released}
      else
        {:ok, state, :already_released}
      end
    else
      nil -> {:ok, state, :already_released}
      {:error, _reason} = error -> error
      _ -> {:error, :unknown_session}
    end
  end

  def release(_state, _token, _session_id, _reason), do: {:error, :invalid_session}

  defp registration_result(state, execution, session) do
    case Map.get(state.sessions, session.session_id) do
      nil ->
        {:ok, put_lease(state, execution, session), :registered}

      existing ->
        refresh_registration(state, execution, existing, session)
    end
  end

  defp refresh_registration(state, execution, existing, session) do
    if same_registration?(existing, session) do
      updated = Map.merge(existing, Map.take(session, [:last_heartbeat_at, :linear_state, :pr_state, :head]))
      {:ok, put_lease(state, execution, updated), :already_registered}
    else
      {:error, :registration_conflict}
    end
  end

  @doc "Fences a generation on terminal tracker/merge observation."
  @spec fence(state(), token(), map(), non_neg_integer()) ::
          {:ok, state(), :fenced | :already_fenced} | {:error, term()}
  def fence(state, token, attrs, now_ms) do
    with :ok <- validate_state(state),
         {:ok, execution} <- current_execution(state, token),
         :ok <- validate_terminal(attrs, now_ms) do
      terminal = %{
        state: attrs.terminal_state,
        accepted_head: attrs.accepted_head,
        merge_identity: Map.get(attrs, :merge_identity),
        observed_at_ms: now_ms
      }

      fence_execution(state, execution, terminal)
    end
  end

  defp fence_execution(state, %{status: :active} = execution, terminal) do
    updated = %{execution | status: :terminal, terminal: terminal, cleanup: :pending}
    {:ok, put_execution(state, updated), :fenced}
  end

  defp fence_execution(state, %{status: :terminal, terminal: existing}, terminal) do
    if same_terminal?(existing, terminal) do
      {:ok, state, :already_fenced}
    else
      {:error, :terminal_conflict}
    end
  end

  @doc "Guards commit, push, and tracker-state mutations for one live generation."
  @spec authorize(state(), token(), atom()) :: {:ok, map()} | {:error, term()}
  def authorize(state, token, action) when action in @mutable_actions do
    with :ok <- validate_state(state),
         {:ok, execution} <- current_execution(state, token),
         :ok <- active_execution(execution),
         :ok <- reconciled_ownership(execution) do
      {:ok, %{issue_id: execution.issue_id, generation: execution.generation, action: action}}
    end
  end

  def authorize(_state, _token, _action), do: {:error, :unsupported_action}

  @doc """
  Approves generation-bound cleanup only after terminal fencing, quiescence,
  exact-head reconciliation, and released/expired leases.
  """
  @spec cleanup(state(), token(), String.t(), non_neg_integer()) ::
          {:ok, state(), :cleaned | :already_cleaned} | {:error, term()}
  def cleanup(state, token, expected_head, now_ms)
      when is_binary(expected_head) and is_integer(now_ms) and now_ms >= 0 do
    with :ok <- validate_state(state),
         {:ok, execution} <- current_execution(state, token) do
      cond do
        execution.cleanup == :cleaned ->
          {:ok, state, :already_cleaned}

        execution.status != :terminal ->
          {:error, :not_terminal}

        execution.ownership != :reconciled ->
          {:error, :ownership_unreconciled}

        active_lease_ids(execution) != [] ->
          {:error, {:leases_active, active_lease_ids(execution)}}

        execution.terminal.accepted_head != expected_head ->
          {:error, :head_diverged}

        true ->
          updated = execution |> Map.put(:cleanup, :cleaned) |> Map.put(:cleaned_at_ms, now_ms)
          {:ok, put_execution(state, updated), :cleaned}
      end
    end
  end

  @doc """
  Reconciles an explicit session snapshot. Unknown, contradictory, stale, or
  missing ownership blocks the affected execution; leases older than the
  supplied TTL are expired deterministically.
  """
  @spec reconcile_sessions(state(), [map()], non_neg_integer(), pos_integer()) ::
          {:ok, state(), map()} | {:error, term()}
  def reconcile_sessions(state, observations, now_ms, ttl_ms \\ @default_lease_ttl_ms)

  @spec reconcile_sessions(state(), [map()], non_neg_integer(), pos_integer()) ::
          {:ok, state(), map()} | {:error, term()}
  def reconcile_sessions(state, observations, now_ms, ttl_ms)
      when is_list(observations) and is_integer(now_ms) and now_ms >= 0 and
             is_integer(ttl_ms) and ttl_ms > 0 do
    with :ok <- validate_state(state),
         {:ok, observations} <- canonical_observations(observations) do
      initial = %{state | executions: reset_ownership(state.executions)}

      {reconciled_state, summary, seen} =
        Enum.reduce(observations, {initial, empty_summary(), MapSet.new()}, fn observation, {state_acc, summary_acc, seen_acc} ->
          reconcile_observation(state_acc, summary_acc, seen_acc, observation, now_ms, ttl_ms)
        end)

      {final_state, final_summary} =
        expire_or_block_missing_leases(reconciled_state, summary, seen, now_ms, ttl_ms)

      {:ok, final_state, finalize_summary(final_summary)}
    end
  end

  def reconcile_sessions(_state, _observations, _now_ms, _ttl_ms),
    do: {:error, :invalid_reconciliation_input}

  defp validate_state(%{schema_version: @schema_version, executions: executions, sessions: sessions, history: history})
       when is_map(executions) and is_map(sessions) and is_list(history) do
    if Enum.all?(executions, fn {issue_id, execution} -> valid_execution?(issue_id, execution) end) and
         Enum.all?(sessions, fn {session_id, session} -> valid_lease?(session_id, session) end) and
         valid_session_registry?(executions, sessions) and
         Enum.all?(history, &is_map/1) do
      :ok
    else
      {:error, :invalid_state}
    end
  end

  defp validate_state(_state), do: {:error, :invalid_state}

  defp valid_execution?(issue_id, execution) when is_binary(issue_id) and is_map(execution) do
    valid_execution_identity?(issue_id, execution) and
      valid_execution_status?(execution) and valid_execution_leases?(execution) and
      valid_terminal_consistency?(execution)
  end

  defp valid_execution?(_issue_id, _execution), do: false

  defp valid_session_registry?(executions, sessions) do
    Enum.all?(sessions, fn {session_id, session} ->
      case Map.get(executions, session.issue_id) do
        %{generation: generation, leases: leases} when generation == session.generation ->
          Map.get(leases, session_id) == session

        _ ->
          false
      end
    end)
  end

  defp valid_execution_identity?(issue_id, execution) do
    Map.get(execution, :issue_id) == issue_id and
      present_string?(Map.get(execution, :repository)) and
      positive_integer?(Map.get(execution, :generation)) and
      present_string?(Map.get(execution, :branch)) and
      present_string?(Map.get(execution, :worktree))
  end

  defp valid_execution_status?(execution) do
    valid_status_cleanup_pair?(Map.get(execution, :status), Map.get(execution, :cleanup)) and
      Map.get(execution, :ownership) in [:reconciled, :unknown, :contradictory]
  end

  defp valid_status_cleanup_pair?(:active, :pending), do: true
  defp valid_status_cleanup_pair?(:terminal, cleanup), do: cleanup in [:pending, :cleaned]
  defp valid_status_cleanup_pair?(_status, _cleanup), do: false

  defp valid_execution_leases?(execution) do
    leases = Map.get(execution, :leases)

    is_map(leases) and
      Enum.all?(leases, fn {session_id, lease} ->
        valid_lease?(session_id, lease) and
          lease.issue_id == execution.issue_id and
          lease.repository == execution.repository and
          lease.generation == execution.generation and
          lease.branch == execution.branch and
          lease.worktree == execution.worktree
      end)
  end

  defp valid_terminal_consistency?(%{status: :active, terminal: nil}), do: true

  defp valid_terminal_consistency?(%{status: :terminal, terminal: terminal}),
    do: is_map(terminal) and valid_terminal?(terminal)

  defp valid_terminal_consistency?(_execution), do: false

  defp valid_lease?(session_id, lease) when is_binary(session_id) and is_map(lease) do
    valid_lease_identity?(session_id, lease) and valid_lease_scope?(lease) and
      valid_lease_status?(lease) and valid_lease_clock?(lease)
  end

  defp valid_lease?(_session_id, _lease), do: false

  defp valid_lease_identity?(session_id, lease) do
    Map.get(lease, :session_id) == session_id and
      present_string?(Map.get(lease, :issue_id)) and
      present_string?(Map.get(lease, :process_id))
  end

  defp valid_lease_scope?(lease) do
    present_string?(Map.get(lease, :repository)) and
      positive_integer?(Map.get(lease, :generation)) and
      Map.get(lease, :role) in @roles and
      present_string?(Map.get(lease, :branch)) and
      present_string?(Map.get(lease, :worktree))
  end

  defp valid_lease_status?(lease) do
    Map.get(lease, :status) in [:active, :released, :expired] and
      present_string?(Map.get(lease, :linear_state)) and
      present_string?(Map.get(lease, :pr_state)) and
      present_string?(Map.get(lease, :head))
  end

  defp valid_lease_clock?(lease) do
    non_negative_integer?(Map.get(lease, :last_heartbeat_at)) and
      non_negative_integer?(Map.get(lease, :registered_at_ms))
  end

  defp valid_terminal?(nil), do: true

  defp valid_terminal?(terminal) when is_map(terminal) do
    present_string?(Map.get(terminal, :state)) and present_string?(Map.get(terminal, :accepted_head)) and
      optional_string?(Map.get(terminal, :merge_identity)) and
      is_integer(Map.get(terminal, :observed_at_ms)) and Map.get(terminal, :observed_at_ms) >= 0
  end

  defp valid_terminal?(_terminal), do: false

  defp execution_sort_key(execution), do: {execution.issue_id, execution.generation}

  defp session_sort_key(session), do: {session.issue_id, session.generation, session.session_id}

  defp sanitize_execution(execution) do
    execution
    |> Map.take([
      :issue_id,
      :repository,
      :generation,
      :branch,
      :worktree,
      :status,
      :ownership,
      :cleanup,
      :admitted_at_ms,
      :cleaned_at_ms
    ])
    |> Map.put(:terminal, sanitize_terminal(execution.terminal))
    |> Map.put(
      :sessions,
      execution.leases
      |> Map.values()
      |> Enum.sort_by(&session_sort_key/1)
      |> Enum.map(&sanitize_session/1)
    )
  end

  defp sanitize_terminal(nil), do: nil

  defp sanitize_terminal(terminal),
    do: Map.take(terminal, [:state, :accepted_head, :merge_identity, :observed_at_ms])

  defp sanitize_session(session) do
    Map.take(session, [
      :issue_id,
      :repository,
      :generation,
      :role,
      :session_id,
      :process_id,
      :branch,
      :worktree,
      :status,
      :registered_at_ms,
      :last_heartbeat_at,
      :linear_state,
      :pr_state,
      :head,
      :release_reason
    ])
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp validate_admission(attrs, now_ms) when is_map(attrs) and is_integer(now_ms) and now_ms >= 0 do
    required = [:issue_id, :repository, :branch, :worktree]

    if Enum.all?(required, &present_string?(Map.get(attrs, &1))) do
      :ok
    else
      {:error, :invalid_admission}
    end
  end

  defp validate_admission(_attrs, _now_ms), do: {:error, :invalid_admission}

  defp admission_allowed(state, attrs) do
    case Map.get(state.executions, attrs.issue_id) do
      %{status: :active} = execution ->
        if quiescent?(execution) do
          repository_execution_blocker(state.executions, attrs.repository)
        else
          {:error, :generation_active}
        end

      %{status: :terminal, cleanup: cleanup} when cleanup != :cleaned ->
        {:error, :execution_not_quiescent}

      _ ->
        repository_execution_blocker(state.executions, attrs.repository)
    end
  end

  defp repository_execution_blocker(executions, repository) do
    Enum.find_value(executions, :ok, fn {issue_id, execution} ->
      if execution.repository == repository and not quiescent?(execution) do
        {:error, {:repository_not_quiescent, issue_id}}
      end
    end)
  end

  defp quiescent?(execution) do
    execution.ownership == :reconciled and active_lease_ids(execution) == [] and
      (execution.status == :active or
         (execution.status == :terminal and execution.cleanup == :cleaned))
  end

  defp archive_previous_execution(state, nil), do: state

  defp archive_previous_execution(state, previous) do
    %{state | history: [previous | state.history]}
  end

  defp remove_previous_sessions(state, nil), do: state

  defp remove_previous_sessions(state, previous) do
    %{state | sessions: Map.drop(state.sessions, Map.keys(previous.leases))}
  end

  defp current_execution(state, %{issue_id: issue_id, generation: generation})
       when is_binary(issue_id) and is_integer(generation) and generation > 0 do
    case Map.get(state.executions, issue_id) do
      nil ->
        {:error, :unknown_execution}

      %{generation: ^generation} = execution ->
        {:ok, execution}

      _execution ->
        {:error, :stale_generation}
    end
  end

  defp current_execution(_state, _token), do: {:error, :invalid_generation_token}

  defp active_execution(%{status: :active}), do: :ok
  defp active_execution(%{status: :terminal}), do: {:error, :terminal_fenced}
  defp active_execution(_execution), do: {:error, :invalid_execution}

  defp reconciled_ownership(%{ownership: :reconciled}), do: :ok
  defp reconciled_ownership(_execution), do: {:error, :ownership_unreconciled}

  defp validate_registration(role, attrs, now_ms)
       when role in @roles and is_map(attrs) and is_integer(now_ms) and now_ms >= 0 do
    required = [
      :session_id,
      :process_id,
      :branch,
      :worktree,
      :linear_state,
      :pr_state,
      :head,
      :last_heartbeat_at
    ]

    if Enum.all?(required, &present_registration_field?(Map.get(attrs, &1))) and
         is_integer(attrs.last_heartbeat_at) and attrs.last_heartbeat_at >= 0 and
         attrs.last_heartbeat_at <= now_ms do
      :ok
    else
      {:error, :invalid_registration}
    end
  end

  defp validate_registration(_role, _attrs, _now_ms), do: {:error, :invalid_registration}

  defp present_registration_field?(value) when is_integer(value), do: value >= 0
  defp present_registration_field?(value), do: present_string?(value)

  defp session_available(state, token, session_id) do
    case Map.get(state.sessions, session_id) do
      nil ->
        :ok

      %{issue_id: issue_id, generation: generation}
      when issue_id == token.issue_id and generation == token.generation ->
        :ok

      _ ->
        {:error, :session_owned_elsewhere}
    end
  end

  defp worker_available(execution, :worker, session_id) do
    case Enum.find(execution.leases, fn {id, lease} -> id != session_id and lease.role == :worker and lease.status == :active end) do
      nil -> :ok
      _ -> {:error, :worker_already_registered}
    end
  end

  defp worker_available(_execution, :reviewer, _session_id), do: :ok

  defp same_registration?(left, right) do
    Map.take(left, [:issue_id, :repository, :generation, :role, :session_id, :process_id, :branch, :worktree]) ==
      Map.take(right, [:issue_id, :repository, :generation, :role, :session_id, :process_id, :branch, :worktree])
  end

  defp put_lease(state, execution, lease) do
    execution = %{execution | leases: Map.put(execution.leases, lease.session_id, lease)}

    state
    |> put_execution(execution)
    |> put_in([:sessions, lease.session_id], lease)
  end

  defp put_execution(state, execution), do: put_in(state, [:executions, execution.issue_id], execution)

  defp validate_terminal(attrs, now_ms) when is_map(attrs) and is_integer(now_ms) and now_ms >= 0 do
    if present_string?(Map.get(attrs, :terminal_state)) and present_string?(Map.get(attrs, :accepted_head)) and
         optional_string?(Map.get(attrs, :merge_identity)) do
      :ok
    else
      {:error, :invalid_terminal_observation}
    end
  end

  defp validate_terminal(_attrs, _now_ms), do: {:error, :invalid_terminal_observation}

  defp same_terminal?(left, right) do
    Map.take(left, [:state, :accepted_head, :merge_identity]) ==
      Map.take(right, [:state, :accepted_head, :merge_identity])
  end

  defp canonical_observations(observations) do
    observations
    |> Enum.reduce_while({:ok, %{}}, &canonical_observation_step/2)
    |> case do
      {:ok, observations_by_key} ->
        {:ok, observations_by_key |> Map.values() |> Enum.sort_by(&observation_sort_key/1)}

      error ->
        error
    end
  end

  defp canonical_observation_step(observation, {:ok, seen}) do
    case validate_observation(observation) do
      :ok -> put_canonical_observation(seen, observation)
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp put_canonical_observation(seen, observation) do
    key = {observation.issue_id, observation.generation, observation.session_id}

    case Map.get(seen, key) do
      nil -> {:cont, {:ok, Map.put(seen, key, observation)}}
      ^observation -> {:cont, {:ok, seen}}
      _other -> {:halt, {:error, {:contradictory_observation, observation.session_id}}}
    end
  end

  defp validate_observation(observation) when is_map(observation) do
    required = [
      :issue_id,
      :repository,
      :generation,
      :session_id,
      :process_id,
      :branch,
      :worktree,
      :last_heartbeat_at,
      :linear_state,
      :pr_state,
      :head
    ]

    if Enum.all?(required, &present_observation_field?(Map.get(observation, &1))) and
         observation.role in @roles and is_integer(observation.generation) and observation.generation > 0 do
      :ok
    else
      {:error, :invalid_session_observation}
    end
  end

  defp validate_observation(_observation), do: {:error, :invalid_session_observation}

  defp present_observation_field?(value) when is_integer(value), do: value >= 0
  defp present_observation_field?(value), do: present_string?(value)

  defp observation_sort_key(observation), do: {observation.issue_id, observation.generation, observation.session_id}

  defp reset_ownership(executions) do
    Map.new(executions, fn {issue_id, execution} -> {issue_id, %{execution | ownership: :reconciled}} end)
  end

  defp empty_summary do
    %{unknown: [], contradictory: [], expired: [], stale: []}
  end

  defp reconcile_observation(state, summary, seen, observation, now_ms, ttl_ms) do
    case Map.get(state.executions, observation.issue_id) do
      nil ->
        {state, add_reason(summary, :unknown, observation.session_id), seen}

      execution when execution.generation != observation.generation ->
        contradictory_generation(state, summary, seen, execution, observation)

      execution ->
        reconcile_known_observation(state, summary, seen, execution, observation, now_ms, ttl_ms)
    end
  end

  defp contradictory_generation(state, summary, seen, execution, observation) do
    blocked_state = mark_ownership(state, execution.issue_id, :contradictory)
    blocked_summary = add_reason(summary, :contradictory, observation.session_id)
    {blocked_state, blocked_summary, seen}
  end

  defp reconcile_known_observation(state, summary, seen, execution, observation, now_ms, ttl_ms) do
    case reconcile_observation_precondition(execution, observation, state, summary, seen, now_ms) do
      {:blocked, next} ->
        next

      :continue ->
        lease = execution.leases[observation.session_id]
        reconcile_known_lease(state, summary, seen, execution, observation, lease, now_ms, ttl_ms)
    end
  end

  defp reconcile_observation_precondition(execution, observation, state, summary, seen, now_ms) do
    cond do
      not matching_scope?(execution, observation) ->
        {:blocked, contradictory_observation(state, summary, seen, execution, observation)}

      execution.status == :terminal and observation.linear_state != execution.terminal.state ->
        {:blocked, contradictory_observation(state, summary, seen, execution, observation)}

      observation.last_heartbeat_at > now_ms ->
        {:blocked, contradictory_observation(state, summary, seen, execution, observation)}

      is_nil(Map.get(execution.leases, observation.session_id)) ->
        {:blocked, unknown_observation(state, summary, seen, execution, observation)}

      true ->
        :continue
    end
  end

  defp contradictory_observation(state, summary, seen, execution, observation) do
    blocked_state = mark_ownership(state, execution.issue_id, :contradictory)
    blocked_summary = add_reason(summary, :contradictory, observation.session_id)
    {blocked_state, blocked_summary, mark_seen(seen, execution, observation)}
  end

  defp unknown_observation(state, summary, seen, execution, observation) do
    unknown_state = mark_ownership(state, execution.issue_id, :unknown)
    unknown_summary = add_reason(summary, :unknown, observation.session_id)
    {unknown_state, unknown_summary, seen}
  end

  defp reconcile_known_lease(state, summary, seen, execution, observation, lease, now_ms, ttl_ms) do
    cond do
      lease.status != :active or not same_registration?(lease, observation) ->
        contradictory_observation(state, summary, seen, execution, observation)

      now_ms - max(lease.last_heartbeat_at, observation.last_heartbeat_at) >= ttl_ms ->
        expire_observed_lease(state, summary, seen, execution, observation)

      now_ms - observation.last_heartbeat_at >= ttl_ms ->
        stale_observed_lease(state, summary, seen, execution, observation)

      true ->
        refreshed =
          Map.merge(lease, Map.take(observation, [:last_heartbeat_at, :linear_state, :pr_state, :head]))

        {put_lease(state, execution, refreshed), summary, mark_seen(seen, execution, observation)}
    end
  end

  defp expire_observed_lease(state, summary, seen, execution, observation) do
    expired_state = expire_lease(state, execution, observation.session_id)
    expired_summary = add_reason(summary, :expired, observation.session_id)
    {expired_state, expired_summary, seen}
  end

  defp stale_observed_lease(state, summary, seen, execution, observation) do
    stale_state = mark_ownership(state, execution.issue_id, :unknown)
    stale_summary = add_reason(summary, :stale, observation.session_id)
    {stale_state, stale_summary, mark_seen(seen, execution, observation)}
  end

  defp matching_scope?(execution, observation) do
    execution.repository == observation.repository and execution.branch == observation.branch and
      execution.worktree == observation.worktree
  end

  defp mark_seen(seen, execution, observation) do
    MapSet.put(seen, {execution.issue_id, execution.generation, observation.session_id})
  end

  defp expire_or_block_missing_leases(state, summary, seen, now_ms, ttl_ms) do
    Enum.reduce(state.executions, {state, summary}, fn {issue_id, execution}, accumulator ->
      Enum.reduce(execution.leases, accumulator, fn {session_id, lease}, inner ->
        reconcile_missing_lease(inner, issue_id, execution, session_id, lease, seen, now_ms, ttl_ms)
      end)
    end)
  end

  defp reconcile_missing_lease({state, summary}, issue_id, execution, session_id, lease, seen, now_ms, ttl_ms) do
    key = {issue_id, execution.generation, session_id}

    cond do
      lease.status != :active or MapSet.member?(seen, key) ->
        {state, summary}

      now_ms - lease.last_heartbeat_at >= ttl_ms ->
        expired_state = expire_lease(state, execution, session_id)
        {expired_state, add_reason(summary, :expired, session_id)}

      true ->
        unknown_state = mark_ownership(state, issue_id, :unknown)
        {unknown_state, add_reason(summary, :unknown, session_id)}
    end
  end

  defp expire_lease(state, execution, session_id) do
    state
    |> put_in([:executions, execution.issue_id, :leases, session_id, :status], :expired)
    |> put_in([:sessions, session_id, :status], :expired)
  end

  defp mark_ownership(state, issue_id, :contradictory), do: put_in(state, [:executions, issue_id, :ownership], :contradictory)

  defp mark_ownership(state, issue_id, :unknown) do
    if get_in(state, [:executions, issue_id, :ownership]) == :contradictory do
      state
    else
      put_in(state, [:executions, issue_id, :ownership], :unknown)
    end
  end

  defp add_reason(summary, key, value) do
    update_in(summary, [key], fn values -> Enum.uniq([value | values]) end)
  end

  defp finalize_summary(summary) do
    summary = Map.new(summary, fn {key, values} -> {key, Enum.sort(values)} end)

    status =
      if summary.unknown == [] and summary.contradictory == [] and summary.stale == [],
        do: :reconciled,
        else: :blocked

    Map.put(summary, :status, status)
  end

  defp active_lease_ids(execution) do
    execution.leases
    |> Enum.filter(fn {_session_id, lease} -> lease.status == :active end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp token(issue_id, generation), do: %{issue_id: issue_id, generation: generation}

  defp present_string?(value) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed != "" and byte_size(trimmed) <= 512 and not String.contains?(trimmed, ["\n", "\r", <<0>>])
  end

  defp present_string?(_value), do: false

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: present_string?(value)
end
