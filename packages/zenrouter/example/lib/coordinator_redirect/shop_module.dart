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
// The module owns its routing as a RouteManifest: an indexed shell whose
// fixed children are the tabs, in tab order. RouteModuleBinding matches URLs
// against it, the bindings turn a match into a tab, and toUri builds the same
// URL back from it, so there is no parser to keep in step.
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

/// The IDs of this module's manifest: its shell, then its tabs.
enum ShopRouteId { shell, home, catalog, billing }

class ShopModule extends RouteModule<RouteUnique>
    with
        RouteModuleBinding<RouteUnique, ShopRouteId>,
        RouteModuleRedirectRule<RouteUnique> {
  ShopModule(super.coordinator, {required this.account, required this.trace});

  /// The module's routing graph. An indexed layout lists its tabs as fixed
  /// children, in the order [tabs] holds them.
  static final manifest = RouteManifest<ShopRouteId>(
    name: 'shop',
    idCodec: RouteIdCodec.enumValues(ShopRouteId.values),
    layouts: [
      RouteManifestLayout.indexed(
        id: ShopRouteId.shell,
        path: '/shop',
        childIds: [ShopRouteId.home, ShopRouteId.catalog, ShopRouteId.billing],
      ),
    ],
    routes: [
      RouteManifestRoute(
        id: ShopRouteId.home,
        path: '/shop',
        parentId: ShopRouteId.shell,
      ),
      RouteManifestRoute(
        id: ShopRouteId.catalog,
        path: '/shop/catalog',
        parentId: ShopRouteId.shell,
      ),
      RouteManifestRoute(
        id: ShopRouteId.billing,
        path: '/shop/billing',
        parentId: ShopRouteId.shell,
      ),
    ],
  );

  /// From a manifest match to a tab. No `notFound`: a URL this module does
  /// not own falls through to the next module.
  @override
  late final routeBindings = manifest.bind<RouteUnique>(
    bindings: [
      RouteBinding(id: ShopRouteId.home, create: (_) => HomeTab()),
      RouteBinding(
        id: ShopRouteId.catalog,
        create: (match) => CatalogTab(queries: match.uri.queryParameters),
      ),
      RouteBinding(id: ShopRouteId.billing, create: (_) => BillingTab()),
    ],
  );

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
  Uri toUri() => ShopModule.manifest.location(ShopRouteId.home);

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

/// The catalog keeps its sort order in the URL query: `/shop/catalog?sort=price`.
///
/// [RouteQueryParameters] keeps the query out of the route's identity, so
/// another sort order is the same tab. A query typed into the address bar
/// reaches the tab set's own entry through `onUpdate`, and the sort control
/// rewrites the URL in place, without a new history entry.
class CatalogTab extends ShopRoute with RouteQueryParameters {
  CatalogTab({Map<String, String> queries = const {}})
    : queryNotifier = ValueNotifier(queries);

  static const sorts = ['name', 'price'];

  @override
  final ValueNotifier<Map<String, String>> queryNotifier;

  @override
  String get label => 'CatalogTab';

  @override
  Uri toUri() => ShopModule.manifest.location(
    ShopRouteId.catalog,
    queryParameters: queries,
  );

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      _Page(
        heading: 'Catalog',
        lines: const [
          'OnboardingGate and SubscriptionGate let this tab through.',
        ],
        children: [
          ValueListenableBuilder<Map<String, String>>(
            valueListenable: queryNotifier,
            builder: (context, queries, _) {
              final sort = queries['sort'] ?? sorts.first;
              return RadioGroup<String>(
                groupValue: sort,
                // Another sort order is the same tab: rewrite the URL in
                // place, without a new history entry.
                onChanged: (value) => updateQueries(
                  coordinator,
                  queries: {...queries, 'sort': value!},
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text('Sorted by $sort'),
                    ),
                    for (final option in sorts)
                      RadioListTile<String>(
                        key: Key('catalog-sort-$option'),
                        title: Text('Sort by $option'),
                        subtitle: Text('/shop/catalog?sort=$option'),
                        value: option,
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      );
}

class BillingTab extends ShopRoute {
  @override
  String get label => 'BillingTab';

  @override
  Uri toUri() => ShopModule.manifest.location(ShopRouteId.billing);

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
