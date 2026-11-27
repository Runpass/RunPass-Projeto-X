import 'package:flutter/material.dart';

import 'identity_gateway.dart';
import 'runpass_theme.dart';

/// Tipos de feedback, com o valor que vai ao servidor.
const feedbackKinds = [
  ('suggestion', 'Sugestão', Icons.lightbulb_outline),
  ('problem', 'Problema', Icons.bug_report_outlined),
  ('praise', 'Elogio', Icons.favorite_border),
];

/// Feedback sobre o app: a pessoa escolhe o tipo e escreve. Vai só para a equipe (não é publicado).
class FeedbackScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const FeedbackScreen({super.key, required this.gateway});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  static const maxLength = 2000;
  final text = TextEditingController();
  String kind = 'suggestion';
  bool sending = false;
  String? error;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final value = text.text.trim();
    if (value.isEmpty) {
      setState(() => error = 'Escreva a sua mensagem antes de enviar.');
      return;
    }
    setState(() {
      sending = true;
      error = null;
    });
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.gateway.request(
        '/feedback',
        method: 'POST',
        body: {'kind': kind, 'text': value},
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Feedback enviado. Obrigado por ajudar a melhorar o app!',
          ),
        ),
      );
      if (navigator.canPop()) navigator.pop();
    } on IdentityIssue catch (issue) {
      if (!mounted) return;
      setState(
        () => error = switch (issue.code) {
          'FEEDBACK_LIMIT_REACHED' => 'Você já enviou o máximo de feedbacks de hoje. Tente de novo amanhã.',
          'SERVICE_UNAVAILABLE' => 'Sem conexão com o servidor. Verifique a internet e tente de novo; o texto continua aqui.',
          _ => 'Não foi possível enviar agora. Tente de novo; o texto continua aqui.',
        },
      );
    } on Exception {
      if (mounted) {
        setState(
          () => error = 'Não foi possível enviar agora. Tente de novo; o texto continua aqui.',
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Enviar feedback')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Conte o que você achou do app: uma ideia, algo que não funcionou ou o que você gostou. '
          'A mensagem vai só para a equipe do +1Pódio.',
          style: TextStyle(color: context.muted),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (value, label, icon) in feedbackKinds)
              ChoiceChip(
                key: Key('feedback-kind-$value'),
                avatar: Icon(icon, size: 18),
                label: Text(label),
                showCheckmark: false,
                selected: kind == value,
                onSelected: sending
                    ? null
                    : (_) => setState(() => kind = value),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('feedback-text'),
          controller: text,
          enabled: !sending,
          minLines: 5,
          maxLines: 10,
          maxLength: maxLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Sua mensagem',
            alignLabelWithHint: true,
            hintText: kind == 'problem'
                ? 'O que você estava fazendo e o que aconteceu?'
                : 'Escreva aqui',
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(error!, key: const Key('feedback-error')),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('feedback-send'),
          onPressed: sending ? null : send,
          icon: const Icon(Icons.send_rounded),
          label: Text(sending ? 'Enviando…' : 'Enviar'),
        ),
      ],
    ),
  );
}
