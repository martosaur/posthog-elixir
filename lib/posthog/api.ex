defmodule PostHog.API do
  @moduledoc false
  def batch(%__MODULE__.Client{} = client, batch) do
    client.module.request(client.client, :post, "/batch", json: %{batch: batch})
  end

  def flags(%__MODULE__.Client{} = client, event) do
    client.module.request(client.client, :post, "/flags", json: event, params: %{v: 2})
  end

  def local_evaluation_flags(%__MODULE__.Client{} = client, api_key, personal_api_key, timeout \\ 10_000) do
    params = %{token: api_key, send_cohorts: true}
    headers = [{"Authorization", "Bearer #{personal_api_key}"}]

    opts = [
      params: params,
      headers: headers,
      receive_timeout: timeout
    ]

    client.module.request(client.client, :get, "/api/feature_flag/local_evaluation/", opts)
  end
end
