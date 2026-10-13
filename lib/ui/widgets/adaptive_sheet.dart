// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

/// Phones get a modal bottom sheet, wide windows a centred dialog, so a
/// picker is the same two taps on both.
Future<T?> showAdaptiveSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  final wide = MediaQuery.sizeOf(context).width >= kTwoPaneWidth;
  if (!wide) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    useRootNavigator: true,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(context).height * 0.88),
        child: Padding(padding: const EdgeInsets.only(top: 16), child: builder(context)),
      ),
    ),
  );
}

/// Scrolling body for [showAdaptiveSheet] with a title and optional footer.
class SheetBody extends StatelessWidget {
  const SheetBody({super.key, required this.title, required this.children, this.footer});

  final String title;
  final List<Widget> children;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Semantics(header: true, child: Text(title, style: t.headlineSmall)),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
        if (footer != null)
          Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), child: footer),
      ],
    );
  }
}
