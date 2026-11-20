import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/my_races.dart';

FeedEntry entry({
  String? city,
  String? state,
  String id = 'p1',
  double? lat,
  double? lon,
}) => FeedEntry(
  postId: id,
  author: 'Corredor',
  username: 'corredor',
  title: 'Corrida',
  mine: false,
  race: RaceRecord(
    {'id': id, 'editionId': 'e-$id'},
    {
      'id': 'e-$id',
      'name': 'Corrida',
      'city': city,
      'state': state,
      'latitude': lat,
      'longitude': lon,
    },
  ),
);

// São Paulo (capital), Guarulhos (~20 km) e Rio de Janeiro (~360 km) — coordenadas reais.
const saoPauloLat = -23.5505, saoPauloLon = -46.6333;
const guarulhosLat = -23.4538, guarulhosLon = -46.5333;
const rioLat = -22.9068, rioLon = -43.1729;

void main() {
  group('feedFilterMatches', () {
    test('Todos, Amigos e Seguindo ja chegam filtrados pelo servidor', () {
      final e = entry(city: 'Qualquer', state: 'XX');
      for (final f in [
        FeedFilter.all,
        FeedFilter.friends,
        FeedFilter.network,
      ]) {
        expect(feedFilterMatches(f, e, null), isTrue);
      }
    });
  });

  group('cityScopedEntries (mesma cidade tem prioridade sobre o raio)', () {
    test('havendo publicacoes da mesma cidade, ignora as vizinhas', () {
      final sameCity = entry(id: 's1', city: 'São Paulo', state: 'SP');
      final nearby = entry(
        id: 'n1',
        city: 'Guarulhos',
        state: 'SP',
        lat: guarulhosLat,
        lon: guarulhosLon,
      );
      final me = {
        'city': 'São Paulo',
        'state': 'SP',
        'latitude': saoPauloLat,
        'longitude': saoPauloLon,
      };
      final shown = cityScopedEntries([sameCity, nearby], me);
      expect(shown.map((e) => e.postId), ['s1']);
    });

    test('sem a mesma cidade, cai para as vizinhas dentro do raio', () {
      final nearby = entry(
        id: 'n1',
        city: 'Guarulhos',
        state: 'SP',
        lat: guarulhosLat,
        lon: guarulhosLon,
      );
      final far = entry(
        id: 'f1',
        city: 'Rio de Janeiro',
        state: 'RJ',
        lat: rioLat,
        lon: rioLon,
      );
      final me = {
        'city': 'São Paulo',
        'state': 'SP',
        'latitude': saoPauloLat,
        'longitude': saoPauloLon,
      };
      final shown = cityScopedEntries([nearby, far], me);
      expect(shown.map((e) => e.postId), ['n1']);
    });

    test('sem coordenada no meu perfil, nao cai para o raio', () {
      final nearby = entry(
        id: 'n1',
        city: 'Guarulhos',
        state: 'SP',
        lat: guarulhosLat,
        lon: guarulhosLon,
      );
      final me = {'city': 'São Paulo', 'state': 'SP'};
      expect(cityScopedEntries([nearby], me), isEmpty);
    });

    test('sem coordenada na corrida, nao cai para o raio', () {
      final nearby = entry(id: 'n1', city: 'Guarulhos', state: 'SP');
      final me = {
        'city': 'São Paulo',
        'state': 'SP',
        'latitude': saoPauloLat,
        'longitude': saoPauloLon,
      };
      expect(cityScopedEntries([nearby], me), isEmpty);
    });
  });

  test('escopo enviado ao servidor por filtro', () {
    expect(feedScopeFor(FeedFilter.all), 'all');
    expect(feedScopeFor(FeedFilter.friends), 'friends');
    expect(feedScopeFor(FeedFilter.network), 'network');
    expect(feedScopeFor(FeedFilter.forYou), 'all');
  });

  test('rotulos dos filtros', () {
    expect(FeedFilter.all.label, 'Todos');
    expect(FeedFilter.friends.label, 'Amigos');
    expect(FeedFilter.network.label, 'Seguindo');
    expect(FeedFilter.forYou.label, 'Pra você');
    expect(FeedFilter.values.length, 4);
  });
}
