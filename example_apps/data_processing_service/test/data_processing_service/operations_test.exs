defmodule DataProcessingService.OperationsTest do
  use ExUnit.Case
  doctest DataProcessingService.Operations

  describe "operations module" do
    test "operations module exports operation info functions" do
      assert function_exported?(DataProcessingService.Operations, :process_data, 0)
    end

    test "operations module exports call functions with parameters" do
      assert function_exported?(DataProcessingService.Operations, :call_process_data, 2)
    end
  end
end
