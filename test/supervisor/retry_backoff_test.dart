import 'package:flutter_alive/src/supervisor/retry_backoff.dart';
import 'package:test/test.dart';

void main() {
  test('backs off at 1, 2, 4 seconds and then caps at 30 seconds', () {
    const backoff = RetryBackoff();

    expect(backoff.delayForAttempt(1), const Duration(seconds: 1));
    expect(backoff.delayForAttempt(2), const Duration(seconds: 2));
    expect(backoff.delayForAttempt(3), const Duration(seconds: 4));
    expect(backoff.delayForAttempt(4), const Duration(seconds: 30));
    expect(backoff.delayForAttempt(20), const Duration(seconds: 30));
  });

  test('rejects invalid attempt numbers', () {
    expect(() => const RetryBackoff().delayForAttempt(0), throwsArgumentError);
  });
}
