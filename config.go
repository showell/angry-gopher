// Server configuration, loaded from a single hand-edited file.
//
// The format is flat `key = value` with `#` comments — chosen over
// JSON so the file (which carries secrets) can be annotated, and so
// there are zero parsing dependencies. Go is the only reader; the
// file is written by hand exactly twice (local dev + the web host).
//
// Example (~/AngryGopher/gopher.conf):
//
//   # Angry Gopher server config
//   port     = 9000
//   data_dir = /home/steve/AngryGopher/prod
//
//   # Zulip login pings
//   zulip_url     = https://example.zulipchat.com
//   zulip_email   = bot@example.com
//   zulip_api_key = ...
//
// data_dir holds gopher's writable state; session data lives under
// {data_dir}/lynrummy/{user}/.

package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type ServerConfig struct {
	Port        int
	DataDir     string
	ZulipURL    string
	ZulipEmail  string
	ZulipAPIKey string
}

func (c *ServerConfig) ListenAddr() string {
	return fmt.Sprintf(":%d", c.Port)
}

// SessionsDataRoot is the root for all on-disk game/puzzle session
// data. One level down is the username; see views.SetDataRoot.
func (c *ServerConfig) SessionsDataRoot() string {
	return filepath.Join(c.DataDir, "lynrummy")
}

// EnsureDirectories creates data_dir and the sessions root if absent.
func (c *ServerConfig) EnsureDirectories() error {
	if err := os.MkdirAll(c.DataDir, 0o755); err != nil {
		return fmt.Errorf("cannot create data_dir: %w", err)
	}
	if err := os.MkdirAll(c.SessionsDataRoot(), 0o755); err != nil {
		return fmt.Errorf("cannot create sessions root: %w", err)
	}
	return nil
}

func loadConfig(path string) (*ServerConfig, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read config file: %w", err)
	}
	defer f.Close()

	c := &ServerConfig{}
	scanner := bufio.NewScanner(f)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("line %d: expected `key = value`, got %q", lineNo, line)
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		switch key {
		case "port":
			n, err := strconv.Atoi(val)
			if err != nil {
				return nil, fmt.Errorf("line %d: port must be a number, got %q", lineNo, val)
			}
			c.Port = n
		case "data_dir":
			c.DataDir = expandHome(val)
		case "zulip_url":
			c.ZulipURL = val
		case "zulip_email":
			c.ZulipEmail = val
		case "zulip_api_key":
			c.ZulipAPIKey = val
		default:
			fmt.Fprintf(os.Stderr, "config: ignoring unknown key %q (line %d)\n", key, lineNo)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	if c.Port == 0 {
		return nil, fmt.Errorf("port is required")
	}
	if c.DataDir == "" {
		return nil, fmt.Errorf("data_dir is required")
	}
	return c, nil
}

// expandHome turns a leading `~/` into the user's home directory so
// the hand-edited file can use the shorthand.
func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(strings.TrimPrefix(p, "~"), "/"))
		}
	}
	return p
}
