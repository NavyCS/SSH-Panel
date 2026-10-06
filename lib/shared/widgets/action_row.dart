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
    this.leading,
  });

  /// Visible button text, e.g. `Load`.
  final String label;

  /// Invoked when the button is pressed. Ignored when [isEnabled] is false.
  final VoidCallback? onPressed;

  /// Tooltip while the action *is* available.
  ///
  /// Hover-only. Screen readers hear [label] while the action is available,
  /// and this string once it is not, because that is when
  /// [DisabledActionWrapper] turns it into the semantics label.
  final String enabledTooltip;

  /// Tooltip while the action is unavailable. Defaults to
  /// [enabledTooltip], which reads wrong for a disabled control — prefer an
  /// explicit reason such as `Start the ssh-agent service first`.
  final String? disabledTooltip;

  /// Optional leading icon.
  final IconData? icon;

  /// Optional leading widget, shown instead of [icon].
  ///
  /// For the cases an icon cannot express, chiefly a progress spinner shown
  /// while the action runs. [icon] takes an `IconData`, and a spinner is not
  /// one, so this is the only way to give a row action busy feedback without
  /// rebuilding the button here.
  ///
  /// The caller owns the widget, including its size: pass a fixed-dimension box
  /// so the row does not change width while the work is in flight.
  final Widget? leading;

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
    // Public final fields do not promote to non-null inside a conditional, so
    // both are read into locals first.
    final icon = action.icon;
    final leading = action.leading;

    return DisabledActionWrapper(
      enabled: enabled,
      tooltip: action.tooltip,
      // ShadButton builds its own semantics boundary that carries `button` and
      // `enabled` but neither the label nor the tap action, which sit on a
      // descendant node instead. The result was a button role with no name
      // and a name with no role, split across two nodes, while the wrapper's
      // disabled label stopped one level too high to reach either.
      //
      // Declaring the node here, excluding the subtree's semantics, puts role,
      // name and the wrapper's `enabled: false` on one node. `excludeSemantics`
      // also drops the `Text` that would otherwise supply the name, so the name
      // is stated explicitly -- and stated once: measured in this project, a
      // `label` declared above a subtree that still has its own label is
      // announced as `"$label $child"` (a plain `Semantics(label: 'X', child:
      // Text('X'))` reads "X\nX"), which is where a "Load Load" button would
      // come from.
      child: Semantics(
        button: true,
        label: action.label,
        excludeSemantics: true,
        // Null while disabled: the wrapper supplies `enabled: false` and
        // IgnorePointer blocks the pointer, so offering a tap to a screen
        // reader would announce a control that cannot be operated.
        onTap: action.onPressed,
        child: ShadButton.ghost(
          size: ShadButtonSize.sm,
          onPressed: action.onPressed,
          child: leading == null && icon == null
              ? Text(action.label)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null)
                      leading
                    else
                      Icon(icon, size: 14),
                    const SizedBox(width: 6),
                    Text(action.label),
                  ],
                ),
        ),
      ),
    );
  }
}
