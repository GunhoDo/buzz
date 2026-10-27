import 'dart:convert';
import 'dart:typed_data';

import 'package:buzz/shared/me/me_assistants.dart';
import 'package:buzz/shared/me/me_sync.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:pointycastle/digests/sha256.dart';

class _Relay extends RelaySessionNotifier {
  final List<List<NostrEvent>> inventory;
  final List<NostrEvent> profiles;
  final inventoryFilters = <Map<String, dynamic>>[];
  final profileFilters = <Map<String, dynamic>>[];
  _Relay({this.inventory = const [], this.profiles = const []});
  List<List<String>?> get profileAuthors => [
    for (final filter in profileFilters)
      (filter['authors'] as List?)?.cast<String>(),
  ];
  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);
  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final filter = filters.single.toJson();
    if (filters.single.kinds.single == 30177) {
      inventoryFilters.add(filter);
      final d = (filter['#d'] as List?)?.cast<String>();
      if (d != null) {
        // Return every record so the client must enforce the requested d.
        return [for (final page in inventory) ...page];
      }
      final page = inventoryFilters.length - 1;
      return page < inventory.length ? inventory[page] : const [];
    }
    expect(filters.single.kinds, [0]);
    profileFilters.add(filter);
    // Return every profile so the client must enforce the requested authors.
    return profiles;
  }
}

void main() {
  final owner = nostr.Keys.generate();
  final other = nostr.Keys.generate();
  final agent = nostr.Keys.generate();
  NostrEvent profile(
    nostr.Keys signer, {
    nostr.Keys? ownedBy,
    int time = 1,
    String conditions = '',
    Object? content,
  }) {
    final digest = SHA256Digest()
        .process(
          Uint8List.fromList(
            utf8.encode('nostr:agent-auth:${signer.public}:$conditions'),
          ),
        )
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    return NostrEvent.fromJson(
      nostr.Event.from(
        kind: 0,
        content: jsonEncode(content ?? {'display_name': 'My assistant'}),
        secretKey: signer.secret,
        createdAt: time,
        tags: [
          if (ownedBy != null)
            [
              'auth',
              ownedBy.public,
              conditions,
              nostr.Schnorr.sign(secretKey: ownedBy.secret, message: digest),
            ],
        ],
      ).toMap(),
    );
  }

  var fakeAgents = 0;
  String fakeAgent() => (++fakeAgents).toRadixString(16).padLeft(64, 'a');
  const policy = {
    'name': 'Agent',
    'parallelism': 1,
    'respond_to': 'owner-only',
  };
  NostrEvent managed(
    String d, {
    nostr.Keys? by,
    int time = 1,
    int kind = 30177,
    Object? content = policy,
  }) => NostrEvent.fromJson(
    nostr.Event.from(
      kind: kind,
      content: jsonEncode(content),
      secretKey: (by ?? owner).secret,
      createdAt: time,
      tags: [
        ['d', d],
      ],
    ).toMap(),
  );

  // A full page of signed records with distinct times, shared because
  // signing dominates fixture cost.
  late final fullPage = [
    for (var i = 0; i < 100; i++) managed(fakeAgent(), time: 5000 - i),
  ];

  ProviderContainer setup(_Relay relay) {
    final sync = MeSync(
      relay,
      RelayConfig(
        baseUrl: 'https://relay.test',
        nsec: nostr.Nip19.encode(
          prefix: nostr.Nip19Prefix.nsec,
          data: owner.secret,
        ),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        relaySessionProvider.overrideWith(() => relay),
        meSyncProvider.overrideWithValue(sync),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('finds verified agents from the owner inventory only', () async {
    final valid = profile(agent, ownedBy: owner);
    final forged = valid.toJson()..['pubkey'] = other.public;
    final otherOwned = nostr.Keys.generate();
    final unlisted = nostr.Keys.generate();
    final relay = _Relay(
      inventory: [
        [
          managed(agent.public),
          managed(otherOwned.public),
          managed(other.public),
        ],
      ],
      profiles: [
        profile(owner),
        profile(otherOwned, ownedBy: other),
        NostrEvent.fromJson(forged),
        profile(unlisted, ownedBy: owner),
        valid,
      ],
    );
    final choices = await setup(relay).read(meAssistantsProvider.future);
    expect(choices.map((a) => a.pubkey), [agent.public]);
    expect(choices.single.displayName, 'My assistant');
    expect(relay.inventoryFilters.single, {
      'kinds': [30177],
      'authors': [owner.public],
      'limit': 100,
    });
    expect(
      relay.profileAuthors.single,
      unorderedEquals([agent.public, otherOwned.public, other.public]),
    );
    expect(relay.profileFilters.single['limit'], 3);
  });
  test('does not query profiles without managed agents', () async {
    final relay = _Relay(profiles: [profile(agent, ownedBy: owner)]);
    expect(await setup(relay).read(meAssistantsProvider.future), isEmpty);
    expect(relay.profileFilters, isEmpty);
  });
  for (final malformed in [7, true, 'wrong', <String, Object>{}, <Object>[]]) {
    test(
      'malformed optional profile fields do not poison directory: $malformed',
      () async {
        final broken = nostr.Keys.generate();
        final container = setup(
          _Relay(
            inventory: [
              [managed(broken.public), managed(agent.public)],
            ],
            profiles: [
              profile(
                broken,
                ownedBy: owner,
                content: {
                  for (final field in [
                    'display_name',
                    'name',
                    'respond_to',
                    'respond_to_allowlist',
                    'channel_ids',
                  ])
                    field: malformed,
                },
              ),
              profile(agent, ownedBy: owner),
            ],
          ),
        );
        final choices = await container.read(meAssistantsProvider.future);
        expect(
          choices.singleWhere((a) => a.pubkey == agent.public).displayName,
          'My assistant',
        );
        expect(
          await isOwnedMeAssistant(
            container.read(meSyncProvider),
            agent.public,
          ),
          isTrue,
        );
      },
    );
  }
  test('latest profile removes obsolete ownership', () async {
    final container = setup(
      _Relay(
        inventory: [
          [managed(agent.public)],
        ],
        profiles: [
          profile(agent, ownedBy: owner),
          profile(agent, time: 2),
        ],
      ),
    );
    expect(await container.read(meAssistantsProvider.future), isEmpty);
  });
  test('skips unnamed, malformed, and superseded inventory records', () async {
    final unnamed = nostr.Keys.generate();
    final renamed = nostr.Keys.generate();
    final relay = _Relay(
      inventory: [
        [
          managed(renamed.public, time: 3, content: {...policy, 'name': ' '}),
          managed(agent.public, time: 2),
          managed(renamed.public, time: 2),
          managed(unnamed.public, content: {...policy, 'name': 7}),
          managed(agent.public.toUpperCase()),
          managed('not-a-pubkey'),
        ],
      ],
      profiles: [
        profile(agent, ownedBy: owner),
        profile(unnamed, ownedBy: owner),
        profile(renamed, ownedBy: owner),
      ],
    );
    final choices = await setup(relay).read(meAssistantsProvider.future);
    expect(choices.map((a) => a.pubkey), [agent.public]);
    expect(relay.profileAuthors.single, [agent.public]);
  });
  for (final (label, content) in [
    ('unsupported respond_to', {...policy, 'respond_to': 'nobody'}),
    ('missing respond_to', {'name': 'Agent', 'parallelism': 1}),
    ('missing parallelism', {'name': 'Agent', 'respond_to': 'anyone'}),
    ('negative parallelism', {...policy, 'parallelism': -1}),
    ('fractional parallelism', {...policy, 'parallelism': 1.5}),
    ('oversized parallelism', {...policy, 'parallelism': 0x100000000}),
    ('non-list allowlist', {...policy, 'respond_to_allowlist': 'x'}),
    (
      'non-string allowlist entry',
      {
        ...policy,
        'respond_to': 'allowlist',
        'respond_to_allowlist': [7],
      },
    ),
    ('null allowlist', {...policy, 'respond_to_allowlist': null}),
    ('non-string model', {...policy, 'model': 7}),
    ('non-object content', ['Agent']),
  ]) {
    test('an unsupported latest policy fails closed: $label', () async {
      final relay = _Relay(
        inventory: [
          [
            managed(agent.public, time: 2, content: content),
            managed(agent.public),
          ],
        ],
        profiles: [profile(agent, ownedBy: owner)],
      );
      final container = setup(relay);
      expect(await container.read(meAssistantsProvider.future), isEmpty);
      expect(
        await isOwnedMeAssistant(container.read(meSyncProvider), agent.public),
        isFalse,
      );
    });
  }
  test('accepts every supported policy shape', () async {
    final shapes = [
      policy,
      {...policy, 'respond_to': 'anyone', 'parallelism': 0},
      {
        ...policy,
        'respond_to': 'allowlist',
        'respond_to_allowlist': [other.public],
        'persona_id': 'scout',
        'model': null,
        'future_field': true,
      },
    ];
    final agents = [for (final _ in shapes) nostr.Keys.generate()];
    final relay = _Relay(
      inventory: [
        [
          for (var i = 0; i < shapes.length; i++)
            managed(agents[i].public, content: shapes[i]),
        ],
      ],
      profiles: [for (final key in agents) profile(key, ownedBy: owner)],
    );
    expect(
      (await setup(
        relay,
      ).read(meAssistantsProvider.future)).map((a) => a.pubkey),
      unorderedEquals(agents.map((key) => key.public)),
    );
  });
  test('reads beyond the first inventory page with a cursor', () async {
    final first = fullPage;
    final relay = _Relay(
      inventory: [
        first,
        [managed(agent.public, time: 101)],
      ],
      profiles: [profile(agent, ownedBy: owner)],
    );
    expect(
      (await setup(relay).read(meAssistantsProvider.future)).single.pubkey,
      agent.public,
    );
    expect(relay.inventoryFilters.length, 2);
    expect(relay.inventoryFilters.last['until'], 4901);
    expect(relay.inventoryFilters.last['before_id'], first.last.id);
    expect(relay.profileAuthors.map((a) => a!.length), [100, 1]);
    expect(relay.profileFilters.map((f) => f['limit']), [100, 1]);
  });
  test(
    'inventory paging is bounded even when the relay keeps paging',
    () async {
      final relay = _Relay(
        inventory: [
          // Each page ends at an older record, so the cursor keeps advancing.
          for (var page = 0; page < 11; page++)
            [...fullPage.take(99), managed(fakeAgent(), time: 100 - page)],
        ],
      );
      await expectLater(
        setup(relay).read(meAssistantsProvider.future),
        throwsStateError,
      );
      expect(relay.inventoryFilters.length, 10);
      expect(relay.profileFilters, isEmpty);
    },
  );
  test('inventory paging fails when the cursor does not advance', () async {
    final relay = _Relay(inventory: [fullPage, fullPage]);
    await expectLater(
      setup(relay).read(meAssistantsProvider.future),
      throwsStateError,
    );
    expect(relay.inventoryFilters.length, 2);
    expect(relay.profileFilters, isEmpty);
  });
  test('inventory cursor follows relay order at same-second ties', () async {
    // Relay order is created_at descending, then id ascending. An unordered
    // tied page must still advance from its largest id.
    final tied = [for (var i = 0; i < 100; i++) managed(fakeAgent(), time: 5)];
    final largest = tied
        .map((e) => e.id)
        .reduce((a, b) => a.compareTo(b) > 0 ? a : b);
    final relay = _Relay(
      inventory: [
        [...tied]..sort((a, b) => b.id.compareTo(a.id)),
        [managed(agent.public, time: 5)],
      ],
      profiles: [profile(agent, ownedBy: owner)],
    );
    expect(
      (await setup(relay).read(meAssistantsProvider.future)).single.pubkey,
      agent.public,
    );
    expect(relay.inventoryFilters.last['until'], 5);
    expect(relay.inventoryFilters.last['before_id'], largest);
  });
  test('same-second inventory records keep the lowest id', () async {
    final named = managed(agent.public, time: 5);
    final unnamed = managed(
      agent.public,
      time: 5,
      content: {...policy, 'name': ''},
    );
    final relay = _Relay(
      inventory: [
        [named, unnamed],
      ],
      profiles: [profile(agent, ownedBy: owner)],
    );
    final namedWins = named.id.compareTo(unnamed.id) < 0;
    expect(
      (await setup(
        relay,
      ).read(meAssistantsProvider.future)).map((a) => a.pubkey),
      namedWins ? [agent.public] : isEmpty,
    );
  });
  test('rejects an inventory page larger than requested', () async {
    final relay = _Relay(
      inventory: [
        [...fullPage, managed(fakeAgent())],
      ],
    );
    await expectLater(
      setup(relay).read(meAssistantsProvider.future),
      throwsStateError,
    );
    expect(relay.profileFilters, isEmpty);
  });
  for (final (label, record) in [
    ('another author', () => managed(agent.public, by: other)),
    ('another kind', () => managed(agent.public, kind: 30175)),
  ]) {
    test('rejects inventory records from $label', () async {
      final relay = _Relay(
        inventory: [
          [record()],
        ],
        profiles: [profile(agent, ownedBy: owner)],
      );
      await expectLater(
        setup(relay).read(meAssistantsProvider.future),
        throwsStateError,
      );
      expect(relay.profileFilters, isEmpty);
    });
  }
  for (final conditions in ['kind=1', 'created_at>1', 'created_at<1']) {
    test(
      'discovery and send revalidation reject inapplicable $conditions',
      () async {
        final relay = _Relay(
          inventory: [
            [managed(agent.public)],
          ],
          profiles: [profile(agent, ownedBy: owner, conditions: conditions)],
        );
        final container = setup(relay);
        expect(await container.read(meAssistantsProvider.future), isEmpty);
        expect(
          await isOwnedMeAssistant(
            container.read(meSyncProvider),
            agent.public,
          ),
          isFalse,
        );
      },
    );
  }
  test('creation revalidates only the chosen assistant', () async {
    final relay = _Relay(
      inventory: [
        [managed(other.public), managed(agent.public)],
      ],
      profiles: [
        profile(agent, ownedBy: owner),
        profile(other, ownedBy: owner),
      ],
    );
    final container = setup(relay);
    expect(
      await isOwnedMeAssistant(container.read(meSyncProvider), agent.public),
      isTrue,
    );
    expect(relay.inventoryFilters.single['authors'], [owner.public]);
    expect(relay.inventoryFilters.single['#d'], [agent.public]);
    expect(relay.profileAuthors, [
      [agent.public],
    ]);
  });
  test('creation rejects an agent removed from the inventory', () async {
    final relay = _Relay(
      inventory: [
        [managed(other.public)],
      ],
      profiles: [profile(agent, ownedBy: owner)],
    );
    expect(
      await isOwnedMeAssistant(setup(relay).read(meSyncProvider), agent.public),
      isFalse,
    );
    expect(relay.profileFilters, isEmpty);
  });
  test('ignores inventory records that fail verification', () async {
    final genuine = managed(other.public, time: 1);
    final forged = managed(agent.public, time: 2).toJson()
      ..['sig'] = genuine.sig;
    final superseding =
        managed(other.public, time: 3, content: {'name': ''}).toJson()
          ..['content'] = jsonEncode({'name': ''})
          ..['sig'] = genuine.sig;
    final relay = _Relay(
      inventory: [
        [
          NostrEvent.fromJson(superseding),
          NostrEvent.fromJson(forged),
          genuine,
        ],
      ],
      profiles: [
        profile(agent, ownedBy: owner),
        profile(other, ownedBy: owner),
      ],
    );
    final container = setup(relay);
    expect(
      (await container.read(meAssistantsProvider.future)).map((a) => a.pubkey),
      [other.public],
    );
    expect(
      await isOwnedMeAssistant(container.read(meSyncProvider), agent.public),
      isFalse,
    );
  });
  for (final forgedFirst in [false, true]) {
    test(
      'a repeated ID cannot inject an agent (forged first: $forgedFirst)',
      () async {
        final genuine = managed(agent.public);
        final forged = NostrEvent.fromJson(
          genuine.toJson()
            ..['tags'] = [
              ['d', other.public],
            ],
        );
        final relay = _Relay(
          inventory: [
            forgedFirst ? [forged, genuine] : [genuine, forged],
          ],
          profiles: [
            profile(agent, ownedBy: owner),
            profile(other, ownedBy: owner),
          ],
        );
        final container = setup(relay);
        expect(
          (await container.read(
            meAssistantsProvider.future,
          )).map((a) => a.pubkey),
          [agent.public],
        );
        final sync = container.read(meSyncProvider);
        expect(await isOwnedMeAssistant(sync, other.public), isFalse);
        expect(await isOwnedMeAssistant(sync, agent.public), isTrue);
      },
    );
  }
  test(
    'creation rejects revoked ownership and unrelated returned profiles',
    () async {
      final relay = _Relay(
        inventory: [
          [managed(agent.public), managed(other.public)],
        ],
        profiles: [
          profile(agent, ownedBy: owner),
          profile(agent, time: 2),
          profile(other, ownedBy: owner),
        ],
      );
      final container = setup(relay);
      expect(
        await isOwnedMeAssistant(container.read(meSyncProvider), agent.public),
        isFalse,
      );
    },
  );
}
