import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class IdentityIssue implements Exception {
  final String code;
  const IdentityIssue(this.code);
}

class JsonReply {
  final int status;
  final Map<String, dynamic> body;
  const JsonReply(this.status, this.body);
}

typedef JsonTransport = Future<JsonReply> Function(
  Uri uri,
  String method,
  Map<String, String> headers,
  Map<String, dynamic>? body,
);

typedef ByteTransport = Future<int> Function(
  Uri uri,
  String method,
  Map<String, String> headers,
  List<int> bytes,
);

typedef Sleeper = Future<void> Function(Duration duration);

Future<void> wait(Duration duration) => Future<void>.delayed(duration);

/// Envia o corpo com Content-Length explicito. Sem ele o Dart usa Transfer-Encoding: chunked,
/// que o S3 recusa em URL pre-assinada (501 NotImplemented).
Future<int> putBytes(
  HttpClient client,
  Uri uri,
  String method,
  Map<String, String> headers,
  List<int> bytes,
) async {
  final request = await client
      .openUrl(method, uri)
      .timeout(const Duration(seconds: 10));
  request.followRedirects = false;
  headers.forEach(request.headers.set);
  request.contentLength = bytes.length;
  request.add(bytes);
  final response = await request.close().timeout(const Duration(seconds: 30));
  await response.drain<void>();
  return response.statusCode;
}

Future<int> sendBytes(
  Uri uri,
  String method,
  Map<String, String> headers,
  List<int> bytes,
) async {
  if (uri.scheme != 'https') throw const IdentityIssue('INVALID_UPLOAD_URL');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await putBytes(client, uri, method, headers, bytes);
  } on IdentityIssue {
    rethrow;
  } on Exception {
    throw const IdentityIssue('UPLOAD_UNAVAILABLE');
  } finally {
    client.close(force: true);
  }
}

Future<JsonReply> sendJson(
  Uri uri,
  String method,
  Map<String, String> headers,
  Map<String, dynamic>? body,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (body != null) {
      // Bytes UTF-8 explicitos: acentos e emojis nao podem depender do charset padrao.
      final bytes = utf8.encode(jsonEncode(body));
      // So a API usa application/json; o Cognito exige application/x-amz-json-1.1 e nao pode
      // ser trocado.
      if (headers['Content-Type'] == 'application/json') {
        request.headers.contentType = ContentType(
          'application',
          'json',
          charset: 'utf-8',
        );
      }
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 15));
    return JsonReply(
      response.statusCode,
      text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>,
    );
  } on Exception {
    throw const IdentityIssue('SERVICE_UNAVAILABLE');
  } finally {
    client.close(force: true);
  }
}

/// Guarda o token de renovacao do Cognito (30 dias) para "manter conectado". So o token de
/// renovacao e gravado, nunca a senha.
///
/// "Trancar" (Sair com biometria ligada) move o token para um item do Keychain que o iOS
/// so entrega com rosto/digital (biometryCurrentSet) e registra quando foi trancado, para
/// o gateway descartar a sessao trancada depois do prazo.
abstract class TokenStore {
  /// Le o token (na sessao trancada, o sistema pede a biometria aqui).
  Future<String?> read();

  /// Grava o token em uso e destrava: apaga a copia protegida e a data da tranca.
  Future<void> write(String token);

  /// Apaga tudo: token em uso, copia protegida e data da tranca.
  Future<void> clear();

  /// Quando a sessao foi trancada; nulo se nao esta trancada. Nao pede biometria.
  Future<DateTime?> lockedAt();

  /// Move o token para o item protegido por biometria e registra `at`.
  Future<void> lock(DateTime at);
}

/// iOS Keychain / Android Keystore.
class SecureTokenStore implements TokenStore {
  static const _key = 'runpass-refresh-token';
  static const _lockedKey = 'runpass-refresh-token-locked';
  static const _lockedAtKey = 'runpass-refresh-token-locked-at';
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const _protected = IOSOptions(
    accessibility: KeychainAccessibility.passcode,
    accessControlFlags: [AccessControlFlag.biometryCurrentSet],
  );

  @override
  Future<String?> read() async {
    try {
      if (await lockedAt() != null) {
        final locked = await _storage.read(
          key: _lockedKey,
          iOptions: _protected,
        );
        if (locked != null && locked.isNotEmpty) return locked;
      }
      return await _storage.read(key: _key);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String token) async {
    try {
      await _storage.write(key: _key, value: token);
    } on Object {
      // Sem armazenamento seguro: a pessoa so precisa entrar de novo na proxima vez.
    }
    await _dropLock();
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } on Object {
      // Nada a limpar.
    }
    await _dropLock();
  }

  @override
  Future<DateTime?> lockedAt() async {
    try {
      final text = await _storage.read(key: _lockedAtKey);
      return text == null ? null : DateTime.tryParse(text);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> lock(DateTime at) async {
    try {
      final token = await _storage.read(key: _key);
      if (token != null && token.isNotEmpty) {
        try {
          await _storage.write(
            key: _lockedKey,
            value: token,
            iOptions: _protected,
          );
          await _storage.delete(key: _key);
        } on Object {
          // Aparelho sem biometria/senha para proteger o item: o token segue no item comum.
        }
      }
      await _storage.write(key: _lockedAtKey, value: at.toIso8601String());
    } on Object {
      // Sem armazenamento seguro: nada a trancar.
    }
  }

  Future<void> _dropLock() async {
    try {
      await _storage.delete(key: _lockedAtKey);
      await _storage.delete(key: _lockedKey, iOptions: _protected);
    } on Object {
      // Nada a limpar.
    }
  }
}

/// Memoria apenas; usado nos testes.
class MemoryTokenStore implements TokenStore {
  String? value;
  DateTime? locked;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String token) async {
    value = token;
    locked = null;
  }

  @override
  Future<void> clear() async {
    value = null;
    locked = null;
  }

  @override
  Future<DateTime?> lockedAt() async => locked;
  @override
  Future<void> lock(DateTime at) async => locked = at;
}

class IdentityGateway {
  final Uri cognito;
  final Uri api;
  final String clientId;
  final JsonTransport transport;
  final ByteTransport byteTransport;
  final Sleeper sleeper;
  final TokenStore? tokenStore;
  final DateTime Function() clock;
  String? _accessToken;
  String? _refreshToken;
  String? _pendingCommand;
  String? _pendingKey;

  IdentityGateway({
    required this.cognito,
    required this.api,
    required this.clientId,
    this.transport = sendJson,
    this.byteTransport = sendBytes,
    this.sleeper = wait,
    this.tokenStore,
    this.clock = DateTime.now,
  }) {
    if (cognito.scheme != 'https' ||
        api.scheme != 'https' ||
        cognito.userInfo.isNotEmpty ||
        api.userInfo.isNotEmpty ||
        clientId.isEmpty) {
      throw ArgumentError(
        'HTTPS endpoints and app client configuration required',
      );
    }
  }

  bool get signedIn => _accessToken != null;

  /// Ha onde guardar a sessao (app real); nos testes nao ha.
  bool get canRestore => tokenStore != null;

  /// Chamada Cognito autenticada por ClientId (SignUp, InitiateAuth, ...).
  Future<Map<String, dynamic>> _cognito(
    String operation,
    Map<String, dynamic> body,
  ) => _cognitoCall(operation, {'ClientId': clientId, ...body});

  /// Chamada Cognito sem ClientId (operacoes autenticadas por AccessToken, como
  /// ChangePassword e GlobalSignOut, que rejeitam o parametro).
  Future<Map<String, dynamic>> _cognitoCall(
    String operation,
    Map<String, dynamic> body,
  ) async {
    final result = await transport(cognito, 'POST', {
      'Content-Type': 'application/x-amz-json-1.1',
      'X-Amz-Target': 'AWSCognitoIdentityProviderService.$operation',
    }, body);
    if (result.status < 200 || result.status >= 300) {
      // Provider messages can contain identifiers; only a stable error code reaches the UI.
      throw IdentityIssue(
        (result.body['__type'] as String? ?? 'SERVICE_UNAVAILABLE')
            .split('#')
            .last,
      );
    }
    return result.body;
  }

  // Senha gerada na conta no momento do SignUp, nunca mostrada; a pessoa define a senha real
  // so depois de confirmar o e-mail (tela de senha separada), trocada com ChangePassword.
  String? _temporaryPassword;

  String _generateTemporaryPassword() {
    final random = Random.secure();
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lower = 'abcdefghijkmnopqrstuvwxyz';
    const digits = '23456789';
    const symbols = '!@#%^&*-_=+?';
    String pick(String chars, int count) =>
        List.generate(count, (_) => chars[random.nextInt(chars.length)]).join();
    final parts = [
      pick(upper, 5),
      pick(lower, 5),
      pick(digits, 5),
      pick(symbols, 5),
    ];
    parts.shuffle(random);
    return parts.join();
  }

  Future<void> signUp(String email) async {
    final password = _generateTemporaryPassword();
    await _cognito('SignUp', {
      'Username': email,
      'Password': password,
      'UserAttributes': [
        {'Name': 'email', 'Value': email},
      ],
    });
    _temporaryPassword = password;
  }

  Future<void> confirm(String email, String code) async {
    await _cognito('ConfirmSignUp', {
      'Username': email,
      'ConfirmationCode': code,
    });
  }

  /// So depois do e-mail confirmado: entra com a senha temporaria do SignUp e troca pela
  /// senha escolhida pela pessoa. Ao final a sessao fica autenticada, como num signIn comum.
  Future<void> setPassword(String email, String newPassword) async {
    final temporary = _temporaryPassword;
    if (temporary == null) throw const IdentityIssue('INVALID_INPUT');
    await signIn(email, temporary);
    await _cognitoCall('ChangePassword', {
      'AccessToken': _accessToken,
      'PreviousPassword': temporary,
      'ProposedPassword': newPassword,
    });
    _temporaryPassword = null;
  }

  Future<void> resendConfirmation(String email) async {
    await _cognito('ResendConfirmationCode', {'Username': email});
  }

  Future<void> forgot(String email) async {
    await _cognito('ForgotPassword', {'Username': email});
  }

  Future<void> reset(String email, String code, String password) async {
    await _cognito('ConfirmForgotPassword', {
      'Username': email,
      'ConfirmationCode': code,
      'Password': password,
    });
  }

  Future<void> signIn(
    String email,
    String password, {
    bool keepSignedIn = false,
  }) async {
    clearSession();
    final response = await _cognito('InitiateAuth', {
      'AuthFlow': 'USER_PASSWORD_AUTH',
      'AuthParameters': {'USERNAME': email, 'PASSWORD': password},
    });
    if (response['ChallengeName'] != null) {
      throw const IdentityIssue('SIGN_IN_CHALLENGE_REQUIRED');
    }
    final token =
        (response['AuthenticationResult']
            as Map<String, dynamic>?)?['AccessToken'];
    if (token is! String || token.isEmpty) {
      throw const IdentityIssue('INVALID_TOKEN');
    }
    _accessToken = token;
    final refresh =
        (response['AuthenticationResult']
            as Map<String, dynamic>?)?['RefreshToken'];
    if (refresh is String && refresh.isNotEmpty) {
      _refreshToken = refresh;
      if (keepSignedIn) {
        await tokenStore?.write(refresh);
      } else {
        await tokenStore?.clear();
      }
    }
  }

  /// Renova o acesso com o token guardado. Falso se nao ha token ou o Cognito o recusou
  /// (expirado, revogado); falha de rede lanca `IdentityIssue` e mantem o token guardado.
  Future<bool> restoreSession() async {
    if (await _lockExpired()) return false;
    final wasLocked = await isLocked;
    final stored = _refreshToken ?? await tokenStore?.read();
    if (stored == null || stored.isEmpty) return false;
    final result = await transport(
      cognito,
      'POST',
      {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth',
      },
      {
        'ClientId': clientId,
        'AuthFlow': 'REFRESH_TOKEN_AUTH',
        'AuthParameters': {'REFRESH_TOKEN': stored},
      },
    );
    final token =
        (result.body['AuthenticationResult']
            as Map<String, dynamic>?)?['AccessToken'];
    if (result.status >= 200 &&
        result.status < 300 &&
        token is String &&
        token.isNotEmpty) {
      _accessToken = token;
      _refreshToken = stored;
      if (wasLocked) await tokenStore?.write(stored); // destranca
      return true;
    }
    if (result.status >= 500 || result.status == 429) {
      throw const IdentityIssue('SERVICE_UNAVAILABLE');
    }
    await forgetSession();
    return false;
  }

  /// Ha um token de renovacao guardado neste aparelho (base do "entrar com o rosto").
  /// Nao pede biometria: na sessao trancada so confere a data da tranca.
  Future<bool> get hasStoredSession async {
    if (await _lockExpired()) return false;
    if (await isLocked) return true;
    final stored = _refreshToken ?? await tokenStore?.read();
    return stored != null && stored.isNotEmpty;
  }

  /// Quanto tempo a sessao trancada (Sair com biometria) continua valendo no aparelho.
  static const lockTtl = Duration(days: 7);

  /// A sessao foi trancada com "Sair" e o token esta atras da biometria do aparelho.
  Future<bool> get isLocked async => (await tokenStore?.lockedAt()) != null;

  /// Passou do prazo da sessao trancada: esquece o token e a pessoa entra com a senha.
  Future<bool> _lockExpired() async {
    final at = await tokenStore?.lockedAt();
    if (at == null || clock().difference(at) <= lockTtl) return false;
    await forgetSession();
    return true;
  }

  /// Sai da conta neste aparelho SEM revogar o token guardado: a proxima entrada e feita
  /// com a biometria. So vale com a biometria ligada; sem ela, use `signOut`.
  /// O token passa para um item do Keychain que so abre com rosto/digital e a tranca vale
  /// por `lockTtl`.
  Future<void> lockSession() async {
    clearSession();
    _refreshToken = null;
    await tokenStore?.lock(clock());
  }

  /// Esquece a sessao neste aparelho, inclusive a guardada para "manter conectado".
  Future<void> forgetSession() async {
    clearSession();
    _refreshToken = null;
    await tokenStore?.clear();
  }

  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) => _request(path, method: method, body: body, query: query, retry: true);

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
    required bool retry,
  }) async {
    if (_accessToken == null) throw const IdentityIssue('INVALID_TOKEN');
    final command = '$method:$path:${jsonEncode(body)}';
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_accessToken',
    };
    if (method != 'GET') {
      if (_pendingCommand != command) {
        _pendingCommand = command;
        final random = Random.secure();
        _pendingKey = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
      }
      headers['Idempotency-Key'] = _pendingKey!;
    }
    final result = await transport(
      api.replace(
        path: '${api.path.replaceFirst(RegExp(r'/$'), '')}$path',
        queryParameters: query,
      ),
      method,
      headers,
      body,
    );
    if (result.status == 401) {
      // O acesso vale 60 minutos; com "manter conectado" renova uma vez e repete a chamada.
      if (retry && _refreshToken != null) {
        try {
          if (await restoreSession()) {
            return await _request(
              path,
              method: method,
              body: body,
              query: query,
              retry: false,
            );
          }
        } on IdentityIssue {
          // Sem rede para renovar: cai na regra abaixo.
        }
      }
      clearSession();
      throw const IdentityIssue('INVALID_TOKEN');
    }
    if (result.status == 403 && result.body['code'] == 'ACCOUNT_UNAVAILABLE') {
      await forgetSession();
    }
    if (result.status < 200 || result.status >= 300) {
      throw IdentityIssue(
        result.body['code'] as String? ?? 'SERVICE_UNAVAILABLE',
      );
    }
    if (method != 'GET') {
      _pendingCommand = null;
      _pendingKey = null;
    }
    return result.body;
  }

  Future<Map<String, dynamic>> uploadImage(
    List<int> bytes,
    String contentType,
  ) async {
    if (bytes.isEmpty || bytes.length > 10000000) {
      throw const IdentityIssue('IMAGE_SIZE_INVALID');
    }
    final session = await request(
      '/uploads',
      method: 'POST',
      body: {'contentType': contentType, 'sizeBytes': bytes.length},
    );
    final url = Uri.tryParse(session['uploadUrl'] as String? ?? '');
    if (url == null) throw const IdentityIssue('INVALID_UPLOAD_URL');
    final headers = Map<String, String>.from(
      (session['uploadHeaders'] as Map?)?.cast<String, String>() ?? const {},
    );
    final status = await byteTransport(
      url,
      session['uploadMethod'] as String? ?? 'PUT',
      headers,
      bytes,
    );
    if (status < 200 || status >= 300) {
      throw const IdentityIssue('UPLOAD_UNAVAILABLE');
    }
    var result = await request(
      '/uploads/${Uri.encodeComponent(session['uploadId'] as String)}/finalize',
      method: 'POST',
    );
    for (
      var attempt = 0;
      attempt < 4 && result['state'] == 'pending';
      attempt++
    ) {
      await sleeper(const Duration(seconds: 1));
      result = await uploadStatus(session['uploadId'] as String);
    }
    return result;
  }

  Future<Map<String, dynamic>> uploadStatus(String uploadId) =>
      request('/uploads/${Uri.encodeComponent(uploadId)}/status');

  void clearSession() {
    _accessToken = null;
    _pendingCommand = null;
    _pendingKey = null;
  }

  Future<void> signOut() async {
    final token = _accessToken;
    await forgetSession();
    if (token == null) return;
    // GlobalSignOut has no ClientId parameter.
    await transport(
      cognito,
      'POST',
      {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityProviderService.GlobalSignOut',
      },
      {'AccessToken': token},
    );
  }
}
