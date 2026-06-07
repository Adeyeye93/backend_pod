defmodule PodWeb.CachedUpdate do
  use PodWeb, :channel
  alias PodWeb.Endpoint
  alias Pod.Interests

  def join("Cache", %{"type" => "interests"}, socket) do
    interests = Interests.list_interests()
    {:ok, %{interests: interests}, socket}
  end

  
end
