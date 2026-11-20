import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/city_photos.dart';
import 'package:runpass/edition_cards.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/settings.dart';

import 'catalog_test.dart' show entry, signed;

void main() {
  test('foto da cidade só para SP, sem acento nem caixa, e nunca inventa', () {
    expect(
      cityPhotoFor({'city': 'São Paulo', 'state': 'SP'})?.title,
      'Parque Ibirapuera',
    );
    expect(cityPhotoFor({'city': 'SAO PAULO', 'state': 'sp'}), isNotNull);
    expect(cityPhotoFor({'city': 'Guarujá', 'state': 'SP'}), isNotNull);
    // Outro estado, cidade sem foto ou sem cidade: sem foto.
    expect(cityPhotoFor({'city': 'São Paulo', 'state': 'RJ'}), isNull);
    expect(cityPhotoFor({'city': 'Campinas', 'state': 'SP'}), isNull);
    expect(
      cityPhotoFor({'city': 'Bertioga', 'state': 'SP'})?.isIllustration,
      isTrue,
    );
    expect(cityPhotoFor({'state': 'SP'}), isNull);
  });

  test(
    'toda foto tem licença livre sem crédito obrigatório e arquivo próprio',
    () {
      expect(cityPhotoList.where((p) => !p.isIllustration), hasLength(6));
      expect(cityPhotoList.where((p) => p.isIllustration), hasLength(10));
      for (final photo in cityPhotoList) {
        expect(
          photo.isIllustration ||
              photo.license == 'CC0 1.0' ||
              photo.license == 'Domínio público',
          isTrue,
          reason: photo.city,
        );
        expect(photo.author, isNotEmpty);
        if (!photo.isIllustration) {
          expect(photo.sourceUrl, startsWith('https://commons.wikimedia.org/'));
        }
        expect(photo.asset, startsWith('assets/cidades/'));
      }
    },
  );

  testWidgets('cartão sem banner usa a foto da cidade, sem texto por cima', (
    tester,
  ) async {
    final gateway = await signed(
      (uri, method, headers, body) async => const JsonReply(200, {}),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditionCompactCard(
            gateway: gateway,
            edition: {
              ...entry('A'),
              'id': 'EA',
              'city': 'Jundiaí',
              'state': 'SP',
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('race-art-photo')), findsOneWidget);
    // Foto limpa: nenhum texto por cima (nem cidade, nem local, nem rótulo).
    expect(find.byKey(const Key('race-art-city')), findsNothing);
    expect(find.byKey(const Key('race-art-venue')), findsNothing);
    expect(find.byKey(const Key('race-art-tag')), findsNothing);
    expect(find.text('foto da cidade'), findsNothing);
    expect(find.text('arte do app'), findsNothing);
    // A data fica num selo sobre a foto.
    expect(find.byKey(const Key('date-chip-EA')), findsOneWidget);
  });

  testWidgets('cidade sem foto continua com a arte do app', (tester) async {
    final gateway = await signed(
      (uri, method, headers, body) async => const JsonReply(200, {}),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditionCompactCard(
            gateway: gateway,
            edition: {
              ...entry('A'),
              'id': 'EA',
              'city': 'Campinas',
              'state': 'SP',
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('race-art-photo')), findsNothing);
    expect(find.text('arte do app'), findsOneWidget);
  });

  testWidgets('créditos das fotos listam autor e licença de cada cidade', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: PhotoCreditsScreen()));
    for (final photo in cityPhotoList) {
      final tile = find.byKey(Key('photo-credit-${photo.city}'));
      expect(tile, findsOneWidget);
      expect(
        find.descendant(
          of: tile,
          matching: find.textContaining(
            photo.isIllustration
                ? photo.license
                : 'Foto: ${photo.author} · ${photo.license}',
          ),
        ),
        findsOneWidget,
        reason: photo.city,
      );
    }
  });
}
