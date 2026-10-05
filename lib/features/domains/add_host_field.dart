import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Step 1 of the add-host flow: type a host, then scan it.
///
/// One click runs the whole flow -- scan the host, then choose which of the
/// keys it returned to write -- and it used to read as a single action: the
/// only sign of progress was a spinner living inside the "Add" button, and
/// the algorithm dialog popped up whenever the scan happened to finish. The
/// two phases the flow already had are now visible without adding a single
/// step:
///
/// * the button names the phase it is in ("Scanning…"), and
/// * a status line under the row says the scan is step 1 of 2, and
/// * the dialog that follows opens with "Step 2 of 2".
class AddHostField extends StatelessWidget {
  const AddHostField({
    super.key,
    required this.hostController,
    required this.isScanning,
    required this.isHostsLoading,
    required this.onAdd,
  });

  /// Field contents. Owned by the tab, which clears it after a successful add.
  final TextEditingController hostController;

  /// True while `ssh-keyscan` is running for the typed host.
  final bool isScanning;

  /// True while `known_hosts` is being re-read, which also blocks the button.
  final bool isHostsLoading;

  /// Starts the flow: validate, scan, then open the key-selection dialog.
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The whole row rebuilds on every keystroke, not just the input. The
          // tooltip and the status line quote the typed host, and this widget is
          // not listening to hostController itself -- reading the text here
          // while only the input rebuilt left both quoting an empty host.
          ListenableBuilder(
            listenable: hostController,
            builder: (context, _) {
              final host = hostController.text.trim();
              return Row(
                children: [
                  Expanded(
                    child: ShadInput(
                      controller: hostController,
                      placeholder: const Text('example.com'),
                      onSubmitted: isScanning ? null : (_) => onAdd(),
                      enabled: !isScanning,
                      trailing: hostController.text.isNotEmpty && !isScanning
                          ? Semantics(
                              button: true,
                              label: 'Clear host input',
                              child: ShadButton.ghost(
                                size: ShadButtonSize.sm,
                                onPressed: hostController.clear,
                                child: const Icon(LucideIcons.x, size: 14),
                              ),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ShadTooltip(
                    builder: (context) => Text(
                      isScanning
                          ? 'Step 1 of 2: fetching the host keys for $host.'
                          : 'Step 1 scans $host for its keys; step 2 lets you '
                              'choose which of them to add to known_hosts.',
                    ),
                    child: Semantics(
                      button: true,
                      label: isScanning
                          ? 'Scanning $host for keys'
                          : 'Add host to known_hosts',
                      child: ShadButton(
                        onPressed: isScanning || isHostsLoading ? null : onAdd,
                        leading: isScanning
                            ? SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: theme.colorScheme.primaryForeground,
                                ),
                              )
                            : null,
                        child: Text(isScanning ? 'Scanning…' : 'Add'),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          if (isScanning) ...[
            const SizedBox(height: 8),
            Text(
              'Step 1 of 2 · Scanning ${hostController.text.trim()} for keys…',
              style: theme.textTheme.muted,
            ),
          ],
        ],
      ),
    );
  }
}
