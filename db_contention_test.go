// Focused test for SQLite contention under concurrent writes.
//
// No HTTP, no rate limiting, no event delivery — just goroutines
// calling SendMessage directly against a file-based DB.

package main

import (
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"testing"

	"angry-gopher/messages"
)

func setupFileDB(t *testing.T, dbPath string) {
	t.Helper()
	os.Setenv("GOPHER_RESET_DB", "1")
	defer os.Unsetenv("GOPHER_RESET_DB")

	initDB(dbPath)
	wireDB()
	seedData(false)

	t.Cleanup(func() { os.Remove(dbPath) })
}

// 4 goroutines each call SendMessage 100 times to the same channel.
// All writes should succeed — zero errors.
func TestDB_ConcurrentSendMessage(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping slow contention test")
	}
	setupFileDB(t, "test_contention.db")

	const numWorkers = 4
	const messagesPerWorker = 100

	var wg sync.WaitGroup
	var errorCount int32

	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for i := 0; i < messagesPerWorker; i++ {
				_, err := messages.SendMessage(
					1, // senderID (Steve)
					3, // channelID (ChitChat, public)
					"load test",
					fmt.Sprintf("worker %d message %d", workerID, i),
				)
				if err != nil {
					atomic.AddInt32(&errorCount, 1)
					t.Logf("worker %d msg %d: %v", workerID, i, err)
				}
			}
		}(w)
	}

	wg.Wait()

	errors := int(atomic.LoadInt32(&errorCount))
	expectedTotal := numWorkers * messagesPerWorker

	var dbCount int
	DB.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = 3`).Scan(&dbCount)

	t.Logf("Results: %d sent, %d errors, %d in DB", expectedTotal, errors, dbCount)

	if errors > 0 {
		t.Errorf("%d send errors out of %d attempts", errors, expectedTotal)
	}
	if dbCount != expectedTotal {
		t.Errorf("expected %d messages in DB, got %d", expectedTotal, dbCount)
	}
}
