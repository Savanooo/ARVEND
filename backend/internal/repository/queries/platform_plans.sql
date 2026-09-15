-- name: ListActivePlans :many
SELECT * FROM platform_plans WHERE is_active = true ORDER BY sort_order;

-- name: ListAllPlans :many
SELECT * FROM platform_plans ORDER BY sort_order;

-- name: GetPlanByCode :one
SELECT * FROM platform_plans WHERE code = $1;
