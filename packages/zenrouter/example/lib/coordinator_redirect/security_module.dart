// =============================================================================
// SecurityModule: two levels deep, root > auth > security
// =============================================================================
// A plain RouteModule with RouteModuleRedirectRule. The host registers it
// under AuthRouteModuleCoordinator, so a destination in its stack is gated by
// the root, then the auth coordinator, then this module:
// OnboardingGate > RequireSession > RequireTwoFactor.
//
// Its shell (SecurityLayout) sits on the root stack; the registry, not the
// widget tree, decides the chain. RequireTwoFactor returns Stop without 2FA.
//
// This file imports only flutter and zenrouter. Its state (TwoFactorStatus)
// and the trace come from the host, through the constructor.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:zenrouter/zenrouter.dart';

/// The security module's own state, created and injected by the host.
class TwoFactorStatus {
  final enabled = ValueNotifier<bool>(false);

  void reset() => enabled.value = false;
}

class SecurityModule extends RouteModule<RouteUnique>
    with RouteModuleRedirectRule<RouteUnique> {
  SecurityModule(
    super.coordinator, {
    required this.status,
    required this.trace,
  });

  final TwoFactorStatus status;
  final void Function(String line) trace;

  /// Read on every resolution pass, so it is built once.
  @override
  late final List<RedirectRule> redirectRules = [
    RequireTwoFactor(status, trace),
  ];

  late final NavigationPath<RouteUnique> securityStack =
      NavigationPath<RouteUnique>.createWith(
        label: 'security',
        coordinator: coordinator,
      )..bindLayout(SecurityLayout.new);

  @override
  List<StackPath> get paths => [securityStack];

  @override
  RouteUnique? parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['account', 'security'] => SecuritySettingsRoute(),
    _ => null,
  };
}

SecurityModule _securityOf(CoordinatorCore coordinator) =>
    (coordinator as CoordinatorModular<RouteUnique>)
        .getModule<SecurityModule>();

/// Stops everything in this module's stack while 2FA is off.
///
/// Typed to [SecurityRoute]: only security routes land in this module's
/// stack. Layout parents are never offered.
class RequireTwoFactor extends RedirectRule<SecurityRoute> {
  RequireTwoFactor(this.status, this.trace);

  /// This rule's name in the trace. Spelled out, never read from the type:
  /// a release web build minifies type names.
  static const label = 'RequireTwoFactor';

  final TwoFactorStatus status;
  final void Function(String line) trace;

  @override
  RedirectResult<SecurityRoute> redirectResult(
    covariant CoordinatorCore coordinator,
    SecurityRoute route,
  ) {
    final name = route.label;
    if (!status.enabled.value) {
      trace('$label($name) → stop (2FA is off)');
      return const RedirectResult.stop();
    }
    trace('$label($name) → continue');
    return const RedirectResult.continueRedirect();
  }
}

// =============================================================================
// Routes
// =============================================================================

/// The security module's route base. Every security destination sits behind
/// [SecurityLayout].
///
/// [label] names a route in the rule trace and the path inspector, and
/// [toString] returns it, so a rule typed to any route can name a security
/// route without importing this file. It is spelled out, never read from the
/// type: a release web build minifies type names.
abstract class SecurityRoute extends RouteTarget with RouteUnique {
  String get label;

  @override
  String toString() => label;

  @override
  Type? get layout => SecurityLayout;
}

/// The security shell, on the root stack. A layout parent: never gated.
class SecurityLayout extends SecurityRoute with RouteLayout<RouteUnique> {
  @override
  String get label => 'SecurityLayout';

  @override
  Type? get layout => null;

  @override
  NavigationPath<RouteUnique> resolvePath(
    covariant CoordinatorCore coordinator,
  ) => _securityOf(coordinator).securityStack;

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      Scaffold(
        appBar: AppBar(title: const Text('Security')),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Banner(
              'SecurityModule · under AuthRouteModuleCoordinator · '
              'RequireTwoFactor',
            ),
            Expanded(child: buildPath(coordinator)),
          ],
        ),
      );
}

class SecuritySettingsRoute extends SecurityRoute {
  @override
  String get label => 'SecuritySettingsRoute';

  @override
  Uri toUri() => Uri.parse('/account/security');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final status = _securityOf(coordinator).status;
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Security settings',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'OnboardingGate (root), RequireSession (auth) and '
              'RequireTwoFactor (this module) let this through, in that '
              'order.',
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: status.enabled,
            builder: (context, enabled, _) => SwitchListTile(
              key: const Key('security-two-factor'),
              title: const Text('Two-factor authentication'),
              subtitle: const Text(
                'Rules guard entry, not presence: turning it off does not '
                'close this page.',
              ),
              value: enabled,
              onChanged: (value) => status.enabled.value = value,
            ),
          ),
        ],
      ),
    );
  }
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
