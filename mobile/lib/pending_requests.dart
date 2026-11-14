import 'package:flutter/material.dart';

import 'edition_requests.dart';
import 'identity_gateway.dart';
import 'my_races.dart' show fetchImageBytes;
import 'runpass_theme.dart';

/// Sugestões de corrida da própria pessoa que a equipe ainda não decidiu. Ficam visíveis só para ela, com
/// o aviso "Em análise"; se a equipe não aprovar, somem daqui e chega uma mensagem com o motivo.
Future<List<Map<String, dynamic>>> loadPendingRequests(
  IdentityGateway gateway,
) async {
  try {
    final page = await gateway.request(
      '/me/edition-requests',
      query: {'limit': '50'},
    );
    return [
      for (final item in (page['items'] as List? ?? const []))
        if ((item as Map)['kind'] != 'banner' &&
            (item['status'] == 'pending' ||
                item['status'] == 'awaiting_load') &&
            item['details'] is Map)
          Map<String, dynamic>.from(item),
    ];
  } on Exception {
    return const []; // é só um complemento da lista: nunca bloqueia a tela
  }
}

class PendingRequestsSection extends StatelessWidget {
  final IdentityGateway gateway;
  final List<Map<String, dynamic>> requests;
  const PendingRequestsSection({
    super.key,
    required this.gateway,
    required this.requests,
  });

  @override
  Widget build(BuildContext context) {
    if (requests.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('pending-requests'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            'Minhas sugestões em análise',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
        ),
        for (final request in requests)
          Card(
            key: Key('pending-request-${request['id']}'),
            child: ListTile(
              leading: Icon(Icons.lock_outline_rounded, color: context.muted),
              title: Text(
                '${(request['details'] as Map)['name']}',
                style: TextStyle(color: context.muted),
              ),
              subtitle: Text(
                '${_line(request['details'] as Map)}\nEm análise pela equipe · só você vê',
                style: TextStyle(color: context.muted),
              ),
              isThreeLine: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MyEditionRequestsScreen(gateway: gateway),
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }

  static String _line(Map details) {
    final date = details['date'] as String?;
    final shown = date == null ? '' : requestDateToDisplay(date);
    final place = [
      details['city'],
      details['state'],
    ].where((e) => e != null && '$e'.isNotEmpty).join('/');
    return [shown, place].where((e) => e.isNotEmpty).join(' · ');
  }
}

/// Banner que a própria pessoa sugeriu para esta corrida e a equipe ainda não decidiu. Aparece só para ela,
/// no lugar do banner (marcado como "em análise"); se a equipe não aprovar, deixa de aparecer e chega um aviso.
Future<List<int>?> loadProvisionalBanner(
  IdentityGateway gateway,
  String editionId,
) async {
  try {
    final page = await gateway.request(
      '/me/edition-requests',
      query: {'limit': '50'},
    );
    final mine = [
      for (final item in (page['items'] as List? ?? const []))
        if ((item as Map)['linkedEditionId'] == editionId &&
            item['bannerState'] == null &&
            (item['status'] == 'linked' || item['status'] == 'approved') &&
            (item['details'] as Map?)?['imageReference'] != null)
          item,
    ];
    if (mine.isEmpty) return null;
    final link = await gateway.request(
      '/edition-requests/${Uri.encodeComponent(mine.first['id'] as String)}/banner-image',
    );
    return await fetchImageBytes(link['url'] as String);
  } on Exception {
    return null;
  }
}
