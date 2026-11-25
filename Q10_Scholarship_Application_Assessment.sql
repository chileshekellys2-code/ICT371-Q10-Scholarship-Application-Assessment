-- ICT371 Advanced Database
-- QUESTION 10: Scholarship Application Assessment
-- Extracted as an individual repository from the supplied Q2-Q10 script.
--
-- PostgreSQL prerequisite:
-- This question schedules a job using pg_cron. The server must have pg_cron
-- installed/configured (including shared_preload_libraries and restart).
-- If pg_cron is unavailable, execute the database objects and seed statements
-- separately, and skip/comment the cron.schedule statement at the end.
--
-- This script creates schema q10; it does not drop existing data.
-- ============================================================

-- Q10  SCHOLARSHIP APPLICATION ASSESSMENT
-- =====================================================================
CREATE SCHEMA q10;  SET search_path TO q10;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT chk_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

-- (b) age 18-25 inclusive AND income <= 3000 AND mark >= 70
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql;

-- (c)
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_age    INTEGER;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
    v_status VARCHAR(10);
    v_ok     BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications WHERE application_id = p_application_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed (%)', p_application_id, v_status;
    END IF;

    v_ok := fn_scholarship_eligible(v_age, v_income, v_mark);
    UPDATE applications
    SET status = CASE WHEN v_ok THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d)
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_applications_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- (a) seed: six PENDING applications, 3 students, boundaries included
INSERT INTO students (student_number, full_name) VALUES
    ('SC001', 'Mercy Hamoonga'), ('SC002', 'Kelvin Mutale'), ('SC003', 'Patricia Nsama');
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 20, 2500.00, 85.00, CURRENT_DATE - 10),   -- clearly qualifies
    (1, 17, 2000.00, 80.00, CURRENT_DATE - 9),    -- age too low
    (2, 18, 3000.00, 70.00, CURRENT_DATE - 8),    -- all three at the boundary: qualifies
    (2, 25, 3000.01, 90.00, CURRENT_DATE - 7),    -- income just over: rejected
    (3, 26, 1000.00, 75.00, CURRENT_DATE - 6),    -- age just over: rejected
    (3, 22, 2800.00, 69.99, CURRENT_DATE - 5);    -- mark just under: rejected

-- (e) no household income column exposed
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) equality column (status) first, range column (submitted_on) second
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) only PENDING rows are looped; a rerun finds none, so nothing is reassessed or re-audited
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications
             WHERE status = 'PENDING' ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

SELECT cron.schedule('q10_assess', '0 8 * * 1',    -- Mondays 08:00
    $$SET search_path TO q10; CALL pr_assess_pending()$$);

-- Demo:
CALL pr_assess_pending();
CALL pr_assess_pending();                 -- rerun: no changes
SELECT * FROM v_approved_applicants;      -- applications 1 and 3
SELECT * FROM decision_audit;             -- exactly 6 rows
