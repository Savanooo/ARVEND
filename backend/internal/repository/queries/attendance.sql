-- name: CreateAttendance :one
INSERT INTO attendance_logs (employee_id, date, check_in, check_out, work_hours, status, note)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: GetAttendanceByID :one
SELECT * FROM attendance_logs WHERE id = $1;

-- name: ListAttendanceByMonth :many
SELECT a.*, e.full_name AS employee_name
FROM attendance_logs a
JOIN employees e ON e.id = a.employee_id
WHERE date_trunc('month', a.date) = date_trunc('month', $1::date)
ORDER BY a.date DESC, e.full_name ASC;

-- name: UpdateAttendance :one
UPDATE attendance_logs
SET check_in = $2, check_out = $3, work_hours = $4, status = $5, note = $6
WHERE id = $1
RETURNING *;

-- name: DeleteAttendance :exec
DELETE FROM attendance_logs WHERE id = $1;
