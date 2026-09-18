# Coordinator as RouteModule

`Coordinator<T>` implements `RouteModule<T>`. A child coordinator can be
registered in a parent's `defineModules()` like any other module.

Typical uses:

- An existing standalone coordinator (legacy app or package)
- A feature that itself has sub-modules
- Two versions of a feature (Shop V1 and Shop V2)

For a new feature with a few routes, use
[`RouteModule`](coordinator-modular.md).

The child does not own a separate browser history. Its routes join the
parent graph.

## Nested CoordinatorModular

```dart
class ShopCoordinator extends Coordinator<AppRoute>
    with CoordinatorModular<AppRoute> {
  ShopCoordinator(this.coordinator);

  @override
  final CoordinatorModular<AppRoute> coordinator;

  late final shopStack = NavigationPath<AppRoute>.createWith(
    label: 'shop',
    coordinator: coordinator,
  )..bindLayout(ShopLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, shopStack];

  @override
  Iterable<RouteModule<AppRoute>> defineModules() => [
    ShopProductsModule(this),
    ShopReviewsModule(this),
  ];

  @override
  AppRoute notFoundRoute(Uri uri) => NotFoundRoute(uri);
}
```

Overriding `coordinator` marks the child as a module. It does not create
a second root stack. Paths use the root coordinator.

```dart
class AppCoordinator extends Coordinator<AppRoute>
    with CoordinatorModular<AppRoute> {
  @override
  Iterable<RouteModule<AppRoute>> defineModules() => [
    AuthModule(this),
    ShopCoordinator(this),
  ];

  @override
  AppRoute notFoundRoute(Uri uri) => NotFoundRoute(uri);
}
```

Parsing walks shop's sub-modules, then returns `null` so the parent can
try the next sibling. Nested `notFoundRoute` is unused.

Spread `super.paths` so inner module paths are included.

Do not mix `RouteModuleBinding` on this grouping coordinator.
`CoordinatorModular` already implements `parseRouteFromUri`. Put
bindings on inner modules.

## Wrapper

Keep the original coordinator independent. Subclass it to set
`coordinator` and optionally strip a prefix:

```dart
class ShopCoordinator extends Coordinator<AppRoute>
    with RouteModuleBinding<AppRoute, ShopRouteId> {
  // manifest, bindings, paths
}

class ShopCoordinatorModule extends ShopCoordinator {
  ShopCoordinatorModule(this.coordinator);

  @override
  final CoordinatorModular<AppRoute> coordinator;

  @override
  FutureOr<AppRoute?> parseRouteFromUri(Uri uri) {
    return switch (uri.pathSegments) {
      ['v1', ...final rest] => super.parseRouteFromUri(
        uri.replace(pathSegments: rest),
      ),
      _ => null,
    };
  }
}
```

`/v1/shop/products/1` is forwarded as `/shop/products/1`.

```dart
@override
Iterable<RouteModule<AppRoute>> defineModules() => [
  ShopCoordinatorModule(this),
  SettingsModule(this),
];
```

## Parallel versions

```dart
class ShopV1Module extends ShopCoordinatorV1 {
  ShopV1Module(this.coordinator);
  @override
  final CoordinatorModular<AppRoute> coordinator;

  @override
  FutureOr<AppRoute?> parseRouteFromUri(Uri uri) =>
      switch (uri.pathSegments) {
        ['v1', ...final rest] =>
          super.parseRouteFromUri(uri.replace(pathSegments: rest)),
        _ => null,
      };
}

class ShopV2Module extends ShopCoordinatorV2 {
  ShopV2Module(this.coordinator);
  @override
  final CoordinatorModular<AppRoute> coordinator;

  @override
  FutureOr<AppRoute?> parseRouteFromUri(Uri uri) =>
      switch (uri.pathSegments) {
        ['v2', ...final rest] =>
          super.parseRouteFromUri(uri.replace(pathSegments: rest)),
        _ => null,
      };
}
```

Give V1 and V2 distinct path labels (`shop-v1`, `shop-v2`).

Runnable sample:
[`main_coordinator_module.dart`](../../example/lib/main_coordinator_module.dart).

## Redirect rules scoped to a module

`RouteModuleRedirectRule` gives a module its own `redirectRules`. Mix it
into the root coordinator, a coordinator used as a module, or a plain
`RouteModule`: one mixin for all three.

```dart
class AuthRouteModuleCoordinator extends Coordinator<AppRoute>
    with CoordinatorModular<AppRoute>, RouteModuleRedirectRule<AppRoute> {
  AuthRouteModuleCoordinator(this.coordinator, {required this.session});

  @override
  final CoordinatorModular<AppRoute> coordinator;

  final AuthSession session;

  // Read on every navigation, so build the list once.
  @override
  late final List<RedirectRule> redirectRules = [RequireSession(session)];

  late final authStack = NavigationPath<AppRoute>.createWith(
    label: 'auth',
    coordinator: coordinator,
  )..bindLayout(AuthLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, authStack];

  @override
  Iterable<RouteModule<AppRoute>> defineModules() => [SecurityModule(this)];

  @override
  AppRoute notFoundRoute(Uri uri) => NotFoundRoute(uri);
}

class RequireSession extends RedirectRule<AppRoute> {
  RequireSession(this.session);

  final AuthSession session;

  @override
  RedirectResult<AppRoute> redirectResult(
    covariant CoordinatorCore coordinator,
    AppRoute route,
  ) {
    // SignInRoute is this rule's own redirect target and lands in the same
    // stack, so the rule continues for it. Otherwise the redirect would loop.
    if (route is SignInRoute || session.signedIn) {
      return const RedirectResult.continueRedirect();
    }
    return RedirectResult.redirectTo(SignInRoute());
  }
}
```

A plain module declares its rules the same way:

```dart
class ShopModule extends RouteModule<AppRoute>
    with RouteModuleRedirectRule<AppRoute> {
  ShopModule(super.coordinator, {required this.account});

  final ShopAccount account;

  @override
  late final List<RedirectRule> redirectRules = [CheckBalanceRule(account)];

  late final shopStack = NavigationPath<AppRoute>.createWith(
    label: 'shop',
    coordinator: coordinator,
  )..bindLayout(ShopLayout.new);

  @override
  List<StackPath> get paths => [shopStack];

  @override
  AppRoute? parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['shop'] => ShopHomeRoute(),
    ['shop', 'checkout'] => CheckoutRoute(),
    _ => null,
  };
}
```

The root's rules gate every destination:

```dart
class AppCoordinator extends Coordinator<AppRoute>
    with CoordinatorModular<AppRoute>, RouteModuleRedirectRule<AppRoute> {
  final onboarding = OnboardingState();
  final account = ShopAccount();
  final session = AuthSession();

  @override
  late final List<RedirectRule> redirectRules = [OnboardingGate(onboarding)];

  @override
  Iterable<RouteModule<AppRoute>> defineModules() => [
    ShopModule(this, account: account),
    NewsFeedModule(this),
    AuthRouteModuleCoordinator(this, session: session),
  ];

  @override
  AppRoute notFoundRoute(Uri uri) => NotFoundRoute(uri);
}
```

With `SecurityModule` declaring `RequireTwoFactor` and `NewsFeedModule`
declaring nothing, this tree gates:

```
AppCoordinator                  OnboardingGate     root stack
  ├─ ShopModule                 CheckBalanceRule   shopStack
  ├─ NewsFeedModule             (no rules)         feedStack
  └─ AuthRouteModuleCoordinator RequireSession     authStack
       └─ SecurityModule        RequireTwoFactor   securityStack
```

| A destination that lands in | is offered, in order |
|---|---|
| the root stack (no layout) | `OnboardingGate` |
| `shopStack` | `OnboardingGate`, `CheckBalanceRule` |
| `feedStack` | `OnboardingGate` |
| `authStack` | `OnboardingGate`, `RequireSession` |
| `securityStack` | `OnboardingGate`, `RequireSession`, `RequireTwoFactor` |
| any stack, when it is a layout parent (a shell or a branch root) | nothing |

The destination's own `RouteRedirect` or `RouteRedirectRule` runs after
these.

### Where a destination lands

- A module owns the stacks it lists in `paths`. Its rules gate every
  destination that lands in one of them, or in a stack of one of its
  sub-modules. The root lists every stack, so its rules gate every
  destination.
- Listing a stack claims it. Two sibling modules cannot list the same stack,
  and a module cannot list the root stack: both are errors (below). A module
  that lists a stack its ancestor owns takes that stack over, because the
  innermost claim wins, so list each stack only in the module that owns it.
- A destination lands where the coordinator commits it: in the stack its
  parent layout resolves to, or on the root stack when it has no layout.
  **A module route without a layout lands on the root stack and belongs to
  the root**: the module's rules never see it. To gate a route, give it a
  layout hosted in one of the module's stacks, and pin its chain in a test
  (below).
- The tree root decides, whatever the call site. The root, a module
  instance, a sibling module, a path-level `push`, a deep link, browser back,
  the restored active route and a tab switch all give a destination the same
  chain.
- The chain follows `defineModules`, not the widget tree. `SecurityModule`'s
  shell can sit on the root stack; because the auth coordinator registers
  `SecurityModule`, `RequireSession` still runs before `RequireTwoFactor`.
- A module without the mixin adds nothing, and does not break the chain of
  the modules below it.

### Order

| Order | Rules |
|---|---|
| 1 | the root's `redirectRules` |
| 2 | each enclosing module that declares rules, outer to inner |
| 3 | the owning module's `redirectRules` |
| 4 | the destination's own `RouteRedirect` / `RouteRedirectRule` |

The first `RedirectResult.stop()` or `RedirectResult.redirectTo(...)` wins,
and nothing after it runs. Outer gates run first so an inner gate can rely
on them: a session exists before a balance is checked, and a module cannot
loosen an app-wide gate. The order is fixed.

A module rule that redirects to the destination itself moves nothing, so it
wins nothing: the rules below it still run, as after `continueRedirect()`.
An outer rule can never switch an inner gate off by handing the destination
back, whether by mistake or because it rebuilds the route and nothing
needed changing.

### Writing rules

- **Continue for your own redirect target.** A `redirectTo(...)` target is
  resolved again from the top of its own chain. When it lands in the same
  scope, the rule sees it too: `RequireSession` above continues for
  `SignInRoute`. A target outside the scope never reaches the rule: a shop
  rule that redirects to a layout-less `LoginRoute` does not gate
  `LoginRoute`. The hop budget (`RouteRedirect.maxRedirectHops`, 20 moves)
  and cycle detection span every level, so two rules that redirect back and
  forth throw `StateError`.
- **Keep rules pure decisions.** `replace` and `recover` resolve a
  destination more than once. So does a coordinator navigation to a tab
  entry: once for the operation, once for the tab switch. A rule can see the
  same destination twice for one tap. Log if you like, but do not count or
  consume anything in a rule.
- **Build the list once.** `redirectRules` is read on every pass, so use
  `late final`. Rules read their state when they run, so signing in takes
  effect on the next navigation. The debug check at commit decides with the
  lists as they are at commit time, so keep `redirectRules` stable between
  navigations: change what a rule decides through its state, not by
  swapping the list.
- **A stop shows nothing, so say why.** `RedirectResult.stop()` cancels the
  navigation and leaves the screen as it was, which to a user is a dead
  button. Tell them: the example's host shows a notice for every stop. When
  the app is opened on a URL and a rule stops it, no page is up yet and the
  app is blank. Redirect instead of stopping for a URL users can land on, or
  give the host a fallback: the example overrides `navigate` and opens its
  hub when the root stack is still empty.
- **Rules guard entry, not presence.** `pop`, `tryPop`, system back,
  `remove`, `reset` and `replaceAll` run no rule, and a page that is open
  stays open when a rule's state changes. Browser back re-enters a URL, so
  it is gated.
- **Restoration re-gates only the active route.** It rebinds every
  restored stack as it was, then re-navigates the active route through its
  chain. Other restored entries are not re-gated, and neither is a restored
  `IndexedStackPath` tab index. A `CoordinatorModular` root parses
  asynchronously, so it must override `parseRouteFromUriSync` to restore at
  all: see [State restoration](state-restoration.md#setup).
- **Layout parents are never offered.** Shells mount as needed, so
  switching `BranchedStackPath` branches runs no rule. A route inside a
  branch gets the chain of the branch stack it lands in. Navigate to a tab
  entry, never to its shell: a tab shell is not gated, and navigating to it
  shows its active entry without offering that entry to any rule.
- **Tabs.** `goToIndexed` resolves the entry through its chain. Every tab
  entry must declare the tab set's layout: an entry without one lands on the
  root stack, so only the root's rules would gate it, and in debug the switch
  asserts, naming the modules it would skip.
  `RedirectResult.stop()` keeps the current tab, and a redirect to another
  entry switches to it. A redirect out of the tab set keeps the current tab
  and is followed through the coordinator, so a session gate can send a tab
  tap to the sign-in page. A gated switch waits for its rules, so two taps
  can overlap: the last one wins, whichever finishes first.

### Misconfiguration fails loudly

These checks apply once any module of the tree mixes in
`RouteModuleRedirectRule`.

The first navigation builds the scope, once. It throws a `StateError` naming
the module and the stack when:

- a module declares rules, but neither it nor its sub-modules list a stack.
  Declare the rules on the module that owns the stack its routes land in.
- two sibling modules list the same stack.
- a module lists the root stack. Inside a module coordinator, `root` is the
  app's root stack.
- a listed stack has no coordinator, or one from another tree.

Navigating throws a `StateError` when:

- a call is made on a module coordinator that declares rules but is not
  returned from `defineModules`, such as `orphan.push(route)`.
- the destination names a parent layout the tree root cannot build. Without
  the check it would land on the root stack silently.
- the destination lands in a stack no module lists. For a
  `BranchedStackPath`, list the branched path and every branch child path.

In debug, an `AssertionError` fires when:

- a path-level push commits a route into a stack whose owners' rules never
  ran for it. Give the route that stack's layout, or navigate through the
  coordinator.
- a route already on a stack is navigated to again, or a tab entry is
  switched to, and the owners of the stack it sits in would not gate it:
  typically a tab entry without its tab set's layout.

These asserts are stripped from a release build, and nothing replaces them
there. Rules run when a destination is navigated to, and only then: they are
routing gates, not a security boundary. Keep the checks that protect data on
the server.

Not detected: a module that declares rules but is not returned from
`defineModules`, or from a sub-module's, is invisible to the scope. Its rules
never run when its stack is reached through the root, a path-level
operation, a deep link or browser back; only a call made on an unregistered
module coordinator itself throws. Return every declaring module from
`defineModules`.

A tree in which no module mixes it in has no scope: none of this applies.

### Pin the chain in a test

`redirectScopeOf` returns the modules whose rules gate a destination, in
the order they run. It gives the same answer from every coordinator of the
tree, an empty list for a layout parent and for a tree without rules, and
throws whatever navigating to the destination would throw.

```dart
test('ProfileRoute is gated by the root, then the auth module', () {
  final app = AppCoordinator();
  final auth = app.getModule<AuthRouteModuleCoordinator>();

  expect(app.redirectScopeOf(ProfileRoute()), [same(app), same(auth)]);
});
```

Use `same`: coordinators extend `Equatable`, so `==` alone could match
another coordinator of the same type. A route that lost its layout shows up
as `[same(app)]`.

### One RedirectRule, two levels

A rule in `RouteModuleRedirectRule.redirectRules` is the same `RedirectRule`
a route lists in `RouteRedirectRule.redirectRules`, with the same
`RedirectResult`s. Move a rule from a route to the module that owns the
route's stack, and it gives the same result, the same stacks and the same
discards.

The two levels compose:

- Module rules run first, then the route's own. After a `stop()` or
  `redirectTo(...)` at module level, the route's rules never run.
- A `redirectTo(...)` from either level starts again at the top of the new
  target's chain.

Two differences are deliberate:

| | Route level (`RouteRedirectRule`) | Module level (`RouteModuleRedirectRule`) |
|---|---|---|
| Gates | the route | every destination that lands in the module's stacks |
| `coordinator` argument | the call site: the coordinator, module instance or path's coordinator the navigation went through | always the tree root |
| Routes offered | the route | any route that lands in those stacks |

- **The coordinator argument.** A module rule gets the tree root even when
  the call went through a module, so the argument cannot lead it to its
  module's state. Capture the state at construction instead:
  `late final redirectRules = [RequireSession(session)];`.
- **Typing.** A `RedirectRule<ProfileRoute>` is safe on `ProfileRoute`. In
  the auth module it is also offered `SignInRoute`, which lands in the same
  stack, and throws a `TypeError`. Type a module rule to the base its stacks
  host (`RedirectRule<AppRoute>`), and type-test inside it, as
  `RequireSession` does for `SignInRoute`.

**Migrating from a route-base getter.** Before, the route base returned the
app-wide rules, and `SignInRoute` overrode the getter with `[]` to opt out:

```dart
abstract class AppRoute extends RouteTarget
    with RouteUnique, RouteRedirect<AppRoute>, RouteRedirectRule<AppRoute> {
  @override
  List<RedirectRule> get redirectRules => [RequireSession(appSession)];
}
```

After, routes are plain and the root declares the rules:

```dart
abstract class AppRoute extends RouteTarget with RouteUnique {}

class AppCoordinator extends Coordinator<AppRoute>
    with CoordinatorModular<AppRoute>, RouteModuleRedirectRule<AppRoute> {
  AppCoordinator(this.session);

  final AuthSession session;

  @override
  late final List<RedirectRule> redirectRules = [RequireSession(session)];

  @override
  Iterable<RouteModule<AppRoute>> defineModules() => [AuthModule(this)];

  @override
  AppRoute notFoundRoute(Uri uri) => NotFoundRoute(uri);
}
```

The same flows give the same results, stacks and discards. What changes:

- The root rule gates every destination, including the routes the old base
  let opt out. Put the exception in the rule: continue for its own redirect
  target and for public routes.
- The rule's `coordinator` argument is always the root.
- A route with rules of its own keeps `RouteRedirectRule`; they run after
  the root's.
- Type the rule to the base every destination shares: `AppRoute` here, or
  `RouteUnique` when modules bring their own route bases.

### Example

The scoped redirect example is a host and four feature modules, one file
per module, as in an app with one package per feature. Modules never import
each other, and only the app module imports modules. Each module gets its
state and the trace through its constructor, and links to another feature
by URI (`coordinator.pushUri(...)`), so a destination gets the same chain
from every module.

```sh
# from packages/zenrouter/example
flutter run -t lib/main_coordinator_redirect.dart
```

| File | Module | Rules | Path |
|---|---|---|---|
| [`app_module.dart`](../../example/lib/coordinator_redirect/app_module.dart) | `AppCoordinator`, the root, with the hub, the rule trace and the path inspector | `OnboardingGate` | root `NavigationPath` |
| [`shop_module.dart`](../../example/lib/coordinator_redirect/shop_module.dart) | `ShopModule`, a plain module | `SubscriptionGate` | `IndexedStackPath`; the bottom bar calls `goToIndexed` directly |
| [`feed_module.dart`](../../example/lib/coordinator_redirect/feed_module.dart) | `NewsFeedModule`, a plain module | none | `BranchedStackPath`, with a `NavigationPath` per branch |
| [`auth_module.dart`](../../example/lib/coordinator_redirect/auth_module.dart) | `AuthRouteModuleCoordinator`, a coordinator used as a module | `RequireSession` | `NavigationPath` |
| [`security_module.dart`](../../example/lib/coordinator_redirect/security_module.dart) | `SecurityModule`, registered by the host under the auth coordinator | `RequireTwoFactor` | `NavigationPath`, two levels deep |

Every module owns its routing as a `RouteManifest`, with `RouteModuleBinding`
on the plain modules. The root and the auth coordinator group sub-modules, so
they cannot mix it in; they give their own graph to the composed one through
`localRouteManifestFragment` and resolve their own URLs through their
bindings. The shells are one layout kind each: `indexed` for the shop tabs,
`branched` for the feed, `stack` for the rest. No file parses a URL by hand,
and `toUri()` builds each URL back from the same manifest with
`location(...)`, using every part of it:

| Part | Route | URL |
|---|---|---|
| `pathParameters` | `PostRoute` | `/feed/following/post/12` |
| `restParameters` | `HelpRoute` | `/help/rules/order` |
| `queryParameters` | `CatalogTab`, `SignInRoute` and `OnboardingRoute`, with `RouteQueryParameters` | `/shop/catalog?sort=price`, `/account/sign-in?from=/shop&continue=/account/profile` |
| `fragment` | `HelpRoute` | `/help/rules/order#stop` |

A query and a fragment are not part of a route's identity. Typing another one
reaches the page that is already open through `onUpdate`, and the page
rewrites its URL in place when the user changes it.

The two detour pages, welcome and sign-in, keep both ends of the trip in
their URL instead of in shared state: `continue` is where the user was going,
`from` is the page they were on. A rule that sends a user on a detour reads
the page on screen as the origin, and inherits the origin of a page that is
itself a detour, so welcome then sign-in still returns to the first page. A
URL taken from a query is followed only when it stays in the app.

The entry point,
[`main_coordinator_redirect.dart`](../../example/lib/main_coordinator_redirect.dart),
only composes the tree. The dock at the bottom of the screen shows every
rule decision, and for each path its type, owner, chain and stack.
zenrouter_devtools draws the composed manifest in its Graph tab.

## See also

- [Modular coordinator](coordinator-modular.md)
- [Mixins API: RouteModuleRedirectRule](../api/mixins.md#routemoduleredirectrule)
- [Layouts](route-layout.md)
- [Route versioning](../recipes/route-versioning.md)
