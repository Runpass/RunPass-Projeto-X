import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/post_card.dart';

void main() {
  test('pace em min:s por km, opcional e com limites', () {
    expect(parsePace(''), isNull);
    expect(parsePace('5:30'), 330);
    expect(parsePace('5:30/km'), 330);
    expect(parsePace('12:05'), 725);
    expect(parsePace('0:30'), -1); // mais rápido que 1:00/km
    expect(parsePace('5:75'), -1);
    expect(parsePace('abc'), -1);
  });

  test('compartilhar leva km, tempo e pace na linha da imagem', () {
    const race = RaceRecord(
      {
        'id': 'p1',
        'editionId': 'E1',
        'distanceId': '10k',
        'timeSeconds': 3000,
        'paceSecondsPerKm': 300,
      },
      {
        'distances': [
          {'id': '10k', 'kilometers': 10},
        ],
      },
    );
    expect(shareLineOf(race), '10 km · 50:00 · 5:00/km');
    expect(
      shareLineOf(const RaceRecord({'id': 'p2', 'timeSeconds': 3000}, null)),
      '50:00',
    );
  });
}
