import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../shared/plural.dart';

/// Step 2 of the add-host flow: choose which of the keys the scan just
/// fetched are written to `known_hosts`.
///
/// Step 1 (running `ssh-keyscan`) happens in the tab before this dialog
/// opens, so the keys already exist by the time the user gets here; the only
/// question this dialog answers is which of them to keep. The description
/// therefore reports what the scan found -- the old text said "select the key
/// algorithms to add", which gave "these" no referent and never said why
/// anyone would clear a checkbox.
///
/// Returns the selected `known_hosts` lines, or `null` when the dialog is
/// cancelled or nothing is selected.
Future<List<String>?> selectKeysToAdd(
  BuildContext context, {
  required String host,
  required List<Map<String, String>> available,
}) async {
  final selected = {for (var i = 0; i < available.length; i++) i};

  final confirmed = await showShadDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setStateDialog) => ShadDialog(
        title: Text('Add $host to known_hosts'),
        description: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Step 2 of 2 · Scan complete: '
              '${plural(available.length, 'key')} found on $host.',
            ),
            const SizedBox(height: 6),
            const Text(
              'Only keys that are not in known_hosts yet are listed. '
              'All are selected — clear one only if a client you use '
              'does not support that algorithm, because anything you clear '
              'is left out of known_hosts.',
            ),
          ],
        ),
        actions: [
          Semantics(
            button: true,
            label: 'Cancel add keys',
            child: ShadButton.outline(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Semantics(
            button: true,
            label: 'Add selected keys',
            child: ShadButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('Add'),
            ),
          ),
        ],
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < available.length; i++)
              Row(
                children: [
                  ShadCheckbox(
                    value: selected.contains(i),
                    onChanged: (value) {
                      setStateDialog(() {
                        if (value) {
                          selected.add(i);
                        } else {
                          selected.remove(i);
                        }
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  Text(
                    available[i]['keyType']!,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ],
              ),
          ],
        ),
      ),
    ),
  );

  if (confirmed != true || selected.isEmpty) return null;
  return selected.map((i) => available[i]['line']!).toList();
}
