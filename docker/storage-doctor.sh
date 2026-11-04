#!/usr/bin/env bash
# storage-doctor — prove that media written by the app is the media the web
# server serves. Run INSIDE the app container:
#
#   docker compose -f compose.prod.yaml -f compose.fork.yaml \
#       exec app bash docker/storage-doctor.sh
#
# Why this exists: every media read/write goes through the DEFAULT disk
# (HasMedia trait stores with Storage::put, Media::url() builds the public
# URL from the same disk). If the effective disk is the private "local"
# disk, or if storage/ is not one shared volume across php-fpm, Horizon
# and nginx, uploads succeed in the database while their URLs return 404 —
# and publishers then fail with "Failed to download video". This script
# writes a probe through the app's own storage layer and reads it back
# over HTTP from the local nginx, so a split cannot hide.
#
# Exit code 0 = all hard checks passed. The APP_URL check is informational
# only (it traverses DNS / reverse proxy / Cloudflare from inside).

set -u
cd /var/www/html || exit 2

PROBE_PATH="medias/.storage-doctor-probe.txt"
TOKEN="storage-doctor-$(date +%s)-$$"
FAILURES=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILURES=$((FAILURES + 1)); }
info() { echo "INFO  $1"; }

tinker() {
    php artisan tinker --execute "$1" 2>/dev/null | tail -n 1
}

DEFAULT_DISK=$(tinker 'echo config("filesystems.default");')
PUBLIC_ROOT=$(tinker 'echo \Illuminate\Support\Facades\Storage::disk("public")->path("");')
APP_URL=$(tinker 'echo rtrim((string) config("app.url"), "/");')
info "default disk (filesystems.default): ${DEFAULT_DISK:-unknown}"
info "public disk root: ${PUBLIC_ROOT:-unknown}"
info "APP_URL: ${APP_URL:-unknown}"

if [ "$DEFAULT_DISK" = "public" ]; then
    pass "default disk is 'public'"
else
    fail "default disk is '${DEFAULT_DISK:-unknown}', expected 'public' — uploads land outside the web-served tree"
fi

# 1. Write a probe through the app's storage layer (the upload path).
WRITE_RESULT=$(tinker "echo \Illuminate\Support\Facades\Storage::put(\"${PROBE_PATH}\", \"${TOKEN}\") ? \"written\" : \"write-failed\";")
if [ "$WRITE_RESULT" = "written" ]; then
    pass "probe written through Storage::put (${PROBE_PATH})"
else
    fail "Storage::put could not write the probe"
fi

# 2. The probe must physically sit under the public disk root.
if [ -f "${PUBLIC_ROOT}${PROBE_PATH}" ] && grep -q "$TOKEN" "${PUBLIC_ROOT}${PROBE_PATH}"; then
    pass "probe file exists under the public disk root"
else
    fail "probe file NOT under the public disk root — the write path and the serve path disagree (split storage)"
fi

# 3. The public/storage symlink must resolve into the same tree.
if [ -e "public/storage/${PROBE_PATH}" ]; then
    pass "public/storage symlink resolves to the probe"
else
    fail "public/storage/${PROBE_PATH} not reachable — storage symlink missing or pointing at another tree"
fi

# 4. nginx must serve it (this is the URL shape publishers download).
HTTP_CODE=$(curl -s -o /tmp/storage-doctor-body -w '%{http_code}' "http://127.0.0.1/storage/${PROBE_PATH}" || echo "000")
if [ "$HTTP_CODE" = "200" ] && grep -q "$TOKEN" /tmp/storage-doctor-body; then
    pass "nginx serves the probe at /storage/${PROBE_PATH} (HTTP 200, content matches)"
else
    fail "nginx returned HTTP ${HTTP_CODE} for /storage/${PROBE_PATH}"
fi

# 5. Reverse direction: a file placed in the public root must be visible
#    to the app (catches a split where the web side owns the real tree).
REVERSE_PATH="medias/.storage-doctor-reverse.txt"
echo "$TOKEN" > "${PUBLIC_ROOT}${REVERSE_PATH}"
REVERSE_SEEN=$(tinker "echo \Illuminate\Support\Facades\Storage::disk(\"public\")->exists(\"${REVERSE_PATH}\") ? \"seen\" : \"missing\";")
if [ "$REVERSE_SEEN" = "seen" ]; then
    pass "app sees files placed in the public root (no reverse split)"
else
    fail "app cannot see ${REVERSE_PATH} in the public root"
fi
rm -f "${PUBLIC_ROOT}${REVERSE_PATH}"

# 6. Informational: the full public URL (APP_URL/storage/...) from inside.
if [ -n "$APP_URL" ]; then
    EXT_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${APP_URL}/storage/${PROBE_PATH}" || echo "000")
    info "GET ${APP_URL}/storage/${PROBE_PATH} -> HTTP ${EXT_CODE} (informational; 200 expected once DNS/proxy point here)"
fi

# Cleanup.
tinker "\Illuminate\Support\Facades\Storage::delete(\"${PROBE_PATH}\");" > /dev/null
rm -f /tmp/storage-doctor-body

echo "-----"
if [ "$FAILURES" -eq 0 ]; then
    echo "STORAGE DOCTOR: ALL CHECKS PASSED"
    exit 0
fi
echo "STORAGE DOCTOR: ${FAILURES} CHECK(S) FAILED — do not publish through this install until fixed"
exit 1
