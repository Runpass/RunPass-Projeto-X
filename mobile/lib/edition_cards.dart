import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'identity_gateway.dart';
import 'runpass_theme.dart';

/// Cartão de corrida em lista (o padrão da tela Corridas): capa, nome e linhas de informação.
/// Reaproveitado pela agenda e pelo perfil. `overlay` fica no canto superior direito (atalhos ou menu).
class EditionListCard extends StatelessWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> edition;
  final List<String> lines;
  final VoidCallback? onTap;
  final Widget? overlay;
  const EditionListCard({
    super.key,
    required this.gateway,
    required this.edition,
    required this.lines,
    this.onTap,
    this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    final archived = edition['status'] == 'archived';
    const shadow = [Shadow(blurRadius: 6, color: Colors.black54)];
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 200,
          child: Stack(
            fit: StackFit.expand,
            children: [
              EditionCover(gateway: gateway, edition: edition),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x33000000), Color(0xD9000000)],
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 12,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      edition['name'] as String? ?? 'Corrida',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: archived ? context.archivedText : Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        shadows: shadow,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      lines.join('\n'),
                      style: TextStyle(
                        color: archived ? context.archivedText : Colors.white,
                        fontSize: 12.5,
                        height: 1.3,
                        shadows: shadow,
                      ),
                    ),
                  ],
                ),
              ),
              if (overlay != null)
                Positioned(top: 6, right: 6, child: overlay!),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cartão de corrida em grade (1 a 5 colunas): capa com nome, data e cidade; o texto acompanha as colunas.
class EditionGridCard extends StatelessWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> edition;
  final int columns;

  /// "dd/mm/aaaa · Cidade/UF" (usado com até 3 colunas) e a nota (até 2 colunas); `shortDate` serve às mais estreitas.
  final String subtitle;
  final String shortDate;
  final String? rating;
  final VoidCallback? onTap;
  final Widget? overlay;
  const EditionGridCard({
    super.key,
    required this.gateway,
    required this.edition,
    required this.columns,
    required this.subtitle,
    required this.shortDate,
    this.rating,
    this.onTap,
    this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    final archived = edition['status'] == 'archived';
    final compact = columns >= 4;
    const shadow = [Shadow(blurRadius: 6, color: Colors.black54)];
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            EditionCover(gateway: gateway, edition: edition),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x1A000000), Color(0xD9000000)],
                ),
              ),
            ),
            Positioned(
              left: compact ? 6 : 10,
              right: compact ? 6 : 10,
              bottom: compact ? 6 : 10,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    edition['name'] as String? ?? 'Corrida',
                    maxLines: compact ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: archived ? context.archivedText : Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: switch (columns) {
                        1 => 17.0,
                        2 => 14.0,
                        3 => 12.0,
                        _ => 10.0,
                      },
                      shadows: shadow,
                    ),
                  ),
                  if (columns <= 3) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: columns == 3 ? 10.5 : 12,
                        shadows: shadow,
                      ),
                    ),
                    if (rating != null && columns <= 2)
                      Text(
                        rating!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          shadows: shadow,
                        ),
                      ),
                  ] else
                    Text(
                      shortDate,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9.5,
                        shadows: shadow,
                      ),
                    ),
                ],
              ),
            ),
            if (overlay != null) Positioned(top: 4, right: 4, child: overlay!),
          ],
        ),
      ),
    );
  }
}

/// Número de colunas -> proporção do cartão da grade.
double gridCardAspectRatio(int columns) => switch (columns) {
  1 => 1.9,
  2 => 0.95,
  3 => 0.8,
  _ => 0.7,
};

const _weekdays = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];
const _months = [
  'jan',
  'fev',
  'mar',
  'abr',
  'mai',
  'jun',
  'jul',
  'ago',
  'set',
  'out',
  'nov',
  'dez',
];

DateTime? _day(String iso) {
  final parsed = DateTime.tryParse(iso);
  return parsed == null
      ? null
      : DateTime(parsed.year, parsed.month, parsed.day);
}

DateTime _today(DateTime? now) {
  final n = now ?? DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// Data para ler de relance: "Hoje", "Amanhã", "Sáb, 22 nov" (até 6 dias à frente), "22 nov" no mesmo ano
/// e "22 nov 2027" em outro ano.
String relativeDay(String isoDate, {DateTime? now}) {
  final day = _day(isoDate);
  if (day == null) return isoDate;
  final today = _today(now);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Hoje';
  if (diff == 1) return 'Amanhã';
  final label = '${day.day} ${_months[day.month - 1]}';
  if (diff > 1 && diff < 7) return '${_weekdays[day.weekday - 1]}, $label';
  return day.year == today.year ? label : '$label ${day.year}';
}

/// Seção da lista: Hoje, Amanhã, Este fim de semana, Próximos dias, Mais adiante ou Já aconteceram.
String periodOf(String isoDate, {DateTime? now}) {
  final day = _day(isoDate);
  if (day == null) return 'Mais adiante';
  final today = _today(now);
  final diff = day.difference(today).inDays;
  if (diff < 0) return 'Já aconteceram';
  if (diff == 0) return 'Hoje';
  if (diff == 1) return 'Amanhã';
  // Fim de semana desta semana (sábado e domingo à frente, até 6 dias).
  if (diff < 7 && day.weekday >= DateTime.saturday) {
    final saturday = today.add(
      Duration(days: (DateTime.saturday - today.weekday) % 7),
    );
    if (!day.isBefore(saturday)) return 'Este fim de semana';
  }
  if (diff <= 7) return 'Próximos dias';
  return 'Mais adiante';
}

/// Distâncias em pílulas ("5K", "21K"); vazio quando a corrida não informa.
List<String> distanceChips(Map<String, dynamic> edition) {
  final kms = [
    for (final d in (edition['distances'] as List? ?? const []))
      if ((d as Map)['kilometers'] is num) (d['kilometers'] as num).toDouble(),
  ]..sort();
  String label(double km) {
    if ((km - 21.0975).abs() < 0.01) return '21K';
    if ((km - 42.195).abs() < 0.01) return '42K';
    return km == km.roundToDouble()
        ? '${km.toInt()}K'
        : '${km.toStringAsFixed(1)}K';
  }

  return [for (final km in kms) label(km)];
}

/// Cartão compacto da tela Corridas (padrão da lista): miniatura à esquerda e, ao lado, quando (relativo) e onde,
/// o nome, as distâncias em pílulas e as ações com rótulo. Cabem bem mais corridas por tela que no cartão grande.
class EditionCompactCard extends StatelessWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> edition;
  final VoidCallback? onTap;
  final Widget? actions;
  final String? rating;
  final DateTime? now;

  /// Canto direito do cartão (ex.: menu da agenda).
  final Widget? trailing;

  /// Sem a imagem e menor: só para a escolha da corrida na nova publicação (nas outras listas a imagem
  /// ocupa a largura inteira do cartão).
  final bool showImage;
  const EditionCompactCard({
    super.key,
    required this.gateway,
    required this.edition,
    this.onTap,
    this.actions,
    this.rating,
    this.now,
    this.trailing,
    this.showImage = true,
  });

  @override
  Widget build(BuildContext context) {
    final archived = edition['status'] == 'archived';
    final chips = distanceChips(edition);
    final muted = context.muted;
    final when = relativeDay('${edition['date']}', now: now);
    final where = [
      edition['city'],
      edition['state'],
    ].whereType<String>().join('/');
    return Card(
      key: Key('compact-card-${edition['id']}'),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.only(bottom: showImage ? 10 : 6),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A imagem ocupa a largura inteira do cartao (mesma lista em todas as telas).
            if (showImage)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    EditionCover(gateway: gateway, edition: edition),
                    // Só a data sobre a foto; o resto das informações fica embaixo.
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                        key: Key('date-chip-${edition['id']}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xb3000000),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          when,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: EdgeInsets.all(showImage ? 10 : 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!showImage) ...[
                          Text(
                            '$when · $where',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: archived
                                  ? context.archivedText
                                  : runPassOrange,
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                        ],
                        Text(
                          edition['name'] as String? ?? 'Corrida',
                          maxLines: showImage ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: showImage ? 16 : 14.5,
                            height: 1.2,
                            color: archived ? context.archivedText : null,
                          ),
                        ),
                        if (!showImage) ...[
                          const SizedBox(height: 6),
                          if (chips.isEmpty)
                            Text(
                              'Distância a confirmar',
                              style: TextStyle(color: muted, fontSize: 12.5),
                            )
                          else
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final chip in chips)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: context.panel,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      chip,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ] else ...[
                          const SizedBox(height: 8),
                          _InfoLine(
                            icon: Icons.place_outlined,
                            text: where.replaceAll('/', ', '),
                            color: muted,
                          ),
                          const SizedBox(height: 4),
                          _InfoLine(
                            icon: Icons.directions_run,
                            text: chips.isEmpty
                                ? 'Distância a confirmar'
                                : chips.join(' · '),
                            color: muted,
                          ),
                        ],
                        if (rating != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            rating!,
                            style: TextStyle(color: muted, fontSize: 12.5),
                          ),
                        ],
                        if (archived)
                          Text(
                            'Arquivada',
                            style: TextStyle(
                              color: context.archivedText,
                              fontSize: 12.5,
                            ),
                          ),
                        if (actions != null) ...[
                          const SizedBox(height: 8),
                          actions!,
                        ],
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Corrida em linha, como em "Quero correr" no perfil: miniatura à esquerda, nome, data e local, e um
/// controle à direita (o coração de "Quero correr"). Tocar na linha abre a corrida.
class PlanRow extends StatelessWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> edition;
  final VoidCallback? onTap;

  /// Controle do canto direito (ex.: o coração que tira a corrida de "Quero correr").
  final Widget? trailing;
  const PlanRow({
    super.key,
    required this.gateway,
    required this.edition,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final date = edition['date'] as String?;
    final place = [
      edition['city'],
      edition['state'],
    ].whereType<String>().where((p) => p.isNotEmpty).join(', ');
    final muted = context.muted;
    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, color: muted),
            ),
          ),
        ],
      ),
    );
    return Card(
      key: Key('plan-row-${edition['id']}'),
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          // Cabe nome em duas linhas, a data e o local (antes, com 92, o texto estourava uns 6 px).
          height: 104,
          child: Row(
            children: [
              SizedBox(
                width: 112,
                height: double.infinity,
                child: EditionCover(gateway: gateway, edition: edition),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        edition['name'] as String? ?? 'Corrida',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15.5,
                          height: 1.15,
                        ),
                      ),
                      if (date != null)
                        line(Icons.event_outlined, longDate(date)),
                      if (place.isNotEmpty) line(Icons.place_outlined, place),
                    ],
                  ),
                ),
              ),
              ?trailing,
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// Linha de informação com ícone (local e distâncias do cartão da lista).
class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _InfoLine({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 17, color: color),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: color),
        ),
      ),
    ],
  );
}
