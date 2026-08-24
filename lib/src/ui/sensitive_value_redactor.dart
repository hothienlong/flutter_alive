final class SensitiveValueRedactor {
  const SensitiveValueRedactor();

  static final RegExp _namedValue = RegExp(
    r'\b(authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|token(?:\s+[^:=\s]+){0,2}|client[_-]?secret|secret|password)\s*([=:])\s*([^\s,;]+)',
    caseSensitive: false,
  );
  static final RegExp _bearer = RegExp(
    r'\bBearer\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final RegExp _dartDefine = RegExp(
    r'--dart-define(?:=|\s+)([^=\s]+)=([^\s]+)',
  );

  String redact(String value) {
    return value
        .replaceAllMapped(
          _dartDefine,
          (match) => '--dart-define=${match.group(1)}=<redacted>',
        )
        .replaceAllMapped(
          _bearer,
          (_) => 'Bearer <redacted>',
        )
        .replaceAllMapped(
          _namedValue,
          (match) => '${match.group(1)}${match.group(2)}<redacted>',
        );
  }
}
