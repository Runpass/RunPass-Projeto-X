import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'catalog_screen.dart' show catalogError;
import 'identity_gateway.dart';

/// Endereços das páginas legais. Entram na compilação (`--dart-define`), não no código: a política e os
/// termos são textos do jurídico, publicados num endereço que o time define. Sem o endereço, o app avisa em
/// vez de abrir uma página que não existe.
const privacyPolicyUrl = String.fromEnvironment('RUNPASS_PRIVACY_URL');
const termsOfUseUrl = String.fromEnvironment('RUNPASS_TERMS_URL');

/// Abre uma página legal no navegador. [url] vazio ou que não seja https mostra um aviso.
Future<void> openLegalPage(
  BuildContext context,
  String url, {
  required String name,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('$name ainda não está disponível neste aparelho.'),
      ),
    );
    return;
  }
  final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!opened) {
    messenger.showSnackBar(
      SnackBar(content: Text('Não foi possível abrir $name agora.')),
    );
  }
}

/// "Ao continuar você aceita os Termos de uso e a Política de privacidade", com os dois links. Fica nas telas de
/// entrar e de criar conta.
class LegalLinks extends StatelessWidget {
  final bool acceptance;
  const LegalLinks({super.key, this.acceptance = false});

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('legal-links'),
    children: [
      if (acceptance)
        Text(
          'Ao criar a conta, você aceita os termos de uso e a política de privacidade.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
      Wrap(
        alignment: WrapAlignment.center,
        children: [
          TextButton(
            key: const Key('legal-terms'),
            onPressed: () =>
                openLegalPage(context, termsOfUseUrl, name: 'Os termos de uso'),
            child: const Text('Termos de uso'),
          ),
          TextButton(
            key: const Key('legal-privacy'),
            onPressed: () => openLegalPage(
              context,
              privacyPolicyUrl,
              name: 'A política de privacidade',
            ),
            child: const Text('Política de privacidade'),
          ),
        ],
      ),
    ],
  );
}

/// Motivos de denúncia, com o valor que vai ao servidor.
const reportReasons = [
  ('spam', 'Spam ou propaganda'),
  ('offensive', 'Ofensivo, assédio ou ódio'),
  ('nudity', 'Nudez ou conteúdo sexual'),
  ('violence', 'Violência'),
  ('fake', 'Perfil falso'),
  ('other', 'Outro motivo'),
];

/// Pergunta o motivo e envia a denúncia. [targetType]: `post`, `comment` ou `user`. Com [blockUserId], oferece
/// bloquear a pessoa em seguida. Devolve `true` quando a denúncia foi enviada.
Future<bool> reportContent(
  BuildContext context,
  IdentityGateway gateway, {
  required String targetType,
  required String targetId,
  String? blockUserId,
  String? blockUserName,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showDialog<(String, String)>(
    context: context,
    builder: (_) => const _ReportDialog(),
  );
  if (choice == null) return false;
  try {
    await gateway.request(
      '/reports',
      method: 'POST',
      body: {
        'targetType': targetType,
        'targetId': targetId,
        'reason': choice.$1,
        if (choice.$2.isNotEmpty) 'text': choice.$2,
      },
    );
  } on IdentityIssue catch (issue) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          issue.code == 'REPORT_LIMIT_REACHED'
              ? 'Você já fez o máximo de denúncias de hoje. Tente de novo amanhã.'
              : catalogError(issue),
        ),
      ),
    );
    return false;
  } on Exception {
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Não foi possível enviar a denúncia agora. Tente de novo.',
        ),
      ),
    );
    return false;
  }
  messenger.showSnackBar(
    const SnackBar(
      content: Text('Denúncia enviada. Nossa equipe vai analisar. Obrigado.'),
    ),
  );
  if (blockUserId != null && context.mounted) {
    await blockPerson(
      context,
      gateway,
      blockUserId,
      blockUserName ?? 'esta pessoa',
      offer: true,
    );
  }
  return true;
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog();

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  String? reason;
  final text = TextEditingController();

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Denunciar'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Qual é o problema?'),
          RadioGroup<String>(
            groupValue: reason,
            onChanged: (value) => setState(() => reason = value),
            child: Column(
              children: [
                for (final r in reportReasons)
                  RadioListTile<String>(
                    key: Key('report-reason-${r.$1}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.$2),
                    value: r.$1,
                  ),
              ],
            ),
          ),
          TextField(
            key: const Key('report-text'),
            controller: text,
            maxLength: 1000,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Detalhes (opcional)'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        key: const Key('report-send'),
        onPressed: reason == null
            ? null
            : () => Navigator.pop(context, (reason!, text.text.trim())),
        child: const Text('Enviar denúncia'),
      ),
    ],
  );
}

/// Bloqueia uma pessoa (com confirmação, a menos que já tenha sido pedida em [offer]). Devolve `true` se
/// bloqueou. Depois de bloquear, a pessoa e as publicações dela somem para os dois lados.
Future<bool> blockPerson(
  BuildContext context,
  IdentityGateway gateway,
  String profileId,
  String name, {
  bool offer = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(offer ? 'Bloquear também?' : 'Bloquear $name?'),
      content: Text(
        'Vocês deixam de ver as publicações, comentários e o perfil um do outro, '
        'e a amizade e o seguir acabam. Dá para desbloquear em Configurações > Pessoas bloqueadas.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: Text(offer ? 'Agora não' : 'Cancelar'),
        ),
        FilledButton(
          key: const Key('block-confirm'),
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('Bloquear'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  try {
    await gateway.request(
      '/profiles/${Uri.encodeComponent(profileId)}/block',
      method: 'PUT',
    );
  } on IdentityIssue catch (issue) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          issue.code == 'BLOCK_LIMIT_REACHED'
              ? 'Você atingiu o limite de pessoas bloqueadas. Desbloqueie alguém em Configurações.'
              : catalogError(issue),
        ),
      ),
    );
    return false;
  } on Exception {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Não foi possível bloquear agora. Tente de novo.'),
      ),
    );
    return false;
  }
  messenger.showSnackBar(SnackBar(content: Text('$name foi bloqueado.')));
  return true;
}

/// Configurações > Pessoas bloqueadas: quem eu bloqueei, com Desbloquear.
class BlockedPeopleScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const BlockedPeopleScreen({super.key, required this.gateway});

  @override
  State<BlockedPeopleScreen> createState() => _BlockedPeopleScreenState();
}

class _BlockedPeopleScreenState extends State<BlockedPeopleScreen> {
  List<Map<String, dynamic>>? items;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => failed = false);
    try {
      final result = await widget.gateway.request('/me/blocks');
      if (!mounted) return;
      setState(
        () => items = ((result['items'] as List?) ?? const [])
            .cast<Map<String, dynamic>>(),
      );
    } on Exception {
      if (mounted) setState(() => failed = true);
    }
  }

  Future<void> unblock(Map<String, dynamic> person) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.gateway.request(
        '/profiles/${Uri.encodeComponent(person['id'] as String)}/block',
        method: 'DELETE',
      );
      if (!mounted) return;
      setState(
        () => items = items!.where((p) => p['id'] != person['id']).toList(),
      );
      messenger.showSnackBar(
        SnackBar(content: Text('${person['displayName']} foi desbloqueado.')),
      );
    } on Exception {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Não foi possível desbloquear agora. Tente de novo.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = items;
    return Scaffold(
      appBar: AppBar(title: const Text('Pessoas bloqueadas')),
      body: failed
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Não foi possível carregar agora.'),
                  TextButton(
                    onPressed: load,
                    child: const Text('Tentar de novo'),
                  ),
                ],
              ),
            )
          : list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
          ? const Center(
              key: Key('blocked-empty'),
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Você não bloqueou ninguém.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                for (final p in list)
                  ListTile(
                    key: Key('blocked-${p['id']}'),
                    leading: const CircleAvatar(
                      child: Icon(Icons.person_off_outlined),
                    ),
                    title: Text('${p['displayName'] ?? 'Usuário removido'}'),
                    subtitle: p['username'] == null
                        ? null
                        : Text('@${p['username']}'),
                    trailing: TextButton(
                      key: Key('unblock-${p['id']}'),
                      onPressed: () => unblock(p),
                      child: const Text('Desbloquear'),
                    ),
                  ),
              ],
            ),
    );
  }
}
