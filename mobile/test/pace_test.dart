import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';

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

  test(
    'pace da inscrição: o guardado, ou o calculado pelo tempo e pela distância',
    () {
      const edition = {
        'distances': [
          {'id': '10k', 'kilometers': 10},
        ],
      };
      // Guardado: vale o guardado.
      const stored = RaceRecord({
        'id': 'p1',
        'distanceId': '10k',
        'timeSeconds': 3000,
        'paceSecondsPerKm': 310,
      }, edition);
      expect(stored.paceSecondsPerKm, 310);
      // Sem pace guardado, mas com tempo e distância: calculado (50:00 em 10 km = 5:00 por km).
      const old = RaceRecord({
        'id': 'p2',
        'distanceId': '10k',
        'timeSeconds': 3000,
      }, edition);
      expect(old.paceSecondsPerKm, 300);
      // Sem tempo, sem distância ou fora do que se aceita: nada.
      expect(
        const RaceRecord({
          'id': 'p3',
          'distanceId': '10k',
        }, edition).paceSecondsPerKm,
        isNull,
      );
      expect(
        const RaceRecord({
          'id': 'p4',
          'timeSeconds': 3000,
        }, null).paceSecondsPerKm,
        isNull,
      );
      expect(
        const RaceRecord({
          'id': 'p5',
          'distanceId': '10k',
          'timeSeconds': 20,
        }, edition).paceSecondsPerKm,
        isNull,
      );
    },
  );
}
