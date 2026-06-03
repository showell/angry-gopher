// Channels — Zulip-shaped private group conversations. v1: hardcoded
// private, no creation UI, membership lives in a .channel file on disk.
//
// On-disk layout (mirrors DM transcripts; only the parent dir differs):
//
//	{ChatDataRoot}/channels/<name>.channel        — members config
//	{ChatDataRoot}/channels/<name>/sessions/<topic>.{md,lastauthor,uploads/}
//
// The .channel file is plaintext: one uid per line, blank lines and
// `#`-prefixed comment lines ignored. Re-read on every membership check
// (cheap — it's tens of bytes); edit the file on the host to change
// membership. No reload signal needed.
//
// The rest of the chat machinery (Conv methods, SSE plumbing, fanout)
// treats a channel exactly like a DM — see Conv in chat_conv.go. The
// only differences live here (storage paths, member parsing) and at
// the URL boundary (/channel/<name>/<topic> vs /chat/c/<conv>/<sid>).
package chat

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// channelNameRe is the canonical channel-name shape: a letter, then
// letters/digits/hyphens, 1..40 chars. Excludes digits-only so it can't
// collide with a DM pair key ("1_2"); excludes "_" so the subscriber
// map key <name>/<sid> stays unambiguous; excludes path separators.
var channelNameRe = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9-]{0,39}$`)

// validChannelName reports whether s is a well-formed channel name. The
// chokepoint for URL parsing — a request whose {channel} fails this
// 404s before the name reaches the filesystem.
func validChannelName(s string) bool { return channelNameRe.MatchString(s) }

// channelsDir is the root for channel storage.
func channelsDir() string { return filepath.Join(ChatDataRoot, "channels") }

// channelConfigPath is the .channel file for a channel.
func channelConfigPath(name string) string {
	return filepath.Join(channelsDir(), name+".channel")
}

// readChannelMembers parses a .channel file: one uid per line, blank
// lines and `#`-prefixed comments ignored. Returns the uid list (in
// file order) or an error if the file is missing/unreadable. Caller
// can assume nil-error means a real config exists on disk.
func readChannelMembers(name string) ([]string, error) {
	f, err := os.Open(channelConfigPath(name))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var members []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		members = append(members, line)
	}
	return members, sc.Err()
}

// ChannelConv builds a Conv for a channel by name, reading the config
// file each call (cheap; the file is tens of bytes). Returns ok=false
// if the channel doesn't exist OR uid isn't a member — same opaque 404
// result from the caller's perspective (Alice → 404 on /channel/General,
// without revealing that General exists). Use raw lookups
// (channelExists / readChannelMembers) when you need to distinguish.
func ChannelConv(name, uid string) (Conv, bool) {
	if !validChannelName(name) {
		return Conv{}, false
	}
	members, err := readChannelMembers(name)
	if err != nil {
		return Conv{}, false
	}
	c := Conv{
		Kind:    KindChannel,
		Key:     name,
		Dir:     filepath.Join(channelsDir(), name),
		Members: members,
	}
	if !c.HasMember(uid) {
		return Conv{}, false
	}
	return c, true
}

// ListUserChannels returns every channel uid is a member of, sorted
// alphabetically. Walks {ChatDataRoot}/channels/*.channel. Cheap at v1
// scale (a handful of channels, tens-of-bytes each).
func ListUserChannels(uid string) []string {
	entries, err := os.ReadDir(channelsDir())
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".channel") {
			continue
		}
		name = strings.TrimSuffix(name, ".channel")
		if !validChannelName(name) {
			continue
		}
		members, err := readChannelMembers(name)
		if err != nil {
			continue
		}
		for _, m := range members {
			if m == uid {
				out = append(out, name)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}
