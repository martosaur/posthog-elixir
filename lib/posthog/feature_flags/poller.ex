defmodule PostHog.FeatureFlags.Poller do
  @moduledoc """
  GenServer for polling feature flag definitions from PostHog API for local evaluation.

  This module is responsible for:
  - Periodically fetching feature flag definitions from the PostHog API
  - Storing the definitions locally for fast access
  - Managing the polling lifecycle based on configuration
  """

  use GenServer
  require Logger

  alias PostHog.Config

  @typedoc "State of the feature flags poller"
  @type state() :: %{
          config: Config.config(),
          timer_ref: reference() | nil,
          feature_flags: list(map()),
          group_type_mapping: map(),
          cohorts: map(),
          last_updated: DateTime.t() | nil
        }

  @doc """
  Start the feature flags poller.
  """
  @spec start_link(Config.config()) :: GenServer.on_start()
  def start_link(config) do
    name = :"#{config.supervisor_name}.FeatureFlags.Poller"
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @doc """
  Get the current feature flag definitions.
  """
  @spec get_feature_flags(Config.config()) :: %{
          feature_flags: list(map()),
          group_type_mapping: map(),
          cohorts: map(),
          last_updated: DateTime.t() | nil
        }
  def get_feature_flags(config) do
    name = :"#{config.supervisor_name}.FeatureFlags.Poller"
    GenServer.call(name, :get_feature_flags)
  end

  @doc """
  Force a refresh of feature flag definitions.
  """
  @spec refresh_feature_flags(Config.config()) :: :ok
  def refresh_feature_flags(config) do
    name = :"#{config.supervisor_name}.FeatureFlags.Poller"
    GenServer.cast(name, :refresh)
  end

  @doc """
  Check if local evaluation is enabled and ready.
  """
  @spec local_evaluation_enabled?(Config.config()) :: boolean()
  def local_evaluation_enabled?(config) do
    config.enable_local_evaluation && not is_nil(config.personal_api_key)
  end

  ## GenServer Callbacks

  @impl GenServer
  def init(config) do
    state = %{
      config: config,
      timer_ref: nil,
      feature_flags: [],
      group_type_mapping: %{},
      cohorts: %{},
      last_updated: nil
    }

    if local_evaluation_enabled?(config) do
      # Start polling immediately and then schedule periodic updates
      send(self(), :poll)
      {:ok, state}
    else
      Logger.info("[PostHog.FeatureFlags.Poller] Local evaluation disabled - personal_api_key not configured")
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_call(:get_feature_flags, _from, state) do
    result = %{
      feature_flags: state.feature_flags,
      group_type_mapping: state.group_type_mapping,
      cohorts: state.cohorts,
      last_updated: state.last_updated
    }

    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast(:refresh, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    if local_evaluation_enabled?(state.config) do
      new_state = poll_feature_flags(state)
      schedule_next_poll(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # Matches only when timer_ref and the state's timer_ref are the same
  @impl GenServer
  def handle_info({:timeout, timer_ref, :poll}, %{timer_ref: timer_ref} = state) do
    send(self(), :poll)
    {:noreply, %{state | timer_ref: nil}}
  end


  # Ignore old timer messages when timer_ref is not the same
  @impl GenServer
  def handle_info({:timeout, _old_timer_ref, :poll}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{timer_ref: timer_ref}) when not is_nil(timer_ref) do
    :erlang.cancel_timer(timer_ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Private Functions

  @spec schedule_next_poll(state()) :: state()
  defp schedule_next_poll(state) do
    # Cancel existing timer if any
    if state.timer_ref do
      :erlang.cancel_timer(state.timer_ref)
    end

    # Schedule next poll
    timer_ref = :erlang.start_timer(state.config.feature_flags_poll_interval, self(), :poll)
    %{state | timer_ref: timer_ref}
  end

  @spec poll_feature_flags(state()) :: state()
  defp poll_feature_flags(state) do
    config = state.config

    case fetch_feature_flags(config) do
      {:ok, response} ->
        Logger.debug("[PostHog.FeatureFlags.Poller] Successfully fetched feature flags")

        %{
          state
          | feature_flags: response["flags"] || [],
            group_type_mapping: response["group_type_mapping"] || %{},
            cohorts: response["cohorts"] || %{},
            last_updated: DateTime.utc_now()
        }

      {:error, reason} ->
        Logger.warning("[PostHog.FeatureFlags.Poller] Failed to fetch feature flags: #{inspect(reason)}")
        state
    end
  end

  @spec fetch_feature_flags(Config.config()) :: {:ok, map()} | {:error, any()}
  defp fetch_feature_flags(config) do
    case PostHog.API.local_evaluation_flags(
           config.api_client,
           config.api_key,
           config.personal_api_key,
           config.feature_flags_request_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 402}} ->
        Logger.warning("[PostHog.FeatureFlags.Poller] Feature flags quota limited")
        {:error, :quota_limited}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_response, %{status: status, body: body}}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
