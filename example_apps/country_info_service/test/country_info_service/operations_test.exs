defmodule CountryInfoService.OperationsTest do
  use ExUnit.Case
  doctest CountryInfoService.Operations

  describe "operations module" do
    test "exports all operation info functions" do
      info_functions = [
        :capital_city,
        :country_name,
        :country_flag,
        :country_currency,
        :country_iso_code,
        :full_country_info,
        :list_of_continents_by_name,
        :list_of_country_names_by_code
      ]

      Enum.each(info_functions, fn fun ->
        assert function_exported?(CountryInfoService.Operations, fun, 0)
      end)
    end

    test "exports all call functions" do
      call_with_params = [
        :call_country_flag,
        :call_capital_city,
        :call_country_name,
        :call_country_currency,
        :call_country_iso_code,
        :call_full_country_info,
        :call_currency_name,
        :call_language_name
      ]

      call_without_params = [
        :call_list_of_continents_by_name,
        :call_list_of_continents_by_code,
        :call_list_of_country_names_by_code,
        :call_list_of_currencies_by_name,
        :call_list_of_languages_by_code,
        :call_full_country_info_all_countries
      ]

      Enum.each(call_with_params, fn fun ->
        assert function_exported?(CountryInfoService.Operations, fun, 2)
      end)

      Enum.each(call_without_params, fn fun ->
        assert function_exported?(CountryInfoService.Operations, fun, 1)
      end)
    end
  end
end
