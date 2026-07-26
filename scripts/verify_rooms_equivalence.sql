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
