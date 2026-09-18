// =============================================================================
// ShopModule: gates only its own tabs (the owner's CheckBalanceRule role)
// =============================================================================
// A plain RouteModule with RouteModuleRedirectRule. SubscriptionGate gates
// every destination that lands in `tabs`, the module's IndexedStackPath, and
// nothing else: the feed next door and the host's hub never reach it.
//
// The bottom bar calls `tabs.goToIndexed` directly. A tab switch resolves the
// entry through RouteRedirect.resolve like any other navigation, so the gate
// sees the tap. SubscriptionGate returns Stop for Billing, which keeps the
// selected tab. It never redirects out of the tab set: a path cannot follow
// such a redirect.
//
// This file imports only flutter and zenrouter. Its state (ShopAccount) and
// the trace come from the host, through the constructor. A link to another
// feature goes by URI.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:zenrouter/zenrouter.dart';

/// The shop's own state, created and injected by the host.
class ShopAccount {
  final subscribed = ValueNotifier<bool>(false);

  void reset() => subscribed.value = false;
}

class ShopModule extends RouteModule<RouteUnique>
    with RouteModuleRedirectRule<RouteUnique> {
  ShopModule(super.coordinator, {required this.account, required this.trace});

  final ShopAccount account;
  final void Function(String line) trace;

  /// Read on every resolution pass, so it is built once.
  @override
  late final List<RedirectRule> redirectRules = [
    SubscriptionGate(account, trace),
  ];

  late final IndexedStackPath<RouteUnique> tabs =
      IndexedStackPath<RouteUnique>.createWith(
        [HomeTab(), CatalogTab(), BillingTab()],
        coordinator: coordinator as Coordinator,
        label: 'shop-tabs',
      )..bindLayout(ShopShell.new);

  /// The stack this module owns, and so the stack its rules gate.
  @override
  List<StackPath> get paths => [tabs];

  @override
  RouteUnique? parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['shop'] => HomeTab(),
    ['shop', 'catalog'] => CatalogTab(),
    ['shop', 'billing'] => BillingTab(),
    _ => null,
  };
}

ShopModule _shopOf(CoordinatorCore coordinator) =>
    (coordinator as CoordinatorModular<RouteUnique>).getModule<ShopModule>();

/// Stops Billing without a subscription, and continues for every other tab.
///
/// Typed to [ShopRoute]: only the tabs land in this module's stack, and they
/// all extend it. Layout parents, [ShopShell] included, are never offered.
class SubscriptionGate extends RedirectRule<ShopRoute> {
  SubscriptionGate(this.account, this.trace);

  /// This rule's name in the trace. Spelled out, never read from the type:
  /// a release web build minifies type names.
  static const label = 'SubscriptionGate';

  final ShopAccount account;
  final void Function(String line) trace;

  @override
  RedirectResult<ShopRoute> redirectResult(
    covariant CoordinatorCore coordinator,
    ShopRoute route,
  ) {
    final name = route.label;
    if (route is BillingTab && !account.subscribed.value) {
      trace('$label($name) → stop (no subscription)');
      return const RedirectResult.stop();
    }
    trace('$label($name) → continue');
    return const RedirectResult.continueRedirect();
  }
}

// =============================================================================
// Routes
// =============================================================================

/// The shop's route base. Every shop destination sits behind [ShopShell].
///
/// [label] names a route in the rule trace and the path inspector, and
/// [toString] returns it, so a rule typed to any route can name a shop route
/// without importing this file. It is spelled out, never read from the type:
/// a release web build minifies type names.
abstract class ShopRoute extends RouteTarget with RouteUnique {
  String get label;

  @override
  String toString() => label;

  @override
  Type? get layout => ShopShell;
}

/// The tabs' shell, on the root stack. A layout parent: never gated.
class ShopShell extends ShopRoute with RouteLayout<RouteUnique> {
  @override
  String get label => 'ShopShell';

  @override
  Type? get layout => null;

  @override
  IndexedStackPath<RouteUnique> resolvePath(
    covariant CoordinatorCore coordinator,
  ) => _shopOf(coordinator).tabs;

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final tabs = resolvePath(coordinator);
    return Scaffold(
      appBar: AppBar(title: const Text('Shop')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Banner('ShopModule · IndexedStackPath · SubscriptionGate'),
          Expanded(child: buildPath(coordinator)),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: tabs,
        builder: (context, _) => NavigationBar(
          selectedIndex: tabs.activeIndex,
          // Straight to the path, on purpose: goToIndexed resolves the entry
          // through RouteRedirect.resolve, so SubscriptionGate sees this tap.
          onDestinationSelected: tabs.goToIndexed,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.storefront), label: 'Home'),
            NavigationDestination(
              icon: Icon(Icons.grid_view),
              label: 'Catalog',
            ),
            NavigationDestination(
              icon: Icon(Icons.receipt_long),
              label: 'Billing',
            ),
          ],
        ),
      ),
    );
  }
}

class HomeTab extends ShopRoute {
  @override
  String get label => 'HomeTab';

  @override
  Uri toUri() => Uri.parse('/shop');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final account = _shopOf(coordinator).account;
    return _Page(
      heading: 'Shop home',
      lines: const [
        'SubscriptionGate gates every tab of this module, and nothing '
            'outside it.',
        'The bottom bar calls tabs.goToIndexed directly; the switch still '
            'runs the chain.',
      ],
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: account.subscribed,
          builder: (context, subscribed, _) => SwitchListTile(
            key: const Key('shop-subscribed'),
            title: const Text('Subscribed'),
            subtitle: const Text('ShopAccount, read by SubscriptionGate'),
            value: subscribed,
            onChanged: (value) => account.subscribed.value = value,
          ),
        ),
        ListTile(
          key: const Key('shop-link-profile'),
          leading: const Icon(Icons.link),
          title: const Text('Profile (by URI)'),
          subtitle: const Text(
            '/account/profile · another module: the same chain as from '
            'anywhere',
          ),
          onTap: () => coordinator.pushUri(Uri.parse('/account/profile')),
        ),
      ],
    );
  }
}

class CatalogTab extends ShopRoute {
  @override
  String get label => 'CatalogTab';

  @override
  Uri toUri() => Uri.parse('/shop/catalog');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const _Page(
        heading: 'Catalog',
        lines: ['OnboardingGate and SubscriptionGate let this tab through.'],
      );
}

class BillingTab extends ShopRoute {
  @override
  String get label => 'BillingTab';

  @override
  Uri toUri() => Uri.parse('/shop/billing');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const _Page(
        heading: 'Billing',
        lines: ['Subscribed: SubscriptionGate let this tab through.'],
      );
}

// =============================================================================
// Widgets (each module file keeps its own: modules share no file)
// =============================================================================

class _Banner extends StatelessWidget {
  const _Banner(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer)),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({
    required this.heading,
    this.lines = const [],
    this.children = const [],
  });

  final String heading;
  final List<String> lines;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            heading,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(line),
          ),
        ...children,
      ],
    ),
  );
}
