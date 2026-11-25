-- ICT371 Advanced Databases | Question 8
-- Transport Fleet Maintenance
-- Run once in a database where you can create a fresh schema.
-- This script creates and uses ict371_q08.
-- The scheduler registration at the end is optional to execute.

BEGIN;

-- (a) Database and seed data
-- The vehicle table ensures service mileage is within the current odometer reading.
-- Load the six trips through the procedure after the trigger is installed.
CREATE SCHEMA ict371_q08;
SET search_path = ict371_q08, pg_catalog;
SET TIME ZONE 'Africa/Lusaka';

CREATE TABLE vehicles (
    vehicle_id integer PRIMARY KEY,
    registration text NOT NULL UNIQUE,
    current_odometer bigint NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer bigint NOT NULL
        CHECK (last_service_odometer BETWEEN 0 AND current_odometer)
);

CREATE TABLE trips (
    trip_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id integer NOT NULL REFERENCES vehicles,
    trip_on date NOT NULL CHECK (isfinite(trip_on)),
    start_odometer bigint NOT NULL CHECK (start_odometer >= 0),
    end_odometer bigint NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id integer PRIMARY KEY REFERENCES vehicles,
    km_since_service bigint NOT NULL CHECK (km_since_service >= 5000),
    flagged_on date NOT NULL
);

INSERT INTO vehicles VALUES
    (1, 'ABC 1234', 10000, 6000),
    (2, 'ABD 2345', 20000, 18000),
    (3, 'ABE 3456', 30000, 25000);

-- (b) Function
-- The service threshold is inclusive. A vehicle exactly 5,000 km past service is due.
CREATE FUNCTION fn_service_due(p_vehicle_id integer)
RETURNS boolean LANGUAGE plpgsql SET search_path = ict371_q08, pg_catalog AS $$
DECLARE
    v_due boolean;
BEGIN
    SELECT current_odometer - last_service_odometer >= 5000 INTO v_due
    FROM vehicles WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', p_vehicle_id;
    END IF;
    RETURN v_due;
END;
$$;

-- (c) Procedure
-- The procedure validates the trip and inserts it. The trigger handles the odometer
-- change.
CREATE PROCEDURE pr_record_trip(
    p_vehicle_id integer, p_trip_on date, p_start bigint, p_end bigint
)
LANGUAGE plpgsql SET search_path = ict371_q08, pg_catalog AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR NOT isfinite(p_trip_on) THEN
        RAISE EXCEPTION 'A valid trip date is required';
    END IF;
    IF p_start IS NULL OR p_end IS NULL OR p_start < 0 OR p_end <= p_start THEN
        RAISE EXCEPTION 'Trip end must exceed its non-negative start';
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Trigger
-- The trigger locks the vehicle, compares the supplied start with the current odometer
-- and advances it once. The trip insert and vehicle update are atomic as part of the
-- same statement.
CREATE FUNCTION fn_apply_trip_odometer()
RETURNS trigger LANGUAGE plpgsql SET search_path = ict371_q08, pg_catalog AS $$
DECLARE
    v_current bigint;
BEGIN
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Trip end must exceed its non-negative start';
    END IF;

    SELECT current_odometer INTO v_current FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at odometer %', v_current;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_apply_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION fn_apply_trip_odometer();

-- (a) Deferred seed data, loaded after the routines and trigger
CALL pr_record_trip(1, DATE '2026-11-23', 10000, 10500);
CALL pr_record_trip(1, DATE '2026-11-24', 10500, 11000);
CALL pr_record_trip(2, DATE '2026-11-23', 20000, 20400);
CALL pr_record_trip(2, DATE '2026-11-24', 20400, 20500);
CALL pr_record_trip(3, DATE '2026-11-23', 30000, 30100);
CALL pr_record_trip(3, DATE '2026-11-24', 30100, 30300);

-- (e) View
-- The seeded view shows ABC 1234 at 5,000 km and ABE 3456 at 5,300 km since service.
CREATE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;

-- (f) Index and execution plan
-- The first index key isolates one vehicle. The second orders its trips by date for
-- range searches.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

EXPLAIN (COSTS OFF)
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN DATE '2026-11-23' AND DATE '2026-11-24';

-- Plan observed on the seed dataset:
-- Seq Scan on trips
--   Filter: ((trip_on >= '2026-11-23'::date) AND (trip_on <= '2026-11-24'::date) AND (vehicle_id = 1))
-- Index plan observed when sequential scans were discouraged:
-- Index Scan using idx_trips_vehicle_date on trips
--   Index Cond: ((vehicle_id = 1) AND (trip_on >= '2026-11-23'::date) AND (trip_on <= '2026-11-24'::date))

-- (g) Scheduled job
-- The Monday 06:00 job refreshes distance for vehicles still due and removes cleared
-- alerts. flagged_on preserves the first flag date of an alert while it remains open.
CREATE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql SET search_path = ict371_q08, pg_catalog AS $$
BEGIN
    WITH distance AS MATERIALIZED (
        SELECT vehicle_id, current_odometer - last_service_odometer AS km
        FROM vehicles
    ), cleared AS (
        DELETE FROM service_alerts AS a
        USING distance AS d
        WHERE a.vehicle_id = d.vehicle_id AND d.km < 5000
    )
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, km, CURRENT_DATE FROM distance WHERE km >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;
END;
$$;

COMMIT;

-- Manual verification. The rollback preserves the original seed state.
BEGIN;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;
UPDATE vehicles SET last_service_odometer = current_odometer
WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;
ROLLBACK;

-- The first refresh flags vehicles 1 and 3. After vehicle 1 is serviced, the second
-- refresh leaves only vehicle 3.

-- (g) Register the schedule when pg_cron is available.
-- Configure the server to preload pg_cron, set cron.database_name to this database and
-- set cron.timezone to Africa/Lusaka. Restart PostgreSQL, then select and run the
-- following block with its surrounding comment markers removed. Use an account allowed
-- to schedule and run the job.
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'ict371-q08',
    '0 6 * * 1',
    $job$
    SET TIME ZONE 'Africa/Lusaka';
    CALL ict371_q08.pr_refresh_service_alerts();
    $job$
);
*/
