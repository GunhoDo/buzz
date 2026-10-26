-- Every kind:39002 roster writer checks the roster against canonical channel
-- membership in the application (validate_channel_roster_snapshot, from
-- #8316), and since #8611 no relay requires this trigger at startup. Retire
-- the trigger that repeats that check: it compares roster labels with the
-- stored role exactly, so it would refuse rosters that show the computed
-- `member`/`bot` label. Every relay and rollback target must run #8611 or
-- later before this migration runs; older relays refuse to start without the
-- trigger. Published migrations remain checksum-frozen.
--
-- DROP TRIGGER locks the partitioned parent and its partitions. Bound the
-- lock acquisition wait. This does not bound statement duration or the time
-- ingestion can be blocked while these locks are held.
SET LOCAL lock_timeout = '5s';

DROP TRIGGER trg_events_guard_channel_roster_snapshot ON events;
DROP FUNCTION guard_channel_roster_snapshot();
