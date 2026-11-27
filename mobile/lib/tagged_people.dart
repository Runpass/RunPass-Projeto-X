import 'package:flutter/material.dart';

import 'friends.dart';
import 'identity_gateway.dart';

/// Máximo de pessoas marcadas em uma publicação (o backend recusa mais que isso).
const maxTaggedPeople = 10;

/// Escolhe as pessoas marcadas na corrida postada. Devolve o perfil de quem ficou marcado (ordem mantida),
/// ou nulo se a pessoa desistiu. Perfil público pode ser marcado sem seguir; perfil privado só se eu o sigo.
Future<List<Map<String, dynamic>>?> pickTaggedPeople(
  BuildContext context,
  IdentityGateway gateway,
  List<Map<String, dynamic>> selected,
) => showModalBottomSheet<List<Map<String, dynamic>>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _TagPicker(gateway: gateway, selected: selected),
);

class _TagPicker extends StatefulWidget {
  final IdentityGateway gateway;
  final List<Map<String, dynamic>> selected;
  const _TagPicker({required this.gateway, required this.selected});

  @override
  State<_TagPicker> createState() => _TagPickerState();
}

class _TagPickerState extends State<_TagPicker> {
  final query = TextEditingController();
  late final List<Map<String, dynamic>> chosen = [...widget.selected];
  List<Map<String, dynamic>> shown = const [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  /// Sem texto: nada (não sugere ninguém). Com 2 letras ou mais: a busca por nome ou usuário.
  Future<void> load() async {
    final text = query.text.trim();
    setState(() {
      loading = true;
      error = null;
    });
    try {
      // Sem sugestões: só aparecem pessoas depois que o nome é digitado (2 letras ou mais).
      if (text.length < 2) {
        if (!mounted) return;
        setState(() => shown = const []);
        return;
      }
      final page = await widget.gateway.request(
        '/profiles',
        query: {'q': text, 'limit': '30'},
      );
      if (!mounted) return;
      setState(() {
        shown = (page['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
      });
    } on Exception {
      if (mounted) {
        setState(() => error = 'Não foi possível buscar agora. Tente de novo.');
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  bool isChosen(Map<String, dynamic> profile) =>
      chosen.any((p) => p['id'] == profile['id']);

  void toggle(Map<String, dynamic> profile) {
    setState(() {
      if (isChosen(profile)) {
        chosen.removeWhere((p) => p['id'] == profile['id']);
      } else if (chosen.length < maxTaggedPeople) {
        chosen.add(profile);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
    child: SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const Key('tag-search'),
              controller: query,
              textInputAction: TextInputAction.search,
              onChanged: (_) => load(),
              decoration: const InputDecoration(
                hintText: 'Buscar por nome ou @usuário',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (chosen.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final person in chosen)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InputChip(
                        key: Key('tag-chip-${person['id']}'),
                        label: Text('@${person['username'] ?? ''}'),
                        onDeleted: () => toggle(person),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                ? Center(child: Text(error!))
                : shown.isEmpty
                ? Center(
                    child: Text(
                      query.text.trim().length < 2
                          ? 'Digite o nome ou @usuário para buscar pessoas.'
                          : 'Ninguém encontrado.',
                      key: const Key('tag-empty'),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView(
                    children: [
                      for (final person in shown)
                        CheckboxListTile(
                          key: Key('tag-option-${person['id']}'),
                          value: isChosen(person),
                          onChanged: (_) => toggle(person),
                          secondary: ProfileAvatar(
                            gateway: widget.gateway,
                            profile: person,
                            radius: 20,
                          ),
                          title: Text('${person['displayName'] ?? ''}'),
                          subtitle: Text('@${person['username'] ?? ''}'),
                        ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('tag-done'),
                onPressed: () => Navigator.pop(context, chosen),
                child: Text(
                  chosen.isEmpty
                      ? 'Sem marcações'
                      : 'Marcar ${chosen.length} ${chosen.length == 1 ? 'pessoa' : 'pessoas'}',
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Ícone de etiqueta com a contagem, embaixo do cartão ao lado dos comentários: abre um pop-up com o perfil de cada pessoa marcada.
class TaggedLink extends StatelessWidget {
  final IdentityGateway gateway;
  final String postId;
  final List<Map<String, dynamic>> tagged;
  const TaggedLink({
    super.key,
    required this.gateway,
    required this.postId,
    required this.tagged,
  });

  @override
  Widget build(BuildContext context) {
    if (tagged.isEmpty) return const SizedBox.shrink();
    final shown = tagged.length < 3 ? tagged.length : 3;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Foto de ate 3 pessoas marcadas, sobrepostas; tocar numa mostra o cartao dela (como na busca).
        SizedBox(
          key: Key('post-tagged-faces-$postId'),
          height: 26,
          width: 26 + 14.0 * (shown - 1),
          child: Stack(
            children: [
              for (var i = 0; i < shown; i++)
                Positioned(
                  left: 14.0 * i,
                  child: GestureDetector(
                    key: Key('post-tagged-face-$postId-$i'),
                    onTap: () => showTaggedCard(context, gateway, tagged[i]),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 1.5,
                        ),
                      ),
                      child: ProfileAvatar(
                        gateway: gateway,
                        profile: tagged[i],
                        radius: 11,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (tagged.length > 3) ...[
          const SizedBox(width: 4),
          Text('+${tagged.length - 3}'),
        ],
      ],
    );
  }
}

/// O cartao da pessoa no mesmo formato da busca de amigos; tocar nele abre o perfil.
Future<void> showTaggedCard(
  BuildContext context,
  IdentityGateway gateway,
  Map<String, dynamic> person,
) => showModalBottomSheet<void>(
  context: context,
  builder: (sheet) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        key: Key('tagged-card-${person['id']}'),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          leading: ProfileAvatar(gateway: gateway, profile: person),
          title: Text(person['displayName'] as String? ?? ''),
          subtitle: Text('@${person['username'] ?? ''}'),
          onTap: () {
            Navigator.of(sheet).pop();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PublicProfileScreen(
                  gateway: gateway,
                  profileId: person['id'] as String,
                  initial: Map<String, dynamic>.from(person),
                ),
              ),
            );
          },
        ),
      ),
    ),
  ),
);

/// Pop-up com os perfis marcados; tocar em um abre o perfil da pessoa.
Future<void> showTaggedPeople(
  BuildContext context,
  IdentityGateway gateway,
  List<Map<String, dynamic>> tagged,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    key: const Key('tagged-dialog'),
    title: const Text('Pessoas marcadas'),
    content: SizedBox(
      width: double.maxFinite,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final person in tagged)
            ListTile(
              key: Key('tagged-${person['id']}'),
              contentPadding: EdgeInsets.zero,
              leading: ProfileAvatar(gateway: gateway, profile: person),
              title: Text('${person['displayName'] ?? ''}'),
              subtitle: Text('@${person['username'] ?? ''}'),
              onTap: () {
                Navigator.pop(dialogContext);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PublicProfileScreen(
                      gateway: gateway,
                      profileId: person['id'] as String,
                      initial: person,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Fechar'),
      ),
    ],
  ),
);
