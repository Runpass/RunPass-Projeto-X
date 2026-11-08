import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'friends.dart';
import 'identity_gateway.dart';
import 'location_picker.dart';
import 'notifications.dart';
import 'post_card.dart' show FeedEntry, PostCard, entryFromPost;
import 'profile_photo.dart';
import 'runpass_theme.dart';
import 'settings.dart';

/// "15/03/1995 • 18 anos", so quando GET /me devolve birthDate (so para o proprio
/// titular; nunca em perfil publico). Nulo se ausente ou mal formatada.
String? birthDateLabel(String? isoBirthDate) {
  final birth = isoBirthDate == null ? null : DateTime.tryParse(isoBirthDate);
  if (birth == null) return null;
  final today = DateTime.now();
  var age = today.year - birth.year;
  if (today.month < birth.month ||
      (today.month == birth.month && today.day < birth.day)) {
    age--;
  }
  final formatted =
      '${birth.day.toString().padLeft(2, '0')}/${birth.month.toString().padLeft(2, '0')}/${birth.year}';
  return '$formatted  •  $age anos';
}

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

/// Imagem privada servida por link curto e assinado (`GET <endpoint>` devolve `url`).
/// Sem foto, sem permissao ou sem rede, mostra o `fallback`.
class SignedPhoto extends StatefulWidget {
  final IdentityGateway gateway;
  final String? endpoint;
  final Widget fallback;
  final BoxFit fit;
  const SignedPhoto({
    super.key,
    required this.gateway,
    required this.endpoint,
    required this.fallback,
    this.fit = BoxFit.cover,
  });

  @override
  State<SignedPhoto> createState() => _SignedPhotoState();
}

/// Links valem 5 minutos; reaproveita enquanto a tela esta aberta.
final Map<String, ({String url, DateTime expires})> _photoLinks = {};

/// Esquece o link guardado, por exemplo depois de trocar a foto.
void forgetMedalPhoto(String participationId) => _photoLinks.remove(
  '/participations/${Uri.encodeComponent(participationId)}/image',
);

void forgetBanner(String profileId) =>
    _photoLinks.remove('/profiles/${Uri.encodeComponent(profileId)}/banner');

void forgetProfilePhoto(String profileId) =>
    _photoLinks.remove('/profiles/${Uri.encodeComponent(profileId)}/photo');

class _SignedPhotoState extends State<SignedPhoto> {
  String? url;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final endpoint = widget.endpoint;
    if (endpoint == null) return;
    final cached = _photoLinks[endpoint];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      url = cached.url;
      return;
    }
    try {
      final reply = await widget.gateway.request(endpoint);
      final link = reply['url'];
      final expires = DateTime.tryParse(reply['expiresAt'] as String? ?? '');
      if (link is String && link.startsWith('https://')) {
        _photoLinks[endpoint] = (
          url: link,
          expires: (expires ?? DateTime.now().add(const Duration(minutes: 4)))
              .subtract(const Duration(seconds: 30)),
        );
        if (mounted) setState(() => url = link);
      }
    } on Exception {
      // Sem foto ou sem rede: fica o fallback.
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = url;
    if (link == null) return widget.fallback;
    return Image.network(
      link,
      fit: widget.fit,
      errorBuilder: (_, _, _) => widget.fallback,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : widget.fallback,
    );
  }
}

/// Foto da medalha enviada pela pessoa (`GET /participations/{id}/image`); sem foto, o trofeu.
class MedalPhoto extends StatelessWidget {
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
  Widget build(BuildContext context) => SignedPhoto(
    gateway: gateway,
    endpoint: participationId == null
        ? null
        : '/participations/${Uri.encodeComponent(participationId!)}/image',
    fallback: MedalArt(size: size),
    fit: fit,
  );
}

/// Detecta JPEG ou PNG pelos primeiros bytes; qualquer outro formato volta nulo.
String? imageContentType(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  return null;
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
  final int completed, cities, countries;
  final double kilometers;
  final Map<double, int> byDistance;
  const RaceStats(
    this.completed,
    this.cities,
    this.byDistance, {
    this.countries = 0,
    this.kilometers = 0,
  });

  factory RaceStats.of(List<RaceRecord> races) {
    final byDistance = <double, int>{};
    var kilometers = 0.0;
    for (final race in races) {
      final km = race.kilometers;
      if (km != null) {
        final key = km.roundToDouble();
        byDistance[key] = (byDistance[key] ?? 0) + 1;
        kilometers += km;
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
      // Edicao sem pais informado e do Brasil.
      countries: {
        for (final race in races)
          if (race.edition != null)
            (race.edition!['country'] as String?)?.trim().toLowerCase() ??
                'brasil',
      }.length,
      kilometers: kilometers,
    );
  }
}

Widget statBlock(
  String value,
  String label, {
  Color? color,
  Color? labelColor,
  VoidCallback? onTap,
}) {
  final column = Column(
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
  );
  return Expanded(
    child: onTap == null
        ? column
        : InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: column,
          ),
  );
}

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
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(
          color: context.isDark
              ? const Color(0xff3a3330)
              : const Color(0xffeadfd8),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
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
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
          Text(
            [
              if (race.place.isNotEmpty) race.place,
              if (race.year != null) '${race.year}',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.muted, fontSize: 10),
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
    data: Theme.of(context),
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
          actions: [
            NotificationBell(gateway: widget.gateway),
            const SizedBox(width: 8),
          ],
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
                          'medalhas',
                          color: runPassOrange,
                        ),
                        statBlock(
                          stats.kilometers == stats.kilometers.roundToDouble()
                              ? '${stats.kilometers.toInt()}'
                              : stats.kilometers.toStringAsFixed(1),
                          "km's\ncorridos",
                          color: const Color(0xffe8b23a),
                        ),
                        statBlock(
                          '${stats.cities}',
                          'cidades\nvisitadas',
                          color: const Color(0xff4cc38a),
                        ),
                        statBlock(
                          '${stats.countries}',
                          'países\nvisitados',
                          color: const Color(0xff4a8cf0),
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
  final List<FeedEntry> myPosts;
  final int followers, following, friends;
  const ProfileData(
    this.profile,
    this.races,
    this.wishlist, [
    this.followers = 0,
    this.following = 0,
    this.myPosts = const [],
    this.friends = 0,
  ]);
}

/// As publicações do próprio usuário (corridas com `publishToFeed=true`), mais recente
/// primeiro, já no formato completo do cartão do Feed (curtidas, comentários).
Future<List<FeedEntry>> loadMyPosts(
  IdentityGateway gateway,
  List<RaceRecord> races,
  String? myId,
) async {
  final published =
      [
        for (final race in races)
          if (race.participation['publishToFeed'] == true) race,
      ]..sort(
        (a, b) => (b.participation['completedAt'] as String? ?? '').compareTo(
          a.participation['completedAt'] as String? ?? '',
        ),
      );
  final entries = <FeedEntry>[];
  for (final race in published) {
    final id = race.participation['id'] as String?;
    if (id == null) continue;
    try {
      final post = await gateway.request('/posts/${Uri.encodeComponent(id)}');
      entries.add(entryFromPost(post, race.edition, myId));
    } on Exception {
      // Uma publicacao que falhar ao carregar simplesmente nao aparece na lista.
    }
  }
  return entries;
}

class RunnerProfileScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final ProfilePhotoPicker photoPicker;
  final ProfilePhotoPicker bannerPicker;
  const RunnerProfileScreen({
    super.key,
    required this.gateway,
    this.photoPicker = pickProfilePhoto,
    this.bannerPicker = pickBannerPhoto,
  });

  @override
  State<RunnerProfileScreen> createState() => _RunnerProfileScreenState();
}

class _RunnerProfileScreenState extends State<RunnerProfileScreen> {
  late Future<ProfileData> data = load();

  Future<void> changePhoto(Map<String, dynamic> profile) async {
    final hasPhoto = profile['photoReference'] != null;
    final choice = await askPhotoChoice(context, canRemove: hasPhoto);
    if (choice == null || !mounted) return;
    try {
      String? reference;
      if (choice == PhotoChoice.remove) {
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remover a foto de perfil?'),
            content: const Text('Seu perfil volta a mostrar o ícone padrão.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                key: const Key('confirm-remove-photo'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remover'),
              ),
            ],
          ),
        );
        if (sure != true) return;
      } else {
        final bytes = await widget.photoPicker(context, choice);
        if (bytes == null) return;
        soon('Enviando a foto...');
        reference = await uploadProfilePhoto(widget.gateway, bytes);
      }
      await widget.gateway.request(
        '/me',
        method: 'PATCH',
        body: {
          'expectedVersion': profile['version'],
          'photoReference': reference,
        },
      );
      forgetProfilePhoto(profile['id'] as String);
      if (mounted) {
        setState(() {
          data = load();
        });
      }
    } on IdentityIssue catch (issue) {
      soon(photoError(issue));
    } on Exception catch (error) {
      soon(photoError(error));
    }
  }

  void openRelationList(
    Map<String, dynamic> profile,
    RelationListKind kind,
    String title,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RelationListScreen(
          gateway: widget.gateway,
          profileId: profile['id'] as String,
          kind: kind,
          title: title,
          ownList: true,
        ),
      ),
    );
  }

  Future<void> editLocation(Map<String, dynamic> profile) async {
    final picked = await pickBrLocation(
      context,
      initialUf: profile['state'] as String?,
      initialCity: profile['city'] as String?,
    );
    if (picked == null || !mounted) return;
    try {
      await widget.gateway.request(
        '/me',
        method: 'PATCH',
        body: {
          'expectedVersion': profile['version'],
          ...brLocationPatch(picked.$1, picked.$2, picked.$3, picked.$4),
        },
      );
      if (mounted) {
        setState(() {
          data = load();
        });
      }
    } on Exception {
      soon('Não foi possível salvar. Tente de novo.');
    }
  }

  Future<void> changeBanner(Map<String, dynamic> profile) async {
    final choice = await askPhotoChoice(
      context,
      canRemove: profile['bannerReference'] != null,
    );
    if (choice == null || !mounted) return;
    try {
      String? reference;
      if (choice != PhotoChoice.remove) {
        final bytes = await widget.bannerPicker(context, choice);
        if (bytes == null) return;
        soon('Enviando o banner...');
        reference = await uploadProfilePhoto(widget.gateway, bytes);
      }
      await widget.gateway.request(
        '/me',
        method: 'PATCH',
        body: {
          'expectedVersion': profile['version'],
          'bannerReference': reference,
        },
      );
      forgetBanner(profile['id'] as String);
      if (mounted) {
        setState(() {
          data = load();
        });
      }
    } on IdentityIssue catch (issue) {
      soon(photoError(issue));
    } on Exception catch (error) {
      soon(photoError(error));
    }
  }

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
    var followers = 0, following = 0, friends = 0;
    final myId = profile['id'] as String?;
    if (myId != null) {
      try {
        final me = await widget.gateway.request(
          '/profiles/${Uri.encodeComponent(myId)}',
        );
        followers = (me['followersCount'] as num?)?.toInt() ?? 0;
        following = (me['followingCount'] as num?)?.toInt() ?? 0;
        friends = (me['friendsCount'] as num?)?.toInt() ?? 0;
      } on Exception {
        // Sem contagem: mostra zero.
      }
    }
    var myPosts = const <FeedEntry>[];
    try {
      myPosts = await loadMyPosts(widget.gateway, races, myId);
    } on Exception {
      // A secao de publicacoes so fica vazia.
    }
    return ProfileData(
      profile,
      races,
      wishlist,
      followers,
      following,
      myPosts,
      friends,
    );
  }

  void soon(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Widget cover(Map<String, dynamic> profile, ProfileData result) => SizedBox(
    height: 232,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          key: const Key('profile-banner'),
          height: 176,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [runPassNavy, Color(0xff5a2a1c), runPassOrange],
            ),
          ),
          child: profile['bannerReference'] == null
              ? null
              : SizedBox.expand(
                  child: SignedPhoto(
                    key: ValueKey('banner-${profile['bannerReference']}'),
                    gateway: widget.gateway,
                    endpoint:
                        '/profiles/${Uri.encodeComponent(profile['id'] as String)}/banner',
                    fallback: const SizedBox.shrink(),
                  ),
                ),
        ),
        Positioned(
          right: 12,
          top: 134,
          child: InkWell(
            key: const Key('change-banner'),
            onTap: () => changeBanner(profile),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.image_outlined, size: 16, color: Colors.white),
                  SizedBox(width: 6),
                  Text(
                    'Banner',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: SafeArea(
            child: Row(
              children: [
                IconTheme(
                  data: const IconThemeData(color: Colors.white),
                  child: NotificationBell(gateway: widget.gateway),
                ),
                IconButton(
                  key: const Key('open-settings'),
                  tooltip: 'Configurações',
                  color: Colors.white,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(gateway: widget.gateway),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Seguidores e seguindo ao lado da foto, ABAIXO do banner (formato do Instagram).
        Positioned(
          left: 124,
          right: 12,
          top: 188,
          child: Row(
            key: const Key('profile-counts'),
            children: [
              statBlock(
                '${result.friends}',
                'amigos',
                onTap: () => openRelationList(
                  profile,
                  RelationListKind.friends,
                  'Amigos',
                ),
              ),
              statBlock(
                '${result.followers}',
                'seguidores',
                onTap: () => openRelationList(
                  profile,
                  RelationListKind.followers,
                  'Seguidores',
                ),
              ),
              statBlock(
                '${result.following}',
                'seguindo',
                onTap: () => openRelationList(
                  profile,
                  RelationListKind.following,
                  'Seguindo',
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 20,
          bottom: 0,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 46,
                backgroundColor: Theme.of(context).colorScheme.surface,
                child: ProfileAvatar(
                  key: ValueKey('avatar-${profile['photoReference']}'),
                  radius: 42,
                  gateway: widget.gateway,
                  profile: profile,
                ),
              ),
              Positioned(
                right: -2,
                bottom: 2,
                child: InkWell(
                  key: const Key('change-profile-photo'),
                  onTap: () => changePhoto(profile),
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
                      style: TextStyle(fontSize: 12, color: context.muted),
                    ),
                  if (edition['city'] != null)
                    Text(
                      '${edition['city']}${edition['state'] == null ? '' : ' - ${edition['state']}'}',
                      style: TextStyle(fontSize: 12, color: context.muted),
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
        final birthLabel = birthDateLabel(profile['birthDate'] as String?);
        final badges = achievementsOf(stats);
        final cities = {
          for (final race in result.races)
            if (race.edition?['city'] != null) race.edition!['city'] as String,
        }.toList();
        final myPosts = result.myPosts;
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            cover(profile, result),
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
                    style: TextStyle(color: context.muted),
                  ),
                  if (bio != null && bio.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(bio),
                  ],
                  if (birthLabel != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.cake_outlined,
                          size: 16,
                          color: context.muted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          birthLabel,
                          style: TextStyle(color: context.muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      key: const Key('edit-profile'),
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Editar perfil'),
                      subtitle: Text(
                        brLocationLabel(profile) ??
                            'Toque para informar seu estado e cidade',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => editLocation(profile),
                    ),
                  ),
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
                  sectionTitle('Minhas publicações'),
                  if (myPosts.isEmpty)
                    const Text(
                      'Suas corridas publicadas aparecerão aqui.',
                      key: Key('no-my-posts'),
                    )
                  else
                    // Mesmo cartão do Feed, uma publicação abaixo da outra — não em grade.
                    for (final entry in myPosts) ...[
                      PostCard(
                        key: Key('my-post-${entry.postId}'),
                        gateway: widget.gateway,
                        entry: entry,
                        onChanged: () {
                          if (mounted) setState(() => data = load());
                        },
                      ),
                      const SizedBox(height: 14),
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
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
