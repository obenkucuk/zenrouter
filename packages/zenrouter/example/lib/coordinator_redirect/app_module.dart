// =============================================================================
// MODULE-SCOPED REDIRECT RULES: the host
// =============================================================================
// A module's redirect rules gate exactly the destinations that land in a stack
// the module lists in `paths`, or that one of its sub-modules lists. The root
// lists every stack, so the root's rules gate every destination. A layout-less
// route lands on the root stack. Layout parents are never offered to a rule.
//
//   AppCoordinator                  root: [OnboardingGate]
//   |   root            NavigationPath      HubRoute, OnboardingRoute,
//   |                                       NotFoundRoute
//   |
//   +-- ShopModule                  plain module: [SubscriptionGate]
//   |     shop-tabs       IndexedStackPath    HomeTab, CatalogTab, BillingTab
//   |                                         (behind ShopShell)
//   +-- NewsFeedModule              plain module: no rules
//   |     feed-branches   BranchedStackPath   ForYouBranch, FollowingBranch
//   |                                         (behind FeedLayout)
//   |     feed-for-you,   NavigationPath      FeedListRoute, PostRoute
//   |     feed-following
//   |
//   +-- AuthRouteModuleCoordinator  module coordinator: [RequireSession]
//         auth            NavigationPath      SignInRoute, ProfileRoute
//         |                                   (behind AuthLayout)
//         +-- SecurityModule        plain module, two levels deep:
//               security  NavigationPath      [RequireTwoFactor]
//                                             SecuritySettingsRoute
//                                             (behind SecurityLayout)
//
// The chain each destination gets, in the order its rules run:
//
//   HubRoute, OnboardingRoute, NotFoundRoute   OnboardingGate
//   HomeTab, CatalogTab, BillingTab            OnboardingGate > SubscriptionGate
//   FeedListRoute, PostRoute                   OnboardingGate
//   SignInRoute, ProfileRoute                  OnboardingGate > RequireSession
//   SecuritySettingsRoute                      OnboardingGate > RequireSession
//                                              > RequireTwoFactor
//   every layout (shells and branch roots)     none
//
// Three shapes carry the same mixin, on purpose. The root is a coordinator.
// The auth module is a coordinator used as a module: the shape whose pointers
// are erased one hop up, and the only one that can register sub-modules, which
// the two-levels-deep case needs. The rest are plain RouteModules.
//
// zenrouter_devtools lists coordinators, and groups each path under
// StackPath.coordinator, which goes one hop up. So it shows two coordinators,
// and lists `security` under AppCoordinator, not under the auth coordinator
// that registers SecurityModule. The path inspector at the bottom of the
// screen reads the defineModules registry instead, so it shows the real owner
// chain: AppCoordinator › AuthRouteModuleCoordinator › SecurityModule.
//
// The chain depends only on where a destination lands, never on the call
// site: a hub button, a tab tap, a branch switch, a link from another module,
// a deep link and a path-level push all get the same chain. Open the rule
// trace and the path inspector at the bottom of the screen to watch it.
//
// The file rule, as in an app with one package per feature: each module lives
// in its own file and imports only flutter and zenrouter. Modules never import
// each other, and only this file imports modules. Each module owns its state
// type and gets it, with the trace, through its constructor. A page that links
// to another feature navigates by URI.
// test/coordinator_redirect_architecture_test.dart pins the rule.
//
// Every name on screen is spelled out, never read from the type: a release
// web build minifies type names. Each module's route base declares a label
// and returns it from toString, each rule writes its own label, and the host
// names the modules, because it composed the tree.
//
// Run:
//   flutter run -t lib/main_coordinator_redirect.dart
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zenrouter/zenrouter.dart';
import 'package:zenrouter_devtools/zenrouter_devtools.dart';

import 'auth_module.dart';
import 'feed_module.dart';
import 'security_module.dart';
import 'shop_module.dart';

/// The example app.
///
/// The entry point composes the tree once and hands it in, the way a real app
/// holds its router for its whole life. The rule trace and the path inspector
/// sit under every page, in [MaterialApp.router]'s `builder`.
class CoordinatorRedirectApp extends StatelessWidget {
  const CoordinatorRedirectApp({required this.coordinator, super.key});

  final AppCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ZenRouter scoped redirect rules',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      routerConfig: coordinator,
      builder: (context, child) => RedirectDock(
        coordinator: coordinator,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}

// =============================================================================
// Host state
// =============================================================================

/// The host's own state.
///
/// Each module owns its state type. The host creates one of each, and injects
/// it together with [log], the trace.
class HostState {
  /// Read by [OnboardingGate].
  final onboarded = ValueNotifier<bool>(true);

  /// Every rule decision, oldest first, as `Rule(Route) → verdict`.
  final trace = ValueNotifier<List<String>>(const []);

  /// Where the user was going when [OnboardingGate] sent them to onboarding.
  Uri? resumeAfterOnboarding;

  /// How a trace line spells a stop: `Rule(Route) → stop (why)`.
  ///
  /// A stopped navigation changes nothing on screen, so the dock reads this
  /// to say so. Without it, a tap that a rule stops looks like a dead button.
  static const stopVerdict = '→ stop';

  /// The trace every rule writes to: a plain `void Function(String)`.
  void log(String line) => trace.value = [...trace.value, line];

  void clearTrace() => trace.value = const [];

  void reset() {
    onboarded.value = true;
    resumeAfterOnboarding = null;
    clearTrace();
  }
}

// =============================================================================
// The root coordinator and the tree composition
// =============================================================================

/// The tree root.
///
/// Its rules gate every destination, because the root lists every stack. See
/// [RouteModuleRedirectRule].
class AppCoordinator extends Coordinator<RouteUnique>
    with
        CoordinatorModular<RouteUnique>,
        RouteModuleRedirectRule<RouteUnique>,
        CoordinatorDebug<RouteUnique> {
  AppCoordinator({
    super.initialRoutePath,
    HostState? host,
    ShopAccount? shopAccount,
    AuthSession? authSession,
    TwoFactorStatus? twoFactor,
  }) : host = host ?? HostState(),
       shopAccount = shopAccount ?? ShopAccount(),
       authSession = authSession ?? AuthSession(),
       twoFactor = twoFactor ?? TwoFactorStatus();

  final HostState host;
  final ShopAccount shopAccount;
  final AuthSession authSession;
  final TwoFactorStatus twoFactor;

  /// Read on every resolution pass, so it is built once.
  @override
  late final List<RedirectRule> redirectRules = [OnboardingGate(host)];

  /// The composition. Each module gets its own state and the trace through
  /// its constructor; no module sees another module or this file.
  @override
  Iterable<RouteModule<RouteUnique>> defineModules() => [
    ShopModule(this, account: shopAccount, trace: host.log),
    NewsFeedModule(this),
    AuthRouteModuleCoordinator(
      this,
      session: authSession,
      trace: host.log,
      // Registered here, under the auth coordinator, which never imports it:
      // root > auth > security, the two-levels-deep case.
      subModules: (auth) => [
        SecurityModule(auth, status: twoFactor, trace: host.log),
      ],
    ),
  ];

  ShopModule get shop => getModule<ShopModule>();

  NewsFeedModule get feed => getModule<NewsFeedModule>();

  AuthRouteModuleCoordinator get auth =>
      getModule<AuthRouteModuleCoordinator>();

  SecurityModule get security => getModule<SecurityModule>();

  /// The host parses its own URIs, then asks the modules (super).
  @override
  FutureOr<RouteUnique?> parseRouteFromUri(Uri uri) {
    switch (uri.pathSegments) {
      case []:
        return HubRoute();
      case ['welcome']:
        return OnboardingRoute();
    }
    return super.parseRouteFromUri(uri);
  }

  @override
  RouteUnique notFoundRoute(Uri uri) => NotFoundRoute(uri);

  /// A rule may stop the URL the app is opened with, and a stopped
  /// navigation shows nothing: on a cold start that is a blank app. The host
  /// never leaves the root stack empty; it opens the hub instead.
  @override
  Future<void> navigate(RouteUnique route) async {
    await super.navigate(route);
    if (root.stack.isEmpty) await replace(HubRoute());
  }

  /// Every path of the app, with the module that owns it.
  ///
  /// The host composed the tree, so it knows the owners; this needs no API
  /// beyond each module's `paths`.
  List<PathRow> get pathRows => [
    PathRow(root, owner: this, enclosing: const []),
    for (final path in shop.paths)
      PathRow(path, owner: shop, enclosing: [this]),
    for (final path in feed.paths)
      PathRow(path, owner: feed, enclosing: [this]),
    PathRow(auth.authStack, owner: auth, enclosing: [this]),
    for (final path in security.paths)
      PathRow(path, owner: security, enclosing: [this, auth]),
  ];

  /// The name of every rule of the tree, root first.
  List<String> get ruleNames => [
    for (final module in <RouteModule<RouteUnique>>[
      this,
      shop,
      feed,
      auth,
      security,
    ])
      if (module is RouteModuleRedirectRule<RouteUnique>)
        for (final rule in module.redirectRules) ruleLabel(rule),
  ];

  /// Resets every state the host injected. [replace] resets the stacks.
  void resetState() {
    host.reset();
    shopAccount.reset();
    authSession.reset();
    twoFactor.reset();
  }
}

/// The root rule: sends everything to onboarding until it is finished.
class OnboardingGate extends RedirectRule<RouteUnique> {
  OnboardingGate(this.host);

  /// This rule's name in the trace. Spelled out, never read from the type:
  /// a release web build minifies type names.
  static const label = 'OnboardingGate';

  final HostState host;

  @override
  RedirectResult<RouteUnique> redirectResult(
    covariant CoordinatorCore coordinator,
    RouteUnique route,
  ) {
    // Every module's route base returns its label from toString.
    final name = '$route';
    // OnboardingRoute is this rule's own redirect target and lands on the
    // root stack, which this rule gates, so the rule continues for it.
    if (route is OnboardingRoute || host.onboarded.value) {
      host.log('$label($name) → continue');
      return const RedirectResult.continueRedirect();
    }
    host.resumeAfterOnboarding = route.toUri();
    host.log('$label($name) → OnboardingRoute (not onboarded)');
    return RedirectResult.redirectTo(OnboardingRoute());
  }
}

// =============================================================================
// The host's routes, on the root stack
// =============================================================================

/// The host's route base.
///
/// [label] names a route in the rule trace and the path inspector, and
/// [toString] returns it. It is spelled out, never read from the type: a
/// release web build minifies type names.
abstract class HostRoute extends RouteTarget with RouteUnique {
  String get label;

  @override
  String toString() => label;
}

/// The home page: every feature, and a switch for each module's state.
class HubRoute extends HostRoute {
  @override
  String get label => 'HubRoute';

  @override
  Uri toUri() => Uri.parse('/');

  @override
  Widget build(covariant AppCoordinator coordinator, BuildContext context) =>
      HubPage(coordinator: coordinator);
}

class OnboardingRoute extends HostRoute {
  @override
  String get label => 'OnboardingRoute';

  @override
  Uri toUri() => Uri.parse('/welcome');

  @override
  Widget build(covariant AppCoordinator coordinator, BuildContext context) =>
      OnboardingPage(coordinator: coordinator);
}

class NotFoundRoute extends HostRoute {
  NotFoundRoute(this.uri);

  final Uri uri;

  @override
  String get label => 'NotFoundRoute';

  @override
  List<Object?> get props => [uri];

  @override
  Uri toUri() => uri;

  @override
  Widget build(covariant AppCoordinator coordinator, BuildContext context) =>
      Scaffold(
        appBar: AppBar(title: const Text('Not found')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('No page for $uri.'),
              TextButton(
                onPressed: () => coordinator.replace(HubRoute()),
                child: const Text('Back to the hub'),
              ),
            ],
          ),
        ),
      );
}

// =============================================================================
// Host pages
// =============================================================================

class HubPage extends StatelessWidget {
  const HubPage({required this.coordinator, super.key});

  final AppCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    final c = coordinator;
    return Scaffold(
      appBar: AppBar(title: const Text('Scoped redirect rules')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _Blurb(
            'Each module gates only what lands in the stacks it owns. The '
            'root owns every stack, so OnboardingGate sees everything; the '
            'other rules see only their own module. Open the rule trace '
            'below after each tap.',
          ),
          const _Section('State: each module owns its own'),
          _FlagTile(
            id: 'onboarded',
            title: 'Onboarded',
            subtitle: 'host state · OnboardingGate',
            flag: c.host.onboarded,
          ),
          _FlagTile(
            id: 'subscribed',
            title: 'Subscribed',
            subtitle: 'ShopAccount · SubscriptionGate',
            flag: c.shopAccount.subscribed,
          ),
          _FlagTile(
            id: 'signed-in',
            title: 'Signed in',
            subtitle: 'AuthSession · RequireSession',
            flag: c.authSession.signedIn,
          ),
          _FlagTile(
            id: 'two-factor',
            title: '2FA on',
            subtitle: 'TwoFactorStatus · RequireTwoFactor',
            flag: c.twoFactor.enabled,
          ),
          const _Section('Shop: IndexedStackPath, ShopModule'),
          _Link(
            id: 'shop-home',
            title: 'Shop home',
            subtitle: 'HomeTab · OnboardingGate › SubscriptionGate',
            onTap: () => c.push(HomeTab()),
          ),
          _Link(
            id: 'catalog',
            title: 'Catalog',
            subtitle: 'CatalogTab · OnboardingGate › SubscriptionGate',
            onTap: () => c.push(CatalogTab()),
          ),
          _Link(
            id: 'billing',
            title: 'Billing',
            subtitle: 'BillingTab · SubscriptionGate stops it unsubscribed',
            onTap: () => c.push(BillingTab()),
          ),
          const _Section('Feed: BranchedStackPath, NewsFeedModule, no rules'),
          _Link(
            id: 'feed',
            title: 'Feed',
            subtitle: 'FeedListRoute · OnboardingGate only',
            onTap: () => c.push(FeedListRoute(FeedBranch.forYou)),
          ),
          const _Section('Account: AuthRouteModuleCoordinator'),
          _Link(
            id: 'profile',
            title: 'Profile',
            subtitle: 'ProfileRoute · OnboardingGate › RequireSession',
            onTap: () => c.push(ProfileRoute()),
          ),
          _Link(
            id: 'sign-in',
            title: 'Sign in',
            subtitle:
                'SignInRoute · RequireSession lets a guest through, and sends '
                'a signed-in user to the profile',
            onTap: () => c.push(SignInRoute()),
          ),
          _Link(
            id: 'security',
            title: 'Security',
            subtitle:
                'SecuritySettingsRoute · two levels deep · OnboardingGate › '
                'RequireSession › RequireTwoFactor',
            onTap: () => c.push(SecuritySettingsRoute()),
          ),
          const _Section('Session'),
          _Link(
            id: 'start-over',
            title: 'Start over',
            subtitle: 'Reset every flag and stack, and clear the trace',
            onTap: () async {
              c.resetState();
              await c.replace(HubRoute());
              c.host.clearTrace();
            },
          ),
        ],
      ),
    );
  }
}

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({required this.coordinator, super.key});

  final AppCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    final host = coordinator.host;
    final resume = host.resumeAfterOnboarding;
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'OnboardingGate sent you here: the app is not onboarded yet.',
          ),
          if (resume != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'You were going to $resume. Finishing onboarding continues '
                'there.',
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('finish-onboarding'),
            onPressed: () {
              host.onboarded.value = true;
              final next = host.resumeAfterOnboarding ?? Uri.parse('/');
              host.resumeAfterOnboarding = null;
              coordinator.pushReplacementUri(next);
            },
            child: const Text('Finish onboarding'),
          ),
        ],
      ),
    );
  }
}

class _Blurb extends StatelessWidget {
  const _Blurb(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Text(text),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _FlagTile extends StatelessWidget {
  const _FlagTile({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.flag,
  });

  final String id;
  final String title;
  final String subtitle;
  final ValueNotifier<bool> flag;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: flag,
    builder: (context, value, _) => SwitchListTile(
      key: Key('flag-$id'),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (next) => flag.value = next,
    ),
  );
}

class _Link extends StatelessWidget {
  const _Link({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String id;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    key: Key('hub-$id'),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

// =============================================================================
// Names on screen
// =============================================================================
// Spelled out, never read from the type: a release web build minifies type
// names, so a name read from the type would show as `minified:…`.

/// The name the path inspector shows for [module].
///
/// The host composed the tree, so it names every module.
String moduleLabel(RouteModule module) => switch (module) {
  AppCoordinator() => 'AppCoordinator',
  ShopModule() => 'ShopModule',
  NewsFeedModule() => 'NewsFeedModule',
  AuthRouteModuleCoordinator() => 'AuthRouteModuleCoordinator',
  SecurityModule() => 'SecurityModule',
  _ => 'unnamed module',
};

/// The name [rule] writes at the start of each of its trace lines, and the
/// key the trace panel groups its decisions by.
String ruleLabel(RedirectRule rule) => switch (rule) {
  OnboardingGate() => OnboardingGate.label,
  SubscriptionGate() => SubscriptionGate.label,
  RequireSession() => RequireSession.label,
  RequireTwoFactor() => RequireTwoFactor.label,
  _ => 'unnamed rule',
};

/// A stack entry as the path inspector shows it: its label, then its props.
///
/// Every module's route base returns its label from toString.
String entryLabel(RouteTarget route) =>
    route.props.isEmpty ? '$route' : '$route[${route.props.join(',')}]';

// =============================================================================
// The dock: rule trace and path inspector, under every page
// =============================================================================

/// The rule trace and the path inspector, collapsed by default.
class RedirectDock extends StatefulWidget {
  const RedirectDock({
    required this.coordinator,
    required this.child,
    super.key,
  });

  final AppCoordinator coordinator;
  final Widget child;

  @override
  State<RedirectDock> createState() => _RedirectDockState();
}

class _RedirectDockState extends State<RedirectDock> {
  bool _traceOpen = false;
  bool _pathsOpen = false;

  @override
  void initState() {
    super.initState();
    widget.coordinator.host.trace.addListener(_noticeStop);
  }

  @override
  void dispose() {
    widget.coordinator.host.trace.removeListener(_noticeStop);
    _stoppedTimer?.cancel();
    super.dispose();
  }

  /// The decision that last stopped a navigation, shown for a few seconds.
  String? _stopped;
  Timer? _stoppedTimer;

  /// A stop leaves the screen as it was, so it is the one decision the user
  /// cannot see. The dock says it: it sits under every page, covers none of
  /// their controls, and is there even when a rule stops the very first
  /// navigation and no page is up yet.
  void _noticeStop() {
    final trace = widget.coordinator.host.trace.value;
    if (!mounted || trace.isEmpty) return;
    if (!trace.last.contains(HostState.stopVerdict)) return;
    _stoppedTimer?.cancel();
    _stoppedTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _stopped = null);
    });
    setState(() => _stopped = trace.last);
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = widget.coordinator;
    return Column(
      children: [
        Expanded(
          // The dock covers the bottom inset, so the pages do not.
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: widget.child,
          ),
        ),
        Material(
          elevation: 8,
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_stopped case final decision?) _StopNotice(decision),
                ValueListenableBuilder<List<String>>(
                  valueListenable: coordinator.host.trace,
                  builder: (context, trace, _) => _DockHeader(
                    title: 'Rule trace',
                    summary: trace.isEmpty ? 'no rule has run' : trace.last,
                    open: _traceOpen,
                    onTap: () => setState(() => _traceOpen = !_traceOpen),
                  ),
                ),
                if (_traceOpen)
                  SizedBox(
                    height: 220,
                    child: TracePanel(coordinator: coordinator),
                  ),
                const Divider(height: 1),
                _DockHeader(
                  title: 'Paths',
                  summary:
                      'every path: its type, owner and the rules that gate it',
                  open: _pathsOpen,
                  onTap: () => setState(() => _pathsOpen = !_pathsOpen),
                ),
                if (_pathsOpen)
                  SizedBox(
                    height: 320,
                    child: PathInspector(coordinator: coordinator),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StopNotice extends StatelessWidget {
  const _StopNotice(this.decision);

  final String decision;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('stop-notice'),
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.block, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'A rule stopped this navigation, so nothing changed · $decision',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _DockHeader extends StatelessWidget {
  const _DockHeader({
    required this.title,
    required this.summary,
    required this.open,
    required this.onTap,
  });

  final String title;
  final String summary;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(open ? Icons.expand_more : Icons.expand_less, size: 20),
            const SizedBox(width: 8),
            Text(title, style: textTheme.titleSmall),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which rules saw which destinations, then every decision, oldest first.
class TracePanel extends StatelessWidget {
  const TracePanel({required this.coordinator, super.key});

  final AppCoordinator coordinator;

  /// The most recent decisions shown; the trace itself keeps them all.
  static const shownLines = 80;

  @override
  Widget build(BuildContext context) {
    final host = coordinator.host;
    final textTheme = Theme.of(context).textTheme;
    return ValueListenableBuilder<List<String>>(
      valueListenable: host.trace,
      builder: (context, trace, _) {
        final saw = {
          for (final rule in coordinator.ruleNames) rule: <String>{},
        };
        for (final line in trace) {
          final open = line.indexOf('(');
          final close = line.indexOf(')');
          if (open <= 0 || close <= open) continue;
          saw
              .putIfAbsent(line.substring(0, open), () => <String>{})
              .add(line.substring(open + 1, close));
        }
        final skipped = trace.length > shownLines
            ? trace.length - shownLines
            : 0;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Which rules saw what', style: textTheme.labelLarge),
              for (final MapEntry(key: rule, value: routes) in saw.entries)
                Text(
                  '$rule: ${routes.isEmpty ? 'nothing' : routes.join(', ')}',
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Every decision, oldest first',
                      style: textTheme.labelLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: trace.isEmpty ? null : host.clearTrace,
                    child: const Text('Clear'),
                  ),
                ],
              ),
              if (trace.isEmpty) const Text('(empty)'),
              for (final (index, line) in trace.skip(skipped).indexed)
                Text('${skipped + index + 1}. $line'),
            ],
          ),
        );
      },
    );
  }
}

/// One row per path of the app, updated live.
class PathInspector extends StatelessWidget {
  const PathInspector({required this.coordinator, super.key});

  final AppCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // The coordinator notifies whenever any of its paths changes.
      listenable: coordinator,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final row in coordinator.pathRows)
              _PathRowView(
                key: Key('path-${row.label}'),
                row: row,
                coordinator: coordinator,
              ),
          ],
        ),
      ),
    );
  }
}

class _PathRowView extends StatelessWidget {
  const _PathRowView({required this.row, required this.coordinator, super.key});

  final PathRow row;
  final AppCoordinator coordinator;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(row.title, style: Theme.of(context).textTheme.titleSmall),
        Text(row.describeChain(coordinator)),
        Text(row.describeStack()),
      ],
    ),
  );
}

/// One row of the path inspector: a path and the module that owns it.
class PathRow {
  const PathRow(this.path, {required this.owner, required this.enclosing});

  final StackPath path;
  final RouteModule owner;

  /// The modules above [owner] in the tree, root first.
  final List<RouteModule> enclosing;

  /// Every path of the example is created with a label.
  String get label => path.debugLabel ?? 'unlabelled path';

  String get type => switch (path) {
    BranchedStackPath() => 'BranchedStackPath',
    IndexedStackPath() => 'IndexedStackPath',
    NavigationPath() => 'NavigationPath',
    _ => 'StackPath',
  };

  String get title => '$label · $type · owner ${moduleLabel(owner)}';

  /// The modules whose rules gate a destination landing in [path], in the
  /// order they run.
  ///
  /// Read with `redirectScopeOf` from the active entry when it is a
  /// destination. Otherwise the declaring modules from the root down to the
  /// owner. Empty for a [BranchedStackPath]: only branch roots land there,
  /// and they are layouts, which are never offered to a rule.
  List<RouteModuleRedirectRule> chain(CoordinatorCore coordinator) {
    if (path is BranchedStackPath) return const [];
    final active = path.activeRoute;
    if (active != null && active is! RouteLayoutParent) {
      return coordinator.redirectScopeOf(active);
    }
    return [...enclosing, owner].whereType<RouteModuleRedirectRule>().toList();
  }

  String describeChain(CoordinatorCore coordinator) {
    if (path is BranchedStackPath) {
      return 'gated by nothing · branch roots are layouts, never offered';
    }
    final modules = chain(coordinator);
    if (modules.isEmpty) return 'gated by nothing';
    return 'gated by ${modules.map(moduleLabel).join(' › ')}';
  }

  /// The entries, with the active one in brackets.
  String describeStack() {
    final path = this.path;
    final entries = path.stack;
    if (entries.isEmpty) return 'stack (empty)';
    final active = path.activeRoute;
    final names = [
      for (final route in entries)
        identical(route, active) ? '[${entryLabel(route)}]' : entryLabel(route),
    ];
    if (path case IndexedStackPath(:final activeIndex)) {
      return 'stack ${names.join(' · ')} · active $activeIndex';
    }
    return 'stack ${names.join(' › ')}';
  }
}
