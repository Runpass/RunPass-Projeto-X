import 'package:flutter/material.dart';

/// Ids de itens com exclusão em espera (janela do "Desfazer"): as listas os escondem enquanto a janela está aberta,
/// mesmo que recarreguem do servidor, onde o item ainda existe.
final Set<String> pendingDeletions = {};

/// Exclusão com "Desfazer". O item some da tela na hora ([hide]); a exclusão no servidor ([perform]) só é enviada
/// depois que a janela ([window]) fecha sem a pessoa tocar em "Desfazer". Se desfizer, [restore] traz o item de
/// volta e nada é enviado. Devolve verdadeiro se a exclusão foi feita.
///
/// Se o app for fechado durante a janela, a exclusão NÃO é enviada (o item continua existindo): o padrão seguro.
/// Exceções de [perform] sobem para quem chamou, que deve chamar [restore] e avisar.
Future<bool> deleteWithUndo(
  BuildContext context, {
  required String id,
  required String message,
  required VoidCallback hide,
  required VoidCallback restore,
  required Future<void> Function() perform,
  Duration window = const Duration(seconds: 6),
}) async {
  final messenger = ScaffoldMessenger.of(context);
  pendingDeletions.add(id);
  hide();
  final reason = await messenger
      .showSnackBar(
        SnackBar(
          content: Text(message),
          duration: window,
          // Com ação, o SnackBar do Flutter 3.29+ fica até ser dispensado; aqui ele fecha sozinho na janela.
          persist: false,
          action: SnackBarAction(
            key: const Key('undo-delete'),
            label: 'Desfazer',
            onPressed: () {},
          ),
        ),
      )
      .closed;
  if (reason == SnackBarClosedReason.action) {
    pendingDeletions.remove(id);
    restore();
    return false;
  }
  try {
    await perform();
  } finally {
    pendingDeletions.remove(id);
  }
  return true;
}
