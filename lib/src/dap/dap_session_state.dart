final class DapSessionState {
  Map<String, Object?>? _initializeRequest;
  Map<String, Object?>? _launchRequest;
  final Map<String, Map<String, Object?>> _breakpointRequests = {};
  final Map<String, Map<String, Object?>> _singletonConfiguration = {};

  bool get hasLaunchRequest => _launchRequest != null;

  String? get deviceSelector {
    final arguments = _argumentsOf(_launchRequest);
    final deviceId = arguments?['deviceId'];
    if (deviceId is String && deviceId.isNotEmpty) {
      return deviceId;
    }
    final toolArgs = arguments?['toolArgs'];
    if (toolArgs is List<Object?>) {
      for (var index = 0; index < toolArgs.length; index += 1) {
        final argument = toolArgs[index];
        if ((argument == '-d' || argument == '--device-id') &&
            index + 1 < toolArgs.length) {
          return toolArgs[index + 1]?.toString();
        }
        if (argument is String && argument.startsWith('--device-id=')) {
          return argument.substring('--device-id='.length);
        }
      }
    }
    return null;
  }

  void record(Map<String, Object?> message) {
    if (message['type'] != 'request') {
      return;
    }
    final command = message['command'];
    if (command is! String) {
      return;
    }
    final copy = _deepCopy(message);
    switch (command) {
      case 'initialize':
        _initializeRequest = copy;
      case 'launch':
      case 'attach':
        _launchRequest = copy;
      case 'setBreakpoints':
        final arguments = _argumentsOf(copy);
        final source = arguments?['source'];
        final path = source is Map<Object?, Object?>
            ? source['path']?.toString() ?? source['name']?.toString()
            : null;
        _breakpointRequests[path ?? 'unknown'] = copy;
      case 'setExceptionBreakpoints':
      case 'setFunctionBreakpoints':
      case 'setInstructionBreakpoints':
      case 'setDataBreakpoints':
      case 'configurationDone':
        _singletonConfiguration[command] = copy;
    }
  }

  Map<String, Object?> initializeRequest(int seq) {
    final request = _initializeRequest;
    if (request == null) {
      throw StateError('No DAP initialize request has been recorded.');
    }
    return _withSeq(request, seq);
  }

  Map<String, Object?> launchRequest(int seq, String deviceId) {
    final request = _launchRequest;
    if (request == null) {
      throw StateError('No DAP launch request has been recorded.');
    }
    final copy = _withSeq(request, seq);
    copy['command'] = 'launch';
    copy['arguments'] = _launchArguments(deviceId);
    return copy;
  }

  Map<String, Object?> attachRequest(int seq, String deviceId) {
    final request = _launchRequest;
    if (request == null) {
      throw StateError('No DAP launch request has been recorded.');
    }
    final original = _argumentsOf(request) ?? const {};
    final arguments = Map<String, Object?>.from(original)
      ..remove('program')
      ..remove('args')
      ..remove('noDebug')
      ..remove('flutterMode')
      ..remove('deviceId');
    final toolArguments = _toolArguments(original, deviceId);
    final appId = original['appId'];
    if (appId is String && appId.isNotEmpty) {
      toolArguments.add('--app-id=$appId');
    }
    arguments
      ..remove('appId')
      ..['toolArgs'] = toolArguments;
    final copy = _withSeq(request, seq);
    copy['command'] = 'attach';
    copy['arguments'] = arguments;
    return copy;
  }

  List<Map<String, Object?>> configurationRequests(int Function() nextSeq) {
    final requests = <Map<String, Object?>>[
      ..._breakpointRequests.values,
      for (final command in const [
        'setExceptionBreakpoints',
        'setFunctionBreakpoints',
        'setInstructionBreakpoints',
        'setDataBreakpoints',
        'configurationDone',
      ])
        if (_singletonConfiguration[command] case final request?) request,
    ];
    return requests
        .map((request) => _withSeq(request, nextSeq()))
        .toList(growable: false);
  }

  Map<String, Object?> _launchArguments(String deviceId) {
    final original = _argumentsOf(_launchRequest) ?? const {};
    final arguments = Map<String, Object?>.from(original)..remove('deviceId');
    arguments['toolArgs'] = _toolArguments(original, deviceId);
    return arguments;
  }

  static List<String> _toolArguments(
    Map<String, Object?> arguments,
    String deviceId,
  ) {
    final raw = arguments['toolArgs'];
    final original = raw is List<Object?>
        ? raw.map((value) => value.toString()).toList(growable: false)
        : const <String>[];
    final output = <String>[];
    for (var index = 0; index < original.length; index += 1) {
      final argument = original[index];
      if (argument == '-d' || argument == '--device-id') {
        index += 1;
        continue;
      }
      if (argument.startsWith('--device-id=')) {
        continue;
      }
      output.add(argument);
    }
    final mode = arguments['flutterMode'];
    if (mode == 'profile' && !output.contains('--profile')) {
      output.add('--profile');
    } else if (mode == 'release' && !output.contains('--release')) {
      output.add('--release');
    }
    output.addAll(['-d', deviceId]);
    return output;
  }

  static Map<String, Object?>? _argumentsOf(Map<String, Object?>? request) {
    final arguments = request?['arguments'];
    if (arguments is! Map<Object?, Object?>) {
      return null;
    }
    return arguments.map((key, value) => MapEntry(key.toString(), value));
  }

  static Map<String, Object?> _withSeq(
    Map<String, Object?> request,
    int seq,
  ) {
    final copy = _deepCopy(request);
    copy['seq'] = seq;
    return copy;
  }

  static Map<String, Object?> _deepCopy(Map<String, Object?> value) {
    Object? copyValue(Object? item) {
      if (item is Map<Object?, Object?>) {
        return item.map(
          (key, nested) => MapEntry(key.toString(), copyValue(nested)),
        );
      }
      if (item is List<Object?>) {
        return item.map(copyValue).toList(growable: false);
      }
      return item;
    }

    return value.map((key, item) => MapEntry(key, copyValue(item)));
  }
}
