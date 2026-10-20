/// What a provider's data refresh couldn't fetch, such as a route or stop
/// list, each as a short description for the loading screen.
class RefreshResult {
  final List<String> failedItems;

  const RefreshResult({this.failedItems = const []});
}
