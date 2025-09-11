# Feature Flags Local Evaluation

PostHog Elixir SDK supports local evaluation of feature flags, which allows you to evaluate feature flags locally without making API calls to PostHog servers for every flag check. This significantly improves performance and reduces latency.

## How It Works

Local evaluation works by:

1. **Polling**: The SDK periodically fetches feature flag definitions from PostHog and stores them locally
2. **Local Evaluation**: When checking a feature flag, the SDK evaluates it locally using the cached definitions
3. **Fallback**: If local evaluation fails or is disabled, the SDK falls back to remote evaluation

## Configuration

To enable local evaluation, you need to configure the following options in your PostHog configuration:

```elixir
config :posthog,
  api_key: "phc_your_project_api_key",
  public_url: "https://us.i.posthog.com", # or "https://eu.i.posthog.com" for EU
  personal_api_key: "phx_your_personal_api_key", # Required for local evaluation
  enable_local_evaluation: true, # Default: true
  feature_flags_poll_interval: 30_000, # Poll every 30 seconds (default)
  feature_flags_request_timeout: 10_000 # Request timeout in ms (default)
```

### Configuration Options

- **`personal_api_key`**: Your PostHog Personal API key (required for local evaluation)
- **`enable_local_evaluation`**: Whether to enable local evaluation (default: `true`)
- **`feature_flags_poll_interval`**: How often to poll for feature flag updates in milliseconds (default: `30_000`)
- **`feature_flags_request_timeout`**: Timeout for feature flag API requests in milliseconds (default: `10_000`)

## Usage

### Basic Feature Flag Check

```elixir
# This will use local evaluation if available, otherwise fall back to remote
{:ok, result} = PostHog.FeatureFlags.check("my-feature-flag", "user123")
```

### Force Local Evaluation Only

```elixir
# This will only use local evaluation and return an error if it fails
{:ok, result} = PostHog.FeatureFlags.check("my-feature-flag", %{
  distinct_id: "user123",
  person_properties: %{"country" => "US", "plan" => "premium"},
  only_evaluate_locally: true
})
```

### Get All Feature Flags

```elixir
# Get all feature flags for a user (with local evaluation if available)
{:ok, all_flags} = PostHog.FeatureFlags.flags_for("user123")

# Force local evaluation for all flags
{:ok, all_flags} = PostHog.FeatureFlags.flags_for(%{
  distinct_id: "user123",
  person_properties: %{"country" => "US"},
  only_evaluate_locally: true
})
```

### Advanced Usage with Person Properties

Local evaluation supports person properties for more accurate flag evaluation:

```elixir
{:ok, result} = PostHog.FeatureFlags.check("geo-specific-feature", %{
  distinct_id: "user123",
  person_properties: %{
    "country" => "US",
    "city" => "San Francisco",
    "plan_type" => "enterprise",
    "signup_date" => "2023-01-15"
  }
})
```

## Benefits

1. **Performance**: No network calls for flag evaluation
2. **Reliability**: Works even if PostHog servers are temporarily unavailable
3. **Lower Latency**: Instant flag evaluation without network round-trips
4. **Reduced Load**: Less load on PostHog servers

## Limitations

1. **Personal API Key Required**: You need a Personal API key for local evaluation to work
2. **Eventually Consistent**: Local flags are updated periodically, so there might be a delay for flag changes
3. **Memory Usage**: Feature flag definitions are stored in memory
4. **Limited Operators**: Some advanced feature flag operators might not be supported in local evaluation

## Monitoring

The SDK logs information about local evaluation:

- When local evaluation is disabled due to missing Personal API key
- When feature flag polling fails
- When feature flags are successfully updated

You can monitor the health of local evaluation by checking the logs for these messages.

## Fallback Behavior

The SDK automatically falls back to remote evaluation in these cases:

1. Local evaluation is disabled
2. Personal API key is not configured
3. Feature flag definitions haven't been loaded yet
4. Local evaluation fails for a specific flag (unless `only_evaluate_locally` is set)

This ensures that your application continues to work even if local evaluation encounters issues.
