defmodule PostHog.Error do
  @moduledoc """
  PostHog error
  """

  @type t() :: %__MODULE__{message: String.t()}

  defexception [:message]
end

defmodule PostHog.UnexpectedResponseError do
  @moduledoc """
  PostHog error that includes a reponse from the API, either full or partial.
  """
  @type t() :: %__MODULE__{response: any(), message: String.t()}

  defexception [:response, :message]

  @impl Exception
  def message(%__MODULE__{response: response, message: message}) do
    "#{message}\n\n#{inspect(response, pretty: true)}"
  end
end
