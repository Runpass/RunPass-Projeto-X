import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'identity_gateway.dart';
import 'location_picker.dart';
import 'my_races.dart' show birthDateLabel;

/// Seletor de data de nascimento (rolagem). Trocavel nos testes.
typedef BirthDatePicker = Future<DateTime?> Function(
  BuildContext context,
  DateTime initial,
);

Future<DateTime?> pickBirthDateByScroll(
  BuildContext context,
  DateTime initial,
) async {
  var chosen = initial;
  final now = DateTime.now();
  return showModalBottomSheet<DateTime>(
    context: context,
    builder: (context) => SizedBox(
      height: 320,
      child: Column(
        children: [
          Expanded(
            child: CupertinoDatePicker(
              key: const Key('birth-wheel'),
              mode: CupertinoDatePickerMode.date,
              initialDateTime: initial,
              minimumDate: DateTime(now.year - 110),
              maximumDate: now,
              onDateTimeChanged: (value) => chosen = value,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton(
              key: const Key('birth-done'),
              onPressed: () => Navigator.pop(context, chosen),
              child: const Text('Confirmar'),
            ),
          ),
        ],
      ),
    ),
  );
}

String editProfileError(Object error) {
  if (error is IdentityIssue) {
    return switch (error.code) {
      'NOT_ELIGIBLE' =>
        'É preciso ter 13 anos ou mais. Confira a data de nascimento.',
      'VERSION_CONFLICT' => 'Seu perfil mudou em outro lugar. Abra a edição de novo e tente outra vez.',
      'INVALID_INPUT' => 'Confira os campos: o nome não pode ficar vazio.',
      _ => 'Não foi possível salvar. Tente de novo.',
    };
  }
  return 'Não foi possível salvar. Tente de novo.';
}

/// Editar perfil: nome, data de nascimento (a idade vem dela), frase e estado/cidade.
/// Só envia o que mudou. Fecha com `true` quando salvou.
class EditProfileScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final Map<String, dynamic> profile;
  final BirthDatePicker birthDatePicker;
  const EditProfileScreen({
    super.key,
    required this.gateway,
    required this.profile,
    this.birthDatePicker = pickBirthDateByScroll,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final name = TextEditingController(
    text: widget.profile['displayName'] as String? ?? '',
  );
  late final phrase = TextEditingController(
    text: widget.profile['bio'] as String? ?? '',
  );
  // `late final` so e avaliado no primeiro uso; por isso o original e lido do perfil.
  DateTime? get originalBirth =>
      DateTime.tryParse(widget.profile['birthDate'] as String? ?? '');
  late DateTime? birth = originalBirth;
  (String, String, double?, double?)? location;
  bool busy = false;
  String? message;

  @override
  void dispose() {
    name.dispose();
    phrase.dispose();
    super.dispose();
  }

  static String iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> pickBirth() async {
    final now = DateTime.now();
    final picked = await widget.birthDatePicker(
      context,
      birth ?? DateTime(now.year - 30, now.month, now.day),
    );
    if (picked != null && mounted) {
      setState(() => birth = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> pickLocation() async {
    final picked = await pickBrLocation(
      context,
      initialUf: location?.$1 ?? widget.profile['state'] as String?,
      initialCity: location?.$2 ?? widget.profile['city'] as String?,
    );
    if (picked != null && mounted) setState(() => location = picked);
  }

  Future<void> save() async {
    final body = <String, dynamic>{};
    final newName = name.text.trim();
    if (newName.isEmpty) {
      setState(() => message = 'Informe seu nome.');
      return;
    }
    if (newName != (widget.profile['displayName'] as String? ?? '')) {
      body['displayName'] = newName;
    }
    final newPhrase = phrase.text.trim();
    final oldPhrase = (widget.profile['bio'] as String? ?? '').trim();
    if (newPhrase != oldPhrase) {
      body['bio'] = newPhrase.isEmpty ? null : newPhrase;
    }
    if (birth != null &&
        (originalBirth == null || iso(birth!) != iso(originalBirth!))) {
      body['birthDate'] = iso(birth!);
    }
    if (location != null) {
      body.addAll(
        brLocationPatch(location!.$1, location!.$2, location!.$3, location!.$4),
      );
    }
    if (body.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.gateway.request(
        '/me',
        method: 'PATCH',
        body: {'expectedVersion': widget.profile['version'], ...body},
      );
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          busy = false;
          message = editProfileError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final birthText = birth == null
        ? 'Toque para informar'
        : birthDateLabel(iso(birth!)) ?? 'Toque para informar';
    final place = location == null
        ? brLocationLabel(widget.profile)
        : '${location!.$1} - ${location!.$2}';
    return Scaffold(
      appBar: AppBar(title: const Text('Editar perfil')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('edit-name'),
            controller: name,
            maxLength: 80,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nome'),
          ),
          const SizedBox(height: 8),
          ListTile(
            key: const Key('edit-birth'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cake_outlined),
            title: const Text('Data de nascimento'),
            subtitle: Text(birthText),
            trailing: const Icon(Icons.chevron_right),
            onTap: pickBirth,
          ),
          ListTile(
            key: const Key('edit-location'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined),
            title: const Text('Estado e cidade'),
            subtitle: Text(place ?? 'Toque para informar'),
            trailing: const Icon(Icons.chevron_right),
            onTap: pickLocation,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('edit-phrase'),
            controller: phrase,
            maxLength: 140,
            maxLines: 3,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Frase',
              hintText: 'Uma frase sua, que aparece no perfil',
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(
              message!,
              key: const Key('edit-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('edit-save'),
            onPressed: busy ? null : save,
            child: Text(busy ? 'Salvando…' : 'Salvar'),
          ),
        ],
      ),
    );
  }
}
