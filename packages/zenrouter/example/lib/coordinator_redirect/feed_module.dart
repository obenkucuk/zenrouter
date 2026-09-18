// =============================================================================
// NewsFeedModule: declares no rules (the owner's NewsFeedCoordinator role)
// =============================================================================
// A plain RouteModule without RouteModuleRedirectRule, so it contributes no
// rule. Its destinations are gated by the root's rules only: SubscriptionGate
// (a sibling's rule) and RequireSession never see a feed page.
//
// The feed shell (FeedLayout) sits on the root stack and resolves to a
// BranchedStackPath with two branch roots, "For you" and "Following". Branch
// roots are layouts, each owning its own NavigationPath, so a post is pushed
// into the active branch's stack and switching branches keeps each branch's
// depth. The branch control calls `branches.goToBranch` directly: a switch
// offers nothing to any rule, because layout parents are never offered.
//
// `paths` lists the branched path AND every branch child path. In a tree with
// scoped rules, a stack a destination lands in must be listed by some module.
//
// Back works the way a user expects it to. The shell's back arrow pops the
// active branch's top post. From a branch's first page, it leaves the feed.
// It never pops a branch's first page, so a back never leaves a branch empty.
//
// The module owns its routing as a RouteManifest: a branched shell whose
// fixed children are the branch roots, each a stack layout with its list and
// its posts under it. RouteModuleBinding matches URLs against it, the bindings
// turn a match into a route, and toUri builds the same URL back from it, so
// there is no parser to keep in step.
//
// This file imports only flutter and zenrouter. A link to another feature
// goes by URI.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zenrouter/zenrouter.dart';

/// The IDs of this module's manifest: the shell, its branch roots, then the
/// routes of each branch. [entry] is `/feed`, the feed's front door.
enum FeedRouteId {
  shell,
  forYouBranch,
  followingBranch,
  entry,
  forYouList,
  forYouPost,
  followingList,
  followingPost,
}

enum FeedBranch {
  forYou(
    'for-you',
    'For you',
    layoutId: FeedRouteId.forYouBranch,
    listId: FeedRouteId.forYouList,
    postId: FeedRouteId.forYouPost,
  ),
  following(
    'following',
    'Following',
    layoutId: FeedRouteId.followingBranch,
    listId: FeedRouteId.followingList,
    postId: FeedRouteId.followingPost,
  );

  const FeedBranch(
    this.slug,
    this.title, {
    required this.layoutId,
    required this.listId,
    required this.postId,
  });

  final String slug;
  final String title;

  /// This branch in the manifest: its root, its list and its posts.
  final FeedRouteId layoutId;
  final FeedRouteId listId;
  final FeedRouteId postId;

  /// The branch root a destination of this branch sits behind.
  Type get layout => switch (this) {
    FeedBranch.forYou => ForYouBranch,
    FeedBranch.following => FollowingBranch,
  };
}

class NewsFeedModule extends RouteModule<RouteUnique>
    with RouteModuleBinding<RouteUnique, FeedRouteId> {
  NewsFeedModule(super.coordinator);

  /// The module's routing graph. A branched layout lists its branch roots as
  /// fixed children, and every direct child of it must be one of them; a
  /// branch's pages sit under its root.
  static final manifest = RouteManifest<FeedRouteId>(
    name: 'feed',
    idCodec: RouteIdCodec.enumValues(FeedRouteId.values),
    layouts: [
      RouteManifestLayout.branched(
        id: FeedRouteId.shell,
        path: '/feed',
        childIds: [for (final branch in FeedBranch.values) branch.layoutId],
      ),
      for (final branch in FeedBranch.values)
        RouteManifestLayout.stack(
          id: branch.layoutId,
          path: '/feed/${branch.slug}',
          parentId: FeedRouteId.shell,
        ),
    ],
    routes: [
      RouteManifestRoute(
        id: FeedRouteId.entry,
        path: '/feed',
        parentId: FeedBranch.forYou.layoutId,
      ),
      for (final branch in FeedBranch.values) ...[
        RouteManifestRoute(
          id: branch.listId,
          path: '/feed/${branch.slug}',
          parentId: branch.layoutId,
        ),
        RouteManifestRoute(
          id: branch.postId,
          path: '/feed/${branch.slug}/post/:id',
          parentId: branch.layoutId,
        ),
      ],
    ],
  );

  /// From a manifest match to a route. No `notFound`: a URL this module does
  /// not own falls through to the next module.
  @override
  late final routeBindings = manifest.bind<RouteUnique>(
    bindings: [
      RouteBinding(
        id: FeedRouteId.entry,
        create: (_) => FeedListRoute(FeedBranch.forYou),
      ),
      for (final branch in FeedBranch.values) ...[
        RouteBinding(id: branch.listId, create: (_) => FeedListRoute(branch)),
        RouteBinding(
          id: branch.postId,
          create: (match) =>
              PostRoute(branch, int.parse(match.pathParameters['id']!)),
        ),
      ],
    ],
  );

  /// A pattern cannot say that `:id` is a number, and a post id is one. A URL
  /// with any other id is not a feed URL: the next module, or the host's
  /// not-found page, gets it.
  @override
  FutureOr<RouteUnique?> parseRouteFromUri(Uri uri) {
    final id = manifest.match(uri)?.pathParameters['id'];
    if (id != null && int.tryParse(id) == null) return null;
    return super.parseRouteFromUri(uri);
  }

  late final NavigationPath<RouteUnique> forYouStack =
      NavigationPath<RouteUnique>.createWith(
        coordinator: coordinator,
        label: 'feed-for-you',
      )..bindLayout(ForYouBranch.new);

  late final NavigationPath<RouteUnique> followingStack =
      NavigationPath<RouteUnique>.createWith(
        coordinator: coordinator,
        label: 'feed-following',
      )..bindLayout(FollowingBranch.new);

  late final BranchedStackPath<RouteUnique> branches =
      BranchedStackPath<RouteUnique>.createWith(
        [ForYouBranch(), FollowingBranch()],
        coordinator: coordinator as Coordinator,
        label: 'feed-branches',
      )..bindLayout(FeedLayout.new);

  NavigationPath<RouteUnique> stackOf(FeedBranch branch) => switch (branch) {
    FeedBranch.forYou => forYouStack,
    FeedBranch.following => followingStack,
  };

  /// The branched path and every branch child path.
  @override
  List<StackPath> get paths => [branches, forYouStack, followingStack];
}

NewsFeedModule _feedOf(CoordinatorCore coordinator) =>
    (coordinator as CoordinatorModular<RouteUnique>)
        .getModule<NewsFeedModule>();

// =============================================================================
// Routes
// =============================================================================

/// The feed's route base.
///
/// [label] names a route in the rule trace and the path inspector, and
/// [toString] returns it, so a rule typed to any route can name a feed route
/// without importing this file. It is spelled out, never read from the type:
/// a release web build minifies type names.
abstract class FeedRoute extends RouteTarget with RouteUnique {
  String get label;

  @override
  String toString() => label;
}

/// The feed shell, on the root stack. A layout parent: never gated.
class FeedLayout extends FeedRoute with RouteLayout<RouteUnique> {
  @override
  String get label => 'FeedLayout';

  @override
  BranchedStackPath<RouteUnique> resolvePath(
    covariant CoordinatorCore coordinator,
  ) => _feedOf(coordinator).branches;

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final feed = _feedOf(coordinator);
    final branches = resolvePath(coordinator);
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ListenableBuilder(
          listenable: Listenable.merge([
            branches,
            for (final branch in FeedBranch.values) feed.stackOf(branch),
          ]),
          builder: (context, _) => AppBar(
            title: const Text('Feed'),
            // Flutter's own back arrow pops the navigator this AppBar sits
            // in, the root one, so from a post it would close the whole feed.
            // This one pops the active branch's top post first, and this shell
            // only from a branch's first page, which it never pops: a back
            // never leaves a branch empty.
            automaticallyImplyLeading: false,
            leading: _canGoBack(context, feed, branches)
                ? BackButton(
                    onPressed: () =>
                        _back(context, coordinator, feed, branches),
                  )
                : null,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Banner('NewsFeedModule · BranchedStackPath · no rules'),
          Padding(
            padding: const EdgeInsets.all(8),
            child: ListenableBuilder(
              listenable: branches,
              builder: (context, _) => SegmentedButton<FeedBranch>(
                key: const Key('feed-branch-control'),
                segments: [
                  for (final branch in FeedBranch.values)
                    ButtonSegment(value: branch, label: Text(branch.title)),
                ],
                selected: {FeedBranch.values[branches.activeBranchIndex]},
                showSelectedIcon: false,
                // Straight to the path. No rule sees a branch switch: branch
                // roots are layouts, and layouts are never offered.
                onSelectionChanged: (selection) =>
                    branches.goToBranch(selection.single.index),
              ),
            ),
          ),
          Expanded(child: buildPath(coordinator)),
        ],
      ),
    );
  }

  /// The stack of the branch on screen.
  static NavigationPath<RouteUnique> _activeStack(
    NewsFeedModule feed,
    BranchedStackPath<RouteUnique> branches,
  ) => feed.stackOf(FeedBranch.values[branches.activeBranchIndex]);

  /// Whether the back arrow has somewhere to go: a post under the active
  /// branch's top page, or a page under this shell.
  static bool _canGoBack(
    BuildContext context,
    NewsFeedModule feed,
    BranchedStackPath<RouteUnique> branches,
  ) =>
      _activeStack(feed, branches).stack.length > 1 ||
      (ModalRoute.of(context)?.impliesAppBarDismissal ?? false);

  /// Pops the active branch's top post through the coordinator, like the
  /// post's "Back to the list". On a branch's first page, pops this shell
  /// from the root navigator, as Flutter's own arrow does.
  ///
  /// The shell is not popped through the coordinator: that resets its
  /// branches a second time while the root navigator builds, and
  /// IndexedStackPath.reset notifies listeners during that build.
  static void _back(
    BuildContext context,
    Coordinator coordinator,
    NewsFeedModule feed,
    BranchedStackPath<RouteUnique> branches,
  ) {
    if (_activeStack(feed, branches).stack.length > 1) {
      coordinator.pop();
    } else {
      Navigator.maybePop(context);
    }
  }
}

/// A branch root: a layout that owns one branch's NavigationPath.
abstract class FeedBranchLayout extends FeedRoute
    with RouteLayout<RouteUnique> {
  FeedBranch get branch;

  @override
  Type? get layout => FeedLayout;

  @override
  NavigationPath<RouteUnique> resolvePath(
    covariant CoordinatorCore coordinator,
  ) => _feedOf(coordinator).stackOf(branch);

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final path = resolvePath(coordinator);
    return ListenableBuilder(
      listenable: path,
      builder: (context, _) => path.stack.isEmpty && _shellIsOpen(context)
          ? _EmptyBranch(branch: branch, coordinator: coordinator)
          : buildPath(coordinator),
    );
  }

  /// Whether the feed shell is open, rather than on its way out.
  ///
  /// Popping the shell resets its branches at once: BranchedStackPath.reset
  /// empties every branch's stack while the shell's page still animates out.
  /// The user did not empty the branch, so it shows no "Nothing in … yet"
  /// page for those frames.
  static bool _shellIsOpen(BuildContext context) =>
      ModalRoute.of(context)?.isActive ?? true;
}

class ForYouBranch extends FeedBranchLayout {
  @override
  String get label => 'ForYouBranch';

  @override
  FeedBranch get branch => FeedBranch.forYou;
}

class FollowingBranch extends FeedBranchLayout {
  @override
  String get label => 'FollowingBranch';

  @override
  FeedBranch get branch => FeedBranch.following;
}

/// A branch's list of posts: the first page of its stack.
class FeedListRoute extends FeedRoute {
  FeedListRoute(this.branch);

  final FeedBranch branch;

  @override
  String get label => 'FeedListRoute';

  @override
  Type? get layout => branch.layout;

  @override
  List<Object?> get props => [branch.slug];

  @override
  Uri toUri() => NewsFeedModule.manifest.location(branch.listId);

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    final slug = branch.slug;
    return _Page(
      heading: '${branch.title} feed',
      lines: const [
        'Only OnboardingGate gates this page: NewsFeedModule declares no '
            'rules.',
      ],
      children: [
        for (var id = 1; id <= 3; id++)
          ListTile(
            key: Key('post-$slug-$id'),
            title: Text('Post $id'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => coordinator.push(PostRoute(branch, id)),
          ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Other features, by URI'),
        ),
        ListTile(
          key: Key('feed-$slug-link-profile'),
          leading: const Icon(Icons.link),
          title: const Text('Profile'),
          subtitle: const Text(
            '/account/profile · lands in the auth stack: OnboardingGate › '
            'RequireSession',
          ),
          onTap: () => coordinator.pushUri(Uri.parse('/account/profile')),
        ),
        ListTile(
          key: Key('feed-$slug-link-billing'),
          leading: const Icon(Icons.link),
          title: const Text('Billing'),
          subtitle: const Text(
            '/shop/billing · lands in the shop tabs: OnboardingGate › '
            'SubscriptionGate',
          ),
          onTap: () => coordinator.pushUri(Uri.parse('/shop/billing')),
        ),
      ],
    );
  }
}

class PostRoute extends FeedRoute {
  PostRoute(this.branch, this.id);

  final FeedBranch branch;
  final int id;

  @override
  String get label => 'PostRoute';

  @override
  Type? get layout => branch.layout;

  @override
  List<Object?> get props => [branch.slug, id];

  @override
  Uri toUri() => NewsFeedModule.manifest.location(
    branch.postId,
    pathParameters: {'id': '$id'},
  );

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      _Page(
        heading: 'Post $id · ${branch.title}',
        lines: [
          'This post sits in the ${branch.title} stack, a NavigationPath '
              'owned by NewsFeedModule. Only OnboardingGate gated it.',
        ],
        children: [
          ListTile(
            key: const Key('post-next'),
            title: const Text('Next post'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => coordinator.push(PostRoute(branch, id + 1)),
          ),
          ListTile(
            key: const Key('post-back'),
            leading: const Icon(Icons.arrow_back),
            title: const Text('Back to the list'),
            onTap: () => coordinator.pop(),
          ),
        ],
      );
}

// =============================================================================
// Widgets (each module file keeps its own: modules share no file)
// =============================================================================

class _EmptyBranch extends StatelessWidget {
  const _EmptyBranch({required this.branch, required this.coordinator});

  final FeedBranch branch;
  final Coordinator coordinator;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Nothing in ${branch.title} yet.'),
            const SizedBox(height: 4),
            const Text(
              'A branch switch runs no rule: branch roots are layouts.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: Key('feed-open-${branch.slug}'),
              onPressed: () => coordinator.push(FeedListRoute(branch)),
              child: Text('Open the ${branch.title} feed'),
            ),
          ],
        ),
      ),
    ),
  );
}

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
