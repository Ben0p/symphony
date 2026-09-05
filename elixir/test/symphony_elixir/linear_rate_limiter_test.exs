defmodule SymphonyElixir.Linear.RateLimiterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.RateLimiter

  setup do
    state_path = Path.join(System.tmp_dir!(), "symphony-linear-rate-limit-test-#{System.unique_integer([:positive])}.state")

    tracker_settings = %{
      provider: %{
        "rate_limit_file" => state_path,
        "rate_limit_min_interval_ms" => 50,
        "rate_limit_max_wait_ms" => 1_000,
        "rate_limit_stale_lock_ms" => 100,
        "rate_limit_max_retry_after_ms" => 100
      }
    }

    on_exit(fn ->
      File.rm(state_path)
      File.rm(state_path <> ".lock")
    end)

    {:ok, tracker_settings: tracker_settings}
  end

  test "reserves a shared minimum interval", %{tracker_settings: tracker_settings} do
    assert :ok = RateLimiter.await(tracker_settings)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = RateLimiter.await(tracker_settings)

    assert System.monotonic_time(:millisecond) - started_at >= 35
  end

  test "serializes concurrent callers through the shared state file", %{tracker_settings: tracker_settings} do
    timestamps =
      1..3
      |> Task.async_stream(
        fn _ ->
          assert :ok = RateLimiter.await(tracker_settings)
          System.monotonic_time(:millisecond)
        end,
        max_concurrency: 3,
        timeout: 2_000
      )
      |> Enum.map(fn {:ok, timestamp} -> timestamp end)
      |> Enum.sort()

    assert Enum.at(timestamps, 2) - Enum.at(timestamps, 0) >= 70
  end

  test "honors a bounded retry-after cooldown", %{tracker_settings: tracker_settings} do
    assert :ok = RateLimiter.observe_response(tracker_settings, %{status: 429, headers: [{"retry-after", "1"}]})

    started_at = System.monotonic_time(:millisecond)
    assert :ok = RateLimiter.await(tracker_settings)

    assert System.monotonic_time(:millisecond) - started_at >= 75
  end

  test "honors a GraphQL rate-limit window embedded in a non-429 response", %{tracker_settings: tracker_settings} do
    tracker_settings =
      put_in(tracker_settings, [:provider, "rate_limit_max_retry_after_ms"], 3_600_000)

    response = %{
      status: 400,
      body: %{
        "errors" => [
          %{
            "type" => "ratelimited",
            "extensions" => %{
              "statusCode" => 429,
              "meta" => %{"rateLimitResult" => %{"duration" => 3_600_000}}
            }
          }
        ]
      }
    }

    assert :ok = RateLimiter.observe_response(tracker_settings, response)
    assert {:error, :linear_rate_limit_wait_exceeded} = RateLimiter.await(tracker_settings)
  end

  test "persists a GraphQL cooldown when the client returns an ok response tuple", %{tracker_settings: tracker_settings} do
    tracker_settings =
      Map.merge(tracker_settings, %{
        api_key: "test-linear-token",
        endpoint: "https://linear.invalid/graphql",
        provider: put_in(tracker_settings.provider, ["rate_limit_max_retry_after_ms"], 3_600_000)
      })

    response = %{
      status: 400,
      body: %{
        "errors" => [
          %{
            "type" => "ratelimited",
            "extensions" => %{
              "statusCode" => 429,
              "meta" => %{"rateLimitResult" => %{"duration" => 3_600_000}}
            }
          }
        ]
      }
    }

    assert {:error, {:linear_api_status, 400}} =
             Client.graphql("query Test { viewer { id } }", %{},
               tracker_settings: tracker_settings,
               request_fun: fn _payload, _headers -> {:ok, response} end
             )

    assert {:ok, next_allowed_at} = File.read(tracker_settings.provider["rate_limit_file"])
    assert String.to_integer(String.trim(next_allowed_at)) >= System.system_time(:millisecond) + 3_599_000
  end
end
