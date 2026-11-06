import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'friends.dart';
import 'identity_gateway.dart';
import 'main.dart' show IdentityScreen;
import 'runpass_theme.dart';

/// A completed participation joined with the official edition it refers to.
class RaceRecord {
  final Map<String, dynamic> participation;
  final Map<String, dynamic>? edition;
  const RaceRecord(this.participation, this.edition);

  String get name =>
      edition?['name'] as String? ?? 'Corrida ${participation['editionId']}';
  String? get date => edition?['date'] as String?;
  int? get year => date == null ? null : int.tryParse(date!.substring(0, 4));
  String get place {
    final city = edition?['city'] as String?;
    final state = edition?['state'] as String?;
    if (city == null) return '';
    return state == null ? city : '$city - $state';
  }

  double? get kilometers {
    for (final distance
        in (edition?['distances'] as List? ?? const []).cast<Map>()) {
      if (distance['id'] == participation['distanceId']) {
        return (distance['kilometers'] as num?)?.toDouble();
      }
    }
    return null;
  }

  num? get timeSeconds => participation['timeSeconds'] as num?;
  num? get paceSecondsPerKm => participation['paceSecondsPerKm'] as num?;
}

String two(int value) => value.toString().padLeft(2, '0');

String formatDuration(num seconds) {
  final total = seconds.round();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final rest = total % 60;
  return hours > 0
      ? '$hours:${two(minutes)}:${two(rest)}'
      : '${two(minutes)}:${two(rest)}';
}

String formatPace(num secondsPerKm) {
  final total = secondsPerKm.round();
  return '${total ~/ 60}:${two(total % 60)}/km';
}

String formatKilometers(double km) => km == km.roundToDouble()
    ? '${km.toInt()} km'
    : '${km.toStringAsFixed(1)} km';

String distanceLabel(double km) => '${km.round()}K';

/// Edition details by id. A lookup that fails is left out of the result.
Future<Map<String, Map<String, dynamic>>> loadEditions(
  IdentityGateway gateway,
  Iterable<String> ids,
) async {
  final editions = <String, Map<String, dynamic>>{};
  await Future.wait([
    for (final id in ids.toSet())
      () async {
        try {
          editions[id] = await gateway.request(
            '/editions/${Uri.encodeComponent(id)}',
          );
        } on Exception {
          // The caller still shows the item, only without edition details.
        }
      }(),
  ]);
  return editions;
}

String timeAgo(DateTime moment, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(moment);
  if (diff.inMinutes < 1) return 'agora';
  if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
  if (diff.inHours < 24) {
    return 'há ${diff.inHours} ${diff.inHours == 1 ? 'hora' : 'horas'}';
  }
  if (diff.inDays < 7) {
    return 'há ${diff.inDays} ${diff.inDays == 1 ? 'dia' : 'dias'}';
  }
  final weeks = diff.inDays ~/ 7;
  return 'há $weeks ${weeks == 1 ? 'semana' : 'semanas'}';
}

/// Placeholder for official medal art, which the API does not serve yet.
class MedalArt extends StatelessWidget {
  final double size;
  const MedalArt({super.key, this.size = 46});

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.emoji_events, size: size, color: const Color(0xffe8b23a));
}

/// Foto da medalha enviada pela pessoa. Pede um link curto e assinado ao servidor
/// (`GET /participations/{id}/image`); se nao houver foto ou a rede falhar, mostra o trofeu.
class MedalPhoto extends StatefulWidget {
  final IdentityGateway gateway;
  final String? participationId;
  final double size;
  final BoxFit fit;
  const MedalPhoto({
    super.key,
    required this.gateway,
    required this.participationId,
    this.size = 46,
    this.fit = BoxFit.cover,
  });

  @override
  State<MedalPhoto> createState() => _MedalPhotoState();
}

/// Links valem 5 minutos; reaproveita enquanto a tela esta aberta.
final Map<String, ({String url, DateTime expires})> _medalLinks = {};

/// Esquece o link guardado, por exemplo depois de trocar a foto da medalha.
void forgetMedalPhoto(String participationId) =>
    _medalLinks.remove(participationId);

class _MedalPhotoState extends State<MedalPhoto> {
  String? url;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final id = widget.participationId;
    if (id == null) return;
    final cached = _medalLinks[id];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      url = cached.url;
      return;
    }
    try {
      final reply = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(id)}/image',
      );
      final link = reply['url'];
      final expires = DateTime.tryParse(reply['expiresAt'] as String? ?? '');
      if (link is String && link.startsWith('https://')) {
        _medalLinks[id] = (
          url: link,
          expires: (expires ?? DateTime.now().add(const Duration(minutes: 4)))
              .subtract(const Duration(seconds: 30)),
        );
        if (mounted) setState(() => url = link);
      }
    } on Exception {
      // Sem foto ou sem rede: fica o trofeu.
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = url;
    if (link == null) return MedalArt(size: widget.size);
    return Image.network(
      link,
      fit: widget.fit,
      errorBuilder: (_, _, _) => MedalArt(size: widget.size),
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : MedalArt(size: widget.size),
    );
  }
}

class Stars extends StatelessWidget {
  final num value;
  final double size;
  const Stars(this.value, {super.key, this.size = 20});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 1; i <= 5; i++)
        Icon(
          value >= i - 0.25
              ? Icons.star
              : value >= i - 0.75
              ? Icons.star_half
              : Icons.star_border,
          size: size,
          color: runPassGold,
        ),
    ],
  );
}

String decimalPt(num value) => value.toStringAsFixed(1).replaceAll('.', ',');

/// Every completed participation of the signed-in runner, newest edition first.
/// Edition lookups that fail leave the record without edition details.
Future<List<RaceRecord>> loadMyRaces(IdentityGateway gateway) async {
  final completed = <Map<String, dynamic>>[];
  String? cursor;
  var pages = 0;
  do {
    final page = await gateway.request(
      '/me/participations',
      query: {'state': 'completed', 'limit': '100', 'cursor': ?cursor},
    );
    completed.addAll(
      (page['items'] as List? ?? const []).cast<Map<String, dynamic>>().where(
        (item) => item['state'] == 'completed',
      ),
    );
    cursor = page['nextCursor'] as String?;
  } while (cursor != null && ++pages < 5);
  final editions = await loadEditions(gateway, [
    for (final p in completed) p['editionId'] as String,
  ]);
  final records = [
    for (final p in completed) RaceRecord(p, editions[p['editionId']]),
  ];
  records.sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
  return records;
}

/// Achievements derived only from the runner's completed races. They are not
/// stored or awarded by the backend: a badge shows when the condition holds.
class Achievement {
  final String title, caption;
  final IconData icon;
  final Color color;
  const Achievement(this.title, this.caption, this.icon, this.color);
}

List<Achievement> achievementsOf(RaceStats stats) => [
  if (stats.cities > 0)
    Achievement(
      'Explorador',
      '${stats.cities} ${stats.cities == 1 ? 'cidade' : 'cidades'}',
      Icons.landscape_outlined,
      const Color(0xff4cc38a),
    ),
  if ((stats.byDistance[5] ?? 0) > 0)
    const Achievement(
      'Especialista',
      '5K',
      Icons.looks_5_outlined,
      Color(0xffff9f2e),
    ),
  if ((stats.byDistance[10] ?? 0) > 0)
    const Achievement(
      'Especialista',
      '10K',
      Icons.filter_1_outlined,
      Color(0xff3fbf8a),
    ),
  if ((stats.byDistance[21] ?? 0) > 0)
    const Achievement(
      'Meia Maratonista',
      '(21K)',
      Icons.star_outline,
      Color(0xff8a5cf6),
    ),
  if ((stats.byDistance[42] ?? 0) > 0)
    const Achievement(
      'Maratonista',
      '(42K)',
      Icons.workspace_premium_outlined,
      Color(0xffe8b23a),
    ),
];

Widget achievementBadge(Achievement item) => SizedBox(
  width: 78,
  child: Column(
    children: [
      CircleAvatar(
        radius: 28,
        backgroundColor: item.color,
        child: Icon(item.icon, color: Colors.white, size: 28),
      ),
      const SizedBox(height: 6),
      Text(
        item.title,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      Text(
        item.caption,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 10, color: Colors.grey),
      ),
    ],
  ),
);

String statLabel(double km) => switch (km.round()) {
  21 => 'meias\n(21K)',
  42 => 'maratona\n(42K)',
  _ => 'corridas\n${distanceLabel(km)}',
};

class RaceStats {
  final int completed, cities;
  final Map<double, int> byDistance;
  const RaceStats(this.completed, this.cities, this.byDistance);

  factory RaceStats.of(List<RaceRecord> races) {
    final byDistance = <double, int>{};
    for (final race in races) {
      final km = race.kilometers;
      if (km != null) {
        final key = km.roundToDouble();
        byDistance[key] = (byDistance[key] ?? 0) + 1;
      }
    }
    return RaceStats(
      races.length,
      {
        for (final race in races)
          if ((race.edition?['city'] as String?) != null)
            race.edition!['city'] as String,
      }.length,
      byDistance,
    );
  }
}

Widget statBlock(
  String value,
  String label, {
  Color? color,
  Color? labelColor,
}) => Expanded(
  child: Column(
    children: [
      Text(
        value,
        style: TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 22,
          color: color,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: labelColor),
      ),
    ],
  ),
);

Widget loadMessage(String text) => Center(
  child: Padding(padding: const EdgeInsets.all(24), child: Text(text)),
);

String loadError(Object error) => error is IdentityIssue
    ? catalogError(error)
    : 'Não foi possível carregar seus dados. Tente novamente.';

void openMedal(
  BuildContext context,
  IdentityGateway gateway,
  RaceRecord race,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        ParticipationDraftScreen(gateway: gateway, initial: race.participation),
  ),
);

enum MedalGrouping { all, year, distance, achievements }

class MedalCollectionScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const MedalCollectionScreen({super.key, required this.gateway});

  @override
  State<MedalCollectionScreen> createState() => _MedalCollectionScreenState();
}

class _MedalCollectionScreenState extends State<MedalCollectionScreen> {
  late final Future<List<RaceRecord>> races = loadMyRaces(widget.gateway);
  MedalGrouping grouping = MedalGrouping.all;
  bool newestFirst = true;

  Widget tile(RaceRecord race) => InkWell(
    onTap: () => openMedal(context, widget.gateway, race),
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xff4a3425), Color(0xff1e1510)],
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 4),
          Expanded(
            flex: 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox.expand(
                child: MedalPhoto(
                  gateway: widget.gateway,
                  participationId: race.participation['id'] as String?,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            race.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          Text(
            [
              if (race.place.isNotEmpty) race.place,
              if (race.year != null) '${race.year}',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, fontSize: 10),
          ),
        ],
      ),
    ),
  );

  Widget grid(List<RaceRecord> list) => GridView.count(
    crossAxisCount: 3,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 10,
    crossAxisSpacing: 10,
    childAspectRatio: 0.72,
    children: [for (final race in list) tile(race)],
  );

  List<Widget> sections(List<RaceRecord> races) {
    final ordered = newestFirst ? races : races.reversed.toList();
    if (grouping == MedalGrouping.achievements) {
      final items = achievementsOf(RaceStats.of(races));
      return [
        Wrap(
          spacing: 14,
          runSpacing: 18,
          children: [for (final item in items) achievementBadge(item)],
        ),
      ];
    }
    if (grouping == MedalGrouping.all) return [grid(ordered)];
    final groups = <String, List<RaceRecord>>{};
    for (final race in ordered) {
      final key = grouping == MedalGrouping.year
          ? '${race.year ?? 'Sem data'}'
          : race.kilometers == null
          ? 'Outras'
          : distanceLabel(race.kilometers!);
      groups.putIfAbsent(key, () => []).add(race);
    }
    final keys = groups.keys.toList();
    if (grouping == MedalGrouping.distance) {
      keys.sort(
        (a, b) => (int.tryParse(a.replaceAll('K', '')) ?? 1 << 20).compareTo(
          int.tryParse(b.replaceAll('K', '')) ?? 1 << 20,
        ),
      );
    }
    return [
      for (final key in keys) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Text(
            key,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
        ),
        grid(groups[key]!),
      ],
    ];
  }

  Widget chip(String label, MedalGrouping value) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: grouping == value,
      onSelected: (_) => setState(() => grouping = value),
      showCheckmark: false,
    ),
  );

  @override
  Widget build(BuildContext context) => Theme(
    data: runPassDarkTheme(),
    child: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              Icon(Icons.workspace_premium, color: Color(0xffe8b23a)),
              SizedBox(width: 10),
              Text(
                'Meu Medalheiro',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        bottomNavigationBar: runPassNavigation(context, widget.gateway, 2),
        body: FutureBuilder<List<RaceRecord>>(
          future: races,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return loadMessage(loadError(snapshot.error!));
            }
            final data = snapshot.data!;
            if (data.isEmpty) {
              return loadMessage(
                'Você ainda não concluiu uma corrida. Sua primeira medalha aparecerá aqui.',
              );
            }
            final stats = RaceStats.of(data);
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      chip('Todas', MedalGrouping.all),
                      chip('Por ano', MedalGrouping.year),
                      chip('Por distância', MedalGrouping.distance),
                      chip('Conquistas', MedalGrouping.achievements),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      children: [
                        statBlock(
                          '${stats.completed}',
                          'provas\nconcluídas',
                          color: runPassOrange,
                        ),
                        statBlock(
                          '${stats.completed}',
                          'medalhas\nna coleção',
                          color: const Color(0xffe8b23a),
                        ),
                        statBlock(
                          '${stats.cities}',
                          'cidades\nvisitadas',
                          color: const Color(0xff4cc38a),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Minhas medalhas',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => newestFirst = !newestFirst),
                      icon: const Icon(Icons.swap_vert, size: 18),
                      label: Text(
                        newestFirst ? 'Mais recentes' : 'Mais antigas',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...sections(data),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class ProfileData {
  final Map<String, dynamic> profile;
  final List<RaceRecord> races;
  final List<Map<String, dynamic>> wishlist;
  const ProfileData(this.profile, this.races, this.wishlist);
}

class RunnerProfileScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const RunnerProfileScreen({super.key, required this.gateway});

  @override
  State<RunnerProfileScreen> createState() => _RunnerProfileScreenState();
}

class _RunnerProfileScreenState extends State<RunnerProfileScreen> {
  late final Future<ProfileData> data = load();

  Future<ProfileData> load() async {
    final profile = await widget.gateway.request('/me');
    var races = const <RaceRecord>[];
    var wishlist = const <Map<String, dynamic>>[];
    try {
      races = await loadMyRaces(widget.gateway);
    } on Exception {
      // The profile still opens, only without the race summary.
    }
    try {
      final page = await widget.gateway.request(
        '/me/wishlist',
        query: {'limit': '20'},
      );
      wishlist = (page['items'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
    } on Exception {
      // The wishlist is optional; its section shows an empty message.
    }
    return ProfileData(profile, races, wishlist);
  }

  void soon(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Widget cover(Map<String, dynamic> profile) => SizedBox(
    height: 190,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          height: 150,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [runPassNavy, Color(0xff5a2a1c), runPassOrange],
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: SafeArea(
            child: IconButton(
              tooltip: 'Configurações',
              color: Colors.white,
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => soon('Configurações em breve.'),
            ),
          ),
        ),
        Positioned(
          left: 20,
          bottom: 0,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const CircleAvatar(
                radius: 46,
                backgroundColor: Colors.white,
                child: CircleAvatar(
                  radius: 42,
                  backgroundColor: Color(0xffffe4dc),
                  child: Icon(Icons.person, size: 48, color: runPassOrange),
                ),
              ),
              Positioned(
                right: -2,
                bottom: 2,
                child: InkWell(
                  onTap: () => soon('Foto do perfil em breve.'),
                  child: const CircleAvatar(
                    radius: 14,
                    backgroundColor: runPassNavy,
                    child: Icon(
                      Icons.photo_camera_outlined,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget sectionTitle(String title, {String? action, VoidCallback? onAction}) =>
      Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 19,
                ),
              ),
            ),
            if (action != null)
              TextButton(onPressed: onAction, child: Text(action)),
          ],
        ),
      );

  Widget wishTile(Map<String, dynamic> entry) {
    final edition = entry['edition'] as Map<String, dynamic>? ?? const {};
    final date = edition['date'] as String?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Container(
              width: 64,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: const LinearGradient(
                  colors: [Color(0xff2b3a55), Color(0xff6a4a3a)],
                ),
              ),
              child: const Icon(
                Icons.landscape_outlined,
                color: Colors.white70,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    edition['name'] as String? ?? 'Corrida',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  if (date != null)
                    Text(
                      displayDate(date),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  if (edition['city'] != null)
                    Text(
                      '${edition['city']}${edition['state'] == null ? '' : ' - ${edition['state']}'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                ],
              ),
            ),
            const Icon(Icons.favorite, color: runPassOrange),
          ],
        ),
      ),
    );
  }

  void toSignIn([String? notice]) => Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute<void>(
      builder: (_) => IdentityScreen(gateway: widget.gateway, notice: notice),
    ),
    (route) => false,
  );

  Future<void> signOut() async {
    try {
      await widget.gateway.signOut();
    } on Exception {
      // A sessão local já foi encerrada; falha de rede não impede sair.
    }
    if (mounted) toSignIn();
  }

  Future<void> deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir sua conta?'),
        content: const Text(
          'O acesso será bloqueado imediatamente e a limpeza dos seus dados (perfil, participações, avaliações e fotos) será agendada. Isso não pode ser desfeito.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir minha conta'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.gateway.request('/me', method: 'DELETE');
    } on IdentityIssue catch (issue) {
      if (mounted) soon(catalogError(issue));
      return;
    }
    widget.gateway.clearSession();
    if (mounted) {
      toSignIn('Exclusão aceita. O acesso à conta foi encerrado.');
    }
  }

  @override
  @override
  Widget build(BuildContext context) => Scaffold(
    bottomNavigationBar: runPassNavigation(context, widget.gateway, 3),
    body: FutureBuilder<ProfileData>(
      future: data,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) return loadMessage(loadError(snapshot.error!));
        final result = snapshot.data!;
        final profile = result.profile;
        final stats = RaceStats.of(result.races);
        final distances = stats.byDistance.keys.toList()..sort();
        final city = profile['city'] as String?;
        final bio = profile['bio'] as String?;
        final badges = achievementsOf(stats);
        final cities = {
          for (final race in result.races)
            if (race.edition?['city'] != null) race.edition!['city'] as String,
        }.toList();
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            cover(profile),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile['displayName'] as String? ?? 'Corredor',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 24,
                    ),
                  ),
                  Text(
                    [
                      '@${profile['username'] ?? ''}',
                      if (city != null && city.isNotEmpty) city,
                    ].join('  •  '),
                    style: const TextStyle(color: Colors.black54),
                  ),
                  if (bio != null && bio.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(bio),
                  ],
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          statBlock('${stats.completed}', 'provas\nconcluídas'),
                          for (final km in distances.take(4))
                            statBlock('${stats.byDistance[km]}', statLabel(km)),
                        ],
                      ),
                    ),
                  ),
                  if (badges.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final item in badges) ...[
                            achievementBadge(item),
                            const SizedBox(width: 10),
                          ],
                        ],
                      ),
                    ),
                  ],
                  sectionTitle(
                    'Quero correr',
                    action: 'Ver todas',
                    onAction: () => soon('Lista completa em breve.'),
                  ),
                  if (result.wishlist.isEmpty)
                    const Text('Sua lista Quero correr aparecerá aqui.')
                  else
                    for (final entry in result.wishlist.take(3)) ...[
                      wishTile(entry),
                      const SizedBox(height: 8),
                    ],
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      leading: const Icon(
                        Icons.map_outlined,
                        color: runPassOrange,
                      ),
                      title: const Text(
                        'Meu passaporte',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        '${cities.length} ${cities.length == 1 ? 'cidade conquistada' : 'cidades conquistadas'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => soon('Passaporte completo em breve.'),
                    ),
                  ),
                  if (cities.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final name in cities.take(6))
                          Chip(
                            avatar: const Icon(Icons.place_outlined, size: 16),
                            label: Text(name),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Card(
                    child: Column(
                      children: [
                        PrivacyTile(gateway: widget.gateway, profile: profile),
                        const Divider(height: 1),
                        ListTile(
                          key: const Key('find-friends-profile'),
                          leading: const Icon(Icons.person_search_rounded),
                          title: const Text('Buscar amigos'),
                          subtitle: const Text(
                            'Procure pessoas por nome ou usuário e siga.',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  FriendSearchScreen(gateway: widget.gateway),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          key: const Key('follow-requests'),
                          leading: const Icon(Icons.how_to_reg_outlined),
                          title: const Text('Pedidos para seguir'),
                          subtitle: const Text(
                            'Aceite ou recuse quem quer seguir seu perfil privado.',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  FollowRequestsScreen(gateway: widget.gateway),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          key: const Key('sign-out'),
                          leading: const Icon(Icons.logout_rounded),
                          title: const Text('Sair'),
                          subtitle: const Text(
                            'Encerra a sessão neste aparelho.',
                          ),
                          onTap: signOut,
                        ),
                        const Divider(height: 1),
                        ListTile(
                          key: const Key('delete-account'),
                          leading: const Icon(
                            Icons.delete_forever_outlined,
                            color: Colors.red,
                          ),
                          title: const Text(
                            'Excluir minha conta',
                            style: TextStyle(color: Colors.red),
                          ),
                          subtitle: const Text(
                            'Bloqueia o acesso na hora e agenda a limpeza dos seus dados.',
                          ),
                          onTap: deleteAccount,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
