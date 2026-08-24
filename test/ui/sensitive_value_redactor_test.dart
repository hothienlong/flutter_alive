import 'package:flutter_alive/src/ui/sensitive_value_redactor.dart';
import 'package:test/test.dart';

void main() {
  const redactor = SensitiveValueRedactor();

  test('redacts common credentials and Dart defines', () {
    final output = redactor.redact(
      'Authorization: Bearer abc.def '
      'api_key=secret-value '
      'TOKEN nè: vietnamese-secret '
      '--dart-define=PAYMENT_TOKEN=top-secret',
    );

    expect(output, isNot(contains('abc.def')));
    expect(output, isNot(contains('secret-value')));
    expect(output, isNot(contains('vietnamese-secret')));
    expect(output, isNot(contains('top-secret')));
    expect(output, contains('PAYMENT_TOKEN=<redacted>'));
  });

  test('leaves ordinary Flutter output unchanged', () {
    expect(
      redactor.redact('Launching lib/main.dart on Test Phone...'),
      'Launching lib/main.dart on Test Phone...',
    );
  });
}
