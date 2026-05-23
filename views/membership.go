// Chat membership: a name becomes a "member" by setting a password, which
// also reserves the name. Membership is a chat concept — Lyn Rummy itself
// stays identity-only — so it lives under the chat data tree, not the
// game tree: a bcrypt hash at {chat}/_members/<name> (the leading
// underscore can't appear in a username or a conversation key, so it
// never collides). Existence of that file == the name is reserved.
package views

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

func chatMembersDir() string      { return filepath.Join(ChatDataRoot, "_members") }
func memberPath(name string) string { return filepath.Join(chatMembersDir(), name) }

// IsReserved reports whether a name is claimed by a member's password.
func IsReserved(name string) bool {
	if strings.TrimSpace(name) == "" {
		return false
	}
	info, err := os.Stat(memberPath(name))
	return err == nil && !info.IsDir()
}

// SetMemberPassword bcrypt-hashes and stores a member's password,
// reserving the name.
func SetMemberPassword(name, password string) error {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(chatMembersDir(), 0o755); err != nil {
		return err
	}
	return os.WriteFile(memberPath(name), hash, 0o600)
}

// CheckMemberPassword verifies a password against the stored hash.
func CheckMemberPassword(name, password string) bool {
	hash, err := os.ReadFile(memberPath(name))
	if err != nil {
		return false
	}
	return bcrypt.CompareHashAndPassword(hash, []byte(password)) == nil
}

// HashPassword returns a bcrypt hash. Used to carry an unconfirmed
// password between the two account-creation steps without ever putting
// the plaintext in the page.
func HashPassword(password string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	return string(h), err
}

// PasswordMatchesHash reports whether a password matches a bcrypt hash.
func PasswordMatchesHash(hash, password string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

// ReleaseMember removes a member's password, freeing the reserved name.
func ReleaseMember(name string) error {
	if strings.TrimSpace(name) == "" {
		return nil
	}
	if err := os.Remove(memberPath(name)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// ListMembers returns every member (password-holding) name, sorted — the
// roster of who you can chat with.
func ListMembers() []string {
	entries, err := os.ReadDir(chatMembersDir())
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}
