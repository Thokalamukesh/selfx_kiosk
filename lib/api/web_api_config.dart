class WebApiConfig {
  static const String defaultBaseUrl = "";
  static const String defaultRestaurantsUrl = "";

  static const String baseUrl = String.fromEnvironment(
    "SELFX_WEB_API_BASE_URL",
    defaultValue: defaultBaseUrl,
  );

  static const String allRestaurantsUrl = String.fromEnvironment(
    "SELFX_WEB_RESTAURANTS_URL",
    defaultValue: defaultRestaurantsUrl,
  );
}
