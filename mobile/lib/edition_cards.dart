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
