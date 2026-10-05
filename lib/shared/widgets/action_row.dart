import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'disabled_action_wrapper.dart';

/// One action in an [ActionRow]: a labelled button plus the reason it is
/// unavailable, when it is.
class RowAction {
  const RowAction({
    required this.label,
    required this.onPressed,
    required this.enabledTooltip,
    this.disabledTooltip,
    this.icon,
  });

  /// Visible button text, e.g. `Load`.
  final String label;

  /// Invoked when the button is pressed. Ignored when [isEnabled] is false.
  final VoidCallback? onPressed;

  /// Tooltip (and screen-reader label) while the action *is* available.
  final String enabledTooltip;

  /// Tooltip while the action is unavailable. Defaults to
  /// [enabledTooltip], which reads wrong for a disabled control — prefer an
  /// explicit reason such as `Start the ssh-agent service first`.
  final String? disabledTooltip;

  /// Optional leading icon.
  final IconData? icon;

  bool get isEnabled => onPressed != null;

  String get tooltip => isEnabled
      ? enabledTooltip
      : (disabledTooltip ?? enabledTooltip);
}

/// A row of small ghost buttons: the repeated View / Load / Unload / Delete
/// cluster that ends every row in the Keys and Hosts tabs.
///
/// This exists because that cluster was copy-pasted per row, with two problems
/// that repetition invites:
///
/// * **Wrong screen-reader output.** Each copy built its own
///   `Semantics(button: true, label: ...)`, which always announced the button
///   as enabled even when it was wrapped in a disabled
///   [DisabledActionWrapper]. Building it once here keeps [DisabledActionWrapper]
///   in charge of the `enabled: false` flag, so the reason is announced too.
///
/// * **Scroll and focus loss.** Flutter keys these children by index; when a
///   row gained or lost an action mid-list, every later row rebuilt and lost
///   its state. [ActionRow] keys each action by its [RowAction.label].
class ActionRow extends StatelessWidget {
  const ActionRow({
    super.key,
    required this.actions,
    this.gap = 4,
  });

  final List<RowAction> actions;

  /// Horizontal space between actions. Keep it on the 4pt grid.
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          KeyedSubtree(
            key: ValueKey(actions[i].label),
            child: _ActionButton(action: actions[i]),
          ),
        ],
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action});

  final RowAction action;

  @override
  Widget build(BuildContext context) {
    final enabled = action.isEnabled;
    return DisabledActionWrapper(
      enabled: enabled,
      tooltip: action.tooltip,
      child: ShadButton.ghost(
        size: ShadButtonSize.sm,
        onPressed: action.onPressed,
        child: action.icon == null
            ? Text(action.label)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(action.icon, size: 14),
                  const SizedBox(width: 6),
                  Text(action.label),
                ],
              ),
      ),
    );
  }
}
