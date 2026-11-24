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

/// Contas que criaram o perfil (Step.profile, `justCreated`) neste aparelho e
/// ainda nao concluiram a celebracao do fim do cadastro — marcada na criacao,
/// removida quando a pessoa de fato toca em "Começar minha jornada". Por id
/// da conta, nao por e-mail nem por numero de versao do perfil: usar a versao
/// (poucas edicoes = "cadastro novo") tambem marcaria como "fresco" uma conta
/// antiga de verdade que, por coincidencia, nunca editou o perfil — e
/// mostraria a celebracao de novo pra quem ja faz tempo que usa o app. Esse
/// sinal explicito evita isso e ainda resolve o bug original: fechar o app
/// entre a admissao e a foto/celebracao nao perde mais a "pendencia", porque
/// ela esta salva no aparelho, nao so em memoria.
class PendingCelebrationPrefs {
  static const _key = 'pending-celebration-account-ids';

  static Future<bool> isPending(String accountId) async {
    try {
      final ids =
          (await SharedPreferences.getInstance()).getStringList(_key) ??
          const [];
      return ids.contains(accountId);
    } on Object {
      return false;
    }
  }

  static Future<void> markPending(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_key) ?? <String>[];
      if (!ids.contains(accountId)) {
        await prefs.setStringList(_key, [...ids, accountId]);
      }
    } on Object {
      // Sem armazenamento: na pior hipotese, a celebracao nao aparece depois
      // de fechar o app no meio do cadastro — pior do que hoje, nao melhor,
      // mas e so nesse caso raro de falha de armazenamento local.
    }
  }

  static Future<void> clearPending(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_key) ?? <String>[];
      if (ids.remove(accountId)) {
        await prefs.setStringList(_key, ids);
      }
    } on Object {
      // Sem armazenamento: na pior hipotese, a celebracao pode aparecer de novo.
    }
  }
}

/// Rascunho local dos campos das etapas de admissao (genero, nascimento,
/// declaracao de maioridade) e localizacao (estado/cidade), que so sao
/// enviados ao servidor quando a pessoa toca em "Continuar" naquela tela.
/// Sem isso, fechar o app antes de tocar "Continuar" perdia o que tinha sido
/// preenchido, mesmo a etapa certa voltando a aparecer (23/11/2026). Por id
/// da conta; cada campo e apagado assim que o dado correspondente e de fato
/// confirmado no servidor (POST /beta/admissions, PATCH /me de localizacao).
class OnboardingDraftPrefs {
  static const _gender = 'draft-gender-';
  static const _birthDate = 'draft-birth-date-';
  static const _adult = 'draft-adult-';
  static const _uf = 'draft-uf-';
  static const _city = 'draft-city-';
  static const _lat = 'draft-lat-';
  static const _lon = 'draft-lon-';

  static Future<void> saveGender(String accountId, String value) =>
      _setString('$_gender$accountId', value);
  static Future<String?> loadGender(String accountId) =>
      _getString('$_gender$accountId');

  static Future<void> saveBirthDate(String accountId, DateTime value) =>
      _setString('$_birthDate$accountId', value.toIso8601String());
  static Future<DateTime?> loadBirthDate(String accountId) async {
    final raw = await _getString('$_birthDate$accountId');
    if (raw == null) return null;
    try {
      return DateTime.parse(raw);
    } on FormatException {
      return null;
    }
  }

  static Future<void> saveAdult(String accountId, bool value) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(
        '$_adult$accountId',
        value,
      );
    } on Object {
      // Sem armazenamento: so nao preenche sozinho se o app for reaberto.
    }
  }

  static Future<bool?> loadAdult(String accountId) async {
    try {
      return (await SharedPreferences.getInstance()).getBool(
        '$_adult$accountId',
      );
    } on Object {
      return null;
    }
  }

  static Future<void> clearAdmission(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_gender$accountId');
      await prefs.remove('$_birthDate$accountId');
      await prefs.remove('$_adult$accountId');
    } on Object {
      // Nada a limpar.
    }
  }

  static Future<void> saveLocation(
    String accountId,
    String uf,
    String city, {
    double? lat,
    double? lon,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_uf$accountId', uf);
      await prefs.setString('$_city$accountId', city);
      if (lat != null) await prefs.setDouble('$_lat$accountId', lat);
      if (lon != null) await prefs.setDouble('$_lon$accountId', lon);
    } on Object {
      // Sem armazenamento: so nao preenche sozinho se o app for reaberto.
    }
  }

  static Future<String?> loadUf(String accountId) => _getString('$_uf$accountId');
  static Future<String?> loadCity(String accountId) =>
      _getString('$_city$accountId');

  static Future<double?> loadLat(String accountId) async {
    try {
      return (await SharedPreferences.getInstance()).getDouble(
        '$_lat$accountId',
      );
    } on Object {
      return null;
    }
  }

  static Future<double?> loadLon(String accountId) async {
    try {
      return (await SharedPreferences.getInstance()).getDouble(
        '$_lon$accountId',
      );
    } on Object {
      return null;
    }
  }

  static Future<void> clearLocation(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_uf$accountId');
      await prefs.remove('$_city$accountId');
      await prefs.remove('$_lat$accountId');
      await prefs.remove('$_lon$accountId');
    } on Object {
      // Nada a limpar.
    }
  }

  static Future<void> _setString(String key, String value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } on Object {
      // Sem armazenamento: so nao preenche sozinho se o app for reaberto.
    }
  }

  static Future<String?> _getString(String key) async {
    try {
      return (await SharedPreferences.getInstance()).getString(key);
    } on Object {
      return null;
    }
  }
}

/// "Manter conectado": ligado por padrao (decisao de produto de 21/11/2026); quem
/// desligar em Configuracoes fica desconectado a cada reinicio do app.
class KeepSignedInPrefs {
  static const _key = 'keep-signed-in';

  static Future<bool> enabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? true;
    } on Object {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, value);
    } on Object {
      // Sem armazenamento: vale ate fechar o app.
    }
  }
}
