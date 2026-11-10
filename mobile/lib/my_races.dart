import 'dart:async';
import 'dart:math' show cos, pi, sin;
import 'dart:ui' as ui;

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

  // Customizacao da medalha na prateleira: cada campo tem o dado do catalogo
  // como padrao e so usa o valor salvo quando a pessoa o personalizou.
  String get medalShape => participation['medalShape'] as String? ?? 'round';
  String? get medalCordColor => participation['medalCordColor'] as String?;
  String get medalDescription =>
      participation['medalDescription'] as String? ?? name;
  String get medalCity =>
      participation['medalCity'] as String? ??
      (edition?['city'] as String? ?? '');
  String get medalState =>
      participation['medalState'] as String? ??
      (edition?['state'] as String? ?? '');
  int? get medalYear => (participation['medalYear'] as num?)?.toInt() ?? year;
  String get medalPlace => medalCity.isEmpty
      ? ''
      : medalState.isEmpty
      ? medalCity
      : '$medalCity - $medalState';
}

/// Converte uma Color para "#rrggbb" para enviar ao backend.
String colorToHex(Color color) {
  int channel(double value) => (value * 255).round().clamp(0, 255);
  final argb = color.toARGB32();
  return '#'
      '${channel(((argb >> 16) & 0xff) / 255).toRadixString(16).padLeft(2, '0')}'
      '${channel(((argb >> 8) & 0xff) / 255).toRadixString(16).padLeft(2, '0')}'
      '${channel((argb & 0xff) / 255).toRadixString(16).padLeft(2, '0')}';
}

/// Converte "#rrggbb" (como salvo pelo backend) de volta para Color.
Color colorFromHex(String hex) {
  final value = int.parse(hex.replaceFirst('#', ''), radix: 16);
  return Color.fromARGB(
    255,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  );
}

const medalShapeOptions = [
  ('round', 'Redonda'),
  ('shield', 'Escudo'),
  ('star', 'Estrela'),
  ('hexagon', 'Hexágono'),
];

const medalCordPalette = <Color>[
  runPassOrange,
  Color(0xffe8b23a),
  Color(0xff4cc38a),
  Color(0xff4a8cf0),
  Color(0xff9b59b6),
  Color(0xffe74c3c),
  Color(0xff1abc9c),
  Color(0xff34495e),
  Color(0xfff1c40f),
  Color(0xffff6fa3),
  Color(0xff2ecc71),
  Color(0xff7f8c8d),
];

/// Desenha o contorno da medalha conforme a forma escolhida; "round" (padrao)
/// e as demais sao polígonos regulares simples.
Path medalShapePath(String shape, Size size) {
  final w = size.width, h = size.height;
  switch (shape) {
    case 'star':
      return _polygonPath(w, h, points: 5, star: true);
    case 'hexagon':
      return _polygonPath(w, h, points: 6, star: false);
    case 'shield':
      return Path()
        ..moveTo(w / 2, 0)
        ..lineTo(w, h * 0.22)
        ..lineTo(w, h * 0.55)
        ..cubicTo(w, h * 0.85, w * 0.7, h, w / 2, h)
        ..cubicTo(w * 0.3, h, 0, h * 0.85, 0, h * 0.55)
        ..lineTo(0, h * 0.22)
        ..close();
    default:
      return Path()..addOval(Rect.fromLTWH(0, 0, w, h));
  }
}

Path _polygonPath(
  double w,
  double h, {
  required int points,
  required bool star,
}) {
  final path = Path();
  final cx = w / 2, cy = h / 2;
  final outerR = w / 2;
  final innerR = outerR * 0.45;
  final vertices = star ? points * 2 : points;
  final step = 360 / vertices;
  for (var i = 0; i < vertices; i++) {
    final angle = (-90 + i * step) * pi / 180;
    final r = star && i.isOdd ? innerR : outerR;
    final x = cx + r * cos(angle);
    final y = cy + r * sin(angle);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  path.close();
  return path;
}

class _MedalShapeClipper extends CustomClipper<Path> {
  final String shape;
  const _MedalShapeClipper(this.shape);
  @override
  Path getClip(Size size) => medalShapePath(shape, size);
  @override
  bool shouldReclip(covariant _MedalShapeClipper oldClipper) =>
      oldClipper.shape != shape;
}

/// Contorno colorido acompanhando exatamente a forma da medalha (redonda,
/// escudo, estrela ou hexagono), para dar o acabamento de "medalha" a foto.
class _MedalRingPainter extends CustomPainter {
  final String shape;
  final Color color;
  const _MedalRingPainter(this.shape, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.width * 0.02;
    final path = medalShapePath(
      shape,
      Size(size.width - inset * 2, size.height - inset * 2),
    ).shift(Offset(inset, inset));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.045,
    );
  }

  @override
  bool shouldRepaint(covariant _MedalRingPainter oldDelegate) =>
      oldDelegate.shape != shape || oldDelegate.color != color;
}

final Map<String, Color> _medalCordColorCache = {};

/// Cor dominante extraida da foto da medalha, para servir de cor padrao do
/// cordao quando a pessoa nao escolheu uma cor manualmente. Calculada uma vez
/// por participacao e reaproveitada (a foto nao muda sem nova customizacao).
Future<Color> dominantCordColor(
  IdentityGateway gateway,
  String participationId,
) async {
  final cached = _medalCordColorCache[participationId];
  if (cached != null) return cached;
  try {
    final reply = await gateway.request(
      '/participations/${Uri.encodeComponent(participationId)}/image',
    );
    final link = reply['url'] as String?;
    if (link == null) return runPassOrange;
    final color = await _sampleDominantColor(link) ?? runPassOrange;
    _medalCordColorCache[participationId] = color;
    return color;
  } on Exception {
    return runPassOrange;
  }
}

Future<Color?> _sampleDominantColor(String url) async {
  try {
    final completer = Completer<ui.Image>();
    final stream = NetworkImage(url).resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final bytes = data.buffer.asUint8List();
    var r = 0, g = 0, b = 0, count = 0;
    final pixels = bytes.length ~/ 4;
    final stride = (pixels / 2000).ceil().clamp(1, 1 << 20);
    for (var i = 0; i + 3 < bytes.length; i += 4 * stride) {
      if (bytes[i + 3] < 128) continue;
      r += bytes[i];
      g += bytes[i + 1];
      b += bytes[i + 2];
      count++;
    }
    if (count == 0) return null;
    return Color.fromARGB(255, r ~/ count, g ~/ count, b ~/ count);
  } on Exception {
    return null;
  }
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
  late Future<List<RaceRecord>> races = loadMyRaces(widget.gateway);
  late final Future<Map> profile = widget.gateway.request('/me');
  MedalGrouping grouping = MedalGrouping.all;
  bool newestFirst = true;

  Future<void> editMedal(RaceRecord race) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => _MedalEditSheet(gateway: widget.gateway, race: race),
    );
    if (result == null || !mounted) return;
    try {
      await widget.gateway.request(
        '/participations/${Uri.encodeComponent(race.participation['id'] as String)}',
        method: 'PATCH',
        body: {'expectedVersion': race.participation['version'], ...result},
      );
      setState(() {
        races = loadMyRaces(widget.gateway);
      });
    } on Exception {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível salvar a medalha. Tente de novo.'),
        ),
      );
    }
  }

  /// Cor do cordao/anel da medalha: a escolhida pela pessoa, ou a dominante da
  /// foto por padrao. Resolvida uma unica vez e compartilhada entre a fita e o
  /// contorno da foto, para os dois ficarem com a mesma cor.
  Future<Color> _cordColorFor(RaceRecord race) {
    final override = race.medalCordColor;
    if (override != null) return Future.value(colorFromHex(override));
    final id = race.participation['id'] as String?;
    if (id == null) return Future.value(runPassOrange);
    return dominantCordColor(widget.gateway, id);
  }

  Widget _ribbon(Color color) => SizedBox(
    height: 22,
    child: Stack(
      alignment: Alignment.topCenter,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: 0,
          left: 14,
          child: Transform.rotate(
            angle: -0.45,
            child: Container(width: 11, height: 26, color: color),
          ),
        ),
        Positioned(
          top: 0,
          right: 14,
          child: Transform.rotate(
            angle: 0.45,
            child: Container(width: 11, height: 26, color: color),
          ),
        ),
      ],
    ),
  );

  Widget _woodShelf() => Container(
    height: 10,
    margin: const EdgeInsets.symmetric(horizontal: 6),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(3),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xffa8703f), Color(0xff7a4c27)],
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 4,
          offset: Offset(0, 2),
        ),
      ],
    ),
  );

  Widget tile(RaceRecord race) => Stack(
    children: [
      InkWell(
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
          child: FutureBuilder<Color>(
            future: _cordColorFor(race),
            builder: (context, snapshot) {
              final color = snapshot.data ?? runPassOrange;
              return Column(
                children: [
                  _ribbon(color),
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      // AspectRatio garante um recorte sempre quadrado: sem
                      // isso, o Expanded entrega uma area retangular e a
                      // medalha "redonda" sai achatada em oval.
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipPath(
                                clipper: _MedalShapeClipper(race.medalShape),
                                child: MedalPhoto(
                                  gateway: widget.gateway,
                                  participationId:
                                      race.participation['id'] as String?,
                                ),
                              ),
                              CustomPaint(
                                painter: _MedalRingPainter(
                                  race.medalShape,
                                  color,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  _woodShelf(),
                  const SizedBox(height: 4),
                  Text(
                    race.medalDescription,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    [
                      if (race.medalPlace.isNotEmpty) race.medalPlace,
                      if (race.medalYear != null) '${race.medalYear}',
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.muted, fontSize: 10),
                  ),
                ],
              );
            },
          ),
        ),
      ),
      Positioned(
        top: 2,
        right: 2,
        child: Material(
          color: Colors.black38,
          shape: const CircleBorder(),
          child: InkWell(
            key: Key('medal-edit-${race.participation['id']}'),
            customBorder: const CircleBorder(),
            onTap: () => editMedal(race),
            child: const Padding(
              padding: EdgeInsets.all(5),
              child: Icon(Icons.edit, size: 14, color: Colors.white),
            ),
          ),
        ),
      ),
    ],
  );

  Widget grid(List<RaceRecord> list) => GridView.count(
    crossAxisCount: 3,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 10,
    crossAxisSpacing: 10,
    // Baixo o suficiente para a foto da medalha caber com a largura inteira do
    // card (quadrada), sem sobrar espaco vazio acima/abaixo dela.
    childAspectRatio: 0.58,
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

  Widget bigStat(IconData icon, Color color, String value, String label) =>
      Expanded(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: context.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

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
          leading: Padding(
            padding: const EdgeInsets.all(6),
            child: FutureBuilder<Map>(
              future: profile,
              builder: (context, snapshot) => InkWell(
                key: const Key('medals-profile-avatar'),
                customBorder: const CircleBorder(),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        RunnerProfileScreen(gateway: widget.gateway),
                  ),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: runPassOrange, width: 2),
                  ),
                  child: ProfileAvatar(
                    radius: 16,
                    gateway: widget.gateway,
                    profile: snapshot.data,
                  ),
                ),
              ),
            ),
          ),
          centerTitle: true,
          title: const Text(
            'Minhas Medalhas',
            style: TextStyle(fontWeight: FontWeight.w800),
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
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 12,
                    ),
                    child: Row(
                      children: [
                        bigStat(
                          Icons.directions_run_rounded,
                          const Color(0xff4cc38a),
                          '${stats.completed}',
                          'provas\nconcluídas',
                        ),
                        bigStat(
                          Icons.military_tech_rounded,
                          const Color(0xffe8b23a),
                          '${stats.completed}',
                          'medalhas\nna coleção',
                        ),
                        bigStat(
                          Icons.location_on_rounded,
                          const Color(0xff4cc38a),
                          '${stats.cities}',
                          'cidades\nvisitadas',
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

/// Bottom sheet para personalizar a medalha: forma, cor do cordao e legenda
/// (descricao, cidade, UF, ano). Devolve o corpo pronto para PATCH
/// /participations/{id}, ou nulo se a pessoa cancelar.
class _MedalEditSheet extends StatefulWidget {
  final IdentityGateway gateway;
  final RaceRecord race;
  const _MedalEditSheet({required this.gateway, required this.race});

  @override
  State<_MedalEditSheet> createState() => _MedalEditSheetState();
}

class _MedalEditSheetState extends State<_MedalEditSheet> {
  late String shape = widget.race.medalShape;
  late String? cordColor = widget.race.medalCordColor;
  late final description = TextEditingController(
    text: widget.race.medalDescription,
  );
  late final city = TextEditingController(text: widget.race.medalCity);
  late final state = TextEditingController(text: widget.race.medalState);
  late final year = TextEditingController(
    text: widget.race.medalYear?.toString() ?? '',
  );

  @override
  void dispose() {
    description.dispose();
    city.dispose();
    state.dispose();
    year.dispose();
    super.dispose();
  }

  String? _blankToNull(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void save() {
    final parsedYear = int.tryParse(year.text.trim());
    final uf = state.text.trim().toUpperCase();
    Navigator.pop<Map<String, dynamic>>(context, {
      'medalShape': shape,
      'medalCordColor': cordColor,
      'medalDescription': _blankToNull(description.text),
      'medalCity': _blankToNull(city.text),
      'medalState': uf.length == 2 ? uf : null,
      'medalYear': parsedYear,
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Personalizar medalha',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            const SizedBox(height: 16),
            const Text('Forma', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final option in medalShapeOptions)
                  ChoiceChip(
                    label: Text(option.$2),
                    selected: shape == option.$1,
                    onSelected: (_) => setState(() => shape = option.$1),
                    showCheckmark: false,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Cor do cordão',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                InkWell(
                  key: const Key('medal-cord-automatic'),
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => cordColor = null),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const SweepGradient(
                        colors: [
                          runPassOrange,
                          Color(0xff4cc38a),
                          Color(0xff4a8cf0),
                          runPassOrange,
                        ],
                      ),
                      border: Border.all(
                        color: cordColor == null
                            ? Colors.black
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: cordColor == null
                        ? const Icon(Icons.check, color: Colors.white, size: 16)
                        : null,
                  ),
                ),
                for (final color in medalCordPalette)
                  InkWell(
                    key: Key('medal-cord-${colorToHex(color)}'),
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => cordColor = colorToHex(color)),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                        border: Border.all(
                          color: cordColor == colorToHex(color)
                              ? Colors.black
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: cordColor == colorToHex(color)
                          ? const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 16,
                            )
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: description,
              decoration: const InputDecoration(
                labelText: 'Descrição',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: city,
                    decoration: const InputDecoration(
                      labelText: 'Cidade',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: state,
                    maxLength: 2,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'UF',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: year,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Ano',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('medal-edit-save'),
                    style: FilledButton.styleFrom(
                      backgroundColor: runPassOrange,
                    ),
                    onPressed: save,
                    child: const Text('Salvar'),
                  ),
                ),
              ],
            ),
          ],
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
