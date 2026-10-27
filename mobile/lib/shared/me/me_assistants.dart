import 'dart:convert';
import 'dart:math';

import 'package:nostr/nostr.dart' as nostr;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../crypto/nip_oa.dart';
import '../mentions/agent_identity_provider.dart';
import '../relay/relay.dart';
import 'me_sync.dart';

/// Owned assistants: the owner's managed-agent records (kind 30177), confirmed
/// by verified profiles, including agents without kind 10100.
/// Agents inherit their owner's community access and need not be listed in the
/// community's human membership snapshot.
final meAssistantsProvider = FutureProvider<List<AgentDirectoryEntry>>((
  ref,
) async {
  final sync = ref.watch(meSyncProvider);
  if (sync.connectionState != null) {
    ref.watch(relaySessionProvider.select((state) => state.status));
  }
  final session = ref.watch(relaySessionProvider.notifier);
  return _loadAssistants(sync, session);
}, retry: (_, _) => null);

/// Freshness-controlled ownership check for one personal-chat recipient.
final meAssistantOwnershipProvider = FutureProvider.family<bool, String>((
  ref,
  pubkey,
) {
  final sync = ref.watch(meSyncProvider);
  if (sync.connectionState != null) {
    ref.watch(relaySessionProvider.select((state) => state.status));
  }
  return isOwnedMeAssistant(sync, pubkey);
});

/// Revalidates only the chosen assistant before creating a chat.
Future<bool> isOwnedMeAssistant(MeSync sync, String pubkey) async =>
    (await _loadAssistants(
      sync,
      sync.session,
      pubkey: pubkey,
    )).any((agent) => agent.pubkey == pubkey);

/// Owner-authored NIP-AP managed-agent identity records (kind 30177).
const _kindManagedAgent = 30177;
const _pageSize = 100;
const _maxInventoryPages = 10;
final _agentPubkey = RegExp(r'^[0-9a-f]{64}$');

Future<List<AgentDirectoryEntry>> _loadAssistants(
  MeSync sync,
  RelaySessionNotifier session, {
  String? pubkey,
}) async {
  final candidates = await _managedAgentPubkeys(sync, session, agent: pubkey);
  final profiles = <String, NostrEvent>{};
  for (var offset = 0; offset < candidates.length; offset += _pageSize) {
    final batch = candidates.sublist(
      offset,
      min(offset + _pageSize, candidates.length),
    );
    sync.check();
    final events = await session.queryRelay([
      NostrFilter(kinds: const [0], authors: batch, limit: batch.length),
    ]);
    sync.check();
    for (final event in events) {
      if (event.kind != 0 || !batch.contains(event.pubkey)) continue;
      try {
        nostr.Event.fromJson(jsonEncode(event.toJson()));
      } catch (_) {
        continue;
      }
      final previous = profiles[event.pubkey];
      if (previous == null || _newer(event, previous)) {
        profiles[event.pubkey] = event;
      }
    }
  }
  final agents = <AgentDirectoryEntry>[];
  for (final event in profiles.values) {
    try {
      if (verifiedProfileOaOwnerPubkey(event) == sync.pubkey) {
        agents.add(AgentDirectoryEntry.fromEvent(event));
      }
    } catch (_) {
      // A malformed profile must not hide unrelated verified agents.
      continue;
    }
  }
  return agents;
}

/// Candidate agents from the owner's own managed-agent records, as desktop
/// discovers them. The records are discovery hints only: each candidate's
/// profile must still carry a valid NIP-OA attestation by the owner. With
/// [agent], only that agent's record is read, so an agent removed from the
/// inventory also fails revalidation before chat creation and send.
Future<List<String>> _managedAgentPubkeys(
  MeSync sync,
  RelaySessionNotifier session, {
  String? agent,
}) async {
  final heads = <String, NostrEvent>{};
  final verified = <String>{};
  NostrEvent? cursor;
  for (var page = 0; ; page++) {
    if (page == _maxInventoryPages) {
      throw StateError('Could not finish loading assistants. Try again.');
    }
    sync.check();
    final events = await session.queryRelay([
      NostrFilter(
        kinds: const [_kindManagedAgent],
        authors: [sync.pubkey],
        limit: _pageSize,
        until: cursor?.createdAt,
        tags: {
          if (agent != null) '#d': [agent],
        },
        extensions: {'before_id': ?cursor?.id},
      ),
    ]);
    sync.check();
    if (events.length > _pageSize) {
      throw StateError('Agent inventory exceeded the requested page size.');
    }
    // Reject mismatched pages rather than presenting another account's agents.
    if (events.any(
      (e) => e.kind != _kindManagedAgent || e.pubkey != sync.pubkey,
    )) {
      throw StateError('Agent inventory response is outside its owner.');
    }
    for (final event in events) {
      final d = event.getTagValue('d');
      if (d == null || (agent != null && d != agent)) continue;
      // Like desktop, skip an envelope that fails verification so a forged
      // record can neither add an agent nor supersede a genuine one. An ID
      // already verified needs no second check when pages overlap.
      if (!verified.contains(event.id)) {
        try {
          nostr.Event.fromJson(jsonEncode(event.toJson()));
        } catch (_) {
          continue;
        }
        verified.add(event.id);
      }
      final previous = heads[d];
      if (previous == null || _newer(event, previous)) heads[d] = event;
    }
    if (events.length < _pageSize) break;
    // Relay order is newest first, then ID ascending at ties.
    final last = events.reduce((a, b) => _newer(a, b) ? b : a);
    if (cursor != null && !_newer(cursor, last)) {
      throw StateError('Could not finish loading assistants. Try again.');
    }
    cursor = last;
  }
  return [
    for (final MapEntry(key: d, value: event) in heads.entries)
      if (_agentPubkey.hasMatch(d) && _hasName(event)) d,
  ];
}

bool _newer(NostrEvent a, NostrEvent b) =>
    a.createdAt > b.createdAt ||
    (a.createdAt == b.createdAt && a.id.compareTo(b.id) < 0);

/// Desktop omits managed-agent records without a name; match its inventory.
bool _hasName(NostrEvent event) {
  try {
    final body = jsonDecode(event.content);
    return body is Map &&
        body['name'] is String &&
        (body['name'] as String).trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}
