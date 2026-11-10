import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/agenda.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/identity_gateway.dart';

import 'catalog_test.dart' show entry, signed;

Map<String, dynamic> upcoming(String id, {String date = '2099-05-01'}) => {
  ...entry(id),
  'id': 'E$id',
  'name': 'Corrida $id com um nome bem comprido para quebrar linhas no banner',
  'date': date,
  'status': 'upcoming',
};

void main() {
  void big(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('o título longo do banner não cobre os ícones', (tester) async {
    tester.view.physicalSize = const Size(
      390,
      2000,
    ); // largura de iPhone: o título ocupa 3+ linhas
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions/EA') return JsonReply(200, upcoming('A'));
      if (uri.path.startsWith('/me/race-plans/')) {
        return const JsonReply(404, {'code': 'PLAN_NOT_FOUND'});
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'EA'),
      ),
    );
    await tester.pumpAndSettle();
    final icons = tester.getRect(find.byTooltip('Voltar'));
    final title = tester.getRect(find.textContaining('CORRIDA A COM UM NOME'));
    expect(
      title.top >= icons.bottom,
      isTrue,
      reason: 'título abaixo da linha dos ícones',
    );
    final heart = tester.getRect(find.byKey(const Key('hero-wanted')));
    expect(title.top >= heart.bottom, isTrue);
  });

  testWidgets('quero correr e inscrito: marca, troca e desmarca com o toque', (
    tester,
  ) async {
    big(tester);
    final calls = <String>[];
    Map<String, dynamic>? plan;
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions/EA') return JsonReply(200, upcoming('A'));
      if (uri.path == '/me/race-plans/EA') {
        calls.add('$method ${body ?? ''}');
        if (method == 'PUT') {
          plan = {'editionId': 'EA', 'version': 1, ...?body};
          return JsonReply(200, plan!);
        }
        if (method == 'DELETE') {
          plan = null;
          return const JsonReply(204, {});
        }
        return plan == null
            ? const JsonReply(404, {'code': 'PLAN_NOT_FOUND'})
            : JsonReply(200, plan!);
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'EA'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Criar rascunho'), findsNothing);
    expect(find.byKey(const Key('plan-wanted')), findsOneWidget);
    expect(find.byKey(const Key('plan-registered')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('plan-wanted')));
    await tester.tap(find.byKey(const Key('plan-wanted')));
    await tester.pumpAndSettle();
    expect(plan?['status'], 'wanted');
    expect(find.textContaining('em Desejadas'), findsOneWidget);
    await tester.tap(find.byKey(const Key('plan-registered')));
    await tester.pumpAndSettle();
    expect(plan?['status'], 'registered');
    expect(find.textContaining('em Inscritas'), findsOneWidget);
    await tester.tap(find.byKey(const Key('plan-registered')));
    await tester.pumpAndSettle();
    expect(plan, isNull);
    expect(find.byKey(const Key('plan-note')), findsNothing);
    // O coração do banner faz o mesmo que "Quero correr".
    await tester.tap(find.byKey(const Key('hero-wanted')));
    await tester.pumpAndSettle();
    expect(plan?['status'], 'wanted');
  });

  testWidgets('corrida que já passou só oferece "Já corri"', (tester) async {
    big(tester);
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions/EA') {
        return JsonReply(200, {
          ...upcoming('A', date: '2020-01-01'),
          'status': 'past',
        });
      }
      if (uri.path.startsWith('/me/race-plans/')) {
        return const JsonReply(404, {'code': 'PLAN_NOT_FOUND'});
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'EA'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('10K'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plan-wanted')), findsNothing);
    expect(find.byKey(const Key('plan-registered')), findsNothing);
    expect(find.byKey(const Key('plan-ran')), findsOneWidget);
  });

  testWidgets('agenda separa desejadas e inscritas e permite mover e tirar', (
    tester,
  ) async {
    big(tester);
    final plans = <Map<String, dynamic>>[
      {
        'editionId': 'EA',
        'status': 'wanted',
        'version': 1,
        'edition': upcoming('A'),
      },
      {
        'editionId': 'EB',
        'status': 'registered',
        'version': 1,
        'edition': upcoming('B', date: '2099-03-01'),
      },
    ];
    final calls = <String>[];
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/me/race-plans' && method == 'GET') {
        return JsonReply(200, {'items': plans});
      }
      if (uri.path.startsWith('/me/race-plans/')) {
        final id = uri.pathSegments.last;
        calls.add('$method $id ${body?['status'] ?? ''}');
        final i = plans.indexWhere((p) => p['editionId'] == id);
        if (method == 'DELETE') {
          plans.removeAt(i);
        }
        if (method == 'PUT') {
          plans[i] = {...plans[i], 'status': body!['status']};
        }
        return method == 'DELETE'
            ? const JsonReply(204, {})
            : JsonReply(200, plans[i]);
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: AgendaScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-EA')), findsOneWidget);
    expect(find.byKey(const Key('agenda-EB')), findsNothing);
    await tester.tap(find.byKey(const Key('agenda-tab-registered')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-EB')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agenda-tab-wanted')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('agenda-menu-EA')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marcar como inscrito'));
    await tester.pumpAndSettle();
    expect(calls.last, 'PUT EA registered');
    expect(find.byKey(const Key('agenda-empty-wanted')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agenda-tab-registered')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-EA')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agenda-menu-EB')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tirar da agenda'));
    await tester.pumpAndSettle();
    expect(calls.last, 'DELETE EB ');
    expect(find.byKey(const Key('agenda-EB')), findsNothing);
  });

  testWidgets('ao digitar o nome, sugere as corridas para escolher uma', (
    tester,
  ) async {
    big(tester);
    final calls = <Uri>[];
    final gateway = await signed((uri, method, headers, body) async {
      calls.add(uri);
      if (uri.path == '/editions' && uri.queryParameters['q'] != null) {
        return JsonReply(200, {
          'items': [
            {...entry('A'), 'id': 'EA', 'name': 'Circuito das Estações Verão'},
            {
              ...entry('B'),
              'id': 'EB',
              'name': 'Circuito das Estações Primavera',
            },
          ],
        });
      }
      if (uri.path == '/editions/EB') {
        return JsonReply(200, {
          ...entry('B'),
          'id': 'EB',
          'name': 'Circuito das Estações Primavera',
        });
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('catalog-phrase')), 'circuito');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-suggestions')), findsOneWidget);
    expect(find.text('Encontramos 2 corridas. Escolha uma:'), findsOneWidget);
    expect(calls.any((u) => u.queryParameters['q'] == 'circuito'), isTrue);
    await tester.tap(find.byKey(const Key('suggestion-EB')));
    await tester.pumpAndSettle();
    expect(find.byType(EditionScreen), findsOneWidget);
    expect(find.text('CIRCUITO DAS ESTAÇÕES PRIMAVERA'), findsOneWidget);
  });

  testWidgets(
    'texto curto não pede sugestões e a falha delas não mostra erro',
    (tester) async {
      big(tester);
      final calls = <Uri>[];
      final gateway = await signed((uri, method, headers, body) async {
        calls.add(uri);
        if (uri.queryParameters['q'] != null) {
          return const JsonReply(503, {'code': 'X'});
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('catalog-phrase')), 'c');
      await tester.pump(const Duration(milliseconds: 600));
      expect(calls.where((u) => u.queryParameters['q'] != null), isEmpty);
      await tester.enterText(find.byKey(const Key('catalog-phrase')), 'cir');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('catalog-suggestions')), findsNothing);
      expect(find.byKey(const Key('catalog-error')), findsNothing);
    },
  );

  testWidgets(
    'a home mostra o ícone da agenda dentro da tela e abre a agenda',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844); // largura de iPhone
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/me') {
          return const JsonReply(200, {
            'id': 'me',
            'displayName': 'Eu',
            'username': 'eu',
            'version': 1,
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      final icon = find.byKey(const Key('home-agenda'));
      expect(icon, findsOneWidget);
      final rect = tester.getRect(icon);
      expect(
        rect.left >= 0 && rect.right <= 390,
        isTrue,
        reason: 'ícone visível na largura do iPhone',
      );
      await tester.tap(icon);
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(find.text('Minha agenda'), findsOneWidget);
    },
  );
}
