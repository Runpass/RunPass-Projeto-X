import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';

Map<String, dynamic> comment(String id, String text, {bool mine = false}) => {
  'id': id,
  'editionId': 'E1',
  'text': text,
  'createdAt': '2026-11-14T15:00:00Z',
  'mine': mine,
  'author': {'id': 'u$id', 'displayName': 'Pessoa $id', 'username': 'p$id'},
};

class Server {
  final List<Map<String, dynamic>> comments;
  final List<String> calls = [];
  Server(this.comments);
  String? postError;
  List<Map<String, dynamic>> reviews = [];
}

Future<(IdentityGateway, Server)> setup(
  List<Map<String, dynamic>> initial,
) async {
  final server = Server(initial);
  final gateway = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      server.calls.add('$method ${uri.path}');
      if (uri.path == '/editions/E1') {
        return const JsonReply(200, {
          'id': 'E1',
          'name': '[FICTICIA] Corrida',
          'date': '2024-09-22',
          'city': 'São Paulo',
          'state': 'SP',
          'status': 'past',
          'version': 1,
          'distances': [
            {'id': '5k', 'kilometers': 5},
          ],
        });
      }
      if (uri.path == '/editions/E1/reviews') {
        return JsonReply(200, {'items': server.reviews, 'summary': null});
      }
      if (uri.path == '/editions/E1/comments' && method == 'GET') {
        return JsonReply(200, {'items': server.comments});
      }
      if (uri.path == '/editions/E1/comments' && method == 'POST') {
        if (server.postError != null) {
          return JsonReply(429, {'code': server.postError});
        }
        final made = comment(
          'novo',
          (body! as Map)['text'] as String,
          mine: true,
        );
        server.comments.insert(0, made);
        return JsonReply(201, made);
      }
      if (uri.path.startsWith('/edition-comments/') && method == 'DELETE') {
        final id = uri.pathSegments.last;
        server.comments.removeWhere((c) => c['id'] == id);
        return JsonReply(200, {'id': id, 'deleted': true});
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return (gateway, server);
}

Future<void> openReviews(WidgetTester tester, IdentityGateway gateway) async {
  tester.view.physicalSize = const Size(800, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: EditionScreen(gateway: gateway, editionId: 'E1'),
    ),
  );
  await tester.pumpAndSettle();
  // Os comentários ficam na aba principal (Sobre), embaixo das informações.
}

void main() {
  testWidgets(
    'a aba Sobre lista os comentários da corrida e mostra a caixa para comentar',
    (tester) async {
      final (gateway, server) = await setup([
        comment('a', 'Percurso plano e bem sinalizado'),
        comment('b', 'Chegada animada', mine: true),
      ]);
      await openReviews(tester, gateway);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('edition-comments-title')),
        200,
        scrollable: list,
      );
      expect(find.text('Comentários da corrida'), findsOneWidget);
      expect(find.byKey(const Key('edition-comment-field')), findsOneWidget);
      expect(find.text('Percurso plano e bem sinalizado'), findsOneWidget);
      expect(find.text('Pessoa a'), findsOneWidget);
      // Só o meu comentário tem a lixeira.
      expect(find.byKey(const Key('edition-comment-delete-a')), findsNothing);
      expect(find.byKey(const Key('edition-comment-delete-b')), findsOneWidget);
      expect(server.calls, contains('GET /editions/E1/comments'));
    },
  );

  testWidgets(
    'qualquer pessoa comenta: o comentário entra no topo e a caixa limpa',
    (tester) async {
      final (gateway, server) = await setup([
        comment('a', 'Comentário antigo'),
      ]);
      await openReviews(tester, gateway);
      final list = find.byType(Scrollable).first;
      final field = find.byKey(const Key('edition-comment-field'));
      await tester.scrollUntilVisible(field, 200, scrollable: list);
      await tester.enterText(field, 'Corri esta e recomendo!');
      await tester.tap(find.byKey(const Key('edition-comment-send')));
      await tester.pumpAndSettle();
      expect(
        server.calls.where((c) => c == 'POST /editions/E1/comments').length,
        1,
      );
      expect(find.text('Corri esta e recomendo!'), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      // vazio não envia
      await tester.tap(find.byKey(const Key('edition-comment-send')));
      await tester.pumpAndSettle();
      expect(
        server.calls.where((c) => c == 'POST /editions/E1/comments').length,
        1,
      );
    },
  );

  testWidgets('apagar o meu comentário pede confirmação e some da lista', (
    tester,
  ) async {
    final (gateway, server) = await setup([
      comment('b', 'Meu comentário', mine: true),
    ]);
    await openReviews(tester, gateway);
    final list = find.byType(Scrollable).first;
    final trash = find.byKey(const Key('edition-comment-delete-b'));
    await tester.scrollUntilVisible(trash, 200, scrollable: list);
    await tester.tap(trash);
    await tester.pumpAndSettle();
    expect(find.text('Apagar comentário?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(server.calls.any((c) => c.startsWith('DELETE')), isFalse);
    await tester.tap(trash);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('edition-comment-delete-confirm')));
    await tester.pumpAndSettle();
    // Some na hora, com "Desfazer"; o DELETE só vai depois da janela.
    expect(find.text('Meu comentário'), findsNothing);
    expect(find.byKey(const Key('undo-delete')), findsOneWidget);
    expect(server.calls.any((c) => c.startsWith('DELETE')), isFalse);
    await tester.pump(const Duration(seconds: 7)); // fecha a janela do Desfazer
    await tester.pumpAndSettle();
    expect(server.calls, contains('DELETE /edition-comments/b'));
    expect(find.byKey(const Key('edition-comments-empty')), findsOneWidget);
  });

  testWidgets('no limite de comentários a pessoa recebe o aviso do que fazer', (
    tester,
  ) async {
    final (gateway, server) = await setup(const []);
    server.postError = 'COMMENT_LIMIT_REACHED';
    await openReviews(tester, gateway);
    final list = find.byType(Scrollable).first;
    final field = find.byKey(const Key('edition-comment-field'));
    await tester.scrollUntilVisible(field, 200, scrollable: list);
    await tester.enterText(field, 'mais um');
    await tester.tap(find.byKey(const Key('edition-comment-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('máximo de comentários'), findsOneWidget);
    expect(
      tester.widget<TextField>(field).controller!.text,
      'mais um',
    ); // não perde o texto
  });

  testWidgets(
    'o comentário feito na avaliação (no cadastro) também aparece nos comentários da corrida',
    (tester) async {
      final (gateway, server) = await setup([]);
      server.reviews = [
        {
          'participationId': 'p1',
          'version': 1,
          'ratings': {'organization': 5},
          'moderationState': 'valid',
          'comment': 'Kit entregue rápido [FICTICIA]',
          'authorName': 'Pessoa da avaliação',
          'createdAt': '2026-11-14T15:00:00Z',
        },
        {
          'participationId': 'p2',
          'version': 1,
          'ratings': {'organization': 4},
          'moderationState': 'valid',
          'authorName': 'Sem comentário',
          'createdAt': '2026-11-13T15:00:00Z',
        },
      ];
      await openReviews(tester, gateway);
      await tester.scrollUntilVisible(
        find.byKey(const Key('edition-comments-title')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const Key('edition-review-comment-p1')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('edition-review-comment-p2')), findsNothing);
      expect(find.byKey(const Key('edition-comments-empty')), findsNothing);
    },
  );
}
