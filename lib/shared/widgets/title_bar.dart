import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'app_credit.dart';

/// The title bar: logo and app name on the left, the optional Admin Mode
/// control, Settings and the attribution on the right.
///
/// Split out of `main.dart`, where it was ~90 lines of the shell's build. It
/// exists to be measured: the overlap between the title and the right-hand
/// controls could only be found by driving the running app, because it appears
/// at the minimum window width and not anywhere in the test suite.
class TitleBar extends StatelessWidget {
  const TitleBar({
    super.key,
    required this.isAdminMode,
    required this.showRestartInAdminMode,
    required this.onSettingsPressed,
    required this.onRestartElevated,
  });

  /// True once the process is elevated, which swaps the restart control for a
  /// read-only badge.
  final bool isAdminMode;

  /// True when elevation is per-launch, so the app offers to relaunch itself
  /// elevated rather than prompting per action.
  final bool showRestartInAdminMode;

  final VoidCallback onSettingsPressed;
  final VoidCallback onRestartElevated;

  /// Space between the app name and the right-hand group, and between the
  /// right-hand group's own items. Kept in one place because the two gaps have
  /// to be tuned together: widening the first is what hides a collision.
  static const double gap = 8;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.border),
        ),
      ),
      child: Row(
        children: [
          SvgPicture.asset(
            'assets/logo.svg',
            width: 40,
            height: 40,
          ),
          const SizedBox(width: 10),
          // Flexible, not a bare Text. The app name was laid out at its natural
          // width with no upper bound, so it could never give ground: when the
          // right-hand group needed more room than was left, the total exceeded
          // the bar and the title and the control painted on top of each other
          // (measured one pixel of overlap at the minimum window width). A
          // bounded title can be shortened instead.
          // Expanded, not Flexible. Both children have to fill the share the
          // flex gives them, or the one that does not leaves its remainder
          // unassigned: with a loose title that remainder had nowhere to go and
          // piled up at the end of the bar, so the credit sat 15px short of the
          // right edge at the app's real width while every narrower width was
          // correct -- which is why it survived a whole release of tests. The
          // app name is inside a tight box now and left-aligned within it, so
          // the slack reads as the gap between the name and the controls, which
          // is where a gap belongs.
          Expanded(
            flex: 1,
            child: Text(
              'SSH Panel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: theme.textTheme.h3,
            ),
          ),
          const SizedBox(width: gap),
          // Expanded, and deliberately with a larger flex than the title.
          //
          // This was the cause of the overlap: the group used to be a
          // `Row(mainAxisSize: min)`, which hands its children *unbounded* width.
          // The attribution's `Flexible` therefore never got a bound and could
          // never shrink, so the group's natural width ran past the bar and the
          // app name and the control painted on top of each other. Measured 59px
          // of overflow at the app's 640px floor, not the 1px it first looked
          // like.
          //
          // With Expanded the group is bounded, so the credit can actually give
          // ground. The flex ratio is the other half of it: 1:4 keeps the
          // natural width of the app name from eating the group's share and
          // squeezing the credit for no reason.
          Expanded(
            flex: 4,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isAdminMode) ...[
                  Semantics(
                    button: true,
                    label: 'Admin Mode',
                    child: const ShadButton.outline(
                      size: ShadButtonSize.sm,
                      onPressed: null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.shield, size: 13),
                          SizedBox(width: 5),
                          Text('Admin Mode'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: gap),
                ] else if (showRestartInAdminMode) ...[
                  ShadTooltip(
                    builder: (context) =>
                        const Text('Restart the app with administrator rights'),
                    child: Semantics(
                      button: true,
                      label: 'Restart in Admin Mode',
                      child: ShadButton.outline(
                        size: ShadButtonSize.sm,
                        onPressed: onRestartElevated,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.shield, size: 13),
                            SizedBox(width: 5),
                            // Shortened from "Restart in Admin Mode". Not made
                            // Flexible: a flexible child inside a
                            // mainAxisSize.min row is unbounded, so it could
                            // never ellipsise anyway.
                            Text('Restart elevated'),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: gap),
                ],
                ShadTooltip(
                  builder: (context) => const Text('Settings'),
                  child: Semantics(
                    button: true,
                    label: 'Settings',
                    child: ShadIconButton(
                      icon: const Icon(LucideIcons.settings),
                      iconSize: 18,
                      onPressed: onSettingsPressed,
                    ),
                  ),
                ),
                const SizedBox(width: gap),
                const Flexible(child: AppCredit()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}