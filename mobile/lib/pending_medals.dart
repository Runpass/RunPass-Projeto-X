import 'identity_gateway.dart';
import 'my_races.dart' show fetchImageBytes;

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
        if (((item as Map)['details'] as Map?)?['medalImageReference'] !=
                null &&
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
