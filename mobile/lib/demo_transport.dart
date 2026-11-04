// UI demonstration only. No network, real identities or backend validation.
import 'identity_gateway.dart';

class DemoTransport {
  final int capacity;
  final accounts = <String, Map<String, dynamic>>{};
  final sessions = <String, String>{};
  final editions = <Map<String, dynamic>>[];
  final participations = <String, Map<String, dynamic>>{};
  final uploads = <String, Map<String, dynamic>>{};
  int sequence = 0;

  DemoTransport({this.capacity = 1000}) {
    accounts['demo@runpass.test'] = {
      'password': 'RunpassDemo123!',
      'confirmed': true,
      'admitted': false,
    };
    for (var i = 1; i <= 24; i++) {
      final day = '2025-${((i - 1) % 12 + 1).toString().padLeft(2, '0')}-10';
      editions.add({
        'id': 'demo-$i',
        'name': 'Corrida de Demonstração ${i.toString().padLeft(2, '0')}',
        'date': day,
        'city': i % 3 == 0 ? 'Rio de Janeiro' : 'São Paulo',
        'state': i % 3 == 0 ? 'RJ' : 'SP',
        'status': i == 24 ? 'archived' : 'past',
        'version': 1,
        'description': 'Dados fictícios para experimentar o RunPass. Esta prova não é um evento real.',
        'distances': [
          {'id': '5k', 'kilometers': 5},
          {'id': '10k', 'kilometers': 10},
        ],
      });
    }
    _seedMedalCollection();
  }

  /// Fictional completed races so the medal collection, home and profile
  /// screens can be seen populated by signing in as medalhas@runpass.test.
  void _seedMedalCollection() {
    const email = 'medalhas@runpass.test';
    accounts[email] = {
      'password': 'RunpassDemo123!',
      'confirmed': true,
      'admitted': true,
      'profile': {
        'id': 'demo-profile-seed',
        'displayName': 'Corredor Medalhista',
        'username': 'medalhista',
        'city': 'São Paulo - SP',
        'bio':
            'Cada prova é uma nova aventura. Dados fictícios de demonstração.',
        'version': 1,
      },
    };
    const races = [
      (2, '5k', 5, 1560),
      (3, '10k', 10, 3490),
      (5, '10k', 10, 3315),
      (6, '5k', 5, 1480),
      (8, '10k', 10, 3600),
      (9, '5k', 5, 1620),
    ];
    for (final (number, distance, km, seconds) in races) {
      final id = 'demo-seed-$number';
      participations[id] = {
        'id': id,
        'owner': email,
        'editionId': 'demo-$number',
        'distanceId': distance,
        'state': 'completed',
        'version': 2,
        'timeSeconds': seconds,
        'paceSecondsPerKm': seconds ~/ km,
        'medalImageReference': 'img_seed',
        'showTime': true,
        'showPlacement': true,
      };
      editions[number - 1]['runScore'] = {
        'value': 4.0 + (number % 5) * 0.2,
        'reviewCount': 120 + number * 37,
      };
      editions[number - 1]['participantCount'] = 300 + number * 41;
    }
  }

  final likes = <String, Set<String>>{};

  /// Fictional posts by other runners, plus the signed-in runner's own
  /// published races. Demonstration data only.
  List<Map<String, dynamic>> demoFeed(String email) {
    final now = DateTime.now().toUtc();
    const people = [
      (
        'demo-author-1',
        'Mariana Lopes',
        'marianalopes',
        'demo-4',
        '10k',
        3503,
        350,
        142,
        18,
      ),
      (
        'demo-author-2',
        'Juliana Martins',
        'jumartins',
        'demo-7',
        '5k',
        1488,
        297,
        87,
        9,
      ),
      (
        'demo-author-3',
        'Carlos Menezes',
        'carlosmenezes',
        'demo-10',
        '10k',
        3120,
        312,
        56,
        4,
      ),
    ];
    const comments = [
      'Prova incrível! Percurso bem sinalizado, clima perfeito e energia em cima.',
      'Organização impecável e percurso lindo pelo parque. Medalha show!',
      'Mais uma para a coleção. Valeu a madrugada!',
    ];
    final posts = <Map<String, dynamic>>[
      for (var i = 0; i < people.length; i++)
        {
          'id': 'demo-post-${i + 1}',
          'author': {
            'id': people[i].$1,
            'displayName': people[i].$2,
            'username': people[i].$3,
            'version': 1,
          },
          'participation': {
            'id': 'demo-feed-${i + 1}',
            'editionId': people[i].$4,
            'distanceId': people[i].$5,
            'state': 'completed',
            'version': 2,
            'timeSeconds': people[i].$6,
            'paceSecondsPerKm': people[i].$7,
          },
          'comment': comments[i],
          'publishedAt': now
              .subtract(Duration(hours: 2 + i * 3))
              .toIso8601String(),
          'version': 1,
          'likeCount':
              people[i].$8 + (likes['demo-post-${i + 1}']?.length ?? 0),
          'commentCount': people[i].$9,
          'likedByMe': likes['demo-post-${i + 1}']?.contains(email) ?? false,
        },
    ];
    final profile = accounts[email]?['profile'] as Map?;
    for (final p in participations.values) {
      if (p['owner'] != email || p['state'] != 'completed') continue;
      if (p['publishToFeed'] == false || profile == null) continue;
      posts.insert(0, {
        'id': 'demo-post-${p['id']}',
        'author': {
          'id': profile['id'],
          'displayName': profile['displayName'],
          'username': profile['username'],
          'version': 1,
        },
        'participation': publicDraft(p),
        'publishedAt': now.toIso8601String(),
        'version': 1,
        'likeCount': likes['demo-post-${p['id']}']?.length ?? 0,
        'commentCount': 0,
        'likedByMe': likes['demo-post-${p['id']}']?.contains(email) ?? false,
      });
    }
    return posts;
  }

  /// Fictional public reviews. The contract's Review has no author, so the
  /// demonstration adds `authorName` and `createdAt` only for presentation.
  List<Map<String, dynamic>> demoReviews(String editionId) {
    final seed = int.tryParse(editionId.replaceAll(RegExp(r'\D'), '')) ?? 1;
    const names = [
      'Juliana Martins',
      'Rafael Souza',
      'Camila Ribeiro',
      'Bruno Alves',
      'Patrícia Lima',
      'Thiago Rocha',
    ];
    const texts = [
      'Prova sensacional! Organização impecável, percurso lindo pelo Ibirapuera. A medalha está uma das mais bonitas da série!',
      'Ótima estrutura e hidratação bem distribuída. Voltarei no próximo ano.',
      'Percurso plano e rápido. Kit simples, mas a prova compensa.',
      'Muita gente e largada um pouco apertada, mas o astral é incrível.',
      'Medalha linda e custo-benefício justo.',
      'Segurança reforçada e ótimo atendimento na chegada.',
    ];
    return [
      for (var i = 0; i < names.length; i++)
        {
          'participationId': 'demo-review-$editionId-$i',
          'version': 1,
          'moderationState': 'valid',
          'authorName': names[i],
          'createdAt': DateTime.now()
              .toUtc()
              .subtract(Duration(days: 4 + i * 6))
              .toIso8601String(),
          'comment': texts[i],
          'ratings': {
            'organization': 4 + (seed + i) % 2,
            'course': 4 + (seed + i + 1) % 2,
            'kit': 3 + (seed + i) % 3,
            'medal': 4 + (seed + i + 2) % 2,
            'hydration': 4 + (seed + i + 1) % 2,
            'facilities': 3 + (seed + i + 1) % 3,
            'safety': 4 + (seed + i) % 2,
            'valueForMoney': 3 + (seed + i + 2) % 3,
          },
        },
    ];
  }

  JsonReply failure(String code, [int status = 400]) =>
      JsonReply(status, {'code': code, '__type': code});

  Future<JsonReply> call(
    Uri uri,
    String method,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    final data = body ?? {};
    final operation = headers['X-Amz-Target']?.split('.').last;
    if (operation != null) {
      final email = data['Username'] as String?;
      final account = accounts[email];
      switch (operation) {
        case 'SignUp':
          if (email == null || !email.endsWith('.test')) {
            return failure('INVALID_INPUT');
          }
          if (account != null) return failure('UsernameExistsException');
          final password = data['Password'] as String;
          if (password.length < 12 ||
              !RegExp(r'[A-Z]').hasMatch(password) ||
              !RegExp(r'[a-z]').hasMatch(password) ||
              !RegExp(r'[0-9]').hasMatch(password) ||
              !RegExp(r'[^a-zA-Z0-9]').hasMatch(password)) {
            return failure('InvalidPasswordException');
          }
          accounts[email] = {
            'password': password,
            'confirmed': false,
            'admitted': false,
          };
          return const JsonReply(200, {});
        case 'ConfirmSignUp':
          if (data['ConfirmationCode'] != '123456' || account == null) {
            return failure('CodeMismatchException');
          }
          account['confirmed'] = true;
          return const JsonReply(200, {});
        case 'ResendConfirmationCode' || 'ForgotPassword':
          return const JsonReply(200, {});
        case 'ConfirmForgotPassword':
          if (data['ConfirmationCode'] != '123456' || account == null) {
            return failure('CodeMismatchException');
          }
          account['password'] = data['Password'];
          return const JsonReply(200, {});
        case 'InitiateAuth':
          final params = data['AuthParameters'] as Map<String, dynamic>;
          final user = accounts[params['USERNAME']];
          if (user == null || user['password'] != params['PASSWORD']) {
            return failure('NotAuthorizedException');
          }
          if (user['confirmed'] != true) {
            return failure('UserNotConfirmedException');
          }
          final token = 'demo-session-${++sequence}';
          sessions[token] = params['USERNAME'] as String;
          return JsonReply(200, {
            'AuthenticationResult': {'AccessToken': token},
          });
        case 'GlobalSignOut':
          sessions.remove(data['AccessToken']);
          return const JsonReply(200, {});
      }
      return failure('INVALID_INPUT');
    }
    final email =
        sessions[headers['Authorization']?.replaceFirst('Bearer ', '')];
    if (email == null) return failure('INVALID_TOKEN', 401);
    final account = accounts[email]!;
    if (account['deleted'] == true) return failure('ACCOUNT_UNAVAILABLE', 403);
    if (uri.path == '/me') {
      if (method == 'GET') {
        return account['profile'] == null
            ? failure('PROFILE_NOT_FOUND', 404)
            : JsonReply(
                200,
                Map<String, dynamic>.from(account['profile'] as Map),
              );
      }
      if (method == 'PUT') {
        if (account['profile'] != null) return failure('PROFILE_EXISTS', 409);
        final username = (data['username'] as String).toLowerCase();
        if (accounts.values.any(
          (a) => (a['profile'] as Map?)?['username'] == username,
        )) {
          return failure('USERNAME_TAKEN', 409);
        }
        final profile = {
          'id': 'demo-profile-${++sequence}',
          'displayName': data['displayName'],
          'username': username,
          'version': 1,
        };
        account['profile'] = profile;
        return JsonReply(201, profile);
      }
      if (method == 'DELETE') {
        account['deleted'] = true;
        return const JsonReply(202, {'accessBlocked': true});
      }
    }
    final full =
        accounts.values.where((a) => a['admitted'] == true).length >= capacity;
    if (uri.path == '/beta/status') {
      return JsonReply(200, {
        'myStatus': account['admitted'] == true
            ? 'admitted'
            : account['waiting'] == true
            ? 'waiting'
            : 'not_admitted',
        'admissionsOpen': !full,
      });
    }
    if (uri.path == '/beta/admissions' || uri.path == '/beta/waitlist') {
      final birth = DateTime.tryParse(data['birthDate'] as String? ?? '');
      final now = DateTime.now();
      final cutoff = DateTime(now.year - 18, now.month, now.day);
      if (birth == null ||
          birth.isAfter(cutoff) ||
          data['declaresAdult'] != true) {
        return failure('NOT_ELIGIBLE', 422);
      }
      if (uri.path == '/beta/waitlist') {
        if (!full) return failure('CAPACITY_AVAILABLE', 409);
        account['waiting'] = true;
        return const JsonReply(201, {'state': 'waiting'});
      }
      if (full && account['admitted'] != true) return failure('BETA_FULL', 409);
      account['admitted'] = true;
      return const JsonReply(201, {'admitted': true});
    }
    if (uri.path == '/me/waitlist' && method == 'DELETE') {
      account['waiting'] = false;
      return const JsonReply(204, {});
    }
    if (account['admitted'] != true) {
      return failure('BETA_ADMISSION_REQUIRED', 403);
    }
    if (uri.path == '/uploads' && method == 'POST') {
      final id = 'demo-upload-${++sequence}';
      uploads[id] = {
        'owner': email,
        'contentType': data['contentType'],
        'sizeBytes': data['sizeBytes'],
      };
      return JsonReply(201, {
        'uploadId': id,
        'uploadUrl': 'https://upload.demo.invalid/$id',
        'uploadMethod': 'PUT',
        'uploadHeaders': {'Content-Type': data['contentType']},
      });
    }
    if (uri.path.startsWith('/uploads/') && uri.path.endsWith('/finalize')) {
      final id = uri.path.split('/')[2];
      final upload = uploads[id];
      if (upload == null || upload['owner'] != email) {
        return failure('UPLOAD_NOT_FOUND', 404);
      }
      if (upload['uploaded'] != true) {
        return failure('OBJECT_NOT_UPLOADED', 409);
      }
      return JsonReply(200, {
        'uploadId': id,
        'state': 'valid',
        'imageReference': 'img_$id',
      });
    }
    if (uri.path == '/editions') {
      final q = uri.queryParameters;
      final limit = int.tryParse(q['limit'] ?? '') ?? 20;
      final start =
          int.tryParse(q['cursor']?.replaceFirst('demo-', '') ?? '') ?? 0;
      var result = editions.where((e) {
        if (q['city'] != null &&
            normalize(e['city'] as String) != normalize(q['city']!)) {
          return false;
        }
        if (q['state'] != null && e['state'] != q['state']!.toUpperCase()) {
          return false;
        }
        if (q['namePrefix'] != null &&
            !normalize(e['name'] as String)
                .startsWith(normalize(q['namePrefix']!))) {
          return false;
        }
        if (q['dateFrom'] != null &&
            (e['date'] as String).compareTo(q['dateFrom']!) < 0) {
          return false;
        }
        if (q['dateTo'] != null &&
            (e['date'] as String).compareTo(q['dateTo']!) > 0) {
          return false;
        }
        if (q['distanceKm'] != null &&
            !(e['distances'] as List).any(
              (d) => d['kilometers'] == num.tryParse(q['distanceKm']!),
            )) {
          return false;
        }
        return true;
      }).toList();
      final byName =
          q['namePrefix'] != null &&
          q['dateFrom'] == null &&
          q['dateTo'] == null;
      result.sort(
        (a, b) => '${a[byName ? 'name' : 'date']}#${a['id']}'.compareTo(
          '${b[byName ? 'name' : 'date']}#${b['id']}',
        ),
      );
      return JsonReply(200, {
        'items': result.skip(start).take(limit).toList(),
        if (start + limit < result.length)
          'nextCursor': 'demo-${start + limit}',
      });
    }
    if (uri.path == '/participations' && method == 'POST') {
      final edition = editions
          .where((e) => e['id'] == data['editionId'])
          .firstOrNull;
      if (edition == null) return failure('EDITION_NOT_FOUND', 404);
      if (edition['status'] == 'archived') {
        return failure('EDITION_ARCHIVED', 409);
      }
      if (!(edition['distances'] as List).any(
        (d) => d['id'] == data['distanceId'],
      )) {
        return failure('DISTANCE_NOT_IN_EDITION', 422);
      }
      if (participations.values.any(
        (p) => p['owner'] == email && p['editionId'] == data['editionId'],
      )) {
        return failure('PARTICIPATION_EXISTS', 409);
      }
      final id = 'demo-participation-${++sequence}';
      final draft = <String, dynamic>{
        'id': id,
        'owner': email,
        'editionId': data['editionId'],
        'distanceId': data['distanceId'],
        'state': 'draft',
        'version': 1,
        'showTime': true,
        'showPlacement': true,
      };
      participations[id] = draft;
      return JsonReply(201, publicDraft(draft));
    }
    if (uri.path == '/me/participations' && method == 'GET') {
      return JsonReply(200, {
        'items': participations.values
            .where((p) => p['owner'] == email)
            .map(publicDraft)
            .toList(),
      });
    }
    if (uri.path.startsWith('/participations/') &&
        uri.path.endsWith('/complete') &&
        method == 'POST') {
      final id = uri.path.split('/')[2];
      final draft = participations[id];
      if (draft == null || draft['owner'] != email) {
        return failure('PARTICIPATION_NOT_FOUND', 404);
      }
      if (draft['state'] != 'draft') {
        return failure('PARTICIPATION_NOT_DRAFT', 409);
      }
      if (data['expectedVersion'] != draft['version']) {
        return failure('VERSION_CONFLICT', 409);
      }
      final ratings = data['ratings'] as Map<String, dynamic>?;
      if (data['declaredCompleted'] != true || ratings?.length != 8) {
        return failure('INVALID_INPUT', 422);
      }
      final reference = data['medalImageReference'] as String?;
      if (reference == null ||
          !uploads.keys.any((id) => 'img_$id' == reference)) {
        return failure('IMAGE_NOT_VALID', 422);
      }
      draft
        ..['state'] = 'completed'
        ..['version'] = (draft['version'] as int) + 1
        ..['medalImageReference'] = reference
        ..['publishToFeed'] = data['publishToFeed']
        ..['review'] = {
          'participationId': id,
          'version': 1,
          'ratings': Map<String, dynamic>.from(ratings!),
          'moderationState': 'valid',
          if (data['comment'] != null) 'comment': data['comment'],
        };
      return JsonReply(200, publicDraft(draft));
    }
    if (uri.path.startsWith('/participations/') &&
        uri.path.endsWith('/review')) {
      final id = uri.path.split('/')[2];
      final participation = participations[id];
      final review = participation?['review'] as Map<String, dynamic>?;
      if (participation == null ||
          participation['owner'] != email ||
          review == null) {
        return failure('REVIEW_NOT_FOUND', 404);
      }
      if (method == 'GET') {
        return JsonReply(200, Map<String, dynamic>.from(review));
      }
      if (method == 'PUT') {
        if (data['expectedVersion'] != review['version'] ||
            (data['ratings'] as Map?)?.length != 8) {
          return failure('VERSION_CONFLICT', 409);
        }
        review
          ..['version'] = (review['version'] as int) + 1
          ..['ratings'] = Map<String, dynamic>.from(data['ratings'] as Map);
        if (data['comment'] == null) {
          review.remove('comment');
        } else {
          review['comment'] = data['comment'];
        }
        return JsonReply(200, Map<String, dynamic>.from(review));
      }
    }
    if (uri.path.startsWith('/participations/') && method == 'DELETE') {
      final id = uri.path.split('/')[2];
      final participation = participations[id];
      if (participation == null || participation['owner'] != email) {
        return failure('PARTICIPATION_NOT_FOUND', 404);
      }
      final expected = int.tryParse(
        uri.queryParameters['expectedVersion'] ?? '',
      );
      if (expected != participation['version']) {
        return failure('VERSION_CONFLICT', 409);
      }
      participation['state'] = 'deleted';
      return const JsonReply(202, {
        'operationId': 'demo-erasure',
        'state': 'pending',
        'publiclyHidden': true,
      });
    }
    if (uri.path.startsWith('/participations/')) {
      final id = uri.path.split('/').last;
      final draft = participations[id];
      if (draft == null || draft['owner'] != email) {
        return failure('PARTICIPATION_NOT_FOUND', 404);
      }
      if (method == 'GET') return JsonReply(200, publicDraft(draft));
      if (method == 'PATCH') {
        if (data['expectedVersion'] != draft['version']) {
          return failure('VERSION_CONFLICT', 409);
        }
        for (final field in [
          'timeSeconds',
          'placement',
          'bibNumber',
          'showTime',
          'showPlacement',
        ]) {
          if (!data.containsKey(field)) continue;
          if (data[field] == null) {
            draft.remove(field);
          } else {
            draft[field] = data[field];
          }
        }
        draft['version'] = (draft['version'] as int) + 1;
        return JsonReply(200, publicDraft(draft));
      }
    }
    if (uri.path == '/feed' && method == 'GET') {
      return JsonReply(200, {'items': demoFeed(email)});
    }
    final like = RegExp(r'^/posts/([^/]+)/like$').firstMatch(uri.path);
    if (like != null && (method == 'PUT' || method == 'DELETE')) {
      final postId = like.group(1)!;
      final likers = likes.putIfAbsent(postId, () => <String>{});
      method == 'PUT' ? likers.add(email) : likers.remove(email);
      return JsonReply(200, {'postId': postId, 'likedByMe': method == 'PUT'});
    }
    if (uri.path == '/me/wishlist' && method == 'GET') {
      return JsonReply(200, {
        'items': [
          for (final id in ['demo-13', 'demo-15', 'demo-18'])
            {
              'edition': editions.firstWhere((e) => e['id'] == id),
              'savedAt': DateTime.now().toUtc().toIso8601String(),
            },
        ],
      });
    }
    final reviews = RegExp(r'^/editions/([^/]+)/reviews$').firstMatch(uri.path);
    if (reviews != null && method == 'GET') {
      final known = editions.any((e) => e['id'] == reviews.group(1));
      return known
          ? JsonReply(200, {'items': demoReviews(reviews.group(1)!)})
          : failure('EDITION_NOT_FOUND', 404);
    }
    final matches = editions.where((e) => uri.path == '/editions/${e['id']}');
    return matches.isEmpty
        ? failure('EDITION_NOT_FOUND', 404)
        : JsonReply(200, matches.first);
  }

  String normalize(String text) => text
      .toLowerCase()
      .replaceAll('ã', 'a')
      .replaceAll('á', 'a')
      .replaceAll('ç', 'c')
      .replaceAll('é', 'e')
      .replaceAll('ó', 'o')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  Map<String, dynamic> publicDraft(Map<String, dynamic> draft) => {
    for (final entry in draft.entries)
      if (entry.key != 'owner') entry.key: entry.value,
  };

  Future<int> putBytes(
    Uri uri,
    String method,
    Map<String, String> headers,
    List<int> bytes,
  ) async {
    final upload = uploads[uri.pathSegments.last];
    if (uri.host != 'upload.demo.invalid' ||
        method != 'PUT' ||
        upload == null) {
      return 404;
    }
    if (headers['Content-Type'] != upload['contentType'] ||
        bytes.length != upload['sizeBytes']) {
      return 409;
    }
    upload['uploaded'] = true;
    return 200;
  }
}
