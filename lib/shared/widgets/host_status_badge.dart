import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Read-only status pill for a host in the Known Hosts list.
///
/// This replaces a `ShadButton.ghost` with an empty `onPressed` that used to
/// wrap the badge. That put a control in the tab order that did nothing when
/// activated, and told screen-reader users it was a button. A status is not an
/// action, so it is now a plain badge; the detail lives in the surrounding
/// tooltip.
///
/// It also carries the semantic colour that the badge was missing: before, a
/// successful scan ("3 keys found"), an unreachable host, and an error all
/// rendered as the same neutral pill, so the row gave no visual signal at a
/// glance. Danger states are now destructive-coloured and success is
/// success-coloured, matching how the rest of the app reports the same
/// outcomes in toasts.
class HostStatusBadge extends StatelessWidget {
  const HostStatusBadge({super.key, required this.status});

  /// A comma-joined list of key types, or the literal `Unreachable`.
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    final isUnreachable = status == 'Unreachable';
    final isError = status.toLowerCase().startsWith('error');

    final label = isUnreachable
        ? 'Unreachable'
        : isError
            ? status
            : _pluralizeKeys(status.split(', ').where((s) => s.isNotEmpty).length);

    final badge = isUnreachable || isError
        ? ShadBadge.destructive(child: Text(label))
        : ShadBadge.secondary(child: Text(label));

    // 10px was below any comfortable reading size and collapsed further under
    // Windows display scaling; 12 is the floor this app now uses.
    return DefaultTextStyle.merge(
      style: theme.textTheme.small.copyWith(fontSize: 12),
      child: badge,
    );
  }

  /// Formats a key count without the "key(s)" pattern used elsewhere in the app.
  static String _pluralizeKeys(int count) =>
      count == 1 ? '1 key found' : '$count keys found';
}
