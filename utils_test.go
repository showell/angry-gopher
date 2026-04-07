// Tests for shared utility functions.

package main

import (
	"testing"

	"angry-gopher/respond"
)

func TestPathSegmentInt(t *testing.T) {
	cases := []struct {
		path  string
		index int
		want  int
	}{
		{"/api/v1/messages/42/reactions", 4, 42},
		{"/api/v1/streams/3", 4, 3},
		{"/api/v1/messages/notanumber/reactions", 4, 0},
		{"/short", 4, 0},
		{"", 0, 0},
	}
	for _, tc := range cases {
		got := respond.PathSegmentInt(tc.path, tc.index)
		if got != tc.want {
			t.Errorf("PathSegmentInt(%q, %d) = %d, want %d",
				tc.path, tc.index, got, tc.want)
		}
	}
}
