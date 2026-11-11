import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Biometria do aparelho (Face ID, Touch ID, digital ou rosto no Android) como trava de abertura.
/// E so uma trava local: a senha do Cognito continua existindo e o segredo guardado e apenas o
/// token de renovacao no Keychain/Keystore.
abstract class BiometricGate {
  /// O aparelho tem biometria cadastrada e disponivel.
  Future<bool> available();

  /// Pede a biometria; falso se a pessoa cancelar, falhar ou nao houver biometria.
  Future<bool> authenticate(String reason);
}

class DeviceBiometricGate implements BiometricGate {
  final _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      final kinds = await _auth.getAvailableBiometrics();
      return kinds.isNotEmpty;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on Object {
      return false;
    }
  }
}

/// Trocavel nos testes.
BiometricGate biometricGate = DeviceBiometricGate();

/// E-mail da ultima conta que entrou neste aparelho (nao e segredo; a senha nunca e guardada).
class SavedAccount {
  static const _key = 'saved-email';

  static Future<String?> email() async {
    try {
      final value = (await SharedPreferences.getInstance()).getString(_key);
      return value == null || value.isEmpty ? null : value;
    } on Object {
      return null;
    }
  }

  static Future<void> save(String email) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, email);
    } on Object {
      // Sem armazenamento: so nao preenche da proxima vez.
    }
  }

  static Future<void> clear() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } on Object {
      // Nada a limpar.
    }
  }
}

class BiometricPrefs {
  static const _enabled = 'biometric-lock';
  static const _asked = 'biometric-asked';

  static Future<bool> enabled() => _flag(_enabled);
  static Future<bool> asked() => _flag(_asked);
  static Future<void> setEnabled(bool value) => _set(_enabled, value);
  static Future<void> setAsked() => _set(_asked, true);

  /// Sair da conta ou excluir: a preferencia some junto com a sessao guardada.
  static Future<void> clear() async {
    await _set(_enabled, false);
    await _set(_asked, false);
  }

  static Future<bool> _flag(String key) async {
    try {
      return (await SharedPreferences.getInstance()).getBool(key) ?? false;
    } on Object {
      return false;
    }
  }

  static Future<void> _set(String key, bool value) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(key, value);
    } on Object {
      // Sem armazenamento: vale ate fechar o app.
    }
  }
}
