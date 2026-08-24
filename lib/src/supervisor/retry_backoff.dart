final class RetryBackoff {
  const RetryBackoff({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.exponentialAttempts = 3,
  });

  final Duration initialDelay;
  final Duration maxDelay;
  final int exponentialAttempts;

  Duration delayForAttempt(int attempt) {
    if (attempt < 1) {
      throw ArgumentError.value(attempt, 'attempt', 'must be at least 1');
    }
    if (attempt > exponentialAttempts) {
      return maxDelay;
    }
    final milliseconds = initialDelay.inMilliseconds * (1 << (attempt - 1));
    final calculated = Duration(milliseconds: milliseconds);
    return calculated > maxDelay ? maxDelay : calculated;
  }
}
