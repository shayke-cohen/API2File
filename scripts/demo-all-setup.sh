#!/bin/bash
# demo-all-setup.sh — Set up all 5 demo adapters for API2File showcase
# Each adapter simulates a different real-world service with different file formats.

set -e

API2FILE_DIR="$HOME/API2File"
SERVICES=("teamboard" "peoplehub" "calsync" "pagecraft" "devops" "mediamanager")

echo "=== API2File Demo Showcase Setup ==="
echo ""

# Create base directory
mkdir -p "$API2FILE_DIR"

for service in "${SERVICES[@]}"; do
  echo "Setting up: $service"
  SERVICE_DIR="$API2FILE_DIR/$service"
  mkdir -p "$SERVICE_DIR/.api2file"

  # Write adapter config
  case "$service" in
    teamboard)
      cat > "$SERVICE_DIR/.api2file/adapter.json" << 'ADAPTER_EOF'
{
  "service": "teamboard",
  "displayName": "TeamBoard — Project Management",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.teamboard.key",
    "setup": { "instructions": "Demo adapter — no real auth needed." }
  },
  "globals": {
    "baseUrl": "http://localhost:8089",
    "headers": { "Content-Type": "application/json" }
  },
  "resources": [
    {
      "name": "tasks",
      "description": "Project tasks (CSV)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/tasks", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/tasks" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/tasks/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/tasks/{id}" }
      },
      "fileMapping": { "strategy": "collection", "directory": ".", "filename": "tasks.csv", "format": "csv", "idField": "id" },
      "sync": { "interval": 15, "debounceMs": 500 }
    },
    {
      "name": "config",
      "description": "Project settings (YAML)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/config", "dataPath": "$" },
      "push": { "update": { "method": "PUT", "url": "http://localhost:8089/api/config" } },
      "fileMapping": { "strategy": "collection", "directory": ".", "filename": "settings.yaml", "format": "yaml", "idField": "id" },
      "sync": { "interval": 15, "debounceMs": 500 }
    }
  ]
}
ADAPTER_EOF
      ;;

    peoplehub)
      cat > "$SERVICE_DIR/.api2file/adapter.json" << 'ADAPTER_EOF'
{
  "service": "peoplehub",
  "displayName": "PeopleHub — CRM & Contacts",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.peoplehub.key",
    "setup": { "instructions": "Demo adapter — no real auth needed." }
  },
  "globals": {
    "baseUrl": "http://localhost:8089",
    "headers": { "Content-Type": "application/json" }
  },
  "resources": [
    {
      "name": "contacts",
      "description": "Contact cards (VCF)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/contacts", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/contacts" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/contacts/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/contacts/{id}" }
      },
      "fileMapping": { "strategy": "one-per-record", "directory": "contacts", "filename": "{firstName|slugify}-{lastName|slugify}.vcf", "format": "vcf", "idField": "id" },
      "sync": { "interval": 20, "debounceMs": 500 }
    },
    {
      "name": "notes",
      "description": "Meeting notes (Markdown)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/notes", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/notes" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/notes/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/notes/{id}" }
      },
      "fileMapping": { "strategy": "one-per-record", "directory": "notes", "filename": "{title|slugify}.md", "format": "md", "idField": "id", "contentField": "content" },
      "sync": { "interval": 20, "debounceMs": 500 }
    }
  ]
}
ADAPTER_EOF
      ;;

    calsync)
      cat > "$SERVICE_DIR/.api2file/adapter.json" << 'ADAPTER_EOF'
{
  "service": "calsync",
  "displayName": "CalSync — Calendar & Scheduling",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.calsync.key",
    "setup": { "instructions": "Demo adapter — no real auth needed." }
  },
  "globals": {
    "baseUrl": "http://localhost:8089",
    "headers": { "Content-Type": "application/json" }
  },
  "resources": [
    {
      "name": "events",
      "description": "Calendar events (ICS)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/events", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/events" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/events/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/events/{id}" }
      },
      "fileMapping": { "strategy": "collection", "directory": ".", "filename": "calendar.ics", "format": "ics", "idField": "id" },
      "sync": { "interval": 10, "debounceMs": 500 }
    },
    {
      "name": "action-items",
      "description": "Tasks as action items (CSV)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/tasks", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/tasks" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/tasks/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/tasks/{id}" }
      },
      "fileMapping": { "strategy": "collection", "directory": ".", "filename": "action-items.csv", "format": "csv", "idField": "id" },
      "sync": { "interval": 10, "debounceMs": 500 }
    }
  ]
}
ADAPTER_EOF
      ;;

    pagecraft)
      cat > "$SERVICE_DIR/.api2file/adapter.json" << 'ADAPTER_EOF'
{
  "service": "pagecraft",
  "displayName": "PageCraft — CMS & Website Builder",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.pagecraft.key",
    "setup": { "instructions": "Demo adapter — no real auth needed." }
  },
  "globals": {
    "baseUrl": "http://localhost:8089",
    "headers": { "Content-Type": "application/json" }
  },
  "resources": [
    {
      "name": "pages",
      "description": "Web pages (HTML)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/pages", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/pages" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/pages/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/pages/{id}" }
      },
      "fileMapping": { "strategy": "one-per-record", "directory": "pages", "filename": "{slug}.html", "format": "html", "idField": "id", "contentField": "content" },
      "sync": { "interval": 15, "debounceMs": 500 }
    },
    {
      "name": "blog-posts",
      "description": "Blog posts (Markdown)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/notes", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/notes" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/notes/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/notes/{id}" }
      },
      "fileMapping": { "strategy": "one-per-record", "directory": "blog", "filename": "{title|slugify}.md", "format": "md", "idField": "id", "contentField": "content" },
      "sync": { "interval": 15, "debounceMs": 500 }
    },
    {
      "name": "config",
      "description": "Site configuration (JSON)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/config", "dataPath": "$" },
      "push": { "update": { "method": "PUT", "url": "http://localhost:8089/api/config" } },
      "fileMapping": { "strategy": "collection", "directory": ".", "filename": "site.json", "format": "json", "idField": "id" },
      "sync": { "interval": 15, "debounceMs": 500 }
    }
  ]
}
ADAPTER_EOF
      ;;

    mediamanager)
      cat > "$SERVICE_DIR/.api2file/adapter.json" << 'ADAPTER_EOF'
{
  "service": "mediamanager",
  "displayName": "MediaManager — Digital Asset Manager",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.mediamanager.key",
    "setup": { "instructions": "Demo adapter — no real auth needed." }
  },
  "globals": {
    "baseUrl": "http://localhost:8089",
    "headers": { "Content-Type": "application/json" }
  },
  "resources": [
    {
      "name": "logos",
      "description": "SVG vector logos",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/logos", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/logos" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/logos/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/logos/{id}" }
      },
      "fileMapping": { "strategy": "one-per-record", "directory": "logos", "filename": "{name|slugify}.svg", "format": "svg", "idField": "id", "contentField": "content" },
      "sync": { "interval": 15, "debounceMs": 500 }
    },
    {
      "name": "photos",
      "description": "PNG images (base64)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/photos", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/photos" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/photos/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/photos/{id}" }
      },
      "fileMapping": { "strategy": "one-per-record", "directory": "photos", "filename": "{name|slugify}.png", "format": "raw", "idField": "id" },
      "sync": { "interval": 15, "debounceMs": 500 }
    },
    {
      "name": "documents",
      "description": "PDF documents (base64)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/documents", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/documents" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/documents/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/documents/{id}" }
      },
      "fileMapping": { "strategy": "one-per-record", "directory": "documents", "filename": "{name|slugify}.pdf", "format": "raw", "idField": "id" },
      "sync": { "interval": 15, "debounceMs": 500 }
    }
  ]
}
ADAPTER_EOF
      ;;

    devops)
      cat > "$SERVICE_DIR/.api2file/adapter.json" << 'ADAPTER_EOF'
{
  "service": "devops",
  "displayName": "DevOps — Infrastructure Monitoring",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.devops.key",
    "setup": { "instructions": "Demo adapter — no real auth needed." }
  },
  "globals": {
    "baseUrl": "http://localhost:8089",
    "headers": { "Content-Type": "application/json" }
  },
  "resources": [
    {
      "name": "services",
      "description": "Microservice health (JSON)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/services", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/services" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/services/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/services/{id}" }
      },
      "fileMapping": { "strategy": "one-per-record", "directory": "services", "filename": "{name|slugify}.json", "format": "json", "idField": "id" },
      "sync": { "interval": 10, "debounceMs": 500 }
    },
    {
      "name": "incidents",
      "description": "Operational incidents (CSV)",
      "pull": { "method": "GET", "url": "http://localhost:8089/api/incidents", "dataPath": "$" },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/incidents" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/incidents/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/incidents/{id}" }
      },
      "fileMapping": { "strategy": "collection", "directory": ".", "filename": "incidents.csv", "format": "csv", "idField": "id" },
      "sync": { "interval": 10, "debounceMs": 500 }
    }
  ]
}
ADAPTER_EOF
      ;;
  esac

  # Add dummy keychain entry (ignore errors if already exists)
  security add-generic-password \
    -a "com.api2file.api2file.${service}.key" \
    -s "com.api2file.api2file.${service}.key" \
    -w "demo-token" \
    -U 2>/dev/null || true

  # Initialize git repo if not already
  if [ ! -d "$SERVICE_DIR/.git" ]; then
    (cd "$SERVICE_DIR" && git init -q && echo ".api2file/" > .gitignore && git add .gitignore && git commit -q -m "init: $service adapter")
  fi

  echo "  ✓ $service ready at $SERVICE_DIR"
done

echo ""
echo "=== Setup Complete ==="
echo ""
echo "6 demo adapters configured under ~/API2File/:"
echo "  teamboard/      — Project management (CSV + YAML)"
echo "  peoplehub/      — CRM & contacts (VCF + Markdown)"
echo "  calsync/        — Calendar (ICS + CSV)"
echo "  pagecraft/      — Website builder (HTML + Markdown + JSON)"
echo "  devops/         — Infrastructure (JSON + CSV)"
echo "  mediamanager/   — Digital assets (SVG + PNG + PDF)"
echo ""
echo "Start the demo server:"
echo "  swift run api2file-demo"
echo ""
echo "Try these commands after a sync:"
echo "  open ~/API2File/calsync/calendar.ics              # Opens in Calendar.app"
echo "  open ~/API2File/peoplehub/contacts/                # VCF files → Contacts.app"
echo "  open ~/API2File/teamboard/tasks.csv                # Opens in Numbers"
echo "  open ~/API2File/pagecraft/pages/home.html          # Opens in Safari"
echo "  open ~/API2File/mediamanager/logos/app-icon.svg     # Opens in Preview"
echo "  open ~/API2File/mediamanager/photos/red-swatch.png  # Opens in Preview"
echo "  open ~/API2File/mediamanager/documents/q1-report.pdf # Opens in Preview"
