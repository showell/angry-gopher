// Server configuration loaded from a JSON file.
//
// The config file specifies the deployment mode, root directory for
// data, and the port to listen on. Example:
//
//   {
//       "mode": "prod",
//       "root": "/home/steve/AngryGopher/prod",
//       "port": 9000
//   }
//
// The server auto-creates the root directory and its subdirectories:
//   {root}/gopher.db    — SQLite database
//   {root}/uploads/     — uploaded files

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type ServerConfig struct {
	Mode string `json:"mode"` // "prod" — only mode now (demo retired 2026-04-28)
	Root string `json:"root"` // root directory for data
	Port int    `json:"port"` // port to listen on
}

func (c *ServerConfig) DBPath() string {
	return filepath.Join(c.Root, "gopher.db")
}

func (c *ServerConfig) UploadsDir() string {
	return filepath.Join(c.Root, "uploads")
}

func (c *ServerConfig) ListenAddr() string {
	return fmt.Sprintf(":%d", c.Port)
}

func loadConfig(path string) (*ServerConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read config file: %w", err)
	}

	var config ServerConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("invalid config JSON: %w", err)
	}

	if config.Mode != "prod" {
		return nil, fmt.Errorf("mode must be \"prod\", got %q", config.Mode)
	}
	if config.Root == "" {
		return nil, fmt.Errorf("root is required")
	}
	if config.Port == 0 {
		return nil, fmt.Errorf("port is required")
	}

	return &config, nil
}

// ensureDirectories creates the root and uploads directories if
// they don't exist.
func (c *ServerConfig) EnsureDirectories() error {
	if err := os.MkdirAll(c.Root, 0755); err != nil {
		return fmt.Errorf("cannot create root directory: %w", err)
	}
	if err := os.MkdirAll(c.UploadsDir(), 0755); err != nil {
		return fmt.Errorf("cannot create uploads directory: %w", err)
	}
	return nil
}
