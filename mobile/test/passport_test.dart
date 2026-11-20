import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/city_photos.dart';
import 'package:runpass/my_races.dart';

RaceRecord race(String id, String? city, String? state) => RaceRecord({
  'id': id,
}, city == null ? null : {'city': city, 'state': state});

void main() {
  test(
    'cidades conquistadas: sem repetir, da mais recente para a mais antiga',
    () {
      // A lista de corridas já vem da mais recente para a mais antiga.
      final cities = conqueredCities([
        race('1', 'Santos', 'SP'),
        race('2', 'São Paulo', 'SP'),
        race('3', 'SANTOS', 'SP'), // mesma cidade, escrita de outro jeito
        race('4', null, null), // sem cidade: não conta
        race('5', 'Campinas', 'SP'),
      ]);
      expect(cities, [
        ('Santos', 'SP'),
        ('São Paulo', 'SP'),
        ('Campinas', 'SP'),
      ]);
    },
  );

  test('total do passaporte nunca fica abaixo das conquistadas', () {
    final comFoto = cityPhotoList.length;
    // Só cidades que já têm foto: o total é o número de cidades com foto.
    expect(passportTotal([('São Paulo', 'SP')]), comFoto);
    // Cidade sem foto entra no total (conquistada, ainda sem foto).
    expect(passportTotal([('Cidade Sem Foto', 'SP')]), comFoto + 1);
    expect(passportTotal(const []), comFoto);
  });

  test('texto do passaporte: N de M cidades conquistadas', () {
    expect(passportSummary(6, 26), '6 de 26 cidades conquistadas');
    expect(passportSummary(0, 26), '0 de 26 cidades conquistadas');
  });

  testWidgets('miniatura do passaporte: foto da cidade ou arte com a inicial', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              PassportCity(city: 'São Paulo', state: 'SP'),
              PassportCity(city: 'Cidade Sem Foto', state: 'SP'),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('passport-photo-São Paulo')), findsOneWidget);
    expect(
      find.byKey(const Key('passport-art-Cidade Sem Foto')),
      findsOneWidget,
    );
    expect(find.text('São Paulo'), findsOneWidget);
    expect(find.text('Cidade Sem Foto'), findsOneWidget);
    expect(find.text('C'), findsOneWidget); // a inicial na arte
  });
}
