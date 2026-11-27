import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Campo de tempo que abre um seletor de rolagem (horas, minutos e segundos).
/// O valor continua guardado no [controller] como "h:mm:ss" (vazio = sem tempo),
/// o mesmo formato que `parseDuration` já lê.
class DurationField extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  const DurationField({
    super.key,
    required this.controller,
    this.enabled = true,
  });

  static Duration _read(String text) {
    final parts = text.split(':').map(int.tryParse).toList();
    if (parts.length != 3 || parts.any((p) => p == null)) return Duration.zero;
    return Duration(hours: parts[0]!, minutes: parts[1]!, seconds: parts[2]!);
  }

  static String format(Duration d) {
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '${d.inHours}:$m:$s';
  }

  Future<void> _pick(BuildContext context) async {
    var chosen = _read(controller.text);
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Cabeçalho com OK sempre visível no alto: Cancelar à esquerda, OK à direita.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  TextButton(
                    key: const Key('duration-cancel'),
                    onPressed: () => Navigator.of(sheet).pop(),
                    child: const Text('Cancelar'),
                  ),
                  const Expanded(
                    child: Text(
                      'Tempo da corrida',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton(
                    key: const Key('duration-ok'),
                    onPressed: () =>
                        Navigator.of(sheet)
                            .pop(chosen == Duration.zero ? '' : format(chosen)),
                    child: const Text(
                      'OK',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 200,
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: Theme.of(sheet).brightness,
                ),
                child: CupertinoTimerPicker(
                  key: const Key('duration-picker'),
                  mode: CupertinoTimerPickerMode.hms,
                  initialTimerDuration: chosen,
                  onTimerDurationChanged: (value) => chosen = value,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  TextButton(
                    key: const Key('duration-clear'),
                    onPressed: () => Navigator.of(sheet).pop(''),
                    child: const Text('Limpar'),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const Key('duration-confirm'),
                    // O tema do app pede largura total nos botões cheios; numa linha com Spacer isso é
                    // largura infinita e o seletor não abre. Aqui o botão tem o tamanho do rótulo.
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(96, 44),
                    ),
                    onPressed: () =>
                        Navigator.of(sheet)
                            .pop(chosen == Duration.zero ? '' : format(chosen)),
                    child: const Text('OK'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (result != null) controller.text = result;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => InkWell(
      key: const Key('time-field'),
      onTap: enabled ? () => _pick(context) : null,
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Tempo (opcional)',
          suffixIcon: Icon(Icons.timer_outlined),
        ),
        child: Text(
          controller.text.isEmpty ? 'Toque para escolher' : controller.text,
        ),
      ),
    ),
  );
}
