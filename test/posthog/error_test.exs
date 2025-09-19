defmodule PostHog.ErrorTest do
  use ExUnit.Case, async: true

  describe "UnexpectedResponseError.message/1" do
    test "adds response to the message" do
      error = %PostHog.UnexpectedResponseError{
        message: "Not friend shape",
        response: %Req.Response{
          status: 500,
          headers: %{
            "access-control-allow-credentials" => ["true"],
            "access-control-allow-origin" => ["*"],
            "connection" => ["keep-alive"],
            "content-length" => ["0"],
            "content-type" => ["text/html; charset=utf-8"],
            "date" => ["Mon, 01 Sep 2025 00:46:59 GMT"],
            "server" => ["gunicorn/19.9.0"]
          },
          body: "",
          trailers: %{},
          private: %{}
        }
      }

      assert Exception.message(error) == """
             Not friend shape

             %Req.Response{
               status: 500,
               headers: %{
                 "access-control-allow-credentials" => ["true"],
                 "access-control-allow-origin" => ["*"],
                 "connection" => ["keep-alive"],
                 "content-length" => ["0"],
                 "content-type" => ["text/html; charset=utf-8"],
                 "date" => ["Mon, 01 Sep 2025 00:46:59 GMT"],
                 "server" => ["gunicorn/19.9.0"]
               },
               body: "",
               trailers: %{},
               private: %{}
             }\
             """
    end
  end

  describe "Error.message/1" do
    test "missing distinct id" do
      error = %PostHog.Error{
        message: "something went wrong"
      }

      assert Exception.message(error) == "something went wrong"
    end
  end
end
