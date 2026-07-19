defmodule PartyLine.ReservedModelsTest do
  use ExUnit.Case, async: true

  alias PartyLine.ReservedModels

  test "the router aliases and model families are reserved, case-insensitively" do
    for name <- ~w(party-line-auto auto default gpt-oss gemma llama qwen mistral phi) do
      assert ReservedModels.reserved?(name)
      assert ReservedModels.reserved?(String.upcase(name))
    end
  end

  test "an ordinary model id is not reserved" do
    refute ReservedModels.reserved?("qwen-7b-someone-lent")
    refute ReservedModels.reserved?("Horse Dentist")
    refute ReservedModels.reserved?("")
  end

  test "non-binary input is never reserved (no crash)" do
    refute ReservedModels.reserved?(nil)
    refute ReservedModels.reserved?(:gemma)
  end

  test "all/0 is the single source the catalogs share" do
    # a lowercase, non-empty list — the host + pipeline catalogs both guard on it
    assert "gemma" in ReservedModels.all()
    assert Enum.all?(ReservedModels.all(), &(&1 == String.downcase(&1)))
  end
end
