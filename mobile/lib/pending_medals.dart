import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'identity_gateway.dart';
import 'runpass_theme.dart';

/// Medalhas provisórias: pedidos de cadastro de corrida que levaram a foto da medalha (`details.medalPhoto`).
/// Ficam na prateleira como "Em análise" até a equipe decidir; a foto só aparece para a própria pessoa.
Future<List<Map<String, dynamic>>> loadPendingMedals(
  IdentityGateway gateway,
) async {
  try {
    final page = await gateway.request(
      '/me/edition-requests',
      query: {'limit': '50'},
    );
    return [
      for (final item in (page['items'] as List? ?? const []))
        if (((item as Map)['details'] as Map?)?['medalPhoto'] == true &&
            item['kind'] != 'banner')
          Map<String, dynamic>.from(item),
    ];
  } on Exception {
    return const []; // é só um complemento da prateleira: nunca bloqueia a tela
  }
}

/// Pedidos aprovados cuja corrida a pessoa já concluiu deixam de aparecer: a medalha de verdade já está na prateleira.
List<Map<String, dynamic>> visiblePendingMedals(
  List<Map<String, dynamic>> pending,
  Set<String> completedEditionIds,
) => [
  for (final request in pending)
    if (!completedEditionIds.contains(request['linkedEditionId']?.toString()))
      request,
];

String pendingMedalStatus(Map<String, dynamic> request) =>
    switch (request['status']) {
      'approved' || 'linked' => 'Corrida aprovada. Toque para concluir.',
      'rejected' => 'Cadastro não aprovado${_reason(request)}',
      _ => 'Em análise pela equipe',
    };

String _reason(Map<String, dynamic> request) {
  final reason = request['reason'];
  return reason is String && reason.isNotEmpty ? ': $reason' : '';
}

class PendingMedalsSection extends StatelessWidget {
  final IdentityGateway gateway;
  final List<Map<String, dynamic>> requests;
  final Future<List<int>?> Function(IdentityGateway gateway, String requestId)
  photoLoader;
  const PendingMedalsSection({
    super.key,
    required this.gateway,
    required this.requests,
    this.photoLoader = loadRequestMedalPhoto,
  });

  @override
  Widget build(BuildContext context) {
    if (requests.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('pending-medals'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 8, 4, 6),
          child: Text(
            'Medalhas em análise',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
        ),
        for (final request in requests)
          _PendingMedalTile(
            key: Key('pending-medal-${request['id']}'),
            gateway: gateway,
            request: request,
            photoLoader: photoLoader,
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Foto da medalha do próprio pedido (`GET /edition-requests/{id}/medal-image`, link curto e assinado).
Future<List<int>?> loadRequestMedalPhoto(
  IdentityGateway gateway,
  String requestId,
) async {
  try {
    final link = await gateway.request(
      '/edition-requests/${Uri.encodeComponent(requestId)}/medal-image',
    );
    return await fetchImageBytes(link['url'] as String);
  } on Exception {
    return null;
  }
}

class _PendingMedalTile extends StatefulWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> request;
  final Future<List<int>?> Function(IdentityGateway, String) photoLoader;
  const _PendingMedalTile({
    super.key,
    required this.gateway,
    required this.request,
    required this.photoLoader,
  });

  @override
  State<_PendingMedalTile> createState() => _PendingMedalTileState();
}

class _PendingMedalTileState extends State<_PendingMedalTile> {
  late final Future<List<int>?> photo = widget.photoLoader(
    widget.gateway,
    widget.request['id'] as String,
  );

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final details = (request['details'] as Map?) ?? const {};
    final linked = request['linkedEditionId'] as String?;
    final approved =
        request['status'] == 'approved' || request['status'] == 'linked';
    // Bloqueada (cinza, com cadeado) até a equipe aprovar a corrida; aprovada, ganha cor e abre a corrida.
    final locked = !approved;
    const grey = ColorFilter.matrix(<double>[
      0.2126,
      0.7152,
      0.0722,
      0,
      0,
      0.2126,
      0.7152,
      0.0722,
      0,
      0,
      0.2126,
      0.7152,
      0.0722,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]);
    return Card(
      child: ListTile(
        key: Key('pending-locked-${request['id']}-$locked'),
        onTap: approved && linked != null
            ? () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      EditionScreen(gateway: widget.gateway, editionId: linked),
                ),
              )
            : null,
        leading: SizedBox(
          width: 60,
          height: 60,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: FutureBuilder<List<int>?>(
                  future: photo,
                  builder: (context, snapshot) {
                    final bytes = snapshot.data;
                    final image = bytes == null
                        ? const ColoredBox(
                            color: Color(0x22FF7A00),
                            child: Icon(
                              Icons.workspace_premium_outlined,
                              color: runPassOrange,
                            ),
                          )
                        : Image.memory(
                            Uint8List.fromList(bytes),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          );
                    return locked
                        ? ColorFiltered(
                            colorFilter: grey,
                            child: Opacity(opacity: .55, child: image),
                          )
                        : image;
                  },
                ),
              ),
              if (locked)
                const Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xAA000000),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.lock_outline_rounded,
                        key: Key('pending-lock'),
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        title: Text(
          '${details['name'] ?? 'Medalha'}',
          style: TextStyle(color: locked ? context.muted : null),
        ),
        subtitle: Text(
          pendingMedalStatus(request),
          key: Key('pending-status-${request['id']}'),
          style: TextStyle(color: locked ? context.muted : null),
        ),
        trailing: approved ? const Icon(Icons.chevron_right) : null,
      ),
    );
  }
}
