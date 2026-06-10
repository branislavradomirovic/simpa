#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ROOT="$REPO_ROOT/customer_bundle"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${1:-$BUNDLE_ROOT/transfer/sipmt_customer_bundle_$TIMESTAMP}"
COMPOSE_ARGS=(-f docker-compose.yml)

BUILD_IMAGES="${BUILD_IMAGES:-true}"
EXPORT_IMAGES="${EXPORT_IMAGES:-true}"
INCLUDE_BACKUP="${INCLUDE_BACKUP:-false}"
ARCHIVE_BUNDLE="${ARCHIVE_BUNDLE:-true}"
ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-tar.gz}"
ARCHIVE_PATHS=()

create_archive() {
  local format="$1"
  local archive_base
  archive_base="$(dirname "$OUTPUT_DIR")/$(basename "$OUTPUT_DIR")"

  case "$format" in
    tar.gz)
      local archive_path="$archive_base.tar.gz"
      echo "[INFO] Creating tar.gz archive: $archive_path"
      tar -czf "$archive_path" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"
      ARCHIVE_PATHS+=("$archive_path")
      echo "[OK] Archive created: $archive_path"
      ;;
    zip)
      local archive_path="$archive_base.zip"
      echo "[INFO] Creating zip archive: $archive_path"
      (
        cd "$(dirname "$OUTPUT_DIR")"
        ditto -c -k --sequesterRsrc --keepParent "$(basename "$OUTPUT_DIR")" "$archive_path"
      )
      ARCHIVE_PATHS+=("$archive_path")
      echo "[OK] Archive created: $archive_path"
      ;;
    *)
      echo "[FAIL] Unsupported archive format: $format" >&2
      exit 1
      ;;
  esac
}

copy_path() {
  local relative_path="$1"
  local source_path="$REPO_ROOT/$relative_path"
  local target_path="$OUTPUT_DIR/$relative_path"

  if [[ ! -e "$source_path" ]]; then
    echo "[WARN] Missing path, skipping: $relative_path"
    return 0
  fi

  mkdir -p "$(dirname "$target_path")"
  cp -R "$source_path" "$target_path"
}

copy_to_root() {
  local relative_path="$1"
  local target_name="$2"
  local source_path="$REPO_ROOT/$relative_path"

  if [[ ! -e "$source_path" ]]; then
    echo "[WARN] Missing file, skipping: $relative_path"
    return 0
  fi

  cp "$source_path" "$OUTPUT_DIR/$target_name"
}

write_bundle_env() {
  if [[ -f "$REPO_ROOT/.env.production" ]]; then
    cp "$REPO_ROOT/.env.production" "$OUTPUT_DIR/.env"
    cp "$REPO_ROOT/.env.production" "$OUTPUT_DIR/.env.production"
  elif [[ -f "$REPO_ROOT/.env.example" ]]; then
    cp "$REPO_ROOT/.env.example" "$OUTPUT_DIR/.env"
  else
    echo "[FAIL] Neither .env.production nor .env.example exists" >&2
    exit 1
  fi
}

export_images() {
  mkdir -p "$OUTPUT_DIR/images"

  if ! docker image inspect postgres:16-alpine >/dev/null 2>&1; then
    echo "[INFO] Pulling postgres:16-alpine"
    docker pull postgres:16-alpine
  fi

  echo "[INFO] Exporting Docker images"
  docker save -o "$OUTPUT_DIR/images/incluscape-sipmt.tar" incluscape-sipmt:latest
  docker save -o "$OUTPUT_DIR/images/incluscape-ollama.tar" incluscape-ollama:latest
  docker save -o "$OUTPUT_DIR/images/postgres-16-alpine.tar" postgres:16-alpine
}

copy_latest_backup() {
  local latest_backup

  if [[ ! -d "$REPO_ROOT/backups" ]]; then
    echo "[WARN] No backups directory found under $REPO_ROOT"
    return 0
  fi

  latest_backup="$(find "$REPO_ROOT/backups" -maxdepth 1 -type d -name 'sipmt_bundle_*' | sort | tail -n 1 || true)"

  mkdir -p "$OUTPUT_DIR/backups"

  if [[ -z "$latest_backup" ]]; then
    echo "[WARN] No backup directory found under $REPO_ROOT/backups"
    return 0
  fi

  echo "[INFO] Copying latest backup: $(basename "$latest_backup")"
  cp -R "$latest_backup" "$OUTPUT_DIR/backups/"
}

archive_bundle() {
  case "$ARCHIVE_FORMAT" in
    tar.gz)
      create_archive "tar.gz"
      ;;
    zip)
      create_archive "zip"
      ;;
    both)
      create_archive "zip"
      create_archive "tar.gz"
      ;;
    none)
      echo "[INFO] Archive creation skipped"
      ;;
    *)
      echo "[FAIL] Unsupported ARCHIVE_FORMAT: $ARCHIVE_FORMAT (expected: tar.gz, zip, both, none)" >&2
      exit 1
      ;;
  esac
}

write_checksum_manifests() {
  local output_manifest="$OUTPUT_DIR/SHA256SUMS.txt"
  local release_manifest="$(dirname "$OUTPUT_DIR")/$(basename "$OUTPUT_DIR")_SHA256SUMS.txt"
  local rel_path

  : > "$output_manifest"
  : > "$release_manifest"

  if [[ -d "$OUTPUT_DIR/images" ]]; then
    while IFS= read -r -d '' image_path; do
      rel_path="${image_path#$OUTPUT_DIR/}"
      shasum -a 256 "$image_path" | sed "s|  $image_path$|  $rel_path|" >> "$output_manifest"
      shasum -a 256 "$image_path" | sed "s|  $image_path$|  $(basename "$OUTPUT_DIR")/$rel_path|" >> "$release_manifest"
    done < <(find "$OUTPUT_DIR/images" -maxdepth 1 -type f -name '*.tar' -print0 | sort -z)
  fi

  for archive_path in "${ARCHIVE_PATHS[@]}"; do
    if [[ -f "$archive_path" ]]; then
      shasum -a 256 "$archive_path" | sed "s|  $archive_path$|  $(basename "$archive_path")|" >> "$release_manifest"
    fi
  done

  echo "[OK] Checksum manifests created: $output_manifest and $release_manifest"
}

mkdir -p "$OUTPUT_DIR"

echo "[INFO] Creating customer bundle in $OUTPUT_DIR"

if [[ "$BUILD_IMAGES" == "true" ]]; then
  echo "[INFO] Building bundled images"
  (
    cd "$REPO_ROOT"
    docker compose "${COMPOSE_ARGS[@]}" build sipmt ollama
  )
fi

if [[ "$EXPORT_IMAGES" == "true" ]]; then
  export_images
fi

copy_path "Dockerfile"
copy_path "docker-compose.yml"
copy_path "requirements.txt"
copy_path "runtime.txt"
copy_path "setup.py"
copy_path "config.py"
copy_path "README.md"
copy_path "CUSTOMER_RELEASE_CHECKLIST.md"
copy_path "Playbook.pdf"
copy_path ".streamlit"
copy_path "assets"
copy_path "change_tracking"
copy_path "database"
copy_path "document_processing"
copy_path "docker"
copy_path "geospatial"
copy_path "landing_page_assets"
copy_path "reference_templates"
copy_path "scripts"
copy_path "streamlit_app"
copy_path "template_matching"
copy_path "utils"
copy_path "customer_bundle/HANDOVER_INSTRUCTIONS.md"
copy_path "customer_bundle/CUSTOMER_EMAIL_TEMPLATE.md"

copy_to_root "customer_bundle/HANDOVER_INSTRUCTIONS.md" "HANDOVER_INSTRUCTIONS.md"
copy_to_root "customer_bundle/CUSTOMER_EMAIL_TEMPLATE.md" "CUSTOMER_EMAIL_TEMPLATE.md"

write_bundle_env

mkdir -p "$OUTPUT_DIR/backups"

if [[ "$INCLUDE_BACKUP" == "true" ]]; then
  copy_latest_backup
fi

cat > "$OUTPUT_DIR/START_HERE.txt" <<'EOF'
SIPMT customer bundle

1. Review .env and replace POSTGRES_PASSWORD and SECRET_KEY.
2. Load Docker images from the images folder.
3. Start services with docker compose up -d postgres ollama sipmt.
4. Run bash scripts/smoke_test_bundle.sh.
5. Open http://localhost:8501.
6. Use Playbook.pdf in the package root as the refreshed printable Help guide.

See HANDOVER_INSTRUCTIONS.md for the full handover guide.
EOF

if [[ "$ARCHIVE_BUNDLE" == "true" ]]; then
  archive_bundle
fi

write_checksum_manifests

echo "[OK] Customer bundle created: $OUTPUT_DIR"
echo "[INFO] BUILD_IMAGES=$BUILD_IMAGES EXPORT_IMAGES=$EXPORT_IMAGES INCLUDE_BACKUP=$INCLUDE_BACKUP ARCHIVE_BUNDLE=$ARCHIVE_BUNDLE ARCHIVE_FORMAT=$ARCHIVE_FORMAT"