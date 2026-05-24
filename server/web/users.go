// The user registry: numeric ids are the primary key for everything
// per-user. A name is just a mutable attribute, so changing it (or
// deleting an account) leaves no name-keyed backdoor to the data.
//
// One dir per user under {data_dir}/users/<id>/:
//
//	name      — display name (mutable)
//	password  — bcrypt hash; its existence == the user is a member
//	admin     — its existence == the user has admin powers
//
// {data_dir}/users/next-id.txt is the id counter.
//
// Guests get an id too (allocated at login). Members are looked up by
// name (a small scan); a name is "reserved" iff some member has it.
package web

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// UsersRoot is the on-disk root for the user registry, set by
// SetUsersRoot at startup.
var UsersRoot = "games/lynrummy/users-data"

// SetUsersRoot points the user registry at the configured dir.
func SetUsersRoot(root string) { UsersRoot = root }

// User is a resolved identity. ID is the storage key; the rest are
// attributes for display/authorization.
type User struct {
	ID     string
	Name   string
	Member bool
	Admin  bool
}

func userDir(id string) string     { return filepath.Join(UsersRoot, id) }
func userFile(id, f string) string { return filepath.Join(UsersRoot, id, f) }

// AllocateUser creates a new user with the given name and returns its id.
func AllocateUser(name string) (string, error) {
	n, err := AllocateID(filepath.Join(UsersRoot, "next-id.txt"))
	if err != nil {
		return "", err
	}
	id := strconv.FormatInt(n, 10)
	if err := os.MkdirAll(userDir(id), 0o755); err != nil {
		return "", err
	}
	if err := SetUserName(id, name); err != nil {
		return "", err
	}
	return id, nil
}

// UserExists reports whether an id is a registered user.
func UserExists(id string) bool {
	if strings.TrimSpace(id) == "" {
		return false
	}
	info, err := os.Stat(userDir(id))
	return err == nil && info.IsDir()
}

// GetUserName returns a user's display name (or "").
func GetUserName(id string) string {
	b, err := os.ReadFile(userFile(id, "name"))
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(b), "\r\n")
}

// SetUserName updates a user's display name.
func SetUserName(id, name string) error {
	return os.WriteFile(userFile(id, "name"), []byte(name), 0o644)
}

// SetUserPassword bcrypt-hashes and stores a password (making the user a
// member).
func SetUserPassword(id, password string) error {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	return os.WriteFile(userFile(id, "password"), hash, 0o600)
}

// SetUserPasswordHash stores an already-computed bcrypt hash (migration).
func SetUserPasswordHash(id, hash string) error {
	return os.WriteFile(userFile(id, "password"), []byte(hash), 0o600)
}

// CheckUserPassword verifies a password against a member's stored hash.
func CheckUserPassword(id, password string) bool {
	hash, err := os.ReadFile(userFile(id, "password"))
	if err != nil {
		return false
	}
	return bcrypt.CompareHashAndPassword(hash, []byte(password)) == nil
}

// UserIsMember reports whether a user has a password.
func UserIsMember(id string) bool {
	_, err := os.Stat(userFile(id, "password"))
	return err == nil
}

// SetUserAdmin grants or revokes admin powers.
func SetUserAdmin(id string, admin bool) error {
	p := userFile(id, "admin")
	if admin {
		return os.WriteFile(p, []byte("1\n"), 0o644)
	}
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// UserIsAdmin reports whether a user has admin powers.
func UserIsAdmin(id string) bool {
	_, err := os.Stat(userFile(id, "admin"))
	return err == nil
}

// TouchUser records "now" as a user's last-activity time (bumped on
// login, a chat message, or a Lyn Rummy move). Best-effort — a write
// failure isn't worth surfacing.
func TouchUser(id string) {
	if strings.TrimSpace(id) == "" {
		return
	}
	_ = os.WriteFile(userFile(id, "last-active"),
		[]byte(strconv.FormatInt(time.Now().Unix(), 10)), 0o644)
}

// UserLastActive returns a user's last-activity time, ok=false if never.
func UserLastActive(id string) (time.Time, bool) {
	b, err := os.ReadFile(userFile(id, "last-active"))
	if err != nil {
		return time.Time{}, false
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	return time.Unix(n, 0), true
}

var uploadBytesMu sync.Mutex

// UserUploadBytes returns the cumulative bytes a user has ever uploaded.
func UserUploadBytes(id string) int64 {
	b, err := os.ReadFile(userFile(id, "upload-bytes"))
	if err != nil {
		return 0
	}
	n, _ := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	return n
}

// ReserveUploadBytes atomically adds n to a user's lifetime upload total if
// that stays within cap, returning true; otherwise it changes nothing and
// returns false. Serialized so concurrent uploads can't both slip past.
func ReserveUploadBytes(id string, n, cap int64) bool {
	uploadBytesMu.Lock()
	defer uploadBytesMu.Unlock()
	total := UserUploadBytes(id) + n
	if total > cap {
		return false
	}
	_ = os.WriteFile(userFile(id, "upload-bytes"), []byte(strconv.FormatInt(total, 10)), 0o644)
	return true
}

// LoadUser resolves a full User from an id (zero User if absent).
func LoadUser(id string) User {
	if !UserExists(id) {
		return User{}
	}
	return User{ID: id, Name: GetUserName(id), Member: UserIsMember(id), Admin: UserIsAdmin(id)}
}

// ListUserIDs returns all user ids, sorted numerically.
func ListUserIDs() []string {
	entries, err := os.ReadDir(UsersRoot)
	if err != nil {
		return nil
	}
	ids := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if _, err := strconv.Atoi(e.Name()); err == nil {
			ids = append(ids, e.Name())
		}
	}
	sort.Slice(ids, func(i, j int) bool { return AtoiOr0(ids[i]) < AtoiOr0(ids[j]) })
	return ids
}

func AtoiOr0(s string) int { n, _ := strconv.Atoi(s); return n }

// ListMembers returns every member (users with a password), sorted by id
// — the roster of who you can chat with.
func ListMembers() []User {
	var out []User
	for _, id := range ListUserIDs() {
		if UserIsMember(id) {
			out = append(out, LoadUser(id))
		}
	}
	return out
}

// FindMemberByName returns the id of the member currently using `name`.
func FindMemberByName(name string) (string, bool) {
	for _, id := range ListUserIDs() {
		if UserIsMember(id) && GetUserName(id) == name {
			return id, true
		}
	}
	return "", false
}

// IsNameReserved reports whether a member currently holds `name`.
func IsNameReserved(name string) bool {
	_, ok := FindMemberByName(name)
	return ok
}

// DeleteUserRecord removes a user's registry entry (name/password/admin).
// Game and chat data are removed separately.
func DeleteUserRecord(id string) error {
	if strings.TrimSpace(id) == "" {
		return nil
	}
	return os.RemoveAll(userDir(id))
}
