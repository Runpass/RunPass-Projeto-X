import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferencias locais (modo escuro, biometria, avisos) comecam vazias em cada teste.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  await testMain();
}
