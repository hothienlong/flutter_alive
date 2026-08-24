import 'dart:io';

import 'package:flutter_alive/flutter_alive.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await FlutterAliveCli().run(arguments);
}
