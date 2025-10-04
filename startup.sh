#!/usr/bin/env bash
# Hardened Azure App Service startup for Laravel (Linux)
set -euo pipefail

log() { echo "[startup] $*"; }

# -----------------------------
# 0) Env flags (configure in App Settings per environment)
# -----------------------------
: "${RUN_MIGRATIONS:=0}"         # 1 to run php artisan migrate --force
: "${RUN_SEEDERS:=0}"            # 1 to run your custom seeders
: "${WARM_CACHES:=1}"            # 1 to (re)build route/config/view caches
: "${START_QUEUE_WORKER:=0}"     # 1 to start queue:work
: "${START_SCHEDULER:=0}"        # 1 to start schedule:work
: "${APP_ARTISAN:=/home/site/wwwroot/artisan}"

# -----------------------------
# 1) Writable paths + symlinks (works with Run-From-Package)
# -----------------------------
RFP="${WEBSITE_RUN_FROM_PACKAGE:-1}"

if [ "$RFP" = "1" ]; then
  log "Run-From-Package detected: wiring /home writable dirs and symlinks"
  mkdir -p /home/laravel/storage/framework/{views,cache/data,sessions} /home/laravel/bootstrap/cache
  # Link storage
  [ -L /home/site/wwwroot/storage ] || rm -rf /home/site/wwwroot/storage || true
  [ -e /home/site/wwwroot/storage ] || ln -s /home/laravel/storage /home/site/wwwroot/storage
  # Link bootstrap/cache
  mkdir -p /home/site/wwwroot/bootstrap || true
  [ -L /home/site/wwwroot/bootstrap/cache ] || rm -rf /home/site/wwwroot/bootstrap/cache || true
  [ -e /home/site/wwwroot/bootstrap/cache ] || ln -s /home/laravel/bootstrap/cache /home/site/wwwroot/bootstrap/cache

  # Force Blade compiled views path so it never guesses wrong
  export VIEW_COMPILED_PATH=/home/laravel/storage/framework/views
else
  log "Writable code mount detected: ensuring in-place dirs exist"
  mkdir -p /home/site/wwwroot/storage/framework/{views,cache/data,sessions} /home/site/wwwroot/bootstrap/cache
  export VIEW_COMPILED_PATH=/home/site/wwwroot/storage/framework/views
fi

# Best-effort permissions (php-fpm user is typically www-data)
chown -R www-data:www-data /home/laravel 2>/dev/null || true
chmod -R 775 /home/laravel 2>/dev/null || true
chmod -R 775 /home/site/wwwroot/{storage,bootstrap/cache} 2>/dev/null || true

# -----------------------------
# 2) Nginx: validate and reload (no service restarts)
# -----------------------------
if nginx -t >/dev/null 2>&1; then
  log "Reloading nginx"
  nginx -s reload || true
else
  log "nginx config test failed (skipping reload)"; true
fi

# -----------------------------
# 3) Remove Azure default page (if present)
# -----------------------------
if [ -f /home/site/wwwroot/hostingstart.html ]; then
  log "Removing hostingstart.html"
  rm -f /home/site/wwwroot/hostingstart.html || true
fi

# -----------------------------
# 4) Optional maintenance + app warmup (controlled via flags)
#    Keep boot fast; only do what you explicitly enable.
# -----------------------------
php_bin="$(command -v php || echo php)"

if [ "$WARM_CACHES" = "1" ]; then
  log "Clearing runtime caches"
  $php_bin "$APP_ARTISAN" cache:clear || true
  $php_bin "$APP_ARTISAN" config:clear || true
  $php_bin "$APP_ARTISAN" route:clear || true
  $php_bin "$APP_ARTISAN" view:clear || true

  log "Rebuilding caches"
  $php_bin "$APP_ARTISAN" route:cache || true
  $php_bin "$APP_ARTISAN" config:cache || true
  $php_bin "$APP_ARTISAN" view:cache || true
else
  log "Skipping cache warmup (WARM_CACHES=0)"
fi

if [ "$RUN_MIGRATIONS" = "1" ]; then
  log "Running database migrations"
  $php_bin "$APP_ARTISAN" migrate --force
else
  log "Skipping migrations (RUN_MIGRATIONS=0)"
fi

if [ "$RUN_SEEDERS" = "1" ]; then
  log "Running custom app tasks/seeders"
  # Example custom commands from your original script. Toggle as needed.
  $php_bin "$APP_ARTISAN" app:change-paynamic-environment || true
  $php_bin "$APP_ARTISAN" app:gps-seeder || true
  $php_bin "$APP_ARTISAN" db:seed --class=DragonCredentials || true
else
  log "Skipping seeders/custom tasks (RUN_SEEDERS=0)"
fi

# -----------------------------
# 5) Optional workers (web container usually shouldn't, but supported via flags)
# -----------------------------
if [ "$START_QUEUE_WORKER" = "1" ]; then
  log "Starting queue worker"
  nohup $php_bin "$APP_ARTISAN" queue:work --sleep=3 --tries=3 >/home/LogFiles/queue.work.log 2>&1 &
else
  log "Queue worker disabled (START_QUEUE_WORKER=0)"
fi

if [ "$START_SCHEDULER" = "1" ]; then
  log "Starting scheduler"
  nohup $php_bin "$APP_ARTISAN" schedule:work >/home/LogFiles/schedule.work.log 2>&1 &
else
  log "Scheduler disabled (START_SCHEDULER=0)"
fi

log "Startup complete"
