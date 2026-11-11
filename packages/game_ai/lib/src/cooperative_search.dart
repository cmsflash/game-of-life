import 'agent.dart';

/// Drives a resumable search while letting native and web UIs process events.
Future<void> runSearchInSlices(
  Iterable<void> work, {
  bool Function()? isCancelled,
}) async {
  void checkCancellation() {
    if (isCancelled?.call() ?? false) throw const SearchCancelledException();
  }

  // Allow the thinking indicator to paint before starting the first slice.
  await Future<void>.delayed(Duration.zero);
  checkCancellation();
  final slice = Stopwatch()..start();
  for (final _ in work) {
    if (slice.elapsedMilliseconds >= 8) {
      await Future<void>.delayed(Duration.zero);
      checkCancellation();
      slice.reset();
    }
  }
  checkCancellation();
}
