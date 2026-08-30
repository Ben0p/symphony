defmodule SymphonyElixir.LinearClientStartupBoundsTest do
  use SymphonyElixir.TestSupport

  test "linear graphql requests use bounded connect, receive, and retry settings" do
    options = Client.request_options_for_test()

    assert get_in(options, [:connect_options, :timeout]) == 10_000
    assert options[:receive_timeout] == 15_000
    assert options[:retry] == :transient
    assert options[:max_retries] == 2
  end

  test "state pagination is bounded for startup cleanup fetches" do
    parent = self()

    graphql = fn _query, variables ->
      send(parent, {:page, variables[:after]})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [issue_node("issue-#{variables[:after] || "first"}", "Done")],
             "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-#{System.unique_integer([:positive])}"}
           }
         }
       }}
    end

    assert {:error, {:linear_page_limit_exceeded, 20}} =
             Client.fetch_issues_by_states_for_test(["Done"], graphql)

    assert_received_pages(20)
  end

  test "state pagination still returns merged issues inside the page limit" do
    graphql = fn _query, variables ->
      case variables[:after] do
        nil ->
          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "nodes" => [issue_node("issue-first", "Done")],
                 "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-1"}
               }
             }
           }}

        "cursor-1" ->
          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "nodes" => [issue_node("issue-second", "Done")],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }}
      end
    end

    assert {:ok, [first, second]} = Client.fetch_issues_by_states_for_test(["Done"], graphql)
    assert first.id == "issue-first"
    assert second.id == "issue-second"
  end

  defp assert_received_pages(0), do: refute_receive({:page, _cursor})

  defp assert_received_pages(count) when count > 0 do
    assert_receive {:page, _cursor}, 100
    assert_received_pages(count - 1)
  end

  defp issue_node(id, state) do
    %{
      "id" => id,
      "identifier" => String.upcase(id),
      "title" => "Startup maintenance #{id}",
      "description" => "description is intentionally ignored by startup maintenance",
      "priority" => 2,
      "state" => %{"name" => state},
      "branchName" => nil,
      "url" => "https://linear.example/#{id}",
      "assignee" => nil,
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []},
      "createdAt" => "2026-08-15T00:00:00Z",
      "updatedAt" => "2026-08-15T00:00:00Z"
    }
  end
end
