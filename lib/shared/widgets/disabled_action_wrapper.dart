import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Dims a widget and blocks pointer input when [enabled] is false.
///
/// Used wherever an action is unavailable because the app is not elevated, or
/// because the ssh-agent service is not running. The tooltip always explains
/// *why* the control is unavailable, which is the only place that information
/// exists — the control itself cannot be interacted with to find out.
///
/// Two accessibility defects were fixed here, both of which had shipped:
///
/// * **Contrast.** The dimming opacity used to default to `0.35`. Painted over
///   a light shadcn card that puts the label at roughly a 2:1 contrast ratio,
///   well under the 4.5:1 that WCAG AA requires for body text — the label was
///   effectively unreadable for anyone with low vision. It now defaults to
///   `0.55`. Callers can still override it, but the value is a deliberate
///   choice rather than a default nobody thought about.
///
/// * **Semantics.** The child used to keep `Semantics(button: true)` with no
///   `enabled: false`, so a screen reader announced a live, tappable control
///   that silently did nothing when activated. The semantics node is now marked
///   `enabled: false` and carries [tooltip] as its label, so the announcement
///   says both *that* it is disabled and *why*.
class DisabledActionWrapper extends StatelessWidget {
  const DisabledActionWrapper({
    super.key,
    required this.enabled,
    required this.tooltip,
    required this.child,
    this.disabledOpacity = 0.55,
    this.disabledCursor = SystemMouseCursors.basic,
  });

  /// Whether the wrapped action is currently available.
  final bool enabled;

  /// Explains why the action is unavailable. Also used as the semantics label
  /// when disabled, since that is the only way a screen-reader user learns
  /// the reason.
  final String tooltip;

  final Widget child;

  /// Opacity applied to [child] while disabled. Keep this at or above `0.55`
  /// unless you have measured the resulting contrast ratio.
  final double disabledOpacity;

  /// Cursor shown while disabled. The default is deliberately not
  /// [SystemMouseCursors.forbidden]: nothing is wrong, the action is simply
  /// unavailable right now.
  final MouseCursor disabledCursor;

  @override
  Widget build(BuildContext context) {
    return ShadTooltip(
      builder: (context) => Text(tooltip),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : disabledCursor,
        child: Semantics(
          enabled: enabled,
          label: enabled ? null : tooltip,
          child: Opacity(
            opacity: enabled ? 1.0 : disabledOpacity,
            child: IgnorePointer(
              ignoring: !enabled,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
