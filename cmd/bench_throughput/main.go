// Throughput stress test: concurrent readers and writers hitting
// SQLite directly (no HTTP, no rate limiting).
//
// Writers: insert messages at full speed.
// Readers: search for IDs, hydrate content, render to Counter.
//
// With -cache flag: readers use an in-memory LRU cache for
// content_id → html, simulating Zulip's memcached pattern.
// Since content rows are immutable, the cache never goes stale.
package main

import (
	"container/list"
	"database/sql"
	"flag"
	"fmt"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "modernc.org/sqlite"
)

// --- LRU Cache ---

type LRUCache struct {
	mu       sync.Mutex
	capacity int
	items    map[int]string   // content_id → html
	order    *list.List       // front = most recent
	elements map[int]*list.Element
	hits     int64
	misses   int64
}

func NewLRUCache(capacity int) *LRUCache {
	return &LRUCache{
		capacity: capacity,
		items:    make(map[int]string),
		order:    list.New(),
		elements: make(map[int]*list.Element),
	}
}

func (c *LRUCache) Get(contentID int) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if html, ok := c.items[contentID]; ok {
		c.order.MoveToFront(c.elements[contentID])
		c.hits++
		return html, true
	}
	c.misses++
	return "", false
}

func (c *LRUCache) Put(contentID int, html string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.items[contentID]; ok {
		c.order.MoveToFront(c.elements[contentID])
		return
	}
	if c.order.Len() >= c.capacity {
		oldest := c.order.Back()
		oldID := oldest.Value.(int)
		c.order.Remove(oldest)
		delete(c.items, oldID)
		delete(c.elements, oldID)
	}
	c.items[contentID] = html
	elem := c.order.PushFront(contentID)
	c.elements[contentID] = elem
}

func (c *LRUCache) Stats() (hits, misses int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.hits, c.misses
}

// --- Counter Writer ---

type Counter struct {
	cnt int64
}

func (c *Counter) Write(p []byte) (int, error) {
	c.cnt += int64(len(p))
	return len(p), nil
}

// --- Main ---

func main() {
	useCache := flag.Bool("cache", false, "enable LRU content cache")
	cacheSize := flag.Int("cache-size", 100000, "LRU cache capacity (content_ids)")
	readers := flag.Int("readers", 4, "number of concurrent readers")
	writers := flag.Int("writers", 1, "number of concurrent writers")
	duration := flag.Duration("duration", 10*time.Second, "test duration")
	flag.Parse()

	// Use a fresh copy of the bench DB.
	db, err := sql.Open("sqlite", "/tmp/gopher_bench.db")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(*readers + *writers + 2)
	db.Exec("PRAGMA journal_mode=WAL")
	db.Exec("PRAGMA busy_timeout=5000")
	db.Exec("PRAGMA cache_size=-200000") // 200MB cache

	var cache *LRUCache
	if *useCache {
		cache = NewLRUCache(*cacheSize)
	}

	// Preload some topic IDs for readers.
	type topicAddr struct {
		channelID int
		topicName string
	}
	rows, _ := db.Query(`SELECT channel_id, topic_name FROM topics LIMIT 50`)
	var topics []topicAddr
	for rows.Next() {
		var t topicAddr
		rows.Scan(&t.channelID, &t.topicName)
		topics = append(topics, t)
	}
	rows.Close()

	var totalReads atomic.Int64
	var totalMsgsRead atomic.Int64
	var totalWrites atomic.Int64
	var totalBytesRendered atomic.Int64

	stop := make(chan struct{})
	var wg sync.WaitGroup

	// Start readers.
	for i := 0; i < *readers; i++ {
		wg.Add(1)
		go func(readerID int) {
			defer wg.Done()
			counter := &Counter{}
			topicIdx := readerID

			for {
				select {
				case <-stop:
					totalBytesRendered.Add(counter.cnt)
					return
				default:
				}

				topic := topics[topicIdx%len(topics)]
				topicIdx++

				// Step 1: get IDs.
				idRows, err := db.Query(`
					SELECT m.id, m.content_id FROM messages m
					JOIN topics t ON m.topic_id = t.topic_id
					WHERE m.channel_id = ? AND t.topic_name = ?
					ORDER BY m.id DESC LIMIT 200`,
					topic.channelID, topic.topicName)
				if err != nil {
					continue
				}

				type msgRef struct {
					id        int
					contentID int
				}
				var refs []msgRef
				for idRows.Next() {
					var r msgRef
					idRows.Scan(&r.id, &r.contentID)
					refs = append(refs, r)
				}
				idRows.Close()

				// Step 2: hydrate, with optional cache.
				var toFetch []int
				cached := 0

				if cache != nil {
					for _, r := range refs {
						if html, ok := cache.Get(r.contentID); ok {
							fmt.Fprintf(counter, "%s", html)
							cached++
						} else {
							toFetch = append(toFetch, r.id)
						}
					}
				} else {
					for _, r := range refs {
						toFetch = append(toFetch, r.id)
					}
				}

				if len(toFetch) > 0 {
					placeholders := make([]string, len(toFetch))
					args := make([]interface{}, len(toFetch))
					for j, id := range toFetch {
						placeholders[j] = "?"
						args[j] = id
					}

					hRows, err := db.Query(fmt.Sprintf(`
						SELECT m.content_id, mc.html
						FROM messages m
						JOIN message_content mc ON m.content_id = mc.content_id
						WHERE m.id IN (%s)`, strings.Join(placeholders, ",")), args...)
					if err == nil {
						for hRows.Next() {
							var contentID int
							var html string
							hRows.Scan(&contentID, &html)
							fmt.Fprintf(counter, "%s", html)
							if cache != nil {
								cache.Put(contentID, html)
							}
						}
						hRows.Close()
					}
				}

				totalReads.Add(1)
				totalMsgsRead.Add(int64(len(refs)))
				refs = refs[:0]
				toFetch = toFetch[:0]
			}
		}(i)
	}

	// Start writers.
	for i := 0; i < *writers; i++ {
		wg.Add(1)
		go func(writerID int) {
			defer wg.Done()
			msgNum := writerID * 100000000

			for {
				select {
				case <-stop:
					return
				default:
				}

				msgNum++
				content := fmt.Sprintf("<p>Stress message %d</p>", msgNum)

				tx, err := db.Begin()
				if err != nil {
					continue
				}
				res, _ := tx.Exec(`INSERT INTO message_content (markdown, html) VALUES (?, ?)`,
					content, content)
				contentID, _ := res.LastInsertId()
				tx.Exec(`INSERT INTO messages (content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, 1, 1, 1, ?)`,
					contentID, time.Now().Unix())
				tx.Commit()

				totalWrites.Add(1)
			}
		}(i)
	}

	// Run for duration, printing stats every second.
	start := time.Now()
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			elapsed := time.Since(start).Truncate(time.Second)
			reads := totalReads.Load()
			msgs := totalMsgsRead.Load()
			writes := totalWrites.Load()

			line := fmt.Sprintf("[%s] reads: %d (%d msgs)  writes: %d",
				elapsed, reads, msgs, writes)
			if cache != nil {
				hits, misses := cache.Stats()
				total := hits + misses
				hitRate := float64(0)
				if total > 0 {
					hitRate = float64(hits) / float64(total) * 100
				}
				line += fmt.Sprintf("  cache: %.1f%% hit (%d/%d)", hitRate, hits, total)
			}
			fmt.Println(line)

			if elapsed >= *duration {
				close(stop)
				wg.Wait()

				fmt.Printf("\n=== Final (%s) ===\n", elapsed)
				fmt.Printf("  Readers: %d, Writers: %d\n", *readers, *writers)
				fmt.Printf("  Total reads: %d (%.0f/sec)\n", reads, float64(reads)/elapsed.Seconds())
				fmt.Printf("  Total messages read: %d (%.0f/sec)\n", msgs, float64(msgs)/elapsed.Seconds())
				fmt.Printf("  Total writes: %d (%.0f/sec)\n", writes, float64(writes)/elapsed.Seconds())
				fmt.Printf("  Bytes rendered: %d\n", totalBytesRendered.Load())
				if cache != nil {
					hits, misses := cache.Stats()
					fmt.Printf("  Cache: %d hits, %d misses (%.1f%% hit rate)\n",
						hits, misses, float64(hits)/float64(hits+misses)*100)
				}
				if !*useCache {
					fmt.Println("\n  (run with -cache to enable LRU content cache)")
				}
				return
			}
		}
	}
}
