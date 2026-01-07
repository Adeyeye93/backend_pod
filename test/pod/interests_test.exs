defmodule Pod.InterestsTest do
  use Pod.DataCase

  alias Pod.Interests

  describe "interests" do
    alias Pod.Interests.Interest

    import Pod.InterestsFixtures

    @invalid_attrs %{name: nil, description: nil, color: nil, icon: nil}

    test "list_interests/0 returns all interests" do
      interest = interest_fixture()
      assert Interests.list_interests() == [interest]
    end

    test "get_interest!/1 returns the interest with given id" do
      interest = interest_fixture()
      assert Interests.get_interest!(interest.id) == interest
    end

    test "create_interest/1 with valid data creates a interest" do
      valid_attrs = %{name: "some name", description: "some description", color: "some color", icon: "some icon"}

      assert {:ok, %Interest{} = interest} = Interests.create_interest(valid_attrs)
      assert interest.name == "some name"
      assert interest.description == "some description"
      assert interest.color == "some color"
      assert interest.icon == "some icon"
    end

    test "create_interest/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Interests.create_interest(@invalid_attrs)
    end

    test "update_interest/2 with valid data updates the interest" do
      interest = interest_fixture()
      update_attrs = %{name: "some updated name", description: "some updated description", color: "some updated color", icon: "some updated icon"}

      assert {:ok, %Interest{} = interest} = Interests.update_interest(interest, update_attrs)
      assert interest.name == "some updated name"
      assert interest.description == "some updated description"
      assert interest.color == "some updated color"
      assert interest.icon == "some updated icon"
    end

    test "update_interest/2 with invalid data returns error changeset" do
      interest = interest_fixture()
      assert {:error, %Ecto.Changeset{}} = Interests.update_interest(interest, @invalid_attrs)
      assert interest == Interests.get_interest!(interest.id)
    end

    test "delete_interest/1 deletes the interest" do
      interest = interest_fixture()
      assert {:ok, %Interest{}} = Interests.delete_interest(interest)
      assert_raise Ecto.NoResultsError, fn -> Interests.get_interest!(interest.id) end
    end

    test "change_interest/1 returns a interest changeset" do
      interest = interest_fixture()
      assert %Ecto.Changeset{} = Interests.change_interest(interest)
    end
  end
end
