import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Asks the user for an SSH key passphrase.
///
/// This was previously inlined twice in `main.dart` — once to load an existing
/// key into the agent, once to create a new one — and the two copies had
/// drifted apart in their wording. The create path was showing
/// "This key is protected by a passphrase", which is only true once the key
/// already exists; when you were *choosing* a passphrase for a brand new key
/// that sentence was simply wrong. [title] and [description] therefore make the
/// caller state the intent, and [confirmLabel] states the consequence.
///
/// Returns the passphrase, or `null` if the user cancelled.
Future<String?> promptPassphrase(
  BuildContext context, {
  required String title,
  required String description,
  String confirmLabel = 'Confirm',
  bool confirmReveals = false,
}) async {
  final controller = TextEditingController();
  var obscure = true;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setStateDialog) => ShadDialog(
        title: Text(title),
        description: Text(description),
        actions: [
          Semantics(
            button: true,
            label: 'Cancel passphrase prompt',
            child: ShadButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Semantics(
            button: true,
            label: confirmLabel,
            child: ShadButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmLabel),
            ),
          ),
        ],
        child: ShadInput(
          controller: controller,
          obscureText: obscure,
          // Focus the field on open: the only purpose of this dialog is to
          // receive a passphrase, and making the user click the field first is
          // a wasted step. Escape also closes, matching the Cancel button.
          autofocus: true,
          placeholder: const Text('Enter passphrase'),
          onSubmitted: (_) => Navigator.of(ctx).pop(true),
          trailing: SizedBox.square(
            dimension: 24,
            child: OverflowBox(
              maxWidth: 28,
              maxHeight: 28,
              child: Semantics(
                button: true,
                label: obscure ? 'Show passphrase' : 'Hide passphrase',
                child: ShadIconButton(
                  iconSize: 20,
                  padding: const EdgeInsets.all(2),
                  icon: Icon(obscure ? LucideIcons.eyeOff : LucideIcons.eye),
                  onPressed: () {
                    setStateDialog(() => obscure = !obscure);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  if (confirmed != true) {
    controller.dispose();
    return null;
  }
  final passphrase = controller.text;
  controller.dispose();
  return passphrase;
}
