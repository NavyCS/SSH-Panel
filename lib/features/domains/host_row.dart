import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../shared/widgets/action_row.dart';
import '../../shared/widgets/host_status_badge.dart';

/// One row of the Known Hosts list: host, key type, its actions, and the
/// result of the last scan of that host.
///
/// Split out of `main.dart`, where it was a method on the tab's state. It
/// renders [entry] plus a handful of flags and two callbacks, so it needs no
/// access to the controller -- which also makes the tab's shell shorter than
/// the row it hosts.
class HostRow extends StatelessWidget {
  const HostRow({
    super.key,
    required this.entry,
    required this.status,
    required this.isChecking,
    required this.isHostsLoading,
    required this.onCheck,
    required this.onRemove,
  });

  /// One `known_hosts` line as `{'host': ..., 'keyType': ...}`.
  final Map<String, String> entry;

  /// Last scan result for this host: `null` when never checked or in flight.
  final String? status;

  /// Whether this host already has a scan running.
  final bool isChecking;

  /// Whether the whole list is being re-read, which blocks every action.
  final bool isHostsLoading;

  /// Scans the host and shows what it offers.
  final VoidCallback onCheck;

  /// Asks for confirmation, then drops this entry from `known_hosts`.
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final host = entry['host']!;
    final keyType = entry['keyType']!;
    // Local copy: a public final field does not promote to non-null inside
    // `if (status != null)`, a local variable does.
    final status = this.status;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(
            LucideIcons.globe,
            size: 14,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  host,
                  style: theme.textTheme.small,
                  softWrap: true,
                ),
                if (keyType.isNotEmpty)
                  Text(
                    keyType,
                    style: theme.textTheme.muted,
                  ),
              ],
            ),
          ),
          ActionRow(
            actions: [
              RowAction(
                label: 'Check',
                onPressed: isHostsLoading || isChecking ? null : onCheck,
                enabledTooltip:
                    'Scan $host and show the keys it offers, to compare '
                    'with what known_hosts already has',
                disabledTooltip: isChecking
                    ? 'Already checking $host'
                    : 'Wait for the current operation to finish',
              ),
              RowAction(
                label: 'Remove',
                onPressed: isHostsLoading ? null : onRemove,
                enabledTooltip: 'Remove $host from known_hosts',
                disabledTooltip: 'Wait for the current operation to finish',
              ),
            ],
          ),
          const SizedBox(width: 6),
          if (status != null)
            // Not a button. It used to be wrapped in ShadButton.ghost with an
            // empty onPressed, which put a dead control in the tab order and
            // announced it as a button to screen readers. The status is read
            // only; the tooltip below carries the detail instead.
            ShadTooltip(
              builder: (context) => Text(
                status == 'Unreachable'
                    ? 'No response from $host. Check the hostname and that'
                        ' port 22 is reachable, then try again.'
                    : status.toLowerCase().startsWith('error')
                        ? status
                        : 'Key types offered by $host: $status',
              ),
              child: Semantics(
                label: 'Host status for $host: $status',
                child: HostStatusBadge(status: status),
              ),
            ),
        ],
      ),
    );
  }
}
