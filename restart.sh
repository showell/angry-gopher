#!/bin/bash
# Kill existing servers, rebuild Angry Gopher, start both servers.
set -e

lsof -ti:9000 | xargs kill -9 2>/dev/null || true
lsof -ti:8000 | xargs kill -9 2>/dev/null || true
sleep 0.5

cd ~/showell_repos/angry-gopher
go build -o gopher-server . 2>/dev/null
GOPHER_DB=seed.db GOPHER_SEED=1 nohup ./gopher-server > /tmp/angry-gopher.log 2>&1 &

cd ~/showell_repos/angry-cat
nohup npx vite --port 8000 > /tmp/angry-cat.log 2>&1 &

# Wait for both to be ready.
for i in $(seq 1 10); do
    GOPHER=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9000/api/v1/users 2>/dev/null || true)
    CAT=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/ 2>/dev/null || true)
    if [ "$GOPHER" = "200" ] && [ "$CAT" = "200" ]; then
        echo "Gopher: http://localhost:9000 (ready)"
        echo "Cat:    http://localhost:8000 (ready)"
        exit 0
    fi
    sleep 1
done

echo "Warning: servers may not be fully ready yet"
