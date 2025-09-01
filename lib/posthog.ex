defmodule PostHog do
  @typedoc "Name under which an instance of PostHog supervision tree is registered."
  @type supervisor_name() :: atom()

  @typedoc "Event name, such as `\"user_signed_up\"` or `\"$create_alias\"`"
  @type event() :: String.t()

  @typedoc "string representing distinct ID"
  @type distinct_id() :: String.t()

  @typedoc """
  Map representing event properties.

  Note that it __must__ be JSON-serializable.
  """
  @type properties() :: %{optional(String.t()) => any(), optional(atom()) => any()}

  @doc """
  Returns the configuration map for a named `PostHog` supervisor.

  ## Examples

  Retrieve the default `PostHog` instance config:

      %{supervisor_name: PostHog} = PostHog.config()
      
  Retrieve named instance config:

      %{supervisor_name: MyPostHog} = PostHog.config(MyPostHog)
  """
  @spec config(supervisor_name()) :: PostHog.Config.config()
  def config(name \\ __MODULE__), do: PostHog.Registry.config(name)

  @doc false
  def bare_capture(event, distinct_id, %{} = properties),
    do: bare_capture(__MODULE__, event, distinct_id, properties)

  @doc """
  Captures a single event without retrieving properties from context.

  Capture is a relatively lightweight operation. The event is prepared
  synchronously and then sent to PostHog workers to be batched together with
  other events and sent over the wire.

  ## Examples

  Capture a simple event:

      PostHog.bare_capture("event_captured", "user123")
      
  Capture an event with properties:

      PostHog.bare_capture("event_captured", "user123", %{backend: "Phoenix"})
      
  Capture through a named PostHog instance:

      PostHog.bare_capture(MyPostHog, "event_captured", "user123")
  """
  @spec bare_capture(supervisor_name(), event(), distinct_id(), properties()) :: :ok
  def bare_capture(name \\ __MODULE__, event, distinct_id, properties \\ %{}) do
    config = PostHog.Registry.config(name)
    properties = Map.merge(properties, config.global_properties)

    event = %{
      event: event,
      distinct_id: distinct_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      properties: properties
    }

    PostHog.Sender.send(event, name)
  end

  @doc false
  def capture(event, %{} = properties),
    do: capture(__MODULE__, event, properties)

  @doc """
  Captures a single event.

  Any context previously set will be included in the event properties. Note that
  `distinct_id` is still required.

  ## Examples

  Set context and capture an event:

      PostHog.set_context(%{distinct_id: "user123", "$feature/my-feature-flag": true})
      PostHog.capture("job_started", %{job_name: "JobName"})
      
  Set context and capture an event through a named PostHog instance:

      PostHog.set_context(MyPostHog, %{distinct_id: "user123", "$feature/my-feature-flag": true})
      PostHog.capture(MyPostHog, "job_started", %{job_name: "JobName"})
  """
  @spec capture(supervisor_name(), event(), properties()) :: :ok | {:error, :missing_distinct_id}
  def capture(name \\ __MODULE__, event, properties \\ %{}) do
    context =
      name
      |> get_event_context(event)
      |> Map.merge(properties)

    case Map.pop(context, :distinct_id) do
      {nil, _} -> {:error, :missing_distinct_id}
      {distinct_id, properties} -> bare_capture(name, event, distinct_id, properties)
    end
  end

  @doc """
  Make request to [`/flags`](https://posthog.com/docs/api/flags) API.

  This function is a thin wrapper over a client call and is useful as a building
  block to build your own `check_feature_flag/3`. For example, this is a preferred
  way to access remote config payload.

  ## Examples

  Make request to `/flags` API:

      PostHog.flags(%{distinct_id: "user123"})
      
  Make request to `/flags` API with additional body params:

      PostHog.flags(%{distinct_id: "my_distinct_id", groups: %{group_type: "group_id"}})
      
  Make request to `/flags` API through a named PostHog instance:

      PostHog.flags(MyPostHog, %{distinct_id: "user123"})
  """
  @spec flags(supervisor_name(), map()) ::
          PostHog.API.Client.response() | {:error, PostHog.Error.t()}
  def flags(name \\ __MODULE__, body) do
    config = config(name)

    case PostHog.API.flags(config.api_client, body) do
      {:ok, %{status: 200, body: %{"flags" => _}}} = resp ->
        resp

      {:ok, %{status: 200, body: body}} ->
        {:error,
         %PostHog.UnexpectedResponseError{
           response: body,
           message: "Expected response body to have \"flags\" key"
         }}

      {:ok, resp} ->
        {:error, %PostHog.UnexpectedResponseError{response: resp, message: "Unexpected response"}}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def get_all_feature_flags(distinct_id_or_body) when not is_atom(distinct_id_or_body),
    do: get_all_feature_flags(__MODULE__, distinct_id_or_body)

  @doc """
  Get all feature flags.

  Accepts an optional `distinct_id` or a map with request body. If neither is
  passed, attempts to read `distinct_id` from the context.

  ## Examples

  Get all feature flags:

      PostHog.get_all_feature_flags("user123")
      
  Get all feature flags with full request body:

      PostHog.get_all_feature_flags(%{distinct_id: "user123", group: %{group_type: "group_id"}})
      
  Get all feature flags for `distinct_id` from the context:

      PostHog.set_context(%{distinct_id: "user123"})
      PostHog.get_all_feature_flags()
      
  Get all feature flags through a named PostHog instance:

      PostHog.get_all_feature_flags(MyPostHog, "foo")
  """
  @spec get_all_feature_flags(supervisor_name(), distinct_id() | map() | nil) ::
          {:ok, map()} | {:error, Exception.t()}
  def get_all_feature_flags(name \\ __MODULE__, distinct_id_or_body \\ nil) do
    with {:ok, body} <- body_for_flags(distinct_id_or_body),
         {:ok, %{body: %{"flags" => flags}}} <- flags(name, body) do
      {:ok, flags}
    end
  end

  @doc false
  def check_feature_flag(flag_name, distinct_id_or_body) when not is_atom(flag_name),
    do: check_feature_flag(__MODULE__, flag_name, distinct_id_or_body)

  @doc """
  Checks feature flag

  If there is a variant assigned, returns `{:ok, variant}`. Otherwise, `{:ok,
  true}` or `{:ok, false}`.

  Accepts an optional `distinct_id` or a map with request body. If neither is
  passed, attempts to read `distinct_id` from the context.

  This function will also
  [send](https://posthog.com/docs/api/flags#step-3-send-a-feature_flag_called-event)
  `$feature_flag_called` event and
  [set](https://posthog.com/docs/api/flags#step-2-include-feature-flag-information-when-capturing-events)
  `$feature/feature-flag-name` property in context. 

  ## Examples

  Check boolean feature flag for `distinct_id`:

      iex> PostHog.check_feature_flag("example-feature-flag-1", "user123")
      {:ok, true}
      
  Check multivariant feature flag for `distinct_id` in the current context:

      iex> PostHog.set_context(%{distinct_id: "user123"})
      iex> PostHog.check_feature_flag("example-feature-flag-1")
      {:ok, "variant1"}
      
  Check boolean feature flag through a named PostHog instance:

      PostHog.check_feature_flag(MyPostHog, "example-feature-flag-1", "user123")
  """
  @spec check_feature_flag(supervisor_name(), String.t(), distinct_id() | map() | nil) ::
          {:ok, boolean()} | {:ok, String.t()} | {:error, Exception.t()}
  def check_feature_flag(name \\ __MODULE__, flag_name, distinct_id_or_body \\ nil) do
    with {:ok, %{distinct_id: distinct_id} = body} <- body_for_flags(distinct_id_or_body),
         {:ok, %{body: body}} <- flags(name, body) do
      result =
        case body do
          %{"flags" => %{^flag_name => %{"variant" => variant}}} when not is_nil(variant) ->
            {:ok, variant}

          %{"flags" => %{^flag_name => %{"enabled" => true}}} ->
            {:ok, true}

          %{"flags" => %{^flag_name => _}} ->
            {:ok, false}

          %{"flags" => _} ->
            {:error,
             %PostHog.UnexpectedResponseError{
               response: body,
               message: "Feature flag #{flag_name} was not found in the response"
             }}
        end

      with {:ok, variant} <- result do
        PostHog.capture(name, "$feature_flag_called", %{
          distinct_id: distinct_id,
          "$feature_flag": flag_name,
          "$feature_flag_response": variant
        })

        PostHog.set_context(name, %{"$feature/#{flag_name}" => variant})
      end

      result
    end
  end

  defp body_for_flags(distinct_id_or_body) do
    case distinct_id_or_body do
      %{distinct_id: _distinct_id} = body ->
        {:ok, body}

      nil ->
        case PostHog.get_context() do
          %{distinct_id: distinct_id} ->
            {:ok, %{distinct_id: distinct_id}}

          _context ->
            {:error,
             %PostHog.Error{
               message:
                 "distinct_id is required but wasn't explicitely provided or found in the context"
             }}
        end

      distinct_id when is_binary(distinct_id) ->
        {:ok, %{distinct_id: distinct_id}}
    end
  end

  @doc """
  Sets context for the current process.

  ## Examples

  Set and retrieve context for the current process:

      > PostHog.set_context(%{foo: "bar"})
      > PostHog.get_context()
      %{foo: "bar"}

  Set and retrieve context for a named PostHog instance:

      > PostHog.set_context(MyPostHog, %{foo: "bar"})
      > PostHog.get_context(MyPostHog)
      %{foo: "bar"}
  """
  @spec set_context(supervisor_name(), properties()) :: :ok
  defdelegate set_context(name \\ __MODULE__, context), to: PostHog.Context, as: :set

  @doc """
  Sets context for the current process scoped to a specific event.

  ## Examples

  Set and retrieve context scoped to an event:

      > PostHog.set_event_context("$exception", %{foo: "bar"})
      > PostHog.get_event_context("$exception")
      %{foo: "bar"}
     
  Set and retrieve context for a specific event through a named PostHog instance:

      > PostHog.set_event_context(MyPostHog, "$exception", %{foo: "bar"})
      > PostHog.get_event_context(MyPostHog, "$exception")
      %{foo: "bar"}
  """
  @spec set_event_context(supervisor_name(), event(), properties()) :: :ok
  def set_event_context(name \\ __MODULE__, event, context),
    do: PostHog.Context.set(name, event, context)

  @doc """
  Retrieves context for the current process.

  ## Examples

  Set and retrieve context for current process:

      > PostHog.set_context(%{foo: "bar"})
      > PostHog.get_context()
      %{foo: "bar"}
      
  Set and retrieve context for a named PostHog instance:

      > PostHog.set_context(MyPostHog, %{foo: "bar"})
      > PostHog.get_context(MyPostHog)
      %{foo: "bar"}
  """
  @spec get_context(supervisor_name()) :: properties()
  defdelegate get_context(name \\ __MODULE__), to: PostHog.Context, as: :get

  @doc """
  Retrieves context for the current process scoped to a specific event.

  ## Examples

  Set and retrieve context scoped to an event:

      > PostHog.set_event_context("$exception", %{foo: "bar"})
      > PostHog.get_event_context("$exception")
      %{foo: "bar"}
     
  Set and retrieve context for a specific event through a named PostHog instance:

      > PostHog.set_event_context(MyPostHog, "$exception", %{foo: "bar"})
      > PostHog.get_event_context(MyPostHog, "$exception")
      %{foo: "bar"}
  """
  @spec get_event_context(supervisor_name()) :: properties()
  def get_event_context(name \\ __MODULE__, event), do: PostHog.Context.get(name, event)
end
