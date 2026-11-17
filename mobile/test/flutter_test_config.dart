import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/my_races.dart' show clearMedalCaches;
import 'package:shared_preferences/shared_preferences.dart';

/// Preferencias locais (modo escuro, biometria, avisos) comecam vazias em cada teste.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clearMedalCaches(); // a prateleira guarda corridas e filtro entre telas: cada teste comeca limpo
  });
  await testMain();
}
