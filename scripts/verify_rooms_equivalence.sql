-- Reconciliation: prove eam_rooms == the old recursive room-climb, per device.
--
-- Run against the QA (or any) avtools Postgres cache AFTER `avtools sync-rooms`
-- has populated eam_rooms:
--     psql "$DATABASE_URL" -f scripts/verify_rooms_equivalence.sql
--
-- The `climb`/`pos_to_room` CTEs below are the CANONICAL room-climb copied from
-- the av_rooms dashboard (anchor = eam_devices.position; climb eam_positions.parentasset;
-- room = eqclass 'AVR' AND category IN ('AV-VCR','AV-VIS','AV-MRO'); topmost wins;
-- sentinels __NO_ROOM_NO_POSITION__ / __NO_ROOM_NO_PARENT__). `old_map` is the room
-- the recursive query assigns each device; it is compared to eam_rooms.room_no.
--
-- Result 1 (summary): mismatches = 0  =>  the eam_rooms join is 1:1 with the climb.
-- Result 2 (detail):  the actual diverging devices, if any.

WITH RECURSIVE
climb AS (
  SELECT dp.position                       AS start_pos,
         p.equipmentno                     AS cur_pos,
         p.parentasset                     AS parent_pos,
         0                                 AS depth,
         ARRAY[p.equipmentno]::varchar[]   AS visited
  FROM (SELECT DISTINCT position FROM eam_devices WHERE position IS NOT NULL) dp
  JOIN eam_positions p ON p.equipmentno = dp.position
  UNION ALL
  SELECT c.start_pos, p.equipmentno, p.parentasset, c.depth + 1,
         (c.visited || p.equipmentno)::varchar[]
  FROM climb c
  JOIN eam_positions p ON p.equipmentno = c.parent_pos
  WHERE c.parent_pos IS NOT NULL AND c.depth < 100 AND NOT p.equipmentno = ANY (c.visited)
),
pos_to_room AS (
  SELECT DISTINCT ON (c.start_pos) c.start_pos, c.cur_pos AS room_no
  FROM climb c
  JOIN eam_positions rp ON rp.equipmentno = c.cur_pos
  WHERE rp.eqclass = 'AVR' AND rp.category IN ('AV-VCR','AV-VIS','AV-MRO')
  ORDER BY c.start_pos, c.depth DESC, c.cur_pos
),
old_map AS (
  SELECT d.equipmentno,
         CASE
           WHEN d.position IS NULL OR pj.equipmentno IS NULL THEN '__NO_ROOM_NO_POSITION__'
           WHEN ptr.room_no IS NOT NULL                      THEN ptr.room_no
           ELSE '__NO_ROOM_NO_PARENT__'
         END AS old_room
  FROM eam_devices d
  LEFT JOIN eam_positions pj  ON pj.equipmentno = d.position
  LEFT JOIN pos_to_room   ptr ON ptr.start_pos  = d.position
)
SELECT count(*)                                                              AS total_devices,
       count(*) FILTER (WHERE o.old_room IS DISTINCT FROM r.room_no)          AS mismatches,
       count(*) FILTER (WHERE o.old_room IS NOT DISTINCT FROM r.room_no)      AS matches
FROM old_map o
JOIN eam_rooms r ON r.equipmentno = o.equipmentno;

-- Detail: the diverging devices (empty when 1:1). Uncomment to inspect.
-- WITH RECURSIVE climb AS ( ... same as above ... ), pos_to_room AS ( ... ), old_map AS ( ... )
-- SELECT o.equipmentno, o.old_room AS climb_room, r.room_no AS eam_rooms_room
-- FROM old_map o JOIN eam_rooms r ON r.equipmentno = o.equipmentno
-- WHERE o.old_room IS DISTINCT FROM r.room_no
-- ORDER BY o.equipmentno;

-- ============================================================================
-- Reconciliation 2: prove the recursive DOWN-walk == eam_rooms, per room.
--
-- The six av_rooms panels that still walked DOWN (room -> its devices) were
-- de-recursed to `GROUP BY eam_rooms` (device count per room) / joins on
-- eam_rooms (device set per room). That down-walk is the INVERSE of the
-- eam_rooms up-mapping, so this must reconcile exactly.
--
-- Below: the CANONICAL recursive climb + down-walk copied verbatim from the
-- Coverage panel (only the entry point `rooms` is de-status-filtered to cover
-- EVERY room). `old_membership` is the old (room_no, device) set; it is compared
-- against `eam_rooms` grouped by room_no. Run AFTER `avtools sync-rooms`:
--     psql "$DATABASE_URL" -f scripts/verify_rooms_equivalence.sql
-- ============================================================================

WITH RECURSIVE
device_positions AS (
  SELECT DISTINCT d.position AS position
  FROM eam_devices d
  WHERE d.position IS NOT NULL
),
pos_joinable AS (
  SELECT dp.position
  FROM device_positions dp
  JOIN eam_positions p ON p.equipmentno = dp.position
),
climb_up AS (
  SELECT
    pj.position                                      AS start_pos,
    p.equipmentno                       AS cur_pos,
    p.parentasset                       AS parent_pos,
    0                                                AS depth,
    ARRAY[p.equipmentno]::varchar[] AS visited
  FROM pos_joinable pj
  JOIN eam_positions p ON p.equipmentno = pj.position

  UNION ALL

  SELECT
    c.start_pos,
    p.equipmentno,
    p.parentasset,
    c.depth + 1,
    (c.visited || p.equipmentno)::varchar[] AS visited
  FROM climb_up c
  JOIN eam_positions p ON p.equipmentno = c.parent_pos
  WHERE c.parent_pos IS NOT NULL
    AND c.depth < 100
    AND p.equipmentno <> ALL (c.visited)
),
pos_to_room AS (
  SELECT DISTINCT ON (c.start_pos)
    c.start_pos,
    c.cur_pos AS room_no
  FROM climb_up c
  JOIN eam_positions rp ON rp.equipmentno = c.cur_pos
  WHERE rp.eqclass = 'AVR'
    AND rp.category IN ('AV-VCR','AV-VIS','AV-MRO')
  ORDER BY c.start_pos, c.depth DESC, c.cur_pos
),
root_per_pos AS (
  SELECT DISTINCT ON (c.start_pos)
    c.start_pos,
    c.cur_pos    AS root_pos,
    c.parent_pos AS root_parent
  FROM climb_up c
  ORDER BY c.start_pos, c.depth DESC, c.cur_pos
),
no_parent_positions AS (
  SELECT r.start_pos
  FROM root_per_pos r
  JOIN eam_positions rp ON rp.equipmentno = r.root_pos
  LEFT JOIN pos_to_room pr ON pr.start_pos = r.start_pos
  WHERE pr.start_pos IS NULL
    AND (
      (r.root_parent IS NULL AND NOT (rp.eqclass = 'AVR' AND rp.category IN ('AV-VCR','AV-VIS','AV-MRO')))
      OR (r.root_parent IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM eam_positions p2
            WHERE p2.equipmentno = r.root_parent
          ))
    )
),
no_position_devices AS (
  SELECT d.equipmentno
  FROM eam_devices d
  LEFT JOIN eam_positions p ON p.equipmentno = d.position
  WHERE d.position IS NULL
     OR p.equipmentno IS NULL
),
rooms AS (
  -- reconciliation entry point: EVERY real (AVR) room, no status filter
  SELECT DISTINCT pr.room_no AS ConferenceRoomNo
  FROM pos_to_room pr
),
down AS (
  -- traverse ONLY real rooms
  SELECT
    r.ConferenceRoomNo,
    p.equipmentno                       AS equipmentno,
    1                                                AS depth,
    ARRAY[p.equipmentno]::varchar[] AS visited
  FROM rooms r
  JOIN eam_positions p ON p.parentasset = r.ConferenceRoomNo
  WHERE r.ConferenceRoomNo NOT LIKE '__NO_ROOM_%'

  UNION ALL

  SELECT
    d.ConferenceRoomNo,
    p.equipmentno,
    d.depth + 1,
    (d.visited || p.equipmentno)::varchar[] AS visited
  FROM down d
  JOIN eam_positions p ON p.parentasset = d.equipmentno
  WHERE d.depth < 100
    AND p.equipmentno <> ALL (d.visited)
),
leafs AS (
  SELECT d.ConferenceRoomNo, d.equipmentno AS leaf_position
  FROM down d
  LEFT JOIN eam_positions ch ON ch.parentasset = d.equipmentno
  WHERE ch.equipmentno IS NULL
),
old_membership AS (
  -- OLD recursive down-walk: room_no -> device equipmentno (real rooms + both pseudo-rooms)
  SELECT l.ConferenceRoomNo AS room_no, dev.equipmentno
  FROM leafs l
  JOIN eam_devices dev ON dev.position = l.leaf_position
  UNION
  SELECT '__NO_ROOM_NO_PARENT__' AS room_no, dev.equipmentno
  FROM no_parent_positions np
  JOIN eam_devices dev ON dev.position = np.start_pos
  UNION
  SELECT '__NO_ROOM_NO_POSITION__' AS room_no, d.equipmentno
  FROM no_position_devices d
),
old_agg AS (
  SELECT room_no,
         count(*)                                    AS device_count,
         array_agg(equipmentno ORDER BY equipmentno) AS device_set
  FROM old_membership
  GROUP BY room_no
),
new_agg AS (
  -- NEW side: the eam_rooms GROUP BY the panels now use (inverse of the down-walk)
  SELECT room_no,
         count(*)                                    AS device_count,
         array_agg(equipmentno ORDER BY equipmentno) AS device_set
  FROM eam_rooms
  GROUP BY room_no
)
-- Result 3 (per-room detail): 0 rows  =>  every room's device COUNT and device SET
-- match between the old recursive down-walk and eam_rooms GROUP BY  =>  provably 1:1.
SELECT
  coalesce(o.room_no, n.room_no)                                 AS room_no,
  o.device_count                                                 AS down_walk_count,
  n.device_count                                                 AS eam_rooms_count,
  coalesce(cardinality(ARRAY(SELECT unnest(o.device_set)
                             EXCEPT SELECT unnest(n.device_set))), 0) AS only_in_down_walk,
  coalesce(cardinality(ARRAY(SELECT unnest(n.device_set)
                             EXCEPT SELECT unnest(o.device_set))), 0) AS only_in_eam_rooms
FROM old_agg o
FULL OUTER JOIN new_agg n USING (room_no)
WHERE o.device_count IS DISTINCT FROM n.device_count
   OR o.device_set   IS DISTINCT FROM n.device_set
ORDER BY room_no;

-- Result 3b (summary): wrap Result 3 in `SELECT count(*) AS rooms_with_differences
-- FROM ( <the SELECT above> ) d;` for a single-number pass/fail (0 = 1:1).
